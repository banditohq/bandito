//! `agents.migrate_*` end to end: two daemons (two apps with their own stores and folders), the whole move, every
//! refusal, and who may call. Every test makes its own temp folders and removes only those.

use super::*;
use crate::hub::Hub;
use crate::migrate::tests::{EVENT_LINE, Tar, gz, manifest_for};
use crate::rpc::{Peer, UNAUTHORIZED, dispatch};
use crate::store::{Device, IntegrationKind, NewIntegration};
use crate::supervisor::{Runtimes, Supervisor};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tempfile::TempDir;

/// One daemon: its own store, data folder and agents folder.
struct Server {
    _root: TempDir,
    app: Arc<App>,
    store: Arc<Store>,
    data: PathBuf,
    agents: PathBuf,
}

fn server() -> Server {
    let root = TempDir::new().unwrap();
    let data = root.path().join("data");
    let agents = root.path().join("agents");
    std::fs::create_dir_all(&data).unwrap();
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let app = App::new_in_home(sup, agents.clone(), App::default_files(), data.clone());
    Server {
        _root: root,
        app,
        store,
        data,
        agents,
    }
}

impl Server {
    async fn call(&self, method: &str, p: Value) -> RpcResult {
        dispatch(&self.app, &Peer::Local, method, p).await
    }

    fn run_dir(&self) -> PathBuf {
        self.data.join("run").join("migrate")
    }

    /// What is in `run/migrate`.
    fn leftovers(&self) -> Vec<String> {
        match std::fs::read_dir(self.run_dir()) {
            Ok(rd) => rd
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect(),
            Err(_) => vec![],
        }
    }

    fn agent_names(&self) -> Vec<String> {
        self.store.agent_list().unwrap().into_iter().map(|a| a.name).collect()
    }

    fn connect(&self, name: &str) {
        self.store
            .integration_create(NewIntegration {
                name: name.into(),
                kind: IntegrationKind::Stdio,
                command: Some("true".into()),
                args: vec![],
                url: None,
                env: Default::default(),
                headers: Default::default(),
                enabled: true,
                auth: Default::default(),
            })
            .unwrap();
    }

    /// The folders under the agents folder.
    fn agent_folders(&self) -> Vec<String> {
        match std::fs::read_dir(&self.agents) {
            Ok(rd) => rd
                .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
                .collect(),
            Err(_) => vec![],
        }
    }
}

fn err_reason(e: &RpcError) -> String {
    e.data
        .as_ref()
        .and_then(|d| d["reason"].as_str())
        .unwrap_or("")
        .to_string()
}

fn device() -> Peer {
    Peer::Device(Device {
        id: "dev-1".into(),
        name: "Mac".into(),
        created_at: 0,
        last_seen_at: None,
    })
}

const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR-picture";

/// The agent the tests move: settings of every kind, a memory folder, a picture, a history and schedules.
async fn make_source(s: &Server) -> String {
    s.connect("notion");
    s.connect("github");
    let made = s
        .call(
            "agents.create",
            json!({
                "name": "Forge",
                "runtime": "claude",
                "role": "builder",
                "model": "opus",
                "approval_mode": "always",
                "system_prompt": "Build things.",
                "effort": "high",
                "memory_mode": "daily",
                "context_budget": 50000,
                "capabilities": ["terminal", "files"],
                "use_personal_settings": true,
                "avatar": {"color": "#112233", "face": "Fx", "emoji": "🔨"},
            }),
        )
        .await
        .unwrap();
    let id = made["id"].as_str().unwrap().to_string();
    let home = PathBuf::from(made["home_dir"].as_str().unwrap());
    std::fs::write(home.join("MEMORY.md"), "# Memory\nthe owner likes tabs").unwrap();
    std::fs::write(home.join("notes/design.md"), "design notes").unwrap();
    std::fs::create_dir_all(home.join("notes/deep/er")).unwrap();
    std::fs::write(home.join("notes/deep/er/x.md"), "x").unwrap();
    std::fs::write(home.join("journal/2026-10-01.md"), "day one").unwrap();
    std::fs::create_dir_all(home.join("files/attachments/2026-10-01")).unwrap();
    std::fs::write(home.join("files/attachments/2026-10-01/pic.png"), PNG).unwrap();
    std::os::unix::fs::symlink("/etc/passwd", home.join("notes/link")).unwrap();
    s.call(
        "agents.avatar_image_set",
        json!({"id": id, "data_base64": STANDARD.encode(PNG)}),
    )
    .await
    .unwrap();
    for (cron, prompt, enabled) in [
        ("0 9 * * *", "Morning digest", true),
        ("*/30 * * * *", "Check CI", false),
    ] {
        s.call(
            "schedules.create",
            json!({"agent_id": id, "cron": cron, "tz": "Asia/Tokyo", "prompt": prompt, "enabled": enabled, "title": prompt}),
        )
        .await
        .unwrap();
    }
    id
}

/// Writes the source agent's history; returns the seqs of the first user message and of the queued one.
fn make_history(s: &Server, id: &str) -> (i64, i64) {
    use crate::event::{EventBody, ReactionBy, Source};
    let home = s.store.agent_get(id).unwrap().unwrap().home_dir.unwrap();
    let user = |text: &str, reply_to: Option<i64>, queued: bool, attachments: Vec<crate::attachments::Attachment>| {
        EventBody::MessageUser {
            text: text.into(),
            source: Source::User,
            from_agent: None,
            command: None,
            reply_to,
            attachments,
            mentions: vec![],
            via_button: false,
            schedule: None,
            queued,
        }
    };
    let att = |path: String, name: &str| crate::attachments::Attachment {
        path,
        name: name.into(),
        size: 3,
        mime: "image/png".into(),
    };
    let first = s
        .store
        .append_event(
            id,
            user(
                "build the thing",
                None,
                false,
                vec![
                    att(format!("{home}/files/attachments/2026-10-01/pic.png"), "pic.png"),
                    att("/Users/someone/project/spec.pdf".into(), "spec.pdf"),
                ],
            ),
        )
        .unwrap()
        .seq;
    s.store
        .append_event(
            id,
            EventBody::TurnStarted {
                turn_id: "t1".into(),
                source: Source::User,
                reactions_until: None,
                message_seq: None,
            },
        )
        .unwrap();
    s.store
        .append_event(id, EventBody::MessageAssistant { text: "on it".into() })
        .unwrap();
    s.store
        .append_event(
            id,
            EventBody::ToolCall {
                call_id: "c1".into(),
                tool: "Bash".into(),
                title: "ls".into(),
                input: json!({"command": "ls"}),
            },
        )
        .unwrap();
    s.store
        .append_event(
            id,
            EventBody::ToolResult {
                call_id: "c1".into(),
                ok: true,
                output: "a b".into(),
            },
        )
        .unwrap();
    s.store
        .append_event(
            id,
            EventBody::ApprovalRequested {
                approval_id: "ap1".into(),
                call_id: "c1".into(),
                tool: "Bash".into(),
                title: "rm".into(),
                command: None,
                diff: None,
                reason: "risky".into(),
                input: None,
            },
        )
        .unwrap();
    s.store
        .append_event(
            id,
            EventBody::TurnCompleted {
                turn_id: "t1".into(),
                status: crate::event::TurnStatus::Ok,
                usage: None,
                cost_usd: None,
            },
        )
        .unwrap();
    let queued = s
        .store
        .append_event(id, user("and also this", Some(first), true, vec![]))
        .unwrap()
        .seq;
    s.store
        .append_event(
            id,
            EventBody::Reaction {
                seq: first,
                emoji: Some("👍".into()),
                by: ReactionBy::User,
            },
        )
        .unwrap();
    s.store
        .append_event(
            id,
            EventBody::AgentStatus {
                status: crate::event::AgentStatus::Idle,
                detail: None,
            },
        )
        .unwrap();
    (first, queued)
}

