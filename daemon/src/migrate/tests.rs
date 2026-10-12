//! Tests of the archive: the round trip, every kind of hostile archive, the manifest checks, the history rules and the
//! registry. Every test makes its own temp folder and removes only that.

use super::*;
use crate::event::{EventBody, Source};
use crate::store::NewAgent;
use crate::store::now_ms;
use std::os::unix::fs::{PermissionsExt, symlink};
use tempfile::TempDir;

// ---- a tar writer of our own, so a test can write what a careful tool never would ----

fn put_octal(field: &mut [u8], value: u64) {
    let width = field.len() - 1;
    let text = format!("{value:0width$o}");
    field[..width].copy_from_slice(text.as_bytes());
    field[width] = 0;
}

pub(crate) fn header(name: &[u8], flag: u8, size: u64, mode: u32, link: &[u8]) -> [u8; 512] {
    let mut h = [0u8; 512];
    let n = name.len().min(100);
    h[..n].copy_from_slice(&name[..n]);
    put_octal(&mut h[100..108], u64::from(mode));
    put_octal(&mut h[108..116], 0);
    put_octal(&mut h[116..124], 0);
    put_octal(&mut h[124..136], size);
    put_octal(&mut h[136..148], 0);
    h[148..156].fill(b' ');
    h[156] = flag;
    let l = link.len().min(100);
    h[157..157 + l].copy_from_slice(&link[..l]);
    h[257..265].copy_from_slice(b"ustar  \0");
    let sum: u64 = h.iter().map(|b| u64::from(*b)).sum();
    let text = format!("{sum:06o}\0 ");
    h[148..156].copy_from_slice(text.as_bytes());
    h
}

/// A tar stream under construction.
#[derive(Default)]
pub(crate) struct Tar(pub(crate) Vec<u8>);

impl Tar {
    pub(crate) fn raw(mut self, name: &[u8], flag: u8, data: &[u8], link: &[u8]) -> Self {
        self.0
            .extend_from_slice(&header(name, flag, data.len() as u64, 0o644, link));
        self.0.extend_from_slice(data);
        let pad = (512 - data.len() % 512) % 512;
        self.0.extend(std::iter::repeat_n(0u8, pad));
        self
    }

    pub(crate) fn file(self, name: &str, data: &[u8]) -> Self {
        self.raw(name.as_bytes(), b'0', data, b"")
    }

    pub(crate) fn dir(self, name: &str) -> Self {
        self.raw(name.as_bytes(), b'5', b"", b"")
    }

    pub(crate) fn long_file(self, name: &str, data: &[u8]) -> Self {
        let mut long = name.as_bytes().to_vec();
        long.push(0);
        self.raw(b"././@LongLink", b'L', &long, b"")
            .raw(b"placeholder", b'0', data, b"")
    }

    pub(crate) fn finish(mut self) -> Vec<u8> {
        self.0.extend(std::iter::repeat_n(0u8, 1024));
        self.0
    }
}

pub(crate) fn gz(tar: &[u8]) -> Vec<u8> {
    let mut enc = GzEncoder::new(Vec::new(), Compression::fast());
    enc.write_all(tar).unwrap();
    enc.finish().unwrap()
}

/// The manifest of an archive with these files (the manifest itself and folders are not listed).
pub(crate) fn manifest_for(files: &[(&str, &[u8])], events_count: u64) -> Manifest {
    Manifest {
        format: FORMAT,
        bandito_version: "0.1.11".into(),
        agent: AgentSpec {
            name: "Scout".into(),
            role: "Finds sources".into(),
            runtime: RuntimeKind::Claude,
            model: None,
            approval_mode: ApprovalMode::Risky,
            system_prompt: Some("Find sources.".into()),
            effort: None,
            memory_mode: MemoryMode::Smart,
            context_budget: None,
            fallback_runtime: None,
            fallback_model: None,
            use_personal_settings: false,
            avatar: None,
            capabilities: None,
            services: vec![],
            schedules: vec![],
            source_home: None,
        },
        events_count,
        files: files
            .iter()
            .map(|(path, data)| FileEntry {
                path: (*path).to_string(),
                size: data.len() as u64,
                sha256: sha_hex(data),
            })
            .collect(),
        skipped: vec![],
    }
}

pub(crate) const EVENT_LINE: &str =
    "{\"seq\":1,\"ts\":10,\"kind\":\"message.assistant\",\"payload\":{\"text\":\"hi\"}}\n";

/// A good archive of these memory files (events.jsonl holds one event), written with our own tar writer.
fn good_tar(memory: &[(&str, &[u8])]) -> Tar {
    let mut files: Vec<(String, Vec<u8>)> = vec![("events.jsonl".into(), EVENT_LINE.as_bytes().to_vec())];
    for (path, data) in memory {
        files.push((format!("memory/{path}"), data.to_vec()));
    }
    let listed: Vec<(&str, &[u8])> = files.iter().map(|(p, d)| (p.as_str(), d.as_slice())).collect();
    let manifest = serde_json::to_vec(&manifest_for(&listed, 1)).unwrap();
    let mut tar = Tar::default().dir("memory/");
    for (path, data) in &files {
        tar = tar.file(path, data);
    }
    tar.file("manifest.json", &manifest)
}

struct Fixture {
    dir: TempDir,
}

impl Fixture {
    fn new() -> Self {
        Self {
            dir: TempDir::new().unwrap(),
        }
    }

    fn archive(&self, bytes: &[u8]) -> PathBuf {
        let path = self.dir.path().join("in.tgz");
        std::fs::write(&path, bytes).unwrap();
        path
    }

    fn dest(&self) -> PathBuf {
        self.dir.path().join("work").join("x-1")
    }

    /// Unpacks `tar` (gzipped here) into a folder inside `work/`; the parent holds a canary a bad path would hit.
    fn unpack(&self, tar: Vec<u8>, limits: &Limits) -> Result<Unpacked> {
        std::fs::create_dir_all(self.dir.path().join("work")).unwrap();
        std::fs::write(self.dir.path().join("work").join("canary"), b"keep").unwrap();
        unpack(&self.archive(&gz(&tar)), &self.dest(), limits)
    }

