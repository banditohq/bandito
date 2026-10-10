//! Vendored skills: each folder under `daemon/skills/<id>/` is a copy of the author's folder at a pinned commit, and
//! `skills_catalog.json` describes them. The files are compiled into the binary (`build.rs`). The `skills.*` RPC
//! methods (`rpc::skills`) serve the catalog and install or remove a skill; see docs/ARCHITECTURE.md#skills.
//! The tests hold the data to the rules the install path relies on.

use crate::commands::{self, InstallError, InstallFile, InstallKind};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

include!(concat!(env!("OUT_DIR"), "/bundled_skills.rs"));

const CATALOG: &str = include_str!("skills_catalog.json");

/// The file that marks a skill folder as installed by Bandito. It holds `{"id", "commit"}`. A folder without it is
/// the person's own, and is never replaced or removed.
pub const MARKER: &str = ".bandito-skill";

/// The catalog entries, as written in `skills_catalog.json` (the files are listed by path, not by content).
pub fn catalog() -> Vec<Value> {
    serde_json::from_str(CATALOG).expect("skills_catalog.json is valid JSON: the tests check it")
}

/// The catalog entry of `id`, if there is one.
pub fn catalog_entry(id: &str) -> Option<Value> {
    catalog()
        .into_iter()
        .find(|e| e.get("id").and_then(Value::as_str) == Some(id))
}

/// Whether `id` is an entry of the catalog.
pub fn is_catalog_id(id: &str) -> bool {
    catalog_entry(id).is_some()
}

/// The files of skill `id` as bundled, `(path, bytes)`, or None when the skill is not bundled.
fn bundled_files(id: &str) -> Option<&'static [(&'static str, &'static [u8])]> {
    SKILLS.iter().find(|(name, _)| *name == id).map(|(_, files)| *files)
}

/// The bytes of one file of a bundled skill: `path` is relative to the skill folder, with `/` separators.
pub fn bundled_file(id: &str, path: &str) -> Option<&'static [u8]> {
    bundled_files(id)?
        .iter()
        .find(|(rel, _)| *rel == path)
        .map(|(_, bytes)| *bytes)
}

/// What is at `base/.claude/skills/<id>`: nothing, a folder Bandito installed (`Ours`), or anything else (`Foreign`:
/// the person's own folder, a link, or a folder whose marker names another skill).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    Absent,
    Ours,
    Foreign,
}

/// The state of skill folder `id` under `base` (the daemon user's home, or an agent's folder). `Ours` needs a real
/// folder with a `SKILL.md` file and a marker whose `id` is `id`.
pub fn slot(base: &Path, id: &str) -> Slot {
    #[derive(Deserialize)]
    struct Marker {
        id: String,
    }
    let dir = base.join(".claude").join("skills").join(id);
    let Ok(meta) = fs::symlink_metadata(&dir) else {
        return Slot::Absent;
    };
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Slot::Foreign;
    }
    let is_file = |p: PathBuf| fs::symlink_metadata(p).is_ok_and(|m| m.is_file());
    let marker = dir.join(MARKER);
    let marker_ok = is_file(marker.clone())
        && fs::read_to_string(&marker)
            .ok()
            .and_then(|text| serde_json::from_str::<Marker>(&text).ok())
            .is_some_and(|m| m.id == id);
    if marker_ok && is_file(dir.join("SKILL.md")) {
        Slot::Ours
    } else {
        Slot::Foreign
    }
}

/// The commit a Bandito install under `base` was made from, as its marker says. None when the folder is not Bandito's
/// (see [`slot`]) or the marker names no commit.
pub fn installed_commit(base: &Path, id: &str) -> Option<String> {
    if slot(base, id) != Slot::Ours {
        return None;
    }
    let text = fs::read_to_string(base.join(".claude").join("skills").join(id).join(MARKER)).ok()?;
    let marker: Value = serde_json::from_str(&text).ok()?;
    marker.get("commit").and_then(Value::as_str).map(str::to_string)
}

