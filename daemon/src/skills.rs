//! Vendored skills: each folder under `daemon/skills/<id>/` is a copy of the author's folder at a pinned commit, and
//! `skills_catalog.json` describes them. The files are compiled into the binary (`build.rs`). The `skills.*` RPC
//! methods (`rpc::skills`) serve the catalog and install or remove a skill; see docs/ARCHITECTURE.md#skills.
//! The tests hold the data to the rules the install path relies on.

use crate::commands::{self, InstallError, InstallFile, InstallKind};
use crate::runtime::RuntimeKind;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

include!(concat!(env!("OUT_DIR"), "/bundled_skills.rs"));

const CATALOG: &str = include_str!("skills_catalog.json");

/// The catalog entries, as written in `skills_catalog.json` (the files are listed by path, not by content).
pub fn catalog() -> Vec<Value> {
    serde_json::from_str(CATALOG).expect("skills_catalog.json is valid JSON: the tests check it")
}

/// Whether `id` is an entry of the catalog.
pub fn is_catalog_id(id: &str) -> bool {
    catalog()
        .iter()
        .any(|e| e.get("id").and_then(Value::as_str) == Some(id))
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

/// Writes skill `id` into `base/.claude/skills/<id>/`, with every bundled file (LICENSE included), replacing an
/// older copy. `base` is the daemon user's home or an agent's folder. The same code as `commands.install` with
/// `kind: skill` and `overwrite: true`.
pub fn install(base: &Path, id: &str) -> Result<PathBuf, InstallError> {
    let Some(files) = bundled_files(id) else {
        return unknown(id);
    };
    let install_files: Vec<InstallFile> = files
        .iter()
        .map(|(rel, _)| InstallFile {
            path: (*rel).to_string(),
            // The path came from the same table, so the file is there.
            content: STANDARD.encode(bundled_file(id, rel).expect("listed file is bundled")),
        })
        .collect();
    commands::install(base, InstallKind::Skill, id, &install_files, true)
}

/// Removes `base/.claude/skills/<id>/`. Only a real folder (not a link) that holds a `SKILL.md` file is removed.
/// Links inside it are removed as links and never followed, so nothing outside the folder is touched.
pub fn remove(base: &Path, id: &str) -> Result<PathBuf, InstallError> {
    if !is_catalog_id(id) {
        return unknown(id);
    }
    let skills_dir = base.join(".claude").join("skills");
    let target = skills_dir.join(id);
    let Ok(meta) = fs::symlink_metadata(&target) else {
        return Err(InstallError {
            reason: "not_installed",
            message: format!("skill {id} is not installed here"),
        });
    };
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return Err(InstallError {
            reason: "not_a_skill_folder",
            message: format!("{} is not a skill folder; a link is not removed", target.display()),
        });
    }
    // The folder's `.claude/skills` must be real folders too: nothing is removed through a link on the way.
    for dir in [base.join(".claude"), skills_dir] {
        if fs::symlink_metadata(&dir).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(InstallError {
                reason: "not_a_skill_folder",
                message: format!("{} is a link; skills are not removed through it", dir.display()),
            });
        }
    }
    let skill_md = fs::symlink_metadata(target.join("SKILL.md"));
    if !skill_md.is_ok_and(|m| m.is_file()) {
        return Err(InstallError {
            reason: "not_a_skill_folder",
            message: format!("{} has no SKILL.md; it is not removed", target.display()),
        });
    }
    fs::remove_dir_all(&target).map_err(|e| InstallError {
        reason: "io",
        message: format!("{}: {e}", target.display()),
    })?;
    Ok(target)
}

/// Ids of the skills in `home` (the daemon user's folder) or in an agent's folder `cwd` (pass `home` as None), as
/// `commands.list` reports them: source `skill`, named by the folder that holds `SKILL.md`.
pub fn installed_in(home: Option<&Path>, cwd: &Path) -> HashSet<String> {
    commands::discover(home, cwd, RuntimeKind::Claude)
        .into_iter()
        .filter(|c| c.source == commands::CommandSource::Skill)
        .filter_map(|c| c.path.parent()?.file_name()?.to_str().map(str::to_string))
        .collect()
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