    /// Nothing was written next to or above the unpack folder, and the folder itself is gone.
    fn assert_contained(&self) {
        let work: Vec<String> = std::fs::read_dir(self.dir.path().join("work"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(work, vec!["canary".to_string()], "only the canary is left in work/");
        assert_eq!(
            std::fs::read(self.dir.path().join("work").join("canary")).unwrap(),
            b"keep"
        );
        let top: Vec<String> = std::fs::read_dir(self.dir.path())
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(
            top.iter().all(|n| n == "work" || n == "in.tgz"),
            "stray entries: {top:?}"
        );
    }
}

fn reason(e: Result<Unpacked>) -> &'static str {
    e.expect_err("the archive must be refused").reason
}

// ---- the round trip ----

fn new_agent(store: &Store, name: &str) -> Agent {
    let n: NewAgent = serde_json::from_value(serde_json::json!({
        "name": name,
        "runtime": "claude",
        "role": "builder",
        "model": "opus",
        "approval_mode": "always",
        "system_prompt": "Build things.",
        "effort": "high",
        "memory_mode": "daily",
        "context_budget": 50000,
        "capabilities": ["terminal", "files"],
        "avatar": {"color": "#112233", "face": "Fx", "emoji": "x"},
    }))
    .unwrap();
    store.agent_create(n).unwrap()
}

fn user(text: &str) -> EventBody {
    EventBody::MessageUser {
        text: text.into(),
        source: Source::User,
        from_agent: None,
        command: None,
        reply_to: None,
        attachments: vec![],
        mentions: vec![],
        via_button: false,
        schedule: None,
        queued: false,
    }
}

#[test]
fn an_exported_agent_unpacks_with_its_settings_files_and_history() {
    let fx = Fixture::new();
    let store = Store::open_in_memory().unwrap();
    let agent = new_agent(&store, "Forge");
    let home = fx.dir.path().join("home");
    std::fs::create_dir_all(home.join("notes")).unwrap();
    std::fs::create_dir_all(home.join("journal")).unwrap();
    std::fs::create_dir_all(home.join(".git")).unwrap();
    std::fs::write(home.join(".git/config"), "[core]").unwrap();
    std::fs::write(home.join(".bandito-agent"), &agent.id).unwrap();
    std::fs::write(home.join("MEMORY.md"), "# Memory\nfacts").unwrap();
    std::fs::write(home.join("notes/a.md"), "note a").unwrap();
    std::fs::write(home.join("notes/ünï.md"), "unicode name").unwrap();
    std::fs::write(home.join("run.sh"), "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(home.join("run.sh"), std::fs::Permissions::from_mode(0o755)).unwrap();
    symlink("/etc/passwd", home.join("link")).unwrap();
    store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
    let agent = store.agent_get(&agent.id).unwrap().unwrap();

    store.append_event(&agent.id, user("hello")).unwrap();
    store
        .append_event(&agent.id, EventBody::MessageAssistant { text: "hi".into() })
        .unwrap();
    store
        .append_event(
            &agent.id,
            EventBody::ApprovalRequested {
                approval_id: "a1".into(),
                call_id: "c1".into(),
                tool: "Bash".into(),
                title: "ls".into(),
                command: None,
                diff: None,
                reason: "r".into(),
                input: None,
            },
        )
        .unwrap();
    store
        .append_event(
            &agent.id,
            EventBody::AgentStatus {
                status: crate::event::AgentStatus::Idle,
                detail: None,
            },
        )
        .unwrap();
    let other = new_agent(&store, "Other");
    store.append_event(&other.id, user("not mine")).unwrap();

    let run = fx.dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    let schedules = vec![ScheduleSpec {
        cron: "0 9 * * *".into(),
        tz: "UTC".into(),
        prompt: "Digest".into(),
        title: Some("Morning".into()),
    }];
    let made = export_archive(
        ExportInput {
            store: &store,
            agent: &agent,
            services: vec!["notion".into()],
            schedules,
            avatar: Some(("png", b"\x89PNG\r\n\x1a\nxx".to_vec())),
        },
        &run,
        "tok",
        &Limits::default(),
    )
    .unwrap();
    assert_eq!(
        made.events, 2,
        "messages only: no approval, no status, no other agent's"
    );
    assert!(made.skipped >= 2, "the link and .git are named");
    let archive = run.join("tok.tgz");
    assert_eq!(std::fs::metadata(&archive).unwrap().len(), made.size);
    assert_eq!(
        std::fs::metadata(&archive).unwrap().permissions().mode() & 0o777,
        0o600,
        "the archive is private"
    );
    assert_eq!(
        hex::encode(Sha256::digest(std::fs::read(&archive).unwrap())),
        made.sha256
    );
    assert!(!run.join("ev-tok.tmp").exists(), "the history temp file is gone");

    let dest = fx.dir.path().join("x-1");
    let un = unpack(&archive, &dest, &Limits::default()).unwrap();
    let m = &un.manifest;
    assert_eq!((m.format, m.events_count), (FORMAT, 2));
    assert_eq!(m.agent.name, "Forge");
    assert_eq!(m.agent.role, "builder");
    assert_eq!(m.agent.model.as_deref(), Some("opus"));
    assert_eq!(m.agent.approval_mode, ApprovalMode::Always);
    assert_eq!(m.agent.system_prompt.as_deref(), Some("Build things."));
    assert_eq!(m.agent.effort, Some(Effort::High));
    assert_eq!(m.agent.memory_mode, MemoryMode::Daily);
    assert_eq!(m.agent.context_budget, Some(50_000));
    assert_eq!(
        m.agent.capabilities,
        Some(vec![Capability::Terminal, Capability::Files])
    );
    assert_eq!(m.agent.services, vec!["notion".to_string()]);
    assert_eq!(m.agent.schedules.len(), 1);
    assert_eq!(
        m.agent.source_home.as_deref(),
        Some(home.display().to_string().as_str())
    );
    assert_eq!(m.agent.avatar.as_ref().unwrap().color, "#112233");
    assert!(m.skipped.iter().any(|s| s.contains("link")));
    assert!(m.skipped.iter().any(|s| s.contains(".git")));

    assert_eq!(
        std::fs::read_to_string(un.memory.join("MEMORY.md")).unwrap(),
        "# Memory\nfacts"
    );
    assert_eq!(std::fs::read_to_string(un.memory.join("notes/a.md")).unwrap(), "note a");
    assert_eq!(
        std::fs::read_to_string(un.memory.join("notes/ünï.md")).unwrap(),
        "unicode name"
    );
    assert!(un.memory.join("journal").is_dir(), "an empty folder survives");
    assert!(!un.memory.join("link").exists(), "a link is not carried");
    assert!(!un.memory.join(".git").exists());
    assert!(!un.memory.join(".bandito-agent").exists(), "the marker is not carried");
    let mode = |p: &str| std::fs::metadata(un.memory.join(p)).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode("MEMORY.md"), 0o600);
    assert_eq!(mode("run.sh"), 0o600, "the executable bit is dropped");
    assert!(un.avatar.as_ref().unwrap().ends_with("avatar.png"));

    let lines: Vec<String> = std::fs::read_to_string(&un.events)
        .unwrap()
        .lines()
        .map(str::to_string)
        .collect();
    assert_eq!(lines.len(), 2);
    assert!(
        lines[0].contains("\"hello\"") && lines[1].contains("\"hi\""),
        "in order"
    );
    assert_eq!(check_events(&un.events, 2, &Limits::default()).unwrap(), 2);
}

#[test]
fn a_long_memory_path_survives_the_round_trip() {
    let fx = Fixture::new();
    let store = Store::open_in_memory().unwrap();
    let agent = new_agent(&store, "Forge");
    let home = fx.dir.path().join("home");
    let deep = format!("{}/{}/{}", "d".repeat(90), "e".repeat(90), "f".repeat(90));
    std::fs::create_dir_all(home.join(&deep)).unwrap();
    std::fs::write(home.join(&deep).join("note.md"), "deep").unwrap();
    store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
    let agent = store.agent_get(&agent.id).unwrap().unwrap();
    let run = fx.dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    export_archive(
        ExportInput {
            store: &store,
            agent: &agent,
            services: vec![],
            schedules: vec![],
            avatar: None,
        },
        &run,
        "tok",
        &Limits::default(),
    )
    .unwrap();
    let un = unpack(&run.join("tok.tgz"), &fx.dir.path().join("x-1"), &Limits::default()).unwrap();
    assert_eq!(
        std::fs::read_to_string(un.memory.join(&deep).join("note.md")).unwrap(),
        "deep"
    );
}

#[test]
fn a_file_that_changes_size_while_it_is_packed_still_matches_the_manifest() {
    let fx = Fixture::new();
    let store = Store::open_in_memory().unwrap();
    let agent = new_agent(&store, "Forge");
    let home = fx.dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    // Over the whole-read size, so it is streamed with the size read at the walk.
    let big = vec![7u8; SMALL_FILE as usize + 10];
    std::fs::write(home.join("big.bin"), &big).unwrap();
    store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
    let agent = store.agent_get(&agent.id).unwrap().unwrap();
    let run = fx.dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    export_archive(
        ExportInput {
            store: &store,
            agent: &agent,
            services: vec![],
            schedules: vec![],
            avatar: None,
        },
        &run,
        "tok",
        &Limits::default(),
    )
    .unwrap();
    let un = unpack(&run.join("tok.tgz"), &fx.dir.path().join("x-1"), &Limits::default()).unwrap();
    assert_eq!(std::fs::read(un.memory.join("big.bin")).unwrap(), big);
}

#[test]
fn an_export_over_a_limit_leaves_no_file_behind() {
    let fx = Fixture::new();
    let store = Store::open_in_memory().unwrap();
    let agent = new_agent(&store, "Forge");
    let home = fx.dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    for i in 0..4 {
        std::fs::write(home.join(format!("f{i}")), "x").unwrap();
    }
    store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
    let agent = store.agent_get(&agent.id).unwrap().unwrap();
    let run = fx.dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    let export = |limits: &Limits| {
        export_archive(
            ExportInput {
                store: &store,
                agent: &agent,
                services: vec![],
                schedules: vec![],
                avatar: None,
            },
            &run,
            "tok",
            limits,
        )
    };
    let few = Limits {
        max_files: 3,
        ..Limits::default()
    };
    assert_eq!(export(&few).unwrap_err().reason, "too_many_files");
    let small = Limits {
        max_archive_bytes: 300,
        ..Limits::default()
    };
    assert_eq!(export(&small).unwrap_err().reason, "too_large");
    let bytes = Limits {
        max_total_bytes: 2,
        ..Limits::default()
    };
    assert_eq!(export(&bytes).unwrap_err().reason, "too_large");
    assert_eq!(
        std::fs::read_dir(&run).unwrap().count(),
        0,
        "no archive and no temp file stays"
    );
}

// ---- hostile archives ----

#[test]
fn paths_that_escape_or_leave_the_layout_are_refused() {
    let cases: &[(&[u8], &str)] = &[
        (b"memory/../../escape", "a .. part"),
        (b"../escape", "a leading .."),
        (b"memory/a/../../../escape", "a .. deeper"),
        (b"/etc/passwd", "an absolute path"),
        (b"/memory/a", "an absolute path in the layout"),
        (b"memory/./a", "a . part"),
        (b"memory//a", "an empty part"),
        (b"memory/a\\b", "a backslash"),
        (b"memory/\xff\xfe", "not UTF-8"),
        (b"etc/passwd", "outside the layout"),
        (b"events.jsonl.bak", "another top-level name"),
        (b"avatar.gif", "another picture"),
        (b"memory", "memory as a file"),
        (b"manifest.json/x", "a file under a file name"),
    ];
    for (path, why) in cases {
        let fx = Fixture::new();
        let tar = Tar::default().raw(path, b'0', b"data", b"").finish();
        let r = fx.unpack(tar, &Limits::default());
        let reason = r.expect_err(why).reason;
        assert!(reason == "bad_path" || reason == "bad_archive", "{why}: {reason}");
        fx.assert_contained();
    }
}

#[test]
fn only_files_and_folders_are_taken() {
    let cases: &[(u8, &str, &[u8])] = &[
        (b'2', "a symbolic link", b"/etc/passwd"),
        (b'2', "a link out of the folder", b"../../x"),
        (b'1', "a hard link", b"memory/a"),
        (b'3', "a character device", b""),
        (b'4', "a block device", b""),
        (b'6', "a named pipe", b""),
        (b'x', "a pax header", b"20 path=../x\n"),
        (b'g', "a global pax header", b"20 path=../x\n"),
        (b'K', "a long link name", b"../x\0"),
        (b'S', "a sparse file", b""),
        (b'7', "a contiguous file", b""),
    ];
    for (flag, why, link) in cases {
        let fx = Fixture::new();
        let tar = Tar::default()
            .file("memory/a", b"a")
            .raw(b"memory/b", *flag, b"", link)
            .finish();
        let r = fx.unpack(tar, &Limits::default());
        let err = r.expect_err(why);
        assert_eq!(err.reason, "bad_archive", "{why}");
        fx.assert_contained();
    }
}

#[test]
fn a_link_entry_cannot_be_followed_by_a_file_through_it() {
    // The classic: a symlink `memory/x -> /tmp`, then a file `memory/x/escape`. The link is refused first.
    let fx = Fixture::new();
    let tar = Tar::default()
        .raw(b"memory/x", b'2', b"", b"/tmp")
        .file("memory/x/escape", b"pwned")
        .finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_archive");
    fx.assert_contained();
}

#[test]
fn a_duplicate_path_is_refused() {
    let fx = Fixture::new();
    let tar = Tar::default().file("memory/a", b"1").file("memory/a", b"2").finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_archive");
    fx.assert_contained();
    let fx = Fixture::new();
    let tar = Tar::default().dir("memory/d/").dir("memory/d/").finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_archive");
}

#[test]
fn a_file_and_a_folder_of_one_name_clash() {
    let fx = Fixture::new();
    let tar = Tar::default().file("memory/a", b"1").file("memory/a/b", b"2").finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_archive");
    fx.assert_contained();
}

#[test]
fn a_folder_outside_memory_is_refused() {
    let fx = Fixture::new();
    let tar = Tar::default().dir("avatar.png/").finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_path");
    fx.assert_contained();
}

#[test]
fn too_many_files_or_folders_or_bytes_or_a_long_path_are_refused() {
    let few = Limits {
        max_files: 3,
        ..Limits::default()
    };
    let fx = Fixture::new();
    let mut tar = Tar::default();
    for i in 0..4 {
        tar = tar.file(&format!("memory/f{i}"), b"x");
    }
    assert_eq!(reason(fx.unpack(tar.finish(), &few)), "too_many_files");
    fx.assert_contained();

    let fx = Fixture::new();
    let mut tar = Tar::default();
    for i in 0..4 {
        tar = tar.dir(&format!("memory/d{i}/"));
    }
    assert_eq!(reason(fx.unpack(tar.finish(), &few)), "too_many_files");

    // At the limit it is still fine to read the entries (the manifest then decides).
    let fx = Fixture::new();
    let tar = Tar::default()
        .file("memory/a", b"x")
        .file("memory/b", b"x")
        .file("memory/c", b"x");
    assert_eq!(
        reason(fx.unpack(tar.finish(), &few)),
        "bad_manifest",
        "three files pass the count"
    );

    let fx = Fixture::new();
    let small = Limits {
        max_total_bytes: 10,
        ..Limits::default()
    };
    let tar = Tar::default()
        .file("memory/a", b"123456")
        .file("memory/b", b"123456")
        .finish();
    assert_eq!(reason(fx.unpack(tar, &small)), "too_large");
    fx.assert_contained();

    let fx = Fixture::new();
    let short = Limits {
        max_path_bytes: 40,
        ..Limits::default()
    };
    let name = format!("memory/{}", "n".repeat(60));
    assert_eq!(
        reason(fx.unpack(Tar::default().file(&name, b"x").finish(), &short)),
        "bad_path"
    );

    // A long name given by a GNU long-name entry is held to the same limit, and cannot be made huge.
    let fx = Fixture::new();
    let name = format!("memory/{}", "n".repeat(5000));
    assert_eq!(
        reason(fx.unpack(Tar::default().long_file(&name, b"x").finish(), &Limits::default())),
        "bad_path"
    );
    fx.assert_contained();
    let fx = Fixture::new();
    let name = format!("memory/{}", "n".repeat(300));
    let tar = Tar::default().long_file(&name, b"x").finish();
    assert_eq!(
        reason(fx.unpack(tar, &Limits::default())),
        "bad_path",
        "a part over 255 bytes"
    );
}

#[test]
fn a_nul_in_a_long_name_is_refused() {
    let fx = Fixture::new();
    let tar = Tar::default().long_file("memory/a\0b", b"x").finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_path");
    fx.assert_contained();
}

#[test]
fn a_big_header_size_is_counted_before_any_data_is_read() {
    // A header that claims 8 GiB but holds nothing: refused on the size, not by reading it.
    let fx = Fixture::new();
    let mut tar = Tar::default();
    tar.0
        .extend_from_slice(&header(b"memory/huge", b'0', 8 * 1024 * 1024 * 1024 - 1, 0o644, b""));
    assert_eq!(reason(fx.unpack(tar.finish(), &Limits::default())), "too_large");
    fx.assert_contained();
}

#[test]
fn a_cut_or_corrupt_archive_is_refused() {
    let fx = Fixture::new();
    std::fs::create_dir_all(fx.dir.path().join("work")).unwrap();
    let path = fx.archive(b"this is not gzip");
    assert_eq!(reason(unpack(&path, &fx.dest(), &Limits::default())), "bad_archive");
    assert!(!fx.dest().exists());

    let fx = Fixture::new();
    let good = good_tar(&[("a", b"hello")]).finish();
    let mut cut = good.clone();
    cut.truncate(1000);
    assert_eq!(reason(fx.unpack(cut, &Limits::default())), "bad_archive");
    fx.assert_contained();

    // A wrong checksum in a header.
    let fx = Fixture::new();
    let mut bad = good.clone();
    bad[0] ^= 0x55;
    assert_eq!(reason(fx.unpack(bad, &Limits::default())), "bad_archive");

    // A gzip stream cut in the middle.
    let fx = Fixture::new();
    std::fs::create_dir_all(fx.dir.path().join("work")).unwrap();
    let zipped = gz(&good);
    let path = fx.archive(&zipped[..zipped.len() / 2]);
    assert!(unpack(&path, &fx.dest(), &Limits::default()).is_err());
    assert!(!fx.dest().exists());
}

#[test]
fn a_base_256_size_is_refused() {
    let fx = Fixture::new();
    let mut h = header(b"memory/a", b'0', 1, 0o644, b"");
    h[124] = 0x80;
    h[148..156].fill(b' ');
    let sum: u64 = h.iter().map(|b| u64::from(*b)).sum();
    h[148..156].copy_from_slice(format!("{sum:06o}\0 ").as_bytes());
    let mut tar = Tar::default();
    tar.0.extend_from_slice(&h);
    assert_eq!(reason(fx.unpack(tar.finish(), &Limits::default())), "bad_archive");
}

// ---- the manifest ----

fn archive_with_manifest(mutate: impl FnOnce(&mut Manifest)) -> Vec<u8> {
    let files: Vec<(&str, &[u8])> = vec![("events.jsonl", EVENT_LINE.as_bytes()), ("memory/a.md", b"hello")];
    let mut manifest = manifest_for(&files, 1);
    mutate(&mut manifest);
    Tar::default()
        .dir("memory/")
        .file("events.jsonl", EVENT_LINE.as_bytes())
        .file("memory/a.md", b"hello")
        .file("manifest.json", &serde_json::to_vec(&manifest).unwrap())
        .finish()
}

#[test]
fn a_good_hand_made_archive_unpacks() {
    let fx = Fixture::new();
    let un = fx.unpack(archive_with_manifest(|_| {}), &Limits::default()).unwrap();
    assert_eq!(std::fs::read(un.memory.join("a.md")).unwrap(), b"hello");
}

#[test]
fn a_file_with_another_hash_or_size_than_the_manifest_is_refused() {
    let fx = Fixture::new();
    let tar = archive_with_manifest(|m| m.files[1].sha256 = sha_hex(b"something else"));
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "hash_mismatch");
    fx.assert_contained();