/// Whether the Bandito install under `base` is older than the catalog: its marker's commit is not the catalog's commit.
/// False when there is no Bandito install there, and for an id that is not in the catalog.
pub fn update_available(base: &Path, id: &str) -> bool {
    let Some(catalog_commit) = catalog_entry(id).and_then(|e| e["source"]["commit"].as_str().map(str::to_string))
    else {
        return false;
    };
    slot(base, id) == Slot::Ours && installed_commit(base, id).as_deref() != Some(catalog_commit.as_str())
}

/// Writes skill `id` into `base/.claude/skills/<id>/`: every bundled file (LICENSE included) and the marker. An older
/// copy that Bandito installed is replaced as a whole (see `commands::install`). A folder the person made is refused
/// (`exists_not_ours`). `base` is the daemon user's home or an agent's folder.
pub fn install(base: &Path, id: &str) -> Result<PathBuf, InstallError> {
    let (Some(files), Some(entry)) = (bundled_files(id), catalog_entry(id)) else {
        return unknown(id);
    };
    let commit = entry["source"]["commit"]
        .as_str()
        .expect("catalog entries have a pinned commit: the tests check it");
    let target = commands::checked_skill_folder(base, id)?;
    if slot(base, id) == Slot::Foreign {
        return Err(InstallError {
            reason: "exists_not_ours",
            message: format!(
                "{} exists and was not installed by Bandito; it is not replaced",
                target.display()
            ),
        });
    }
    let mut install_files: Vec<InstallFile> = files
        .iter()
        .map(|(rel, _)| InstallFile {
            path: (*rel).to_string(),
            // The path came from the same table, so the file is there.
            content: STANDARD.encode(bundled_file(id, rel).expect("listed file is bundled")),
        })
        .collect();
    let marker = json!({ "id": id, "commit": commit }).to_string();
    install_files.push(InstallFile {
        path: MARKER.to_string(),
        content: STANDARD.encode(marker),
    });
    remove_leftovers(base, id)?;
    commands::install(base, InstallKind::Skill, id, &install_files, true)
}

/// Removes what an interrupted install left beside skill `id`: the folders `.<id>.tmp-*` and `.<id>.old-*`. Only real
/// folders are removed; a link with that name is left alone.
fn remove_leftovers(base: &Path, id: &str) -> Result<(), InstallError> {
    let skills = base.join(".claude").join("skills");
    let Ok(read) = fs::read_dir(&skills) else {
        return Ok(());
    };
    let prefixes = [format!(".{id}.tmp-"), format!(".{id}.old-")];
    for entry in read.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let leftover = prefixes.iter().any(|p| name.starts_with(p.as_str()));
        if leftover && entry.file_type().is_ok_and(|t| t.is_dir()) {
            let path = entry.path();
            fs::remove_dir_all(&path).map_err(|e| InstallError {
                reason: "io",
                message: format!("{}: {e}", path.display()),
            })?;
        }
    }
    Ok(())
}

/// Removes `base/.claude/skills/<id>/`, only when Bandito installed it (`not_ours` otherwise). A link is refused
/// (`unsafe_path`) and never followed; links inside the folder are removed as links.
pub fn remove(base: &Path, id: &str) -> Result<PathBuf, InstallError> {
    if !is_catalog_id(id) {
        return unknown(id);
    }
    let target = commands::checked_skill_folder(base, id)?;
    match slot(base, id) {
        Slot::Ours => {}
        Slot::Absent => {
            return Err(InstallError {
                reason: "not_installed",
                message: format!("skill {id} is not installed here"),
            });
        }
        Slot::Foreign => {
            return Err(InstallError {
                reason: "not_ours",
                message: format!("{} was not installed by Bandito; it is not removed", target.display()),
            });
        }
    }
    fs::remove_dir_all(&target).map_err(|e| InstallError {
        reason: "io",
        message: format!("{}: {e}", target.display()),
    })?;
    Ok(target)
}