async fn export(s: &Server, id: &str) -> Value {
    s.call("agents.migrate_export", json!({ "agent_id": id }))
        .await
        .unwrap()
}

/// Reads the whole export in pieces of `len`, as the app does.
async fn download(s: &Server, export: &Value, len: u64) -> Vec<u8> {
    let token = export["token"].as_str().unwrap();
    let size = export["size"].as_u64().unwrap();
    let mut bytes: Vec<u8> = Vec::new();
    loop {
        let r = s
            .call(
                "agents.migrate_read",
                json!({"token": token, "offset": bytes.len(), "length": len}),
            )
            .await
            .unwrap();
        let chunk = STANDARD.decode(r["data"].as_str().unwrap()).unwrap();
        assert!(chunk.len() as u64 <= len.min(READ_MAX as u64));
        bytes.extend_from_slice(&chunk);
        if r["eof"].as_bool().unwrap() {
            break;
        }
        assert!(!chunk.is_empty(), "no progress");
    }
    assert_eq!(bytes.len() as u64, size);
    assert_eq!(hex::encode(Sha256::digest(&bytes)), export["sha256"].as_str().unwrap());
    bytes
}

fn sha(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Begins an upload of `bytes` and writes it in pieces of `len`. Returns the upload id.
async fn upload(s: &Server, bytes: &[u8], len: usize) -> String {
    let begin = s
        .call(
            "agents.migrate_import_begin",
            json!({"size": bytes.len(), "sha256": sha(bytes)}),
        )
        .await
        .unwrap();
    let id = begin["upload_id"].as_str().unwrap().to_string();
    let mut offset = 0;
    for chunk in bytes.chunks(len) {
        let r = s
            .call(
                "agents.migrate_import_write",
                json!({"upload_id": id, "offset": offset, "data": STANDARD.encode(chunk)}),
            )
            .await
            .unwrap();
        offset += chunk.len();
        assert_eq!(r["written"], offset);
    }
    id
}

async fn move_agent(from: &Server, to: &Server, id: &str, commit: Value) -> RpcResult {
    let ex = export(from, id).await;
    let bytes = download(from, &ex, 60_000).await;
    let up = upload(to, &bytes, 70_000).await;
    let mut p = commit;
    p["upload_id"] = json!(up);
    let result = to.call("agents.migrate_import_commit", p).await;
    // The app ends the source's export, whatever the target said.
    from.call("agents.migrate_done", json!({"token": ex["token"]}))
        .await
        .unwrap();
    result
}

// ---- the whole move ----

#[tokio::test]
async fn an_agent_moves_with_its_settings_memory_history_services_and_schedules() {
    let src = server();
    let dst = server();
    let id = make_source(&src).await;
    let (first, queued) = make_history(&src, &id);
    dst.connect("notion");

    let reply = move_agent(&src, &dst, &id, json!({})).await.unwrap();
    assert_eq!(reply["errors"], json!([]), "{reply}");
    let a = &reply["agent"];
    let new_id = a["id"].as_str().unwrap();
    assert_ne!(new_id, id, "a new id");
    assert_eq!(a["name"], "Forge");
    assert_eq!(a["role"], "builder");
    assert_eq!(a["runtime"], "claude");
    assert_eq!(a["model"], "opus");
    assert_eq!(a["approval_mode"], "always");
    assert_eq!(a["system_prompt"], "Build things.");
    assert_eq!(a["effort"], "high");
    assert_eq!(a["memory_mode"], "daily");
    assert_eq!(a["context_budget"], 50_000);
    assert_eq!(a["capabilities"], json!(["terminal", "files"]));
    assert_eq!(a["use_personal_settings"], true);
    assert_eq!(a["avatar"]["color"], "#112233");
    assert_eq!(a["avatar"]["face"], "Fx");
    assert_eq!(a["avatar"]["emoji"], "🔨");
    assert_eq!(a["avatar"]["image"], true);
    assert_eq!(a["paused"], false);
    assert_eq!(a["lead"], false);
    assert_eq!(a["migrated_to"], Value::Null);
    assert_eq!(
        reply["missing_services"],
        json!(["github"]),
        "notion is connected here, github is not"
    );

    // The agent is the one `agents.create` makes: its own folder, with the marker of the new id.
    let home = PathBuf::from(a["home_dir"].as_str().unwrap());
    assert!(home.starts_with(&dst.agents));
    assert_eq!(std::fs::read_to_string(home.join(".bandito-agent")).unwrap(), new_id);
    assert_eq!(a["cwd"], home.display().to_string(), "no cwd given: its own folder");
    // The memory: files and contents, and the template did not win.
    assert_eq!(
        std::fs::read_to_string(home.join("MEMORY.md")).unwrap(),
        "# Memory\nthe owner likes tabs"
    );
    assert_eq!(
        std::fs::read_to_string(home.join("notes/design.md")).unwrap(),
        "design notes"
    );
    assert_eq!(std::fs::read_to_string(home.join("notes/deep/er/x.md")).unwrap(), "x");
    assert_eq!(
        std::fs::read_to_string(home.join("journal/2026-10-01.md")).unwrap(),
        "day one"
    );
    assert!(!home.join("notes/link").exists() && home.join("notes/link").symlink_metadata().is_err());
    assert_eq!(
        reply["files"], 5,
        "MEMORY.md, design.md, x.md, the journal day and the picture file"
    );
    // The avatar picture.
    let pic = dst
        .call("agents.avatar_image_get", json!({"id": new_id}))
        .await
        .unwrap();
    assert_eq!(STANDARD.decode(pic["data_base64"].as_str().unwrap()).unwrap(), PNG);
    // The services: only the enabled catalog integration that exists here.
    let notion = dst.store.integration_list().unwrap().remove(0);
    assert_eq!(a["integrations"], json!([notion.id]));
    // The schedules: both off, with their times and prompts.
    let schedules = dst.store.schedule_list(Some(new_id)).unwrap();
    assert_eq!(schedules.len(), 2);
    assert!(schedules.iter().all(|s| !s.enabled), "schedules arrive off");
    assert_eq!(
        schedules
            .iter()
            .map(|s| (s.cron.as_str(), s.tz.as_str(), s.prompt.as_str()))
            .collect::<Vec<_>>(),
        vec![
            ("0 9 * * *", "Asia/Tokyo", "Morning digest"),
            ("*/30 * * * *", "Asia/Tokyo", "Check CI")
        ]
    );
    assert_eq!(reply["schedule_ids"].as_array().unwrap().len(), 2);

    // The history: the messages, turns and tool calls in order, with new seqs; no approvals, no status.
    let events: Vec<_> = dst
        .store
        .events_for_export(new_id, 0, i64::MAX, 100)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind != "agent_changed")
        .collect();
    let kinds: Vec<&str> = events.iter().map(|e| e.kind.as_str()).collect();
    assert_eq!(
        kinds,
        vec![
            "message.user",
            "turn.started",
            "message.assistant",
            "tool.call",
            "tool.result",
            "turn.completed",
            "message.user",
            "reaction"
        ]
    );
    assert_eq!(reply["events"], 8);
    let text = |i: usize| serde_json::from_str::<Value>(&events[i].payload).unwrap();
    assert_eq!(
        text(0)["text"].as_str().unwrap().lines().next().unwrap(),
        "build the thing"
    );
    assert_eq!(text(2)["text"], "on it");
    assert_eq!(text(4)["output"], "a b");
    let src_events = src.store.events_for_export(&id, 0, i64::MAX, 100).unwrap();
    let ts_of = |kind: &str| src_events.iter().find(|e| e.kind == kind).unwrap().ts;
    assert_eq!(events[0].ts, ts_of("message.user"), "times are the source's");
    assert!(events.windows(2).all(|w| w[0].seq < w[1].seq));
    // Links follow the new seqs; a queued message no longer waits.
    let first_new = events[0].seq;
    assert_ne!(first_new, first);
    assert_eq!(text(6)["reply_to"], first_new);
    assert!(text(6).get("queued").is_none(), "{queued} no longer waits");
    assert_eq!(text(7)["seq"], first_new);
    // Attachments: the one in the moved folder points at the new path; the other became text.
    let attachments = text(0)["attachments"].as_array().unwrap().clone();
    assert_eq!(attachments.len(), 1);
    let new_path = home.join("files/attachments/2026-10-01/pic.png");
    assert_eq!(attachments[0]["path"], new_path.display().to_string());
    assert!(new_path.is_file());
    assert!(
        text(0)["text"]
            .as_str()
            .unwrap()
            .contains("[attachment not moved: spec.pdf]")
    );
    // Every event reads back through the normal path.
    let page = dst
        .call("events.page", json!({"agent_id": new_id, "limit": 50}))
        .await
        .unwrap();
    assert_eq!(
        page.as_array().unwrap().len(),
        10,
        "the 8 and the agent's own two agent_changed events"
    );

    // The temp files are gone on both sides; the source is untouched.
    assert!(dst.leftovers().is_empty(), "{:?}", dst.leftovers());
    assert!(
        src.leftovers().is_empty(),
        "the source export was ended by migrate_done"
    );
    assert_eq!(src.store.agent_get(&id).unwrap().unwrap().migrated_to, None);
    assert!(!src.store.agent_get(&id).unwrap().unwrap().paused);
    assert_eq!(dst.agent_names(), vec!["Forge".to_string()]);
}