    let fx = Fixture::new();
    let tar = archive_with_manifest(|m| m.files[1].size += 1);
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "hash_mismatch");

    let fx = Fixture::new();
    let tar = archive_with_manifest(|m| m.files[0].sha256 = "0".repeat(64));
    assert_eq!(
        reason(fx.unpack(tar, &Limits::default())),
        "hash_mismatch",
        "the history too"
    );

    // A hash in capitals is the same hash.
    let fx = Fixture::new();
    let tar = archive_with_manifest(|m| m.files[1].sha256 = m.files[1].sha256.to_uppercase());
    assert!(fx.unpack(tar, &Limits::default()).is_ok());
}

#[test]
fn a_manifest_that_does_not_match_the_files_is_refused() {
    type Mutation = Box<dyn FnOnce(&mut Manifest)>;
    let cases: Vec<(&str, Mutation)> = vec![
        (
            "a listed file is missing",
            Box::new(|m| {
                m.files.push(FileEntry {
                    path: "memory/ghost".into(),
                    size: 1,
                    sha256: sha_hex(b"x"),
                })
            }),
        ),
        (
            "a file is not listed",
            Box::new(|m| {
                m.files.remove(1);
            }),
        ),
        (
            "a file is listed twice",
            Box::new(|m| {
                let again = m.files[1].clone();
                m.files.push(again);
            }),
        ),
        (
            "events.jsonl is not listed",
            Box::new(|m| {
                m.files.remove(0);
            }),
        ),
        (
            "a listed path escapes",
            Box::new(|m| m.files[1].path = "memory/../x".into()),
        ),
        (
            "a listed path is absolute",
            Box::new(|m| m.files[1].path = "/memory/a.md".into()),
        ),
        (
            "the manifest lists itself",
            Box::new(|m| {
                m.files.push(FileEntry {
                    path: "manifest.json".into(),
                    size: 1,
                    sha256: sha_hex(b"x"),
                })
            }),
        ),
        ("a sha256 is not hex", Box::new(|m| m.files[1].sha256 = "zz".into())),
        ("the name is not valid", Box::new(|m| m.agent.name = "bad/name".into())),
        ("the name is empty", Box::new(|m| m.agent.name = " ".into())),
        (
            "too many services",
            Box::new(|m| m.agent.services = (0..101).map(|i| format!("s{i}")).collect()),
        ),
    ];
    for (why, mutate) in cases {
        let fx = Fixture::new();
        let r = fx.unpack(archive_with_manifest(mutate), &Limits::default());
        assert_eq!(r.expect_err(why).reason, "bad_manifest", "{why}");
        fx.assert_contained();
    }
}