fn unknown<T>(id: &str) -> Result<T, InstallError> {
    Err(InstallError {
        reason: "unknown_skill",
        message: format!("no skill {id} in the catalog"),
    })
}

#[cfg(test)]
mod tests {
    use super::CATALOG;
    use serde::Deserialize;
    use std::collections::HashSet;
    use std::fs;
    use std::path::{Path, PathBuf};

    const ALLOWED_LICENSES: [&str; 7] = [
        "MIT",
        "Apache-2.0",
        "BSD-2-Clause",
        "BSD-3-Clause",
        "ISC",
        "CC0-1.0",
        "CC-BY-4.0",
    ];
    const MAX_FILES: usize = 50;
    const MAX_BYTES: u64 = 2 * 1024 * 1024;
    const CODE_EXTENSIONS: [&str; 6] = ["sh", "py", "js", "ts", "cjs", "mjs"];

    #[allow(dead_code)]
    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Entry {
        id: String,
        name: String,
        publisher: String,
        source: Source,
        category: Category,
        description_en: String,
        description_ru: String,
        long_en: String,
        long_ru: String,
        l10n: L10n,
        runtimes: Vec<Runtime>,
        scripts: bool,
        warning_en: Option<String>,
        warning_ru: Option<String>,
        files: Vec<String>,
    }

    #[allow(dead_code)]
    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Source {
        repo: String,
        path: String,
        commit: String,
        license: String,
    }

    #[derive(Debug, PartialEq, Deserialize)]
    #[serde(rename_all = "lowercase")]
    enum Category {
        Dev,
        Writing,
        Design,
        Research,
        Data,
        Productivity,
        Ops,
    }

    #[derive(Debug, PartialEq, Deserialize)]
    #[serde(rename_all = "lowercase")]
    enum Runtime {
        Claude,
        Codex,
        Grok,
    }

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct L10n {
        de: Text,
        es: Text,
        fr: Text,
        ja: Text,
        ko: Text,
        #[serde(rename = "pt-BR")]
        pt_br: Text,
        #[serde(rename = "zh-Hans")]
        zh_hans: Text,
    }

    impl L10n {
        fn all(&self) -> [(&'static str, &Text); 7] {
            [
                ("de", &self.de),
                ("es", &self.es),
                ("fr", &self.fr),
                ("ja", &self.ja),
                ("ko", &self.ko),
                ("pt-BR", &self.pt_br),
                ("zh-Hans", &self.zh_hans),
            ]
        }
    }

    #[derive(Debug, Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Text {
        description: String,
        long: String,
    }

    fn load() -> Vec<Entry> {
        serde_json::from_str(CATALOG).expect("skills_catalog.json matches the schema")
    }