#[tokio::test]
async fn a_second_move_gets_a_free_name_and_the_name_param_overrides() {
    let src = server();
    let dst = server();
    let id = make_source(&src).await;
    move_agent(&src, &dst, &id, json!({})).await.unwrap();
    let two = move_agent(&src, &dst, &id, json!({})).await.unwrap();
    assert_eq!(two["agent"]["name"], "Forge 2");
    let three = move_agent(&src, &dst, &id, json!({})).await.unwrap();
    assert_eq!(three["agent"]["name"], "Forge 3");
    let named = move_agent(&src, &dst, &id, json!({"name": "  Anvil "})).await.unwrap();
    assert_eq!(named["agent"]["name"], "Anvil");
    let clash = move_agent(&src, &dst, &id, json!({"name": "anvil"})).await.unwrap();
    assert_eq!(clash["agent"]["name"], "anvil 2", "compared without case");
    // Folders do not clash either.
    let folders = dst.agent_folders();
    assert_eq!(folders.len(), 5, "{folders:?}");
    // A name at the limit still gets its suffix within 32 characters.
    let long = "L".repeat(32);
    let first = move_agent(&src, &dst, &id, json!({"name": long})).await.unwrap();
    assert_eq!(first["agent"]["name"].as_str().unwrap().chars().count(), 32);
    let next = move_agent(&src, &dst, &id, json!({"name": long})).await.unwrap();
    let name = next["agent"]["name"].as_str().unwrap();
    assert_eq!(name.chars().count(), 32);
    assert!(name.ends_with(" 2"));
}