#[test]
fn the_format_and_the_shape_of_the_manifest_are_checked() {
    let with_manifest = |bytes: &[u8]| {
        Tar::default()
            .file("events.jsonl", EVENT_LINE.as_bytes())
            .file("manifest.json", bytes)
            .finish()
    };
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"{\"format\": 2}"), &Limits::default())),
        "unsupported_format"
    );
    fx.assert_contained();
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"{\"format\": 99, \"agent\": 5}"), &Limits::default())),
        "unsupported_format"
    );
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"{}"), &Limits::default())),
        "bad_manifest"
    );
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"{\"format\": \"1\"}"), &Limits::default())),
        "bad_manifest"
    );
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"not json"), &Limits::default())),
        "bad_manifest"
    );
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"{\"format\": 1, \"agent\": {}}"), &Limits::default())),
        "bad_manifest"
    );
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b"[]"), &Limits::default())),
        "bad_manifest"
    );
    let fx = Fixture::new();
    assert_eq!(
        reason(fx.unpack(with_manifest(b""), &Limits::default())),
        "bad_manifest"
    );
    // No manifest at all.
    let fx = Fixture::new();
    let tar = Tar::default().file("events.jsonl", EVENT_LINE.as_bytes()).finish();
    assert_eq!(reason(fx.unpack(tar, &Limits::default())), "bad_manifest");
    fx.assert_contained();
    // An oversized manifest.
    let fx = Fixture::new();
    let small = Limits {
        max_manifest_bytes: 10,
        ..Limits::default()
    };
    assert_eq!(reason(fx.unpack(with_manifest(&[b' '; 50]), &small)), "bad_manifest");
}

// ---- the history ----

fn events_file(dir: &TempDir, text: &str) -> PathBuf {
    let path = dir.path().join("events.jsonl");
    std::fs::write(&path, text).unwrap();
    path
}

fn line(seq: i64, kind: &str, payload: &str) -> String {
    format!("{{\"seq\":{seq},\"ts\":1,\"kind\":\"{kind}\",\"payload\":{payload}}}\n")
}

#[test]
fn the_history_is_checked_before_anything_is_made() {
    let dir = TempDir::new().unwrap();
    let ok = format!(
        "{}{}",
        line(1, "message.assistant", "{\"text\":\"a\"}"),
        line(5, "message.assistant", "{\"text\":\"b\"}")
    );
    assert_eq!(check_events(&events_file(&dir, &ok), 2, &Limits::default()).unwrap(), 2);
    assert_eq!(check_events(&events_file(&dir, ""), 0, &Limits::default()).unwrap(), 0);

    let refused = |text: &str, count: u64, why: &str| {
        let e = check_events(&events_file(&dir, text), count, &Limits::default()).expect_err(why);
        assert_eq!(e.reason, "bad_events", "{why}");
    };
    refused(&ok, 3, "the count is wrong");
    refused(&ok, 1, "the count is wrong the other way");
    refused(&line(1, "approval.requested", "{}"), 1, "a kind that is not carried");
    refused(&line(1, "agent.status", "{\"status\":\"idle\"}"), 1, "a status event");
    refused(&line(1, "nonsense", "{}"), 1, "an unknown kind");
    refused(
        &line(1, "message.assistant", "{\"nope\":1}"),
        1,
        "a payload that does not decode",
    );
    refused(
        &line(1, "message.user", "{\"text\":\"x\",\"source\":\"alien\"}"),
        1,
        "a payload with a bad enum",
    );
    refused("not json\n", 1, "a line that is not JSON");
    refused("{\"seq\":1}\n", 1, "a line without fields");
    refused("[]\n", 1, "a line that is not an object");
    let rising = format!(
        "{}{}",
        line(5, "message.assistant", "{\"text\":\"a\"}"),
        line(5, "message.assistant", "{\"text\":\"b\"}")
    );
    refused(&rising, 2, "seqs that do not rise");
    let tiny = Limits {
        max_line_bytes: 20,
        ..Limits::default()
    };
    let e = check_events(&events_file(&dir, &ok), 2, &tiny).unwrap_err();
    assert_eq!(e.reason, "bad_events", "a line over the limit");
}