    fn skills_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("skills")
    }

    /// Every file under `dir`, as paths relative to `dir` with `/` separators.
    fn folder_files(dir: &Path) -> Vec<String> {
        fn walk(dir: &Path, base: &Path, out: &mut Vec<String>) {
            for entry in fs::read_dir(dir).expect("skill folder is readable") {
                let path = entry.expect("directory entry").path();
                if path.is_dir() {
                    walk(&path, base, out);
                } else {
                    let rel = path.strip_prefix(base).expect("under the skill folder");
                    out.push(rel.to_string_lossy().replace('\\', "/"));
                }
            }
        }
        let mut out = Vec::new();
        walk(dir, dir, &mut out);
        out.sort();
        out
    }

    /// The author's license file, copied to the top of the folder; not part of the skill's `files`.
    fn is_notice(rel: &str) -> bool {
        matches!(rel, "LICENSE" | "NOTICE")
    }

    fn is_code(path: &Path) -> bool {
        let by_extension = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| CODE_EXTENSIONS.contains(&e));
        by_extension || is_executable(path)
    }

    #[cfg(unix)]
    fn is_executable(path: &Path) -> bool {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
    }

    #[cfg(not(unix))]
    fn is_executable(_path: &Path) -> bool {
        false
    }

    #[test]
    fn catalog_parses_strictly() {
        assert!(!load().is_empty());
    }

    #[test]
    fn unknown_field_is_rejected() {
        let text = CATALOG.replacen('{', "{\"surprise\": true,", 1);
        assert!(serde_json::from_str::<Vec<Entry>>(&text).is_err());
    }

    #[test]
    fn ids_are_unique_slugs() {
        let mut seen = HashSet::new();
        for e in load() {
            let slug = !e.id.is_empty()
                && e.id
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
            assert!(slug, "id {:?} is not [a-z0-9-]+", e.id);
            assert!(seen.insert(e.id.clone()), "duplicate id {}", e.id);
        }
    }

    #[test]
    fn every_skill_has_skill_md_and_license_on_disk() {
        for e in load() {
            let dir = skills_dir().join(&e.id);
            assert!(dir.join("SKILL.md").is_file(), "{}: SKILL.md is missing", e.id);
            let license =
                fs::read_to_string(dir.join("LICENSE")).unwrap_or_else(|_| panic!("{}: LICENSE is missing", e.id));
            assert!(!license.trim().is_empty(), "{}: LICENSE is empty", e.id);
        }
    }

    #[test]
    fn files_match_the_folder_and_install_limits_hold() {
        for e in load() {
            let dir = skills_dir().join(&e.id);
            let actual = folder_files(&dir);

            assert!(
                e.files.iter().all(|f| !is_notice(f)),
                "{}: files must not list LICENSE or NOTICE",
                e.id
            );
            let listed: HashSet<&String> = e.files.iter().collect();
            assert_eq!(listed.len(), e.files.len(), "{}: duplicate entries in files", e.id);

            let mut expected = e.files.clone();
            expected.sort();
            let mut on_disk: Vec<String> = actual.iter().filter(|f| !is_notice(f)).cloned().collect();
            on_disk.sort();
            assert_eq!(expected, on_disk, "{}: files differ from the folder", e.id);

            assert!(
                actual.len() <= MAX_FILES,
                "{}: {} files, limit is {MAX_FILES}",
                e.id,
                actual.len()
            );
            let bytes: u64 = actual
                .iter()
                .map(|f| fs::metadata(dir.join(f)).expect("file exists").len())
                .sum();
            assert!(bytes <= MAX_BYTES, "{}: {bytes} bytes, limit is {MAX_BYTES}", e.id);
        }
    }

    #[test]
    fn licenses_are_allowed_and_match_the_license_file() {
        for e in load() {
            let spdx = e.source.license.as_str();
            assert!(
                ALLOWED_LICENSES.contains(&spdx),
                "{}: license {spdx} is not allowed",
                e.id
            );
            let text = fs::read_to_string(skills_dir().join(&e.id).join("LICENSE")).expect("LICENSE exists");
            let looks_right = match spdx {
                "MIT" => text.contains("MIT License"),
                "Apache-2.0" => text.contains("Apache License") && text.contains("Version 2.0"),
                _ => !text.trim().is_empty(),
            };
            assert!(looks_right, "{}: LICENSE file does not look like {spdx}", e.id);
        }
    }

    #[test]
    fn sources_are_pinned_to_a_commit() {
        for e in load() {
            let commit = &e.source.commit;
            assert!(
                commit.len() == 40 && commit.chars().all(|c| c.is_ascii_digit() || matches!(c, 'a'..='f')),
                "{}: commit must be a full lowercase SHA",
                e.id
            );
            assert_eq!(e.source.repo.split('/').count(), 2, "{}: repo must be owner/name", e.id);
            assert!(
                Path::new(&e.source.path).file_name().and_then(|n| n.to_str()) == Some(e.id.as_str()),
                "{}: source path must end with the skill id",
                e.id
            );
        }
    }

    #[test]
    fn all_texts_are_filled_in_every_language() {
        for e in load() {
            let plain = [
                ("name", &e.name),
                ("publisher", &e.publisher),
                ("description_en", &e.description_en),
                ("description_ru", &e.description_ru),
                ("long_en", &e.long_en),
                ("long_ru", &e.long_ru),
            ];
            for (field, value) in plain {
                assert!(!value.trim().is_empty(), "{}: {field} is empty", e.id);
            }
            for (lang, text) in e.l10n.all() {
                assert!(
                    !text.description.trim().is_empty(),
                    "{}: l10n {lang} description is empty",
                    e.id
                );
                assert!(!text.long.trim().is_empty(), "{}: l10n {lang} long is empty", e.id);
            }
            assert_eq!(
                e.warning_en.is_some(),
                e.warning_ru.is_some(),
                "{}: warning_en and warning_ru come together",
                e.id
            );
            for warning in [&e.warning_en, &e.warning_ru].into_iter().flatten() {
                assert!(!warning.trim().is_empty(), "{}: empty warning", e.id);
            }
        }
    }

    #[test]
    fn scripts_flag_and_runtimes_agree_with_the_folder() {
        for e in load() {
            let dir = skills_dir().join(&e.id);
            let has_code = folder_files(&dir).iter().any(|f| is_code(&dir.join(f)));
            assert_eq!(e.scripts, has_code, "{}: scripts flag does not match the folder", e.id);
            if e.scripts {
                assert_eq!(
                    e.runtimes,
                    vec![Runtime::Claude],
                    "{}: scripts run only on claude",
                    e.id
                );
            } else {
                assert_eq!(
                    e.runtimes,
                    vec![Runtime::Claude, Runtime::Codex, Runtime::Grok],
                    "{}: instruction-only skills run on every runtime",
                    e.id
                );
            }
        }
    }
}