#[tokio::test]
async fn the_folder_param_is_the_agents_cwd_and_a_bad_one_keeps_the_upload() {
    let src = server();
    let dst = server();
    let id = make_source(&src).await;
    let ex = export(&src, &id).await;
    let bytes = download(&src, &ex, 100_000).await;
    let up = upload(&dst, &bytes, 100_000).await;
    let project = TempDir::new().unwrap();

    for (cwd, why) in [("relative/dir", "relative"), ("/no/such/folder/anywhere", "missing")] {
        let e = dst
            .call("agents.migrate_import_commit", json!({"upload_id": up, "cwd": cwd}))
            .await
            .unwrap_err();
        assert_eq!(err_reason(&e), "bad_folder", "{why}");
        assert_eq!(e.code, MIGRATE_ERROR);
    }
    let file = project.path().join("a file");
    std::fs::write(&file, "x").unwrap();
    let e = dst
        .call(
            "agents.migrate_import_commit",
            json!({"upload_id": up, "cwd": file.display().to_string()}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "bad_folder", "a file is not a folder");
    for name in ["bad/name", "x".repeat(33).as_str()] {
        let e = dst
            .call("agents.migrate_import_commit", json!({"upload_id": up, "name": name}))
            .await
            .unwrap_err();
        assert_eq!(err_reason(&e), "bad_name");
    }
    assert!(dst.agent_names().is_empty(), "nothing was made");
    // The upload is still there: the same one commits with a good folder.
    let reply = dst
        .call(
            "agents.migrate_import_commit",
            json!({"upload_id": up, "cwd": project.path().display().to_string()}),
        )
        .await
        .unwrap();
    assert_eq!(reply["agent"]["cwd"], project.path().display().to_string());
    // The memory is in the agent's own folder, not in the project.
    let home = PathBuf::from(reply["agent"]["home_dir"].as_str().unwrap());
    assert!(home.join("MEMORY.md").is_file());
    assert!(!project.path().join("MEMORY.md").exists());
}

#[tokio::test]
async fn done_with_a_server_name_marks_and_pauses_and_without_it_only_cleans_up() {
    let src = server();
    let id = make_source(&src).await;
    let ex = export(&src, &id).await;
    let token = ex["token"].as_str().unwrap();
    assert_eq!(src.leftovers().len(), 1);

    for bad in ["", "   ", &"n".repeat(65), "bad\nname"] {
        let e = src
            .call("agents.migrate_done", json!({"token": token, "moved_to": bad}))
            .await
            .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS, "{bad:?}");
    }
    assert_eq!(src.leftovers().len(), 1, "a refused name keeps the export");
    assert!(!src.store.agent_get(&id).unwrap().unwrap().paused);

    let done = src
        .call("agents.migrate_done", json!({"token": token, "moved_to": " My VPS "}))
        .await
        .unwrap();
    assert_eq!(done["ok"], true);
    assert_eq!(done["agent"]["migrated_to"], "My VPS");
    assert_eq!(done["agent"]["paused"], true);
    assert!(done["agent"]["migrated_at"].as_i64().unwrap() > 0);
    assert!(src.leftovers().is_empty(), "the archive is deleted");
    let got = src.call("agents.get", json!({"id": id})).await.unwrap();
    assert_eq!(
        (got["migrated_to"].as_str(), got["paused"].as_bool()),
        (Some("My VPS"), Some(true))
    );
    let listed = src.call("agents.list", json!({})).await.unwrap();
    assert_eq!(listed[0]["migrated_to"], "My VPS");
    assert!(listed[0]["migrated_at"].is_i64());

    // The token is spent.
    let e = src
        .call("agents.migrate_done", json!({"token": token}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_token");
    let e = src
        .call(
            "agents.migrate_read",
            json!({"token": token, "offset": 0, "length": 10}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_token");

    // Without `moved_to`: the archive goes, the agent is not marked.
    let other = make_source_named(&src, "Scout").await;
    let ex = export(&src, &other).await;
    let done = src
        .call("agents.migrate_done", json!({"token": ex["token"]}))
        .await
        .unwrap();
    assert_eq!(done["ok"], true);
    let got = src.call("agents.get", json!({"id": other})).await.unwrap();
    assert_eq!(
        (got["migrated_to"].clone(), got["paused"].as_bool()),
        (Value::Null, Some(false))
    );
    assert!(src.leftovers().is_empty());
}

async fn make_source_named(s: &Server, name: &str) -> String {
    s.call("agents.create", json!({"name": name, "runtime": "claude"}))
        .await
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string()
}

#[tokio::test]
async fn done_for_a_deleted_agent_still_removes_the_archive() {
    let src = server();
    let id = make_source_named(&src, "Gone").await;
    let ex = export(&src, &id).await;
    src.call("agents.delete", json!({"id": id})).await.unwrap();
    let e = src
        .call("agents.migrate_done", json!({"token": ex["token"], "moved_to": "vps"}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_agent");
    assert!(src.leftovers().is_empty());
}

#[tokio::test]
async fn reads_check_their_offset_and_cap_their_length() {
    let src = server();
    let id = make_source(&src).await;
    // Incompressible memory, so the archive is over one piece.
    let home = PathBuf::from(src.store.agent_get(&id).unwrap().unwrap().home_dir.unwrap());
    let mut x: u64 = 0x9E37_79B9_7F4A_7C15;
    let noise: Vec<u8> = (0..1_800_000)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 24) as u8
        })
        .collect();
    std::fs::write(home.join("files/noise.bin"), &noise).unwrap();
    let ex = export(&src, &id).await;
    let size = ex["size"].as_u64().unwrap();
    assert!(size > READ_MAX as u64 * 3 / 2);
    let token = ex["token"].as_str().unwrap();

    let big = src
        .call(
            "agents.migrate_read",
            json!({"token": token, "offset": 0, "length": 10_000_000}),
        )
        .await
        .unwrap();
    assert_eq!(
        STANDARD.decode(big["data"].as_str().unwrap()).unwrap().len(),
        READ_MAX,
        "capped at 1 MiB"
    );
    assert_eq!(big["eof"], false);
    let tail = src
        .call(
            "agents.migrate_read",
            json!({"token": token, "offset": size - 5, "length": 100}),
        )
        .await
        .unwrap();
    assert_eq!(STANDARD.decode(tail["data"].as_str().unwrap()).unwrap().len(), 5);
    assert_eq!(tail["eof"], true);
    let at_end = src
        .call(
            "agents.migrate_read",
            json!({"token": token, "offset": size, "length": 100}),
        )
        .await
        .unwrap();
    assert_eq!(
        (at_end["data"].as_str(), at_end["eof"].as_bool()),
        (Some(""), Some(true))
    );
    let past = src
        .call(
            "agents.migrate_read",
            json!({"token": token, "offset": size + 1, "length": 1}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&past), "bad_offset");
    let zero = src
        .call("agents.migrate_read", json!({"token": token, "offset": 0, "length": 0}))
        .await
        .unwrap_err();
    assert_eq!(zero.code, INVALID_PARAMS);
    let negative = src
        .call(
            "agents.migrate_read",
            json!({"token": token, "offset": -1, "length": 1}),
        )
        .await
        .unwrap_err();
    assert_eq!(negative.code, INVALID_PARAMS);
    // The whole thing in odd pieces still adds up, and imports.
    let bytes = download(&src, &ex, 777_777).await;
    let dst = server();
    let up = upload(&dst, &bytes, 1_000_000).await;
    let reply = dst
        .call("agents.migrate_import_commit", json!({"upload_id": up}))
        .await
        .unwrap();
    let home = PathBuf::from(reply["agent"]["home_dir"].as_str().unwrap());
    assert_eq!(std::fs::read(home.join("files/noise.bin")).unwrap(), noise);
}

#[tokio::test]
async fn a_token_that_is_not_ours_reads_and_deletes_nothing() {
    let src = server();
    let id = make_source_named(&src, "Forge").await;
    let ex = export(&src, &id).await;
    let stolen = "mg_00000000000000000000000000000000";
    for method in ["agents.migrate_read", "agents.migrate_done"] {
        let e = src
            .call(
                method,
                json!({"token": stolen, "offset": 0, "length": 5, "moved_to": "x"}),
            )
            .await
            .unwrap_err();
        assert_eq!(err_reason(&e), "unknown_token", "{method}");
    }
    // Names that are paths never reach the disk.
    for token in [
        "../../etc/passwd",
        "/etc/passwd",
        ex["token"].as_str().unwrap().to_uppercase().as_str(),
        "",
    ] {
        let e = src
            .call("agents.migrate_read", json!({"token": token, "offset": 0, "length": 5}))
            .await
            .unwrap_err();
        assert_eq!(err_reason(&e), "unknown_token", "{token}");
    }
    // Another daemon does not know this daemon's token.
    let other = server();
    let e = other
        .call(
            "agents.migrate_read",
            json!({"token": ex["token"], "offset": 0, "length": 5}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_token");
    assert_eq!(src.leftovers().len(), 1, "the real export is untouched");
    let e = src
        .call("agents.migrate_export", json!({"agent_id": "nobody"}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_agent");
}

#[tokio::test]
async fn only_so_many_exports_and_uploads_are_open() {
    let src = server();
    let id = make_source_named(&src, "Forge").await;
    for _ in 0..crate::migrate::EXPORTS_MAX {
        export(&src, &id).await;
    }
    let e = src
        .call("agents.migrate_export", json!({"agent_id": id}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "too_many_exports");
    assert_eq!(
        src.leftovers().len(),
        crate::migrate::EXPORTS_MAX,
        "the refused one left nothing"
    );

    let dst = server();
    let p = json!({"size": 10, "sha256": sha(b"x")});
    dst.call("agents.migrate_import_begin", p.clone()).await.unwrap();
    dst.call("agents.migrate_import_begin", p.clone()).await.unwrap();
    let e = dst.call("agents.migrate_import_begin", p).await.unwrap_err();
    assert_eq!(err_reason(&e), "too_many_uploads");
}

// ---- uploads ----

#[tokio::test]
async fn an_upload_is_taken_in_order_and_checked() {
    let dst = server();
    let bytes = vec![1u8; 100];
    let begin = |size: u64, sha: &str| dst.call("agents.migrate_import_begin", json!({"size": size, "sha256": sha}));
    assert_eq!(err_reason(&begin(0, &sha(&bytes)).await.unwrap_err()), "size_mismatch");
    assert_eq!(
        err_reason(&begin(1 << 40, &sha(&bytes)).await.unwrap_err()),
        "too_large"
    );
    assert_eq!(err_reason(&begin(100, "xyz").await.unwrap_err()), "checksum_mismatch");
    let id = begin(100, &sha(&bytes)).await.unwrap()["upload_id"]
        .as_str()
        .unwrap()
        .to_string();
    let write = |offset: u64, data: &[u8]| {
        dst.call(
            "agents.migrate_import_write",
            json!({"upload_id": id, "offset": offset, "data": STANDARD.encode(data)}),
        )
    };
    assert_eq!(write(0, &bytes[..40]).await.unwrap()["written"], 40);
    assert_eq!(
        err_reason(&write(50, &bytes[40..]).await.unwrap_err()),
        "bad_offset",
        "a gap"
    );
    assert_eq!(
        err_reason(&write(0, &bytes[..40]).await.unwrap_err()),
        "bad_offset",
        "a repeat"
    );
    assert_eq!(
        err_reason(&write(40, &[0u8; 80]).await.unwrap_err()),
        "size_mismatch",
        "too much"
    );
    // Not whole yet.
    let e = dst
        .call("agents.migrate_import_commit", json!({"upload_id": id}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "size_mismatch");
    // Bad input.
    let e = dst
        .call(
            "agents.migrate_import_write",
            json!({"upload_id": id, "offset": 40, "data": "!!!not base64!!!"}),
        )
        .await
        .unwrap_err();
    assert_eq!(e.code, INVALID_PARAMS);
    let huge = STANDARD.encode(vec![0u8; WRITE_MAX + 1]);
    let e = dst
        .call(
            "agents.migrate_import_write",
            json!({"upload_id": id, "offset": 40, "data": huge}),
        )
        .await
        .unwrap_err();
    assert_eq!(e.code, INVALID_PARAMS, "a chunk over 4 MiB");
    let e = dst
        .call(
            "agents.migrate_import_write",
            json!({"upload_id": "up_nope", "offset": 0, "data": ""}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_upload");
    // Finishing it, with the wrong content: the hash does not match, and nothing is made.
    write(40, &[9u8; 60]).await.unwrap();
    let e = dst
        .call("agents.migrate_import_commit", json!({"upload_id": id}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "checksum_mismatch");
    assert!(dst.agent_names().is_empty());
    assert!(dst.leftovers().is_empty(), "a wrong archive is removed");
    let e = dst
        .call("agents.migrate_import_commit", json!({"upload_id": id}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_upload");
}

#[tokio::test]
async fn a_second_commit_finds_nothing() {
    let src = server();
    let dst = server();
    let id = make_source(&src).await;
    let ex = export(&src, &id).await;
    let bytes = download(&src, &ex, 100_000).await;
    let up = upload(&dst, &bytes, 100_000).await;
    dst.call("agents.migrate_import_commit", json!({"upload_id": up}))
        .await
        .unwrap();
    let e = dst
        .call("agents.migrate_import_commit", json!({"upload_id": up}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_upload");
    assert_eq!(dst.agent_names(), vec!["Forge".to_string()], "one agent, not two");
    // Two commits at once: one makes the agent, the other is refused.
    let up = upload(&dst, &bytes, 100_000).await;
    let (a, b) = tokio::join!(
        dst.call("agents.migrate_import_commit", json!({"upload_id": up})),
        dst.call("agents.migrate_import_commit", json!({"upload_id": up})),
    );
    assert_eq!([a.is_ok(), b.is_ok()].iter().filter(|ok| **ok).count(), 1);
    assert_eq!(dst.agent_names().len(), 2);
}

// ---- hostile and broken archives through the methods ----

async fn commit_bytes(dst: &Server, tgz: &[u8]) -> RpcResult {
    let up = upload(dst, tgz, 100_000).await;
    dst.call("agents.migrate_import_commit", json!({"upload_id": up})).await
}

/// A good archive whose pieces a test can change.
fn good_files() -> Vec<(String, Vec<u8>)> {
    vec![
        ("events.jsonl".into(), EVENT_LINE.as_bytes().to_vec()),
        ("memory/MEMORY.md".into(), b"memory".to_vec()),
    ]
}

fn tgz_of(files: &[(String, Vec<u8>)], mutate: impl FnOnce(&mut crate::migrate::Manifest), extra: Tar) -> Vec<u8> {
    let listed: Vec<(&str, &[u8])> = files.iter().map(|(p, d)| (p.as_str(), d.as_slice())).collect();
    let mut manifest = manifest_for(&listed, 1);
    mutate(&mut manifest);
    let mut tar = extra;
    for (path, data) in files {
        tar = tar.file(path, data);
    }
    gz(&tar
        .file("manifest.json", &serde_json::to_vec(&manifest).unwrap())
        .finish())
}

#[tokio::test]
async fn a_good_hand_made_archive_imports() {
    let dst = server();
    let reply = commit_bytes(&dst, &tgz_of(&good_files(), |_| {}, Tar::default()))
        .await
        .unwrap();
    assert_eq!(reply["agent"]["name"], "Scout");
    assert_eq!(reply["errors"], json!([]));
    assert_eq!(reply["events"], 1);
}

#[tokio::test]
async fn a_hostile_archive_makes_nothing_and_leaves_nothing() {
    let outside = TempDir::new().unwrap();
    let canary = outside.path().join("canary");
    std::fs::write(&canary, "keep").unwrap();
    let cases: Vec<(&str, &str, Vec<u8>)> = vec![
        (
            "dotdot",
            "bad_path",
            tgz_of(
                &good_files(),
                |_| {},
                Tar::default().raw(b"memory/../../../escape", b'0', b"pwned", b""),
            ),
        ),
        (
            "absolute",
            "bad_path",
            tgz_of(
                &good_files(),
                |_| {},
                Tar::default().raw(canary.to_str().unwrap().as_bytes(), b'0', b"pwned", b""),
            ),
        ),
        (
            "symlink",
            "bad_archive",
            tgz_of(
                &good_files(),
                |_| {},
                Tar::default().raw(b"memory/link", b'2', b"", outside.path().to_str().unwrap().as_bytes()),
            ),
        ),
        (
            "hardlink",
            "bad_archive",
            tgz_of(
                &good_files(),
                |_| {},
                Tar::default().raw(b"memory/hard", b'1', b"", b"memory/MEMORY.md"),
            ),
        ),
        (
            "device",
            "bad_archive",
            tgz_of(&good_files(), |_| {}, Tar::default().raw(b"memory/dev", b'3', b"", b"")),
        ),
        (
            "bad file hash",
            "hash_mismatch",
            tgz_of(&good_files(), |m| m.files[1].sha256 = "a".repeat(64), Tar::default()),
        ),
        (
            "future format",
            "unsupported_format",
            gz(&Tar::default().file("manifest.json", b"{\"format\":2}").finish()),
        ),
        (
            "not a manifest",
            "bad_manifest",
            gz(&Tar::default().file("manifest.json", b"nope").finish()),
        ),
        (
            "no manifest",
            "bad_manifest",
            gz(&Tar::default().file("events.jsonl", EVENT_LINE.as_bytes()).finish()),
        ),
        (
            "not an archive",
            "bad_archive",
            gz(b"definitely not tar data, just text that goes on for a while"),
        ),
    ];
    for (why, reason, tgz) in cases {
        let dst = server();
        let e = commit_bytes(&dst, &tgz).await.expect_err(why);
        assert_eq!(e.code, MIGRATE_ERROR, "{why}");
        assert!(
            err_reason(&e) == reason || (reason == "bad_path" && err_reason(&e) == "bad_archive"),
            "{why}: {} ({})",
            err_reason(&e),
            e.message
        );
        assert!(dst.agent_names().is_empty(), "{why}: an agent was made");
        assert!(dst.agent_folders().is_empty(), "{why}: a folder was made");
        assert!(dst.leftovers().is_empty(), "{why}: {:?}", dst.leftovers());
        assert_eq!(std::fs::read_to_string(&canary).unwrap(), "keep");
        assert_eq!(
            std::fs::read_dir(outside.path()).unwrap().count(),
            1,
            "{why}: nothing next to the canary"
        );
    }
}

#[tokio::test]
async fn a_bad_history_is_refused_before_the_agent_exists() {
    let approval = "{\"seq\":1,\"ts\":1,\"kind\":\"approval.requested\",\"payload\":{}}\n";
    let broken = "{\"seq\":1,\"ts\":1,\"kind\":\"message.user\",\"payload\":{\"nope\":true}}\n";
    for (why, text, count) in [
        ("a kind that is not carried", approval, 1),
        ("an event that does not decode", broken, 1),
        ("a wrong count", EVENT_LINE, 5),
    ] {
        let dst = server();
        let files = vec![
            ("events.jsonl".to_string(), text.as_bytes().to_vec()),
            ("memory/MEMORY.md".to_string(), b"memory".to_vec()),
        ];
        let listed: Vec<(&str, &[u8])> = files.iter().map(|(p, d)| (p.as_str(), d.as_slice())).collect();
        let manifest = manifest_for(&listed, count);
        let mut tar = Tar::default();
        for (path, data) in &files {
            tar = tar.file(path, data);
        }
        let tgz = gz(&tar
            .file("manifest.json", &serde_json::to_vec(&manifest).unwrap())
            .finish());
        let e = commit_bytes(&dst, &tgz).await.expect_err(why);
        assert_eq!(err_reason(&e), "bad_events", "{why}");
        assert!(dst.agent_names().is_empty(), "{why}");
        assert!(dst.agent_folders().is_empty(), "{why}");
        assert!(dst.leftovers().is_empty(), "{why}");
    }
}

#[tokio::test]
async fn a_failure_after_the_agent_exists_is_listed_and_not_rolled_back() {
    let dst = server();
    let files = good_files();
    // One schedule is not a valid cron: the agent is made, the schedule is listed as failed.
    let tgz = tgz_of(
        &files,
        |m| {
            m.agent.schedules = vec![
                crate::migrate::ScheduleSpec {
                    cron: "not a cron".into(),
                    tz: "UTC".into(),
                    prompt: "bad".into(),
                    title: None,
                },
                crate::migrate::ScheduleSpec {
                    cron: "0 9 * * *".into(),
                    tz: "UTC".into(),
                    prompt: "good".into(),
                    title: None,
                },
            ];
            m.agent.services = vec!["notion".into(), "not-in-the-catalog".into()];
        },
        Tar::default(),
    );
    let reply = commit_bytes(&dst, &tgz).await.unwrap();
    let errors = reply["errors"].as_array().unwrap();
    assert_eq!(errors.len(), 1, "{errors:?}");
    assert_eq!(errors[0]["step"], "schedule");
    assert_eq!(errors[0]["index"], 0);
    assert_eq!(
        reply["schedule_ids"].as_array().unwrap().len(),
        1,
        "the good one is made"
    );
    assert_eq!(dst.agent_names(), vec!["Scout".to_string()], "the agent stays");
    assert_eq!(reply["missing_services"], json!(["notion", "not-in-the-catalog"]));
    assert_eq!(reply["events"], 1);
    assert_eq!(
        std::fs::read_to_string(
            reply["agent"]["home_dir"]
                .as_str()
                .map(|h| PathBuf::from(h).join("MEMORY.md"))
                .unwrap()
        )
        .unwrap(),
        "memory"
    );
}

#[tokio::test]
async fn an_agent_with_no_memory_files_and_no_history_still_moves() {
    let src = server();
    let dst = server();
    let id = make_source_named(&src, "Plain").await;
    let reply = move_agent(&src, &dst, &id, json!({})).await.unwrap();
    assert_eq!(reply["agent"]["name"], "Plain");
    assert_eq!(reply["events"], 0);
    assert_eq!(reply["errors"], json!([]));
    assert_eq!(reply["agent"]["avatar"], Value::Null);
    // The template memory of the new agent is there.
    let home = PathBuf::from(reply["agent"]["home_dir"].as_str().unwrap());
    assert!(home.join("MEMORY.md").is_file());
}

// ---- who may call ----

const METHODS: &[&str] = &[
    "agents.migrate_export",
    "agents.migrate_read",
    "agents.migrate_done",
    "agents.migrate_import_begin",
    "agents.migrate_import_write",
    "agents.migrate_import_commit",
];

#[tokio::test]
async fn only_the_owner_and_apps_may_move_agents() {
    let s = server();
    let id = make_source_named(&s, "Forge").await;
    let agent = Peer::Agent(id.clone());
    let anonymous = Peer::Anonymous("203.0.113.7".into(), None);
    let params = json!({"agent_id": id, "token": "mg_x", "offset": 0, "length": 1, "upload_id": "up_x", "size": 1, "sha256": sha(b"x"), "data": ""});
    for method in METHODS {
        for peer in [&agent, &anonymous] {
            let e = dispatch(&s.app, peer, method, params.clone()).await.unwrap_err();
            assert_eq!(e.code, UNAUTHORIZED, "{method} from {peer:?}");
            assert!(!crate::rpc::allowed(peer, method));
        }
    }
    assert!(s.leftovers().is_empty(), "the refused calls made no file");
    for method in METHODS {
        for peer in [Peer::Local, device()] {
            assert!(crate::rpc::allowed(&peer, method), "{method} from {peer:?}");
            let e = dispatch(&s.app, &peer, method, params.clone()).await;
            if let Err(e) = e {
                assert_ne!(e.code, UNAUTHORIZED, "{method}");
            }
        }
    }
    assert!(
        dispatch(&s.app, &Peer::Local, "agents.migrate_nothing", json!({}))
            .await
            .unwrap_err()
            .code
            == METHOD_NOT_FOUND
    );
}

#[tokio::test]
async fn the_feature_is_listed() {
    assert!(crate::rpc::features().contains(&"agent_migrate"));
    let s = server();
    let info = s.call("daemon.info", json!({})).await.unwrap();
    assert!(info["features"].as_array().unwrap().contains(&json!("agent_migrate")));
}

// ---- time ----

#[tokio::test]
async fn files_older_than_an_hour_are_removed_by_the_next_call_and_at_start() {
    let s = server();
    let id = make_source_named(&s, "Forge").await;
    let ex = export(&s, &id).await;
    let token = ex["token"].as_str().unwrap();
    let dir = s.run_dir();
    let old = std::time::SystemTime::now() - std::time::Duration::from_secs(2 * 3600);
    let backdate = |path: &Path| {
        std::fs::File::open(path).unwrap().set_modified(old).unwrap();
    };
    // Leftovers of an earlier daemon: an unfinished upload, an unpack folder, an archive.
    std::fs::write(dir.join("in-up_dead.tgz"), "x").unwrap();
    std::fs::create_dir_all(dir.join("x-dead/memory")).unwrap();
    std::fs::write(dir.join("mg_dead.tgz"), "x").unwrap();
    for name in ["in-up_dead.tgz", "x-dead", "mg_dead.tgz"] {
        backdate(&dir.join(name));
    }
    let fresh = dir.join("in-up_fresh.tgz");
    std::fs::write(&fresh, "x").unwrap();
    // The next call of any method clears the old ones, and only those.
    let e = s
        .call(
            "agents.migrate_read",
            json!({"token": "mg_nobody", "offset": 0, "length": 1}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_token");
    let mut left = s.leftovers();
    left.sort();
    let mut want = vec![format!("{token}.tgz"), "in-up_fresh.tgz".to_string()];
    want.sort();
    assert_eq!(left, want);
    // At start: a daemon that finds old files removes them before serving, and keeps the fresh ones.
    std::fs::write(dir.join("mg_old2.tgz"), "x").unwrap();
    backdate(&dir.join("mg_old2.tgz"));
    cleanup_at_start(&s.data);
    assert!(!dir.join("mg_old2.tgz").exists());
    assert!(fresh.exists(), "a fresh file is kept");

    // A registry entry past its hour goes the same way (judged by its own clock).
    let in_two_hours = crate::store::now_ms() + 2 * TTL_MS;
    s.app.migrate.sweep(&dir, in_two_hours, TTL_MS);
    let e = s
        .call("agents.migrate_read", json!({"token": token, "offset": 0, "length": 1}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_token", "an expired export is gone");
    assert!(!dir.join(format!("{token}.tgz")).exists());
}

#[tokio::test]
async fn an_upload_that_goes_quiet_for_an_hour_is_dropped() {
    let dst = server();
    let bytes = b"abcd".to_vec();
    let up = dst
        .call("agents.migrate_import_begin", json!({"size": 4, "sha256": sha(&bytes)}))
        .await
        .unwrap()["upload_id"]
        .as_str()
        .unwrap()
        .to_string();
    let dir = dst.run_dir();
    dst.app.migrate.sweep(&dir, crate::store::now_ms() + 2 * TTL_MS, TTL_MS);
    let e = dst
        .call(
            "agents.migrate_import_write",
            json!({"upload_id": up, "offset": 0, "data": STANDARD.encode(&bytes)}),
        )
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_upload");
    assert!(dst.leftovers().is_empty());
}

// ---- the security review's points ----

#[tokio::test]
async fn never_ask_is_not_carried_over_and_the_services_given_are_listed() {
    let dst = server();
    dst.connect("notion");
    dst.connect("not-in-the-catalog");
    let tgz = tgz_of(
        &good_files(),
        |m| {
            m.agent.approval_mode = crate::store::ApprovalMode::Never;
            m.agent.services = vec!["notion".into(), "github".into()];
        },
        Tar::default(),
    );
    let reply = commit_bytes(&dst, &tgz).await.unwrap();
    assert_eq!(reply["agent"]["approval_mode"], "risky");
    assert_eq!(reply["downgraded"], json!(["approval_mode"]));
    assert_eq!(reply["granted_services"], json!(["notion"]));
    assert_eq!(reply["missing_services"], json!(["github"]));
    let notion = dst
        .store
        .integration_list()
        .unwrap()
        .into_iter()
        .find(|i| i.name == "notion")
        .unwrap();
    assert_eq!(reply["agent"]["integrations"], json!([notion.id]));

    // Any other mode is kept as it is, and nothing is reported.
    let tgz = tgz_of(
        &good_files(),
        |m| m.agent.approval_mode = crate::store::ApprovalMode::Always,
        Tar::default(),
    );
    let reply = commit_bytes(&dst, &tgz).await.unwrap();
    assert_eq!(reply["agent"]["approval_mode"], "always");
    assert_eq!(reply["downgraded"], json!([]));
    assert_eq!(reply["granted_services"], json!([]));
}

#[tokio::test]
async fn tool_configuration_files_are_dropped_and_named_and_the_rest_is_private() {
    let dst = server();
    let extra = Tar::default()
        .file("memory/.Git/hooks/pre-commit", b"#!/bin/sh\necho pwned")
        .file("memory/.CLAUDE/settings.json", b"{\"hooks\":{}}")
        .file("memory/sub/.mcp.json", b"{}");
    let mut files = good_files();
    files.push(("memory/CLAUDE.md".into(), b"the agent's own memory".to_vec()));
    let reply = commit_bytes(&dst, &tgz_of(&files, |_| {}, extra)).await.unwrap();
    assert_eq!(reply["errors"], json!([]));
    let skipped: Vec<String> = reply["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s.as_str().unwrap().to_string())
        .collect();
    assert_eq!(skipped.len(), 3, "{skipped:?}");
    for want in [".Git/hooks/pre-commit", ".CLAUDE/settings.json", "sub/.mcp.json"] {
        assert!(skipped.iter().any(|s| s.starts_with(want)), "{want} in {skipped:?}");
    }
    let home = PathBuf::from(reply["agent"]["home_dir"].as_str().unwrap());
    assert!(!home.join(".Git").exists() && !home.join(".CLAUDE").exists());
    assert!(!home.join("sub/.mcp.json").exists());
    use std::os::unix::fs::PermissionsExt;
    let mode = |p: &str| std::fs::metadata(home.join(p)).unwrap().permissions().mode() & 0o777;
    assert_eq!(
        std::fs::read(home.join("CLAUDE.md")).unwrap(),
        b"the agent's own memory"
    );
    assert_eq!(mode("CLAUDE.md"), 0o600, "no exec bit, owner only");
    assert_eq!(mode("MEMORY.md"), 0o600);
}

#[tokio::test]
async fn a_working_agent_is_not_exported_and_a_refusal_keeps_no_place() {
    use crate::event::{AgentStatus, EventBody};
    let src = server();
    let id = make_source_named(&src, "Forge").await;
    for status in [AgentStatus::Working, AgentStatus::NeedsYou] {
        src.store
            .append_event(&id, EventBody::AgentStatus { status, detail: None })
            .unwrap();
        // More refusals than the export limit allows: none of them may use up a place.
        for _ in 0..crate::migrate::EXPORTS_MAX + 2 {
            let e = src
                .call("agents.migrate_export", json!({"agent_id": id}))
                .await
                .unwrap_err();
            assert_eq!(err_reason(&e), "agent_busy");
        }
    }
    assert!(src.leftovers().is_empty());
    for status in [AgentStatus::Idle, AgentStatus::Error, AgentStatus::Offline] {
        src.store
            .append_event(&id, EventBody::AgentStatus { status, detail: None })
            .unwrap();
        let ex = export(&src, &id).await;
        src.call("agents.migrate_done", json!({"token": ex["token"]}))
            .await
            .unwrap();
    }
}

#[tokio::test]
async fn exports_started_together_cannot_pass_the_limit() {
    let src = server();
    let id = make_source_named(&src, "Forge").await;
    let calls =
        (0..crate::migrate::EXPORTS_MAX + 3).map(|_| src.call("agents.migrate_export", json!({"agent_id": id})));
    let results = futures_util::future::join_all(calls).await;
    let ok = results.iter().filter(|r| r.is_ok()).count();
    assert_eq!(ok, crate::migrate::EXPORTS_MAX);
    for r in results.iter().filter_map(|r| r.as_ref().err()) {
        assert_eq!(err_reason(r), "too_many_exports");
    }
    assert_eq!(src.leftovers().len(), crate::migrate::EXPORTS_MAX);
    // A failed export gives its place back.
    let e = src
        .call("agents.migrate_export", json!({"agent_id": "nobody"}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "unknown_agent");
}

#[tokio::test]
async fn an_agent_that_did_something_after_the_export_is_not_marked_as_moved() {
    use crate::event::{AgentStatus, EventBody};
    let src = server();
    let id = make_source_named(&src, "Forge").await;
    let ex = export(&src, &id).await;
    let token = ex["token"].as_str().unwrap();
    // Events the archive does not carry change nothing.
    src.store
        .append_event(
            &id,
            EventBody::AgentStatus {
                status: AgentStatus::Working,
                detail: None,
            },
        )
        .unwrap();
    // A message after the export does.
    src.store
        .append_event(&id, EventBody::MessageAssistant { text: "late".into() })
        .unwrap();
    let e = src
        .call("agents.migrate_done", json!({"token": token, "moved_to": "vps"}))
        .await
        .unwrap_err();
    assert_eq!(err_reason(&e), "changed_since_export");
    let got = src.call("agents.get", json!({"id": id})).await.unwrap();
    assert_eq!(
        (got["migrated_to"].clone(), got["paused"].as_bool()),
        (Value::Null, Some(false))
    );
    assert_eq!(src.leftovers().len(), 1, "the archive stays");
    // Without moved_to it still cleans up.
    src.call("agents.migrate_done", json!({"token": token})).await.unwrap();
    assert!(src.leftovers().is_empty());
    // A fresh export after the message is whole again (the agent is idle once more).
    src.store
        .append_event(
            &id,
            EventBody::AgentStatus {
                status: AgentStatus::Idle,
                detail: None,
            },
        )
        .unwrap();
    let ex = export(&src, &id).await;
    let done = src
        .call("agents.migrate_done", json!({"token": ex["token"], "moved_to": "vps"}))
        .await
        .unwrap();
    assert_eq!(done["agent"]["migrated_to"], "vps");
}

#[tokio::test]
async fn the_periodic_cleanup_removes_what_is_old() {
    let s = server();
    let dir = migrate::migrate_dir(&s.data).unwrap();
    let old = std::time::SystemTime::now() - std::time::Duration::from_secs(2 * 3600);
    std::fs::write(dir.join("in-up_dead.tgz"), "x").unwrap();
    std::fs::File::open(dir.join("in-up_dead.tgz"))
        .unwrap()
        .set_modified(old)
        .unwrap();
    std::fs::write(dir.join("in-up_fresh.tgz"), "x").unwrap();
    cleanup_now(&s.app);
    assert!(!dir.join("in-up_dead.tgz").exists());
    assert!(dir.join("in-up_fresh.tgz").exists());
    // With no folder yet, it makes none.
    let fresh = server();
    cleanup_now(&fresh.app);
    assert!(!fresh.run_dir().exists());
}

#[tokio::test]
async fn an_agent_that_is_working_again_is_not_marked_as_moved() {
    use crate::event::{AgentStatus, EventBody};
    let src = server();
    let id = make_source_named(&src, "Forge").await;
    let ex = export(&src, &id).await;
    for status in [AgentStatus::Working, AgentStatus::NeedsYou] {
        src.store
            .append_event(&id, EventBody::AgentStatus { status, detail: None })
            .unwrap();
        let e = src
            .call("agents.migrate_done", json!({"token": ex["token"], "moved_to": "vps"}))
            .await
            .unwrap_err();
        assert_eq!(e.code, MIGRATE_ERROR);
        assert_eq!(e.data.as_ref().unwrap()["reason"], "changed_since_export");
    }
    let got = src.call("agents.get", json!({"id": id})).await.unwrap();
    assert_eq!(
        (got["migrated_to"].clone(), got["paused"].as_bool()),
        (Value::Null, Some(false))
    );
    // Idle again: the archive is still whole.
    src.store
        .append_event(
            &id,
            EventBody::AgentStatus {
                status: AgentStatus::Idle,
                detail: None,
            },
        )
        .unwrap();
    let done = src
        .call("agents.migrate_done", json!({"token": ex["token"], "moved_to": "vps"}))
        .await
        .unwrap();
    assert_eq!(done["agent"]["migrated_to"], "vps");
}