#[test]
fn read_events_yields_the_events_and_stops_at_a_bad_line() {
    let dir = TempDir::new().unwrap();
    let text = format!(
        "{}{}",
        line(7, "message.assistant", "{\"text\":\"a\"}"),
        line(9, "message.assistant", "{\"text\":\"b\"}")
    );
    let got: Vec<NewEvent> = read_events(&events_file(&dir, &text), &Limits::default())
        .unwrap()
        .collect::<anyhow::Result<_>>()
        .unwrap();
    assert_eq!(got.iter().map(|e| e.old_seq).collect::<Vec<_>>(), vec![7, 9]);
    let bad = format!("{}garbage\n", line(1, "message.assistant", "{\"text\":\"a\"}"));
    let results: Vec<_> = read_events(&events_file(&dir, &bad), &Limits::default())
        .unwrap()
        .collect();
    assert!(results[0].is_ok() && results[1].is_err());
}

#[test]
fn remap_follows_the_new_seqs_and_clears_the_queue() {
    let remap = Remap {
        old_home: None,
        new_home: PathBuf::new(),
    };
    let map: HashMap<i64, i64> = [(10, 100), (11, 101)].into();
    let apply = |kind: &str, mut payload: Value| {
        let keep = remap.apply(kind, &mut payload, &map);
        (keep, payload)
    };
    let (keep, p) = apply(
        "message.user",
        serde_json::json!({"text": "x", "source": "user", "queued": true, "reply_to": 10}),
    );
    assert!(keep);
    assert_eq!(p["reply_to"], 100);
    assert!(p.get("queued").is_none(), "a message that waited no longer waits");
    let (_, p) = apply(
        "message.user",
        serde_json::json!({"text": "x", "source": "user", "reply_to": 999}),
    );
    assert!(
        p.get("reply_to").is_none(),
        "a reply to a message that was not carried loses the link"
    );
    let (keep, p) = apply(
        "turn.started",
        serde_json::json!({"turn_id": "t", "source": "user", "message_seq": 11}),
    );
    assert!(keep);
    assert_eq!(p["message_seq"], 101);
    let (_, p) = apply(
        "turn.started",
        serde_json::json!({"turn_id": "t", "source": "user", "message_seq": 5}),
    );
    assert!(p.get("message_seq").is_none());
    let (keep, p) = apply("message.dropped", serde_json::json!({"seq": 10, "reason": "crash"}));
    assert!(keep);
    assert_eq!(p["seq"], 100);
    assert!(!apply("message.dropped", serde_json::json!({"seq": 5, "reason": "crash"})).0);
    let (keep, p) = apply("reaction", serde_json::json!({"seq": 11, "emoji": "x", "by": "user"}));
    assert!(keep);
    assert_eq!(p["seq"], 101);
    assert!(!apply("reaction", serde_json::json!({"seq": 5, "emoji": "x", "by": "user"})).0);
    assert!(apply("message.assistant", serde_json::json!({"text": "t"})).0);
    // Every remapped payload still decodes.
    for (kind, payload) in [
        (
            "message.user",
            serde_json::json!({"text": "x", "source": "user", "queued": true, "reply_to": 10}),
        ),
        (
            "turn.started",
            serde_json::json!({"turn_id": "t", "source": "user", "message_seq": 5}),
        ),
    ] {
        let (_, p) = apply(kind, payload);
        assert!(EventBody::from_parts(kind, p).is_ok());
    }
}

#[test]
fn remap_keeps_an_attachment_that_is_in_the_moved_folder_and_turns_the_rest_into_text() {
    let new_home = TempDir::new().unwrap();
    std::fs::create_dir_all(new_home.path().join("files/attachments")).unwrap();
    std::fs::write(new_home.path().join("files/attachments/pic.png"), "png").unwrap();
    symlink("/etc/passwd", new_home.path().join("files/attachments/link.png")).unwrap();
    let remap = Remap {
        old_home: Some("/old/agents/forge".into()),
        new_home: new_home.path().to_path_buf(),
    };
    let attachment =
        |path: &str, name: &str| serde_json::json!({"path": path, "name": name, "size": 3, "mime": "image/png"});
    let mut payload = serde_json::json!({
        "text": "look",
        "source": "user",
        "attachments": [
            attachment("/old/agents/forge/files/attachments/pic.png", "pic.png"),
            attachment("/old/agents/forge/files/attachments/gone.png", "gone.png"),
            attachment("/somewhere/else/project.zip", "project.zip"),
            attachment("/old/agents/forge/files/attachments/link.png", "link.png"),
            attachment("/old/agents/forge/../../../etc/passwd", "pass\nwd"),
            attachment("/old/agents/forgery/x.png", "forgery.png"),
        ],
    });
    assert!(remap.apply("message.user", &mut payload, &HashMap::new()));
    let kept = payload["attachments"].as_array().unwrap();
    assert_eq!(kept.len(), 1);
    assert_eq!(
        kept[0]["path"],
        new_home.path().join("files/attachments/pic.png").display().to_string()
    );
    let text = payload["text"].as_str().unwrap();
    assert!(text.starts_with("look"));
    for name in ["gone.png", "project.zip", "link.png", "forgery.png", "pass"] {
        assert!(
            text.contains(&format!("[attachment not moved: {name}")),
            "{name} in {text}"
        );
    }
    assert!(EventBody::from_parts("message.user", payload).is_ok());
}

// ---- moving the memory in ----

#[test]
fn the_memory_replaces_the_template_and_merges_into_the_folder() {
    let dir = TempDir::new().unwrap();
    let memory = dir.path().join("memory");
    let home = dir.path().join("home");
    std::fs::create_dir_all(memory.join("notes/deep")).unwrap();
    std::fs::create_dir_all(memory.join("empty")).unwrap();
    std::fs::write(memory.join("MEMORY.md"), "moved memory").unwrap();
    std::fs::write(memory.join("notes/a.md"), "a").unwrap();
    std::fs::write(memory.join("notes/deep/b.md"), "b").unwrap();
    std::fs::create_dir_all(home.join("notes")).unwrap();
    std::fs::create_dir_all(home.join("journal")).unwrap();
    std::fs::write(home.join("MEMORY.md"), "template").unwrap();
    std::fs::write(home.join("notes/keep.md"), "stays").unwrap();
    std::fs::write(home.join(".bandito-agent"), "new-id").unwrap();
    let moved = install_memory(&memory, &home).unwrap();
    assert_eq!(moved, 3);
    assert_eq!(std::fs::read_to_string(home.join("MEMORY.md")).unwrap(), "moved memory");
    assert_eq!(std::fs::read_to_string(home.join("notes/a.md")).unwrap(), "a");
    assert_eq!(std::fs::read_to_string(home.join("notes/deep/b.md")).unwrap(), "b");
    assert_eq!(std::fs::read_to_string(home.join("notes/keep.md")).unwrap(), "stays");
    assert!(home.join("empty").is_dir() && home.join("journal").is_dir());
    assert_eq!(std::fs::read_to_string(home.join(".bandito-agent")).unwrap(), "new-id");
}

#[test]
fn a_moved_file_over_a_folder_and_a_folder_over_a_file_both_work() {
    let dir = TempDir::new().unwrap();
    let memory = dir.path().join("memory");
    let home = dir.path().join("home");
    std::fs::create_dir_all(memory.join("a")).unwrap();
    std::fs::write(memory.join("a/x"), "x").unwrap();
    std::fs::write(memory.join("b"), "file b").unwrap();
    std::fs::create_dir_all(home.join("b")).unwrap();
    std::fs::write(home.join("b/old"), "old").unwrap();
    std::fs::write(home.join("a"), "file a").unwrap();
    install_memory(&memory, &home).unwrap();
    assert_eq!(std::fs::read_to_string(home.join("a/x")).unwrap(), "x");
    assert_eq!(std::fs::read_to_string(home.join("b")).unwrap(), "file b");
}

// ---- the registry ----

fn sha_of(data: &[u8]) -> String {
    sha_hex(data)
}