#[cfg(test)]
mod install_tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn source(id: &str, rel: &str) -> Vec<u8> {
        fs::read(Path::new(env!("CARGO_MANIFEST_DIR")).join("skills").join(id).join(rel)).unwrap()
    }

    #[test]
    fn the_bundle_matches_the_folders_and_holds_no_dotfiles() {
        for (id, files) in SKILLS {
            assert!(!files.is_empty(), "{id} has no files");
            for (rel, bytes) in files.iter() {
                assert!(!rel.split('/').any(|c| c.starts_with('.')), "{id}/{rel} is a dotfile");
                assert_eq!(*bytes, source(id, rel).as_slice(), "{id}/{rel}");
            }
        }
    }

    #[test]
    fn bundled_file_looks_up_one_file() {
        assert_eq!(
            bundled_file("commit", "SKILL.md").unwrap(),
            source("commit", "SKILL.md").as_slice()
        );
        assert!(bundled_file("commit", "missing.md").is_none());
        assert!(bundled_file("nope", "SKILL.md").is_none());
    }

    #[test]
    fn every_skill_is_installed_with_a_marker_and_the_right_modes() {
        for entry in catalog() {
            let id = entry["id"].as_str().unwrap();
            let home = TempDir::new().unwrap();
            install(home.path(), id).unwrap();
            let folder = home.path().join(".claude/skills").join(id);
            assert_eq!(slot(home.path(), id), Slot::Ours, "{id}");
            check_modes(&folder, id);
        }
    }

    #[cfg(unix)]
    fn check_modes(folder: &Path, id: &str) {
        use std::os::unix::fs::PermissionsExt;
        for (rel, bytes) in bundled_files(id).unwrap() {
            let expected = commands::skill_file_mode(Path::new(rel), bytes);
            let mode = fs::metadata(folder.join(rel)).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, expected, "{id}/{rel}");
        }
    }

    #[cfg(not(unix))]
    fn check_modes(_folder: &Path, _id: &str) {}

    #[test]
    fn modes_follow_scripts_and_shebangs() {
        assert_eq!(
            commands::skill_file_mode(Path::new("scripts/run.py"), b"print(1)"),
            0o755
        );
        assert_eq!(commands::skill_file_mode(Path::new("tool.sh"), b"#!/bin/sh\n"), 0o755);
        assert_eq!(commands::skill_file_mode(Path::new("SKILL.md"), b"# Skill"), 0o644);
        assert_eq!(commands::skill_file_mode(Path::new("notes/scripts.md"), b"text"), 0o644);
    }

    #[test]
    fn a_folder_the_person_made_is_never_replaced() {
        let home = TempDir::new().unwrap();
        let folder = home.path().join(".claude/skills/commit");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("SKILL.md"), "mine").unwrap();
        let err = install(home.path(), "commit").unwrap_err();
        assert_eq!(err.reason, "exists_not_ours");
        assert_eq!(fs::read_to_string(folder.join("SKILL.md")).unwrap(), "mine");
        assert_eq!(slot(home.path(), "commit"), Slot::Foreign);
    }

    #[test]
    fn a_failed_write_leaves_the_old_copy_and_no_temporary_folder() {
        // `x` is a file and `x/y` needs `x` to be a folder: the write fails halfway through the new copy.
        let home = TempDir::new().unwrap();
        install(home.path(), "commit").unwrap();
        let folder = home.path().join(".claude/skills/commit");
        fs::write(folder.join("keep.md"), "old").unwrap();
        let mut files: Vec<InstallFile> = bundled_files("commit")
            .unwrap()
            .iter()
            .map(|(rel, _)| InstallFile {
                path: (*rel).to_string(),
                content: STANDARD.encode(bundled_file("commit", rel).unwrap()),
            })
            .collect();
        files.push(InstallFile {
            path: "x".into(),
            content: STANDARD.encode("file"),
        });
        files.push(InstallFile {
            path: "x/y".into(),
            content: STANDARD.encode("nested"),
        });
        let err = commands::install(home.path(), InstallKind::Skill, "commit", &files, true).unwrap_err();
        assert_eq!(err.reason, "io");
        assert_eq!(fs::read_to_string(folder.join("keep.md")).unwrap(), "old");
        assert!(folder.join("SKILL.md").is_file());
        let names: Vec<String> = fs::read_dir(home.path().join(".claude/skills"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["commit".to_string()], "no .tmp or .old folder left");
    }

    #[cfg(unix)]
    #[test]
    fn a_linked_claude_folder_is_refused_before_any_write() {
        use std::os::unix::fs::symlink;
        let home = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        symlink(outside.path(), home.path().join(".claude")).unwrap();
        let err = install(home.path(), "commit").unwrap_err();
        assert_eq!(err.reason, "unsafe_path");
        assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
    }
}