#[test]
fn an_upload_takes_the_pieces_in_order_and_checks_them() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let limits = Limits::default();
    let data = b"0123456789".to_vec();
    let id = reg.begin_upload(dir.path(), 10, &sha_of(&data), &limits, 0).unwrap();
    assert!(id.starts_with("up_") && id.len() == 3 + 32);
    assert!(dir.path().join(format!("in-{id}.tgz")).exists());
    assert_eq!(
        std::fs::metadata(dir.path().join(format!("in-{id}.tgz")))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    assert_eq!(reg.write_upload(&id, 0, &data[..4], 1).unwrap(), 4);
    assert_eq!(
        reg.write_upload(&id, 5, &data[4..], 2).unwrap_err().reason,
        "bad_offset",
        "a gap"
    );
    assert_eq!(
        reg.write_upload(&id, 0, &data[..4], 2).unwrap_err().reason,
        "bad_offset",
        "a repeat"
    );
    assert_eq!(
        reg.write_upload(&id, 4, &[0u8; 20], 2).unwrap_err().reason,
        "size_mismatch",
        "too much"
    );
    assert_eq!(
        reg.take_for_commit(&id).unwrap_err().reason,
        "size_mismatch",
        "not whole yet"
    );
    assert_eq!(reg.write_upload(&id, 4, &data[4..], 3).unwrap(), 10);
    let ticket = reg.take_for_commit(&id).unwrap();
    assert_eq!(std::fs::read(&ticket.path).unwrap(), data);
    assert_eq!(
        reg.take_for_commit(&id).unwrap_err().reason,
        "busy",
        "a second commit while one runs"
    );
    assert_eq!(reg.write_upload(&id, 10, b"x", 4).unwrap_err().reason, "busy");
    reg.finish_upload(&id);
    assert!(!ticket.path.exists());
    assert_eq!(
        reg.take_for_commit(&id).unwrap_err().reason,
        "unknown_upload",
        "a repeated commit"
    );
    assert_eq!(reg.write_upload(&id, 0, b"x", 4).unwrap_err().reason, "unknown_upload");
}

#[test]
fn an_upload_with_the_wrong_hash_is_removed_at_commit() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let id = reg
        .begin_upload(dir.path(), 4, &sha_of(b"abcd"), &Limits::default(), 0)
        .unwrap();
    reg.write_upload(&id, 0, b"abce", 1).unwrap();
    assert_eq!(reg.take_for_commit(&id).unwrap_err().reason, "checksum_mismatch");
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    assert_eq!(reg.take_for_commit(&id).unwrap_err().reason, "unknown_upload");
}

#[test]
fn uploads_have_limits() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let limits = Limits::default();
    let sha = sha_of(b"x");
    assert_eq!(
        reg.begin_upload(dir.path(), 0, &sha, &limits, 0).unwrap_err().reason,
        "size_mismatch"
    );
    assert_eq!(
        reg.begin_upload(dir.path(), limits.max_archive_bytes + 1, &sha, &limits, 0)
            .unwrap_err()
            .reason,
        "too_large"
    );
    assert_eq!(
        reg.begin_upload(dir.path(), 1, "abc", &limits, 0).unwrap_err().reason,
        "checksum_mismatch"
    );
    assert_eq!(
        reg.begin_upload(dir.path(), 1, &"g".repeat(64), &limits, 0)
            .unwrap_err()
            .reason,
        "checksum_mismatch"
    );
    let a = reg.begin_upload(dir.path(), 1, &sha, &limits, 0).unwrap();
    let b = reg.begin_upload(dir.path(), 1, &sha, &limits, 0).unwrap();
    assert_ne!(a, b);
    assert_eq!(
        reg.begin_upload(dir.path(), 1, &sha, &limits, 0).unwrap_err().reason,
        "too_many_uploads"
    );
    reg.finish_upload(&a);
    assert!(
        reg.begin_upload(dir.path(), 1, &sha, &limits, 0).is_ok(),
        "a finished upload frees its place"
    );
}

#[test]
fn old_exports_uploads_and_stray_files_are_removed() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let now = now_ms();
    // An export and an upload of two hours ago, one export and one upload of now.
    let old_export = dir.path().join("mg_old.tgz");
    std::fs::write(&old_export, "x").unwrap();
    reg.add_export(
        "mg_old".into(),
        Export {
            agent_id: "a".into(),
            path: old_export.clone(),
            size: 1,
            sha256: String::new(),
            created_ms: now - 2 * TTL_MS,
            upto: 0,
        },
    );
    let fresh_export = dir.path().join("mg_new.tgz");
    std::fs::write(&fresh_export, "x").unwrap();
    reg.add_export(
        "mg_new".into(),
        Export {
            agent_id: "a".into(),
            path: fresh_export.clone(),
            size: 1,
            sha256: String::new(),
            created_ms: now - 1000,
            upto: 0,
        },
    );
    let old_up = reg
        .begin_upload(dir.path(), 1, &sha_of(b"x"), &Limits::default(), now - 2 * TTL_MS)
        .unwrap();
    let new_up = reg
        .begin_upload(dir.path(), 1, &sha_of(b"x"), &Limits::default(), now - 1000)
        .unwrap();
    // Files no registry entry owns: an old one (a crashed daemon's) and a fresh one.
    let stray = dir.path().join("in-up_stray.tgz");
    std::fs::write(&stray, "x").unwrap();
    std::fs::File::options()
        .write(true)
        .open(&stray)
        .unwrap()
        .set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(3 * 3600))
        .unwrap();
    let stray_dir = dir.path().join("x-stray");
    std::fs::create_dir_all(stray_dir.join("memory")).unwrap();
    std::fs::File::open(&stray_dir)
        .unwrap()
        .set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(3 * 3600))
        .unwrap();
    let fresh_stray = dir.path().join("ev-fresh.tmp");
    std::fs::write(&fresh_stray, "x").unwrap();

    reg.sweep(dir.path(), now, TTL_MS);
    assert!(
        reg.export("mg_old").is_none() && !old_export.exists(),
        "an old export goes"
    );
    assert!(reg.export("mg_new").is_some() && fresh_export.exists());
    assert_eq!(
        reg.write_upload(&old_up, 0, b"x", now).unwrap_err().reason,
        "unknown_upload"
    );
    assert!(reg.write_upload(&new_up, 0, b"x", now).is_ok());
    assert!(!stray.exists(), "an old stray file goes");
    assert!(!stray_dir.exists(), "an old unpack folder goes");
    assert!(fresh_stray.exists(), "a fresh file stays");
}

#[test]
fn an_upload_being_unpacked_is_not_swept() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let id = reg
        .begin_upload(dir.path(), 1, &sha_of(b"x"), &Limits::default(), 0)
        .unwrap();
    reg.write_upload(&id, 0, b"x", 0).unwrap();
    let ticket = reg.take_for_commit(&id).unwrap();
    reg.sweep(dir.path(), 5 * TTL_MS, TTL_MS);
    assert!(ticket.path.exists());
}

fn an_export(dir: &Path, name: &str) -> Export {
    Export {
        agent_id: "a".into(),
        path: dir.join(format!("{name}.tgz")),
        size: 1,
        sha256: String::new(),
        created_ms: now_ms(),
        upto: 0,
    }
}

#[test]
fn a_commit_that_hangs_is_swept_after_an_hour() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let id = reg
        .begin_upload(dir.path(), 1, &sha_of(b"x"), &Limits::default(), now_ms())
        .unwrap();
    reg.write_upload(&id, 0, b"x", now_ms()).unwrap();
    let ticket = reg.take_for_commit(&id).unwrap();
    // Within the hour it stays, however long ago the last byte came.
    reg.sweep(dir.path(), now_ms() + TTL_MS / 2, TTL_MS);
    assert!(ticket.path.exists());
    // An hour after the commit began, it is stuck: the upload and its file go.
    reg.sweep(dir.path(), now_ms() + 2 * TTL_MS, TTL_MS);
    assert!(!ticket.path.exists());
    assert_eq!(reg.take_for_commit(&id).unwrap_err().reason, "unknown_upload");
}

#[test]
fn a_dropped_commit_guard_spends_the_upload() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    let id = reg
        .begin_upload(dir.path(), 1, &sha_of(b"x"), &Limits::default(), now_ms())
        .unwrap();
    reg.write_upload(&id, 0, b"x", now_ms()).unwrap();
    let ticket = reg.take_for_commit(&id).unwrap();
    {
        // The call is cancelled: the guard goes with it.
        let _guard = reg.commit_guard(&id);
    }
    assert!(!ticket.path.exists());
    assert_eq!(reg.counts().1, 0, "no upload is left marked as committing");
}