#[cfg(all(test, unix))]
mod leftover_tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;
    use tempfile::TempDir;

    #[test]
    fn install_clears_the_leftovers_of_its_own_id_only() {
        let home = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        let skills = home.path().join(".claude/skills");
        fs::create_dir_all(skills.join(".commit.tmp-1/sub")).unwrap();
        fs::write(skills.join(".commit.tmp-1/sub/x"), "junk").unwrap();
        fs::create_dir_all(skills.join(".commit.old-2")).unwrap();
        fs::write(skills.join(".commit.old-2/SKILL.md"), "old").unwrap();
        fs::create_dir_all(skills.join(".other.tmp-3")).unwrap();
        fs::write(skills.join(".other.tmp-3/keep"), "keep").unwrap();
        symlink(outside.path(), skills.join(".commit.tmp-4")).unwrap();
        fs::write(outside.path().join("data"), "outside").unwrap();

        install(home.path(), "commit").unwrap();
        assert!(!skills.join(".commit.tmp-1").exists());
        assert!(!skills.join(".commit.old-2").exists());
        assert_eq!(fs::read_to_string(skills.join(".other.tmp-3/keep")).unwrap(), "keep");
        assert_eq!(fs::read_to_string(outside.path().join("data")).unwrap(), "outside");
        assert!(
            skills.join(".commit.tmp-4").symlink_metadata().is_ok(),
            "a link is left alone"
        );
        assert_eq!(slot(home.path(), "commit"), Slot::Ours);
    }
}