#[test]
fn only_so_many_exports_wait_and_a_building_one_holds_its_place() {
    let dir = TempDir::new().unwrap();
    let reg = Registry::default();
    // Five started at once, none finished yet: the sixth is refused before anything is built.
    for _ in 0..EXPORTS_MAX {
        reg.reserve_export().unwrap();
    }
    assert_eq!(reg.reserve_export().unwrap_err().reason, "too_many_exports");
    // One fails: its place is free again. One finishes: its place is the export's.
    reg.cancel_reservation();
    reg.reserve_export().unwrap();
    for i in 0..EXPORTS_MAX {
        reg.add_export(format!("mg_{i}"), an_export(dir.path(), &i.to_string()));
    }
    assert_eq!(reg.counts().0, EXPORTS_MAX);
    assert_eq!(reg.reserve_export().unwrap_err().reason, "too_many_exports");
    assert!(reg.remove_export("mg_0").is_some());
    assert!(reg.remove_export("mg_0").is_none());
    reg.reserve_export().unwrap();
}

#[test]
fn file_names_come_from_random_tokens_only() {
    let a = new_token("mg_");
    let b = new_token("mg_");
    assert_ne!(a, b);
    assert!(a.starts_with("mg_") && a[3..].len() == 32 && a[3..].bytes().all(|c| c.is_ascii_hexdigit()));
    let dir = TempDir::new().unwrap();
    let made = migrate_dir(dir.path()).unwrap();
    assert_eq!(made, dir.path().join("run/migrate"));
    assert_eq!(std::fs::metadata(&made).unwrap().permissions().mode() & 0o777, 0o700);
    assert!(migrate_dir(dir.path()).is_ok(), "making it twice is fine");
}

#[test]
fn check_path_accepts_the_layout() {
    let l = Limits::default();
    for ok in [
        "manifest.json",
        "events.jsonl",
        "avatar.png",
        "avatar.jpg",
        "memory",
        "memory/",
        "memory/MEMORY.md",
        "memory/notes/a b.md",
        "memory/ünï/日本語.md",
        "memory/.hidden",
        "memory/a.git",
    ] {
        assert!(check_path(ok.as_bytes(), &l).is_ok(), "{ok}");
    }
    assert_eq!(check_path(b"memory/notes/", &l).unwrap(), "memory/notes");
    assert!(check_path(b"memory/.gitignore", &l).is_ok(), ".gitignore is not .git");
}

// ---- names that run tools, modes, and files swapped during the walk ----

const TOOL_PATHS: &[&str] = &[
    ".CLAUDE/settings.json",
    ".Git/hooks/x",
    "sub/.mcp.json",
    ".envrc",
    ".gitmodules",
    ".GITATTRIBUTES",
    ".codex/config.toml",
    ".gemini/settings.json",
    ".grok/x",
    ".cursor/rules",
    ".vscode/tasks.json",
    "deep/er/.idea/workspace.xml",
    ".g\u{200c}it/hooks/x",
];

const KEPT_PATHS: &[&str] = &[
    "CLAUDE.md",
    "AGENTS.md",
    "notes/ok.md",
    "sub/claude.md",
    ".gitignore",
    "x.envrc",
];

#[test]
fn tool_configuration_names_are_dropped_on_import_whatever_their_case() {
    let fx = Fixture::new();
    // Even a manifest that lists them does not bring them in.
    let memory: Vec<(&str, &[u8])> = TOOL_PATHS
        .iter()
        .chain(KEPT_PATHS)
        .map(|p| (*p, b"data".as_slice()))
        .collect();
    let un = fx.unpack(good_tar(&memory).finish(), &Limits::default()).unwrap();
    for kept in KEPT_PATHS {
        assert_eq!(
            std::fs::read(un.memory.join(kept)).unwrap(),
            b"data",
            "{kept} is carried"
        );
    }
    for dropped in TOOL_PATHS {
        let top = dropped.split('/').next().unwrap();
        assert!(
            !un.memory.join(top).exists() || top == "sub" || top == "deep",
            "{dropped} is not unpacked"
        );
        assert!(
            un.skipped.iter().any(|s| s.starts_with(&format!("{dropped}:"))),
            "{dropped} is named in skipped: {:?}",
            un.skipped
        );
    }
    assert!(!un.memory.join("sub/.mcp.json").exists());
    assert!(!un.memory.join("deep/er/.idea").exists());
}

#[test]
fn the_agent_marker_is_dropped_too_and_a_marker_in_a_folder_is_not_one() {
    let fx = Fixture::new();
    let un = fx
        .unpack(
            good_tar(&[(".bandito-agent", b"other-id"), ("sub/.bandito-agent", b"x")]).finish(),
            &Limits::default(),
        )
        .unwrap();
    assert!(!un.memory.join(".bandito-agent").exists());
    assert!(un.memory.join("sub/.bandito-agent").is_file());
}

#[test]
fn tool_configuration_folders_are_dropped_as_folders_too() {
    let fx = Fixture::new();
    let tar = good_tar(&[("a.md", b"x")])
        .dir("memory/.CLAUDE/")
        .dir("memory/.claude/skills/")
        .file("memory/.claude/skills/s.md", b"x");
    let un = fx.unpack(tar.finish(), &Limits::default()).unwrap();
    assert!(!un.memory.join(".claude").exists() && !un.memory.join(".CLAUDE").exists());
    assert!(un.memory.join("a.md").is_file());
}

#[test]
fn every_imported_file_is_0600_and_every_folder_0700() {
    let fx = Fixture::new();
    let mut tar = Tar::default().dir("memory/");
    // A header that asks for setuid, setgid and rwx for everyone.
    tar.0
        .extend_from_slice(&header(b"memory/tool.sh", b'0', 3, 0o7777, b""));
    tar.0.extend_from_slice(b"hi!");
    tar.0.extend(std::iter::repeat_n(0u8, 509));
    tar.0.extend_from_slice(&header(b"memory/d/", b'5', 0, 0o777, b""));
    let files: Vec<(&str, &[u8])> = vec![("events.jsonl", EVENT_LINE.as_bytes()), ("memory/tool.sh", b"hi!")];
    let manifest = serde_json::to_vec(&manifest_for(&files, 1)).unwrap();
    let tar = tar
        .file("events.jsonl", EVENT_LINE.as_bytes())
        .file("manifest.json", &manifest);
    let un = fx.unpack(tar.finish(), &Limits::default()).unwrap();
    let mode = |p: &PathBuf| std::fs::metadata(p).unwrap().permissions().mode() & 0o7777;
    assert_eq!(mode(&un.memory.join("tool.sh")), 0o600);
    assert_eq!(mode(&un.memory.join("d")), 0o700);
    assert_eq!(mode(&un.memory), 0o700);
    assert_eq!(mode(&un.root), 0o700);
    assert_eq!(mode(&un.events), 0o600);
}

fn export_home(fx: &Fixture, home: &Path) -> (Unpacked, Exported) {
    let store = Store::open_in_memory().unwrap();
    let agent = new_agent(&store, "Forge");
    store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
    let agent = store.agent_get(&agent.id).unwrap().unwrap();
    let run = fx.dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    let made = export_archive(
        ExportInput {
            store: &store,
            agent: &agent,
            services: vec![],
            schedules: vec![],
            avatar: None,
        },
        &run,
        "tok",
        &Limits::default(),
    )
    .unwrap();
    let un = unpack(&run.join("tok.tgz"), &fx.dir.path().join("x-1"), &Limits::default()).unwrap();
    (un, made)
}

#[test]
fn tool_configuration_names_are_left_out_of_an_export_too() {
    let fx = Fixture::new();
    let home = fx.dir.path().join("home");
    for p in TOOL_PATHS.iter().chain(KEPT_PATHS) {
        let path = home.join(p);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "data").unwrap();
    }
    let (un, made) = export_home(&fx, &home);
    for kept in KEPT_PATHS {
        assert_eq!(std::fs::read(un.memory.join(kept)).unwrap(), b"data", "{kept}");
    }
    for dropped in TOOL_PATHS {
        let top = dropped.split('/').next().unwrap();
        if top == "sub" || top == "deep" {
            continue;
        }
        assert!(!un.memory.join(top).exists(), "{dropped}");
        assert!(
            un.manifest.skipped.iter().any(|s| s.starts_with(top)),
            "{top} is named in the manifest's skipped: {:?}",
            un.manifest.skipped
        );
    }
    assert!(!un.memory.join("sub/.mcp.json").exists());
    assert!(!un.memory.join("deep/er/.idea").exists());
    assert!(made.skipped >= 10, "{}", made.skipped);
}

fn set_after_list(f: impl Fn(&str) + 'static) {
    AFTER_LIST.with(|h| *h.borrow_mut() = Some(Box::new(f)));
}

fn mkfifo(path: &Path) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a valid C string and a mode.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}

fn all_text(dir: &Path) -> String {
    let mut out = String::new();
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            out.push_str(&all_text(&p));
        } else {
            out.push_str(&std::fs::read_to_string(&p).unwrap_or_default());
        }
    }
    out
}

#[test]
fn a_link_or_a_pipe_put_in_a_files_place_during_the_walk_is_not_packed() {
    let fx = Fixture::new();
    let home = fx.dir.path().join("home");
    let outside = fx.dir.path().join("outside");
    std::fs::create_dir_all(home.join("notes")).unwrap();
    std::fs::create_dir_all(home.join("d")).unwrap();
    std::fs::create_dir_all(outside.join("dir")).unwrap();
    std::fs::write(outside.join("secret"), "TOP SECRET").unwrap();
    std::fs::write(outside.join("dir/x"), "TOP SECRET 2").unwrap();
    for name in ["a.md", "b.md", "c.md", "keep.md"] {
        std::fs::write(home.join("notes").join(name), "mine").unwrap();
    }
    std::fs::write(home.join("d/x"), "mine").unwrap();
    let (h, o) = (home.clone(), outside.clone());
    set_after_list(move |rel| {
        if rel == "notes" {
            // a.md becomes a link, b.md a pipe (opening it for reading would hang without O_NONBLOCK), c.md a
            // link to a folder.
            for name in ["a.md", "b.md", "c.md"] {
                std::fs::remove_file(h.join("notes").join(name)).unwrap();
            }
            symlink(o.join("secret"), h.join("notes/a.md")).unwrap();
            mkfifo(&h.join("notes/b.md"));
            symlink(&o, h.join("notes/c.md")).unwrap();
        }
        if rel == "d" {
            // The folder itself is swapped for a link to another folder.
            std::fs::remove_dir_all(h.join("d")).unwrap();
            symlink(o.join("dir"), h.join("d")).unwrap();
        }
    });
    let (un, _) = export_home(&fx, &home);
    AFTER_LIST.with(|h| *h.borrow_mut() = None);
    assert_eq!(std::fs::read(un.memory.join("notes/keep.md")).unwrap(), b"mine");
    for gone in ["notes/a.md", "notes/b.md", "notes/c.md", "d/x"] {
        assert!(!un.memory.join(gone).exists(), "{gone} must not be in the archive");
    }
    assert!(!all_text(&un.memory).contains("TOP SECRET"));
    assert!(un.manifest.skipped.len() >= 3, "{:?}", un.manifest.skipped);
}

#[test]
fn a_pipe_in_the_folder_is_skipped_without_hanging() {
    let fx = Fixture::new();
    let home = fx.dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("a.md"), "mine").unwrap();
    mkfifo(&home.join("pipe"));
    let (un, _) = export_home(&fx, &home);
    assert!(un.memory.join("a.md").is_file() && !un.memory.join("pipe").exists());
    assert!(un.manifest.skipped.iter().any(|s| s.starts_with("pipe")));
}

#[test]
fn an_attachment_is_not_kept_when_the_new_folder_is_unknown() {
    let remap = Remap {
        old_home: Some("/old/home".into()),
        new_home: PathBuf::new(),
    };
    let mut payload = serde_json::json!({
        "text": "see", "source": "user",
        "attachments": [{"path": "/old/home/files/a.png", "name": "a.png", "size": 1, "mime": "image/png"}],
    });
    assert!(remap.apply("message.user", &mut payload, &HashMap::new()));
    assert!(payload.get("attachments").is_none());
    assert!(
        payload["text"]
            .as_str()
            .unwrap()
            .contains("[attachment not moved: a.png]")
    );
}

#[test]
fn excluded_folds_case_and_look_alike_characters() {
    for name in [
        ".GIT",
        ".Claude/x",
        "a/.CODEX",
        ".gro\u{212a}",
        ".g\u{200b}it",
        ".gi\u{feff}t/hooks",
        ".c\u{200d}laude",
        ".MCP.JSON",
        "deep/.VsCode/tasks.json",
        ".bandito-agent",
        ".Bandito-Agent",
    ] {
        assert!(excluded(name).is_some(), "{name:?}");
    }
    for name in [
        "CLAUDE.md",
        "AGENTS.md",
        "claude.md",
        ".gitignore",
        "x.git",
        "notes/.claude.md",
        "sub/.bandito-agent",
        ".gitx",
        "git",
    ] {
        assert!(excluded(name).is_none(), "{name:?}");
    }
}

#[test]
fn look_alike_letters_and_marks_fold_to_the_excluded_names() {
    for name in [
        ".mcp.j\u{17f}on",
        ".v\u{17f}code",
        ".cur\u{17f}or",
        ".gitmodule\u{17f}",
        ".claude\u{307}",
        ".cl\u{307}aude",
        ".\u{130}dea",
        ".\u{131}dea",
        ".cargo",
        ".Cargo/config.toml",
        ".yarnrc.yml",
        ".YARNRC",
        ".npmrc",
        ".zed/settings.json",
        ".opencode",
        ".aider.conf.yml",
        ".AIDER.chat.history.md",
        ".aider",
        ".windsurf/rules",
        ".devcontainer/devcontainer.json",
        ".husky/pre-commit",
        ".pre-commit-config.yaml",
        "deep/er/.husky/x",
    ] {
        assert!(excluded(name).is_some(), "{name:?}");
    }
    for name in [
        "aider.md",
        ".aide",
        "cargo",
        "npmrc",
        ".husky.md",
        "zed",
        "notes/.pre-commit.md",
    ] {
        assert!(excluded(name).is_none(), "{name:?}");
    }
}

#[test]
fn dropped_entries_do_not_count_against_the_file_and_byte_limits_but_have_a_budget() {
    let tight = Limits {
        max_files: 4,
        max_total_bytes: 6000,
        ..Limits::default()
    };
    // Ten files of 500 bytes under tool names: more files than the limit and more bytes than the real files have.
    let mut tar = good_tar(&[("a.md", b"x")]);
    for i in 0..10 {
        tar = tar.file(&format!("memory/.claude/f{i}"), &[7u8; 500]);
    }
    let fx = Fixture::new();
    let un = fx.unpack(tar.finish(), &tight).unwrap();
    assert_eq!(un.skipped.len(), 10);
    assert!(un.memory.join("a.md").is_file());
    // But a mountain of them is refused: they have a byte budget of their own.
    let mut tar = good_tar(&[("a.md", b"x")]);
    for i in 0..14 {
        tar = tar.file(&format!("memory/.claude/f{i}"), &[7u8; 500]);
    }
    let fx = Fixture::new();
    assert_eq!(reason(fx.unpack(tar.finish(), &tight)), "too_large");
    fx.assert_contained();
}

#[test]
fn an_export_fails_when_the_agents_folder_cannot_be_opened_and_is_empty_when_it_is_gone() {
    let fx = Fixture::new();
    let store = Store::open_in_memory().unwrap();
    let agent = new_agent(&store, "Forge");
    let run = fx.dir.path().join("run");
    std::fs::create_dir_all(&run).unwrap();
    let export = |home: &Path| {
        store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
        let agent = store.agent_get(&agent.id).unwrap().unwrap();
        export_archive(
            ExportInput {
                store: &store,
                agent: &agent,
                services: vec![],
                schedules: vec![],
                avatar: None,
            },
            &run,
            "tok",
            &Limits::default(),
        )
    };
    // A path that is a file, not a folder: not "no memory", an error, and no archive left.
    let file = fx.dir.path().join("a file");
    std::fs::write(&file, "x").unwrap();
    assert_eq!(export(&file).unwrap_err().reason, "io");
    assert_eq!(std::fs::read_dir(&run).unwrap().count(), 0);
    // A folder that is not there: an agent with no memory files.
    assert!(export(&fx.dir.path().join("gone")).is_ok());
}
