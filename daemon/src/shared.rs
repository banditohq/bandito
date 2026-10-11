//! Shared bots and skills: the payloads that `agents.export`, `skills.export`, `agents.create_from_shared` and
//! `skills.install_shared` read and write (see docs/ARCHITECTURE.md#sharing). The limits are the platform's: a payload
//! that the platform accepts is accepted here, and an export never makes a payload the import would refuse.
//! The RPC layer is `rpc::templates` (bots) and `rpc::skills` (skills).

use crate::commands::{self, InstallError};
use crate::skills::{self, MARKER, Slot};
use crate::store::{ALL_CAPABILITIES, Agent, Capability};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// The integrations catalog: the ids of the services a shared bot may name, and their urls.
const INTEGRATIONS_JSON: &str = include_str!("integrations_catalog.json");

/// The only payload schema this daemon reads and writes.
pub const SCHEMA: u32 = 1;
pub const BOT_NAME_MAX: usize = 40;
pub const BOT_ROLE_MAX: usize = 80;
pub const BOT_PROMPT_MAX: usize = 20_000;
pub const BOT_SERVICES_MAX: usize = 20;
pub const BOT_SCHEDULES_MAX: usize = 5;
pub const BOT_SCHEDULE_TEXT_MAX: usize = 120;
pub const BOT_SCHEDULE_PROMPT_MAX: usize = 4_000;
pub const BOT_STARTER_MAX: usize = 2_000;
pub const SKILL_DESCRIPTION_MAX: usize = 1_024;
pub const SKILL_FILES_MAX: usize = 50;
/// The bytes of all files of a skill together.
pub const SKILL_BYTES_MAX: usize = 150 * 1024;
/// The licenses a skill may name (the platform's list).
pub const LICENSES: [&str; 9] = [
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "MPL-2.0",
    "CC-BY-4.0",
    "CC0-1.0",
    "Unlicense",
];

/// A bot as shared: no secrets, memory, paths or integration accounts. `services` are catalog ids.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BotPayload {
    pub schema: u32,
    pub name: String,
    pub role: String,
    pub system_prompt: String,
    pub capabilities: Vec<String>,
    pub services: Vec<String>,
    pub schedules: Vec<BotSchedule>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub starter: Option<String>,
}

/// One schedule of a shared bot. `text` is the cron of the schedule (5 fields, in the server's zone rules).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BotSchedule {
    pub text: String,
    pub prompt: String,
}

/// A skill as shared: its files as UTF-8 text by path inside the folder, and the paths that are executable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SkillPayload {
    pub schema: u32,
    pub name: String,
    pub description: String,
    pub license: String,
    pub files: BTreeMap<String, String>,
    pub executable: Vec<String>,
}

/// Why a shared payload, a parameter, or a skill folder cannot be used.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ShareError {
    /// A payload or parameter is wrong. The RPC message is `invalid: <field>` (`INVALID_PARAMS`).
    Invalid(String),
    /// A folder or file cannot be used. `reason` is the stable code in `error.data.reason` (`COMMANDS_ERROR`).
    Refused { reason: &'static str, message: String },
}

impl ShareError {
    pub fn invalid(field: impl Into<String>) -> Self {
        ShareError::Invalid(field.into())
    }

    fn refused(reason: &'static str, message: impl Into<String>) -> Self {
        ShareError::Refused {
            reason,
            message: message.into(),
        }
    }
}

impl From<InstallError> for ShareError {
    fn from(e: InstallError) -> Self {
        ShareError::Refused {
            reason: e.reason,
            message: e.message,
        }
    }
}

/// Parses a bot payload and checks it against the limits. An unknown key is `invalid: <key>`.
pub fn parse_bot(value: Value) -> Result<BotPayload, ShareError> {
    let p: BotPayload = serde_json::from_value(value).map_err(serde_field)?;
    check_bot(&p)?;
    Ok(p)
}

/// Parses a skill payload and checks it against the limits.
pub fn parse_skill(value: Value) -> Result<SkillPayload, ShareError> {
    let p: SkillPayload = serde_json::from_value(value).map_err(serde_field)?;
    check_skill(&p)?;
    Ok(p)
}

/// The limits of a bot payload, field by field. The first failing field is named.
pub fn check_bot(p: &BotPayload) -> Result<(), ShareError> {
    check_schema(p.schema)?;
    let name = p.name.trim();
    if name.is_empty() || name.chars().count() > BOT_NAME_MAX {
        return Err(ShareError::invalid("name"));
    }
    if p.role.chars().count() > BOT_ROLE_MAX {
        return Err(ShareError::invalid("role"));
    }
    if p.system_prompt.chars().count() > BOT_PROMPT_MAX {
        return Err(ShareError::invalid("system_prompt"));
    }
    let mut seen = HashSet::new();
    for c in &p.capabilities {
        if Capability::parse(c).is_none() || !seen.insert(c.as_str()) {
            return Err(ShareError::invalid("capabilities"));
        }
    }
    if p.services.len() > BOT_SERVICES_MAX || p.services.iter().any(|s| !service_id(s)) {
        return Err(ShareError::invalid("services"));
    }
    if p.schedules.len() > BOT_SCHEDULES_MAX {
        return Err(ShareError::invalid("schedules"));
    }
    for (i, s) in p.schedules.iter().enumerate() {
        if s.text.trim().is_empty() || s.text.chars().count() > BOT_SCHEDULE_TEXT_MAX {
            return Err(ShareError::invalid(format!("schedules[{i}].text")));
        }
        if s.prompt.trim().is_empty() || s.prompt.chars().count() > BOT_SCHEDULE_PROMPT_MAX {
            return Err(ShareError::invalid(format!("schedules[{i}].prompt")));
        }
    }
    if p.starter.as_ref().is_some_and(|s| s.chars().count() > BOT_STARTER_MAX) {
        return Err(ShareError::invalid("starter"));
    }
    Ok(())
}

/// The limits of a skill payload: schema, name, description, license, files (count, bytes, paths, `SKILL.md`) and
/// the executables (under `scripts/`, listed files only).
pub fn check_skill(p: &SkillPayload) -> Result<(), ShareError> {
    check_schema(p.schema)?;
    if !skill_name(&p.name) {
        return Err(ShareError::invalid("name"));
    }
    if p.description.trim().is_empty() || p.description.chars().count() > SKILL_DESCRIPTION_MAX {
        return Err(ShareError::invalid("description"));
    }
    if !LICENSES.contains(&p.license.as_str()) {
        return Err(ShareError::invalid("license"));
    }
    if p.files.len() > SKILL_FILES_MAX {
        return Err(ShareError::invalid("files"));
    }
    let mut total = 0usize;
    for (path, text) in &p.files {
        if !valid_path(path) {
            return Err(ShareError::invalid("files"));
        }
        total += text.len();
    }
    if total > SKILL_BYTES_MAX {
        return Err(ShareError::invalid("files"));
    }
    // A file cannot also be the folder of another file.
    for a in p.files.keys() {
        for b in p.files.keys() {
            if b.len() > a.len() && b.starts_with(a.as_str()) && b.as_bytes()[a.len()] == b'/' {
                return Err(ShareError::invalid("files"));
            }
        }
    }
    if !p.files.contains_key("SKILL.md") {
        return Err(ShareError::invalid("SKILL.md"));
    }
    let mut seen = HashSet::new();
    for e in &p.executable {
        let under_scripts = e.starts_with("scripts/");
        if !under_scripts || !valid_path(e) || !p.files.contains_key(e) || !seen.insert(e.as_str()) {
            return Err(ShareError::invalid("executable"));
        }
    }
    Ok(())
}

/// Whether `path` is a safe relative path of a skill: each `/`-separated component is non-empty, does not start with
/// a dot (so no `.`, `..`, hidden names) and holds only letters, digits, `.`, `_` and `-`. Checked per component.
pub fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && path.split('/').all(|seg| {
            !seg.is_empty()
                && !seg.starts_with('.')
                && !seg.contains("..")
                && seg
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        })
}

/// A share id: 22 characters, base62 (`[0-9A-Za-z]`). Anything else is `invalid: share_id`.
pub fn check_share_id(id: &str) -> Result<(), ShareError> {
    if id.len() == 22 && id.bytes().all(|c| c.is_ascii_alphanumeric()) {
        Ok(())
    } else {
        Err(ShareError::invalid("share_id"))
    }
}

/// A share version: an integer from 1. Anything else is `invalid: version`.
pub fn check_version(version: u32) -> Result<(), ShareError> {
    if version >= 1 {
        Ok(())
    } else {
        Err(ShareError::invalid("version"))
    }
}

/// Whether `id` is a service of the integrations catalog (`integrations_catalog.json`).
pub fn is_catalog_service(id: &str) -> bool {
    catalog_entries().iter().any(|e| e["id"].as_str() == Some(id))
}

/// The catalog id of an integration with `name` and `url`: `name` when it is a catalog id, else the entry whose url is
/// `url`. None for a custom integration.
pub fn catalog_service(name: &str, url: Option<&str>) -> Option<String> {
    let entries = catalog_entries();
    if entries.iter().any(|e| e["id"].as_str() == Some(name)) {
        return Some(name.to_string());
    }
    let url = url?;
    entries
        .iter()
        .find(|e| e["url"].as_str() == Some(url))
        .and_then(|e| e["id"].as_str())
        .map(str::to_string)
}

/// The bot payload of `agent`, with the services and schedules the caller computed (see `rpc::templates`). Fails with
/// `invalid: <field>` when the agent is over a limit, so an export never makes a payload the import would refuse.
pub fn bot_from_agent(
    agent: &Agent,
    services: Vec<String>,
    schedules: Vec<BotSchedule>,
) -> Result<BotPayload, ShareError> {
    let capabilities = match &agent.capabilities {
        Some(list) => list.iter().map(|c| c.as_str().to_string()).collect(),
        // Null means every capability (see docs/ARCHITECTURE.md#capabilities).
        None => ALL_CAPABILITIES.iter().map(|c| c.as_str().to_string()).collect(),
    };
    let p = BotPayload {
        schema: SCHEMA,
        name: agent.name.clone(),
        role: agent.role.clone(),
        system_prompt: agent.system_prompt.clone().unwrap_or_default(),
        capabilities,
        services,
        schedules,
        starter: None,
    };
    check_bot(&p)?;
    Ok(p)
}

/// The skill payload of the folder `base/.claude/skills/<name>`, for `skills.export`. `license` is the owner's choice
/// (None is `license_required`). Refused, with the path named: a catalog install (`catalog_skill`), no folder
/// (`no_skill`), a link (`unsafe_path`), a file that is not a regular file (`unsafe_path`), a path component the
/// payload does not allow (`bad_path`), a file that is not UTF-8 (`not_utf8`), a file over the limit (`too_large`).
/// The marker `.bandito-skill` at the top is never exported. Executables are the files under `scripts/` with an execute
/// bit. The description is the `description:` line of the SKILL.md front matter.
pub fn skill_from_folder(base: &Path, name: &str, license: Option<&str>) -> Result<SkillPayload, ShareError> {
    if !skill_name(name) {
        return Err(ShareError::invalid("name"));
    }
    let license = license.ok_or_else(|| {
        ShareError::refused(
            "license_required",
            "the skill needs a license: pass one of the platform's licenses",
        )
    })?;
    if !LICENSES.contains(&license) {
        return Err(ShareError::invalid("license"));
    }
    let skills_dir = base.join(".claude").join("skills");
    for link in [base.join(".claude"), skills_dir.clone()] {
        if fs::symlink_metadata(&link).is_ok_and(|m| m.file_type().is_symlink()) {
            return Err(ShareError::refused(
                "unsafe_path",
                format!("{} is a link; skills are not shared through it", link.display()),
            ));
        }
    }
    let dir = skills_dir.join(name);
    let meta = fs::symlink_metadata(&dir)
        .map_err(|_| ShareError::refused("no_skill", format!("no skill {name} in {}", skills_dir.display())))?;
    if meta.file_type().is_symlink() {
        return Err(ShareError::refused(
            "unsafe_path",
            format!("{} is a link; it is not shared", dir.display()),
        ));
    }
    if !meta.is_dir() {
        return Err(ShareError::refused(
            "no_skill",
            format!("{} is not a skill folder", dir.display()),
        ));
    }
    if catalog_marker(&dir, name) {
        return Err(ShareError::refused(
            "catalog_skill",
            format!("{name} is a skill of the catalog: only the owner's own skills are shared"),
        ));
    }

    let mut found = Vec::new();
    walk(&dir, "", &mut found)?;
    let mut files = BTreeMap::new();
    let mut executable = Vec::new();
    for (rel, path, exec) in found {
        let bytes = fs::read(&path).map_err(|e| io_refused(&path, &e))?;
        if bytes.len() > SKILL_BYTES_MAX {
            return Err(ShareError::refused("too_large", format!("{rel} is over 150 KiB")));
        }
        let text = String::from_utf8(bytes)
            .map_err(|_| ShareError::refused("not_utf8", format!("{rel} is not UTF-8 text")))?;
        if exec && rel.starts_with("scripts/") {
            executable.push(rel.clone());
        }
        files.insert(rel, text);
    }
    let skill_md = files.get("SKILL.md").ok_or_else(|| ShareError::invalid("SKILL.md"))?;
    let description = description_of(skill_md).ok_or_else(|| ShareError::invalid("description"))?;
    let p = SkillPayload {
        schema: SCHEMA,
        name: name.to_string(),
        description,
        license: license.to_string(),
        files,
        executable,
    };
    check_skill(&p)?;
    Ok(p)
}

/// Writes a shared skill into `base/.claude/skills/<name>/` as `skills::install` does: the same folder checks, the same
/// atomic replace, the same leftovers cleanup. The marker is `{"id", "source": "shared:<share_id>", "version"}`. Modes:
/// 0755 for the paths in `executable` and 0644 for every other file, the marker included.
/// A folder that is not Bandito's, or a Bandito folder of another source, is `exists_not_ours`. A Bandito copy of the
/// same share is replaced (`updated: true`). A name that is a catalog id is `catalog_skill`.
pub fn install_shared(
    base: &Path,
    name: &str,
    share_id: &str,
    version: u32,
    payload: &SkillPayload,
) -> Result<(PathBuf, bool), ShareError> {
    if name != payload.name {
        return Err(ShareError::invalid("name"));
    }
    check_share_id(share_id)?;
    check_version(version)?;
    check_skill(payload)?;
    if skills::is_catalog_id(name) {
        return Err(ShareError::refused(
            "catalog_skill",
            format!("{name} is the name of a skill in the catalog; a shared skill cannot take it"),
        ));
    }
    let source = format!("shared:{share_id}");
    let target = commands::checked_skill_folder(base, name)?;
    let updated = match skills::slot(base, name) {
        Slot::Absent => false,
        Slot::Foreign => {
            return Err(ShareError::refused(
                "exists_not_ours",
                format!(
                    "{} exists and was not installed by Bandito; it is not replaced",
                    target.display()
                ),
            ));
        }
        // Only the same share replaces its own copy. A catalog copy or another share's copy is kept.
        Slot::Ours => {
            if marker_source(&target).as_deref() != Some(source.as_str()) {
                return Err(ShareError::refused(
                    "exists_not_ours",
                    format!(
                        "{} was installed from another source; it is not replaced",
                        target.display()
                    ),
                ));
            }
            true
        }
    };
    let mut files: Vec<(PathBuf, Vec<u8>, u32)> = payload
        .files
        .iter()
        .map(|(rel, text)| {
            let mode = if payload.executable.contains(rel) { 0o755 } else { 0o644 };
            (PathBuf::from(rel), text.as_bytes().to_vec(), mode)
        })
        .collect();
    let marker = json!({ "id": name, "source": source, "version": version }).to_string();
    files.push((PathBuf::from(MARKER), marker.into_bytes(), 0o644));
    skills::remove_leftovers(base, name)?;
    let path = commands::write_skill(base, name, &files)?;
    Ok((path, updated))
}

/// The integrations catalog as JSON values. The file is checked by the tests, so the parse cannot fail at run time.
fn catalog_entries() -> Vec<Value> {
    serde_json::from_str(INTEGRATIONS_JSON).expect("integrations_catalog.json is valid JSON: the tests check it")
}

/// The key a serde error names: an unknown key, or a required one that is missing. Any other error is `payload`.
fn serde_field(e: serde_json::Error) -> ShareError {
    let text = e.to_string();
    for prefix in ["unknown field `", "missing field `"] {
        let named = text.strip_prefix(prefix).and_then(|rest| rest.split_once('`'));
        if let Some((field, _)) = named {
            return ShareError::invalid(field);
        }
    }
    ShareError::invalid("payload")
}

fn check_schema(schema: u32) -> Result<(), ShareError> {
    if schema == SCHEMA {
        Ok(())
    } else {
        Err(ShareError::invalid("schema"))
    }
}

/// A skill name: lowercase letters, digits and `-`, starting with a letter or a digit, 1 to 64 characters.
fn skill_name(name: &str) -> bool {
    let b = name.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

/// A service id as the catalog writes it: lowercase letters, digits, `-` and `_`, 1 to 64 characters.
fn service_id(id: &str) -> bool {
    let b = id.as_bytes();
    !b.is_empty()
        && b.len() <= 64
        && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit())
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || matches!(c, b'-' | b'_'))
}

/// Whether `folder` holds a marker of a catalog install of `name`: `{"id", "commit"}`, with no `source`. A shared
/// install has a `source` and no `commit`.
fn catalog_marker(folder: &Path, name: &str) -> bool {
    let path = folder.join(MARKER);
    if !fs::symlink_metadata(&path).is_ok_and(|m| m.is_file()) {
        return false;
    }
    let Ok(text) = fs::read_to_string(&path) else {
        return false;
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return false;
    };
    v.get("id").and_then(Value::as_str) == Some(name)
        && v.get("commit").is_some_and(Value::is_string)
        && v.get("source").is_none()
}

/// The `source` of a shared install's marker, or None.
fn marker_source(folder: &Path) -> Option<String> {
    let text = fs::read_to_string(folder.join(MARKER)).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.get("source")?.as_str().map(str::to_string)
}

/// Every file under `dir`, relative to the skill folder: `(path, absolute path, executable)`. The marker at the top is
/// skipped. A link, or a file that is not a regular file, is refused (`unsafe_path`); a path the payload does not allow
/// is refused (`bad_path`). Both name the path.
fn walk(dir: &Path, rel: &str, found: &mut Vec<(String, PathBuf, bool)>) -> Result<(), ShareError> {
    let mut entries: Vec<fs::DirEntry> = fs::read_dir(dir)
        .map_err(|e| io_refused(dir, &e))?
        .collect::<Result<_, _>>()
        .map_err(|e| io_refused(dir, &e))?;
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let os_name = entry.file_name();
        let Some(file_name) = os_name.to_str() else {
            return Err(ShareError::refused(
                "bad_path",
                format!("{} has a name that is not UTF-8", entry.path().display()),
            ));
        };
        if rel.is_empty() && file_name == MARKER {
            continue;
        }
        let child = if rel.is_empty() {
            file_name.to_string()
        } else {
            format!("{rel}/{file_name}")
        };
        let path = entry.path();
        let meta = fs::symlink_metadata(&path).map_err(|e| io_refused(&path, &e))?;
        if meta.file_type().is_symlink() {
            return Err(ShareError::refused(
                "unsafe_path",
                format!("{child} is a link; links are not shared"),
            ));
        }
        if meta.is_dir() {
            walk(&path, &child, found)?;
            continue;
        }
        if !meta.is_file() {
            return Err(ShareError::refused(
                "unsafe_path",
                format!("{child} is not a regular file"),
            ));
        }
        if !valid_path(&child) {
            return Err(ShareError::refused(
                "bad_path",
                format!("{child} is a name a shared skill cannot have"),
            ));
        }
        found.push((child, path, is_executable(&meta)));
    }
    Ok(())
}

#[cfg(unix)]
fn is_executable(meta: &fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_meta: &fs::Metadata) -> bool {
    false
}

fn io_refused(path: &Path, e: &std::io::Error) -> ShareError {
    ShareError::refused("io", format!("{}: {e}", path.display()))
}

/// The `description:` line of a SKILL.md front matter, without quotes. A folded or literal block (`>`, `|`) is not
/// read, and an empty value is none: the owner is asked for one line.
fn description_of(skill_md: &str) -> Option<String> {
    let mut lines = skill_md.lines();
    if lines.next()?.trim_end() != "---" {
        return None;
    }
    for line in lines {
        if line.trim_end() == "---" {
            break;
        }
        if let Some(value) = line.strip_prefix("description:") {
            let value = value.trim();
            let quoted = value.len() >= 2
                && ((value.starts_with('"') && value.ends_with('"'))
                    || (value.starts_with('\'') && value.ends_with('\'')));
            let text = if quoted { &value[1..value.len() - 1] } else { value };
            let block = matches!(value, ">" | "|" | ">-" | "|-" | ">+" | "|+");
            return (!block && !text.is_empty()).then(|| text.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::features;
    use serde_json::json;
    use std::fs;
    use tempfile::TempDir;

    const SHARE: &str = "AbCdEfGhIjKlMnOpQrStUv";
    const OTHER_SHARE: &str = "ZyXwVuTsRqPoNmLkJiHgFe";

    fn bot() -> Value {
        json!({
            "schema": 1,
            "name": "Scout",
            "role": "Finds sources",
            "system_prompt": "You find sources.",
            "capabilities": ["browser", "files"],
            "services": ["notion"],
            "schedules": [{"text": "0 9 * * *", "prompt": "Morning digest"}],
        })
    }

    fn skill_md() -> String {
        "---\nname: release-notes\ndescription: Writes release notes\n---\n\n# Release notes\n".to_string()
    }

    fn skill() -> Value {
        json!({
            "schema": 1,
            "name": "release-notes",
            "description": "Writes release notes",
            "license": "MIT",
            "files": {
                "SKILL.md": skill_md(),
                "scripts/run.sh": "#!/bin/sh\necho hi\n",
                "docs/notes.md": "details",
            },
            "executable": ["scripts/run.sh"],
        })
    }

    /// `v` with `key` set to `value`.
    fn with(mut v: Value, key: &str, value: Value) -> Value {
        v[key] = value;
        v
    }

    fn invalid(v: Value) -> String {
        match parse_bot(v) {
            Err(ShareError::Invalid(field)) => field,
            other => panic!("expected invalid, got {other:?}"),
        }
    }

    fn skill_invalid(v: Value) -> String {
        match parse_skill(v) {
            Err(ShareError::Invalid(field)) => field,
            other => panic!("expected invalid, got {other:?}"),
        }
    }

    fn repeat_chars(c: char, n: usize) -> String {
        std::iter::repeat_n(c, n).collect()
    }

    // ---- bot payload ----

    #[test]
    fn a_valid_bot_is_accepted_and_round_trips() {
        let p = parse_bot(bot()).unwrap();
        assert_eq!(p.name, "Scout");
        assert_eq!(p.starter, None);
        assert_eq!(
            serde_json::to_value(&p).unwrap(),
            bot(),
            "no starter key when there is none"
        );
    }

    #[test]
    fn an_unknown_key_is_invalid_and_named() {
        assert_eq!(invalid(with(bot(), "memory", json!("x"))), "memory");
    }

    #[test]
    fn schema_must_be_the_number_one() {
        assert_eq!(invalid(with(bot(), "schema", json!(2))), "schema");
        assert_eq!(
            invalid(with(bot(), "schema", json!("1"))),
            "payload",
            "a string is not the number one"
        );
        let mut no_schema = bot();
        no_schema.as_object_mut().unwrap().remove("schema");
        assert!(parse_bot(no_schema).is_err(), "schema is required");
    }

    #[test]
    fn a_wrong_type_is_invalid() {
        assert_eq!(invalid(with(bot(), "name", json!(5))), "payload");
    }

    #[test]
    fn bot_name_is_one_to_forty_characters_and_not_blank() {
        assert_eq!(invalid(with(bot(), "name", json!(""))), "name");
        assert_eq!(invalid(with(bot(), "name", json!("   "))), "name");
        assert!(
            parse_bot(with(bot(), "name", json!(repeat_chars('а', BOT_NAME_MAX)))).is_ok(),
            "40 Cyrillic letters"
        );
        assert_eq!(invalid(with(bot(), "name", json!(repeat_chars('a', 41)))), "name");
    }

    #[test]
    fn bot_limits_pass_at_the_edge_and_fail_one_past() {
        let cases: Vec<(&str, Value, Value, &str)> = vec![
            (
                "role",
                json!(repeat_chars('r', BOT_ROLE_MAX)),
                json!(repeat_chars('r', BOT_ROLE_MAX + 1)),
                "role",
            ),
            (
                "system_prompt",
                json!(repeat_chars('p', BOT_PROMPT_MAX)),
                json!(repeat_chars('p', BOT_PROMPT_MAX + 1)),
                "system_prompt",
            ),
            (
                "services",
                json!((0..BOT_SERVICES_MAX).map(|i| format!("svc-{i}")).collect::<Vec<_>>()),
                json!((0..=BOT_SERVICES_MAX).map(|i| format!("svc-{i}")).collect::<Vec<_>>()),
                "services",
            ),
            (
                "schedules",
                json!(vec![json!({"text": "0 9 * * *", "prompt": "p"}); BOT_SCHEDULES_MAX]),
                json!(vec![json!({"text": "0 9 * * *", "prompt": "p"}); BOT_SCHEDULES_MAX + 1]),
                "schedules",
            ),
            (
                "starter",
                json!(repeat_chars('s', BOT_STARTER_MAX)),
                json!(repeat_chars('s', BOT_STARTER_MAX + 1)),
                "starter",
            ),
        ];
        for (key, edge, past, field) in cases {
            assert!(parse_bot(with(bot(), key, edge)).is_ok(), "{key} at its limit");
            assert_eq!(invalid(with(bot(), key, past)), field, "{key} one past its limit");
        }
    }

    #[test]
    fn schedule_text_and_prompt_limits_pass_at_the_edge() {
        let at = |text: String, prompt: String| with(bot(), "schedules", json!([{"text": text, "prompt": prompt}]));
        assert!(
            parse_bot(at(
                repeat_chars('0', BOT_SCHEDULE_TEXT_MAX),
                repeat_chars('p', BOT_SCHEDULE_PROMPT_MAX)
            ))
            .is_ok()
        );
        assert_eq!(
            invalid(at(repeat_chars('0', BOT_SCHEDULE_TEXT_MAX + 1), "p".into())),
            "schedules[0].text"
        );
        assert_eq!(
            invalid(at("0 9 * * *".into(), repeat_chars('p', BOT_SCHEDULE_PROMPT_MAX + 1))),
            "schedules[0].prompt"
        );
    }

    #[test]
    fn a_schedule_takes_only_text_and_prompt() {
        let v = with(
            bot(),
            "schedules",
            json!([{"text": "0 9 * * *", "prompt": "p", "enabled": false}]),
        );
        assert_eq!(invalid(v), "enabled");
    }

    #[test]
    fn capabilities_are_the_daemon_names_without_repeats() {
        assert_eq!(
            invalid(with(bot(), "capabilities", json!(["teleport"]))),
            "capabilities"
        );
        assert_eq!(
            invalid(with(bot(), "capabilities", json!(["files", "files"]))),
            "capabilities"
        );
        assert!(
            parse_bot(with(bot(), "capabilities", json!([]))).is_ok(),
            "an empty list is a real choice"
        );
    }

    #[test]
    fn services_are_catalog_shaped_and_unknown_ones_pass_the_check() {
        assert_eq!(invalid(with(bot(), "services", json!(["Bad Id!"]))), "services");
        assert_eq!(invalid(with(bot(), "services", json!(["../notion"]))), "services");
        assert!(
            parse_bot(with(bot(), "services", json!(["service-not-in-catalog"]))).is_ok(),
            "dropped at creation, not refused"
        );
    }

    #[test]
    fn a_starter_is_kept_when_present() {
        let p = parse_bot(with(bot(), "starter", json!("Start here"))).unwrap();
        assert_eq!(p.starter.as_deref(), Some("Start here"));
    }

    // ---- skill payload ----

    #[test]
    fn a_valid_skill_is_accepted() {
        let p = parse_skill(skill()).unwrap();
        assert_eq!(p.executable, vec!["scripts/run.sh".to_string()]);
        assert_eq!(p.files.len(), 3);
    }

    #[test]
    fn a_skill_has_the_schema_no_unknown_key_and_a_platform_license() {
        assert_eq!(skill_invalid(with(skill(), "schema", json!(2))), "schema");
        assert_eq!(skill_invalid(with(skill(), "owner", json!("me"))), "owner");
        assert_eq!(skill_invalid(with(skill(), "license", json!("GPL-3.0"))), "license");
        let mut no_license = skill();
        no_license.as_object_mut().unwrap().remove("license");
        assert!(parse_skill(no_license).is_err(), "license is required");
    }

    #[test]
    fn skill_names_follow_the_pattern_and_the_length_limit() {
        for bad in ["Bad", "-x", "a_b", "", "a.b", &repeat_chars('a', 65)] {
            assert_eq!(skill_invalid(with(skill(), "name", json!(bad))), "name", "{bad}");
        }
        assert!(parse_skill(with(skill(), "name", json!("a"))).is_ok());
        assert!(parse_skill(with(skill(), "name", json!(repeat_chars('a', 64)))).is_ok());
    }

    #[test]
    fn description_is_required_and_at_most_1024_characters() {
        assert_eq!(skill_invalid(with(skill(), "description", json!(""))), "description");
        assert!(
            parse_skill(with(
                skill(),
                "description",
                json!(repeat_chars('d', SKILL_DESCRIPTION_MAX))
            ))
            .is_ok()
        );
        assert_eq!(
            skill_invalid(with(
                skill(),
                "description",
                json!(repeat_chars('d', SKILL_DESCRIPTION_MAX + 1))
            )),
            "description"
        );
    }

    #[test]
    fn paths_are_checked_one_component_at_a_time() {
        for good in ["SKILL.md", "a/b.md", "scripts/run.sh", "v1.2/x-y_z.md", "docs/a.b.md"] {
            assert!(valid_path(good), "{good} is a valid path");
        }
        for bad in [
            "../x",
            "/abs",
            "a//b",
            ".hidden/x",
            "scripts/../../x",
            "scripts/./run.sh",
            "a\\b",
            "",
            "x/",
            "sp ace.md",
            "a/..b",
            "a/.b/c",
        ] {
            assert!(!valid_path(bad), "{bad} is not a valid path");
        }
    }

    #[test]
    fn a_bad_path_in_the_files_is_invalid() {
        for bad in ["../x", "/abs", "a//b", ".hidden/x", "scripts/../../x"] {
            let mut v = skill();
            v["files"][bad] = json!("x");
            assert_eq!(skill_invalid(v), "files", "{bad}");
        }
    }

    #[test]
    fn a_skill_needs_skill_md() {
        let mut v = skill();
        v["files"].as_object_mut().unwrap().remove("SKILL.md");
        assert_eq!(skill_invalid(v), "SKILL.md");
    }

    #[test]
    fn a_file_cannot_be_both_a_file_and_a_folder_of_another() {
        let mut v = skill();
        v["files"]["docs"] = json!("a file named docs");
        v["files"]["docs/notes.md"] = json!("inside");
        assert_eq!(skill_invalid(v), "files");
    }

    #[test]
    fn executables_are_listed_files_under_scripts() {
        let outside = with(skill(), "executable", json!(["docs/notes.md"]));
        assert_eq!(skill_invalid(outside), "executable");
        let missing = with(skill(), "executable", json!(["scripts/gone.sh"]));
        assert_eq!(skill_invalid(missing), "executable");
        let twice = with(skill(), "executable", json!(["scripts/run.sh", "scripts/run.sh"]));
        assert_eq!(skill_invalid(twice), "executable");
        let none = with(skill(), "executable", json!([]));
        assert!(parse_skill(none).is_ok(), "no executables is fine");
    }

    #[test]
    fn the_file_count_and_the_bytes_have_limits_that_pass_at_the_edge() {
        let mut many = skill();
        many["files"] = json!({"SKILL.md": skill_md()});
        for i in 0..SKILL_FILES_MAX - 1 {
            many["files"][format!("docs/f{i}.md")] = json!("x");
        }
        assert!(parse_skill(many.clone()).is_ok(), "50 files");
        many["files"][format!("docs/f{}.md", SKILL_FILES_MAX)] = json!("x");
        assert_eq!(skill_invalid(many), "files", "51 files");

        let mut exact = skill();
        exact["files"] = json!({"SKILL.md": skill_md()});
        let used = skill_md().len();
        exact["files"]["docs/big.md"] = json!(repeat_chars('b', SKILL_BYTES_MAX - used));
        assert!(parse_skill(exact.clone()).is_ok(), "exactly 150 KiB in all");
        exact["files"]["docs/big.md"] = json!(repeat_chars('b', SKILL_BYTES_MAX - used + 1));
        assert_eq!(skill_invalid(exact), "files", "one byte over");
    }

    // ---- ids, versions, catalog ----

    #[test]
    fn a_share_id_is_22_base62_characters() {
        assert!(check_share_id(SHARE).is_ok());
        for bad in [
            "",
            "AbCdEfGhIjKlMnOpQrStU",
            "AbCdEfGhIjKlMnOpQrStUvW",
            "AbCdEfGhIjKlMnOpQrSt-v",
        ] {
            assert_eq!(check_share_id(bad), Err(ShareError::invalid("share_id")), "{bad}");
        }
    }

    #[test]
    fn a_version_starts_at_one() {
        assert!(check_version(1).is_ok());
        assert_eq!(check_version(0), Err(ShareError::invalid("version")));
    }

    #[test]
    fn a_catalog_service_matches_by_name_or_by_its_catalog_url() {
        assert!(is_catalog_service("notion"));
        assert!(!is_catalog_service("nope-not-here"));
        assert_eq!(catalog_service("notion", None), Some("notion".to_string()));
        assert_eq!(catalog_service("my-own", None), None);
        let entries: Vec<Value> = serde_json::from_str(include_str!("integrations_catalog.json")).unwrap();
        let url = entries.iter().find(|e| e["id"] == "notion").unwrap()["url"]
            .as_str()
            .unwrap();
        assert_eq!(catalog_service("my-own", Some(url)), Some("notion".to_string()));
        assert_eq!(catalog_service("my-own", Some("https://example.invalid/")), None);
    }

    #[test]
    fn the_daemon_advertises_sharing() {
        assert!(features().contains(&"sharing"));
    }

    // ---- reading a skill folder ----

    /// A folder the person made: a `SKILL.md` with a description, and a script that can run.
    fn own_skill(home: &Path, name: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let dir = home.join(".claude/skills").join(name);
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::create_dir_all(dir.join("docs")).unwrap();
        fs::write(dir.join("SKILL.md"), skill_md()).unwrap();
        fs::write(dir.join("scripts/run.sh"), "#!/bin/sh\necho hi\n").unwrap();
        fs::set_permissions(dir.join("scripts/run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        fs::write(dir.join("scripts/plain.txt"), "no bit").unwrap();
        fs::write(dir.join("docs/notes.md"), "details").unwrap();
        dir
    }

    #[test]
    #[cfg(unix)]
    fn a_folder_exports_its_files_and_its_executables() {
        let home = TempDir::new().unwrap();
        own_skill(home.path(), "release-notes");
        let p = skill_from_folder(home.path(), "release-notes", Some("MIT")).unwrap();
        assert_eq!(p.name, "release-notes");
        assert_eq!(p.description, "Writes release notes");
        assert_eq!(p.license, "MIT");
        let names: Vec<&str> = p.files.keys().map(String::as_str).collect();
        assert_eq!(
            names,
            vec!["SKILL.md", "docs/notes.md", "scripts/plain.txt", "scripts/run.sh"]
        );
        assert_eq!(p.executable, vec!["scripts/run.sh".to_string()]);
        assert!(
            parse_skill(serde_json::to_value(&p).unwrap()).is_ok(),
            "the export is a valid payload"
        );
    }

    #[test]
    fn a_catalog_install_is_not_exported() {
        let home = TempDir::new().unwrap();
        let dir = own_skill(home.path(), "commit");
        fs::write(
            dir.join(MARKER_NAME),
            r#"{"id":"commit","commit":"0123456789abcdef0123456789abcdef01234567"}"#,
        )
        .unwrap();
        match skill_from_folder(home.path(), "commit", Some("MIT")) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "catalog_skill"),
            other => panic!("expected catalog_skill, got {other:?}"),
        }
    }

    #[test]
    fn the_license_is_the_owners_and_is_required() {
        let home = TempDir::new().unwrap();
        own_skill(home.path(), "release-notes");
        match skill_from_folder(home.path(), "release-notes", None) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "license_required"),
            other => panic!("expected license_required, got {other:?}"),
        }
        assert_eq!(
            skill_from_folder(home.path(), "release-notes", Some("GPL-3.0")),
            Err(ShareError::invalid("license"))
        );
    }

    #[test]
    fn a_missing_folder_is_refused() {
        let home = TempDir::new().unwrap();
        match skill_from_folder(home.path(), "nothing-here", Some("MIT")) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "no_skill"),
            other => panic!("expected no_skill, got {other:?}"),
        }
    }

    #[test]
    #[cfg(unix)]
    fn a_link_in_the_folder_is_refused_and_the_path_is_named() {
        use std::os::unix::fs::symlink;
        let home = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        fs::write(outside.path().join("secret.md"), "outside").unwrap();
        let dir = own_skill(home.path(), "release-notes");
        symlink(outside.path().join("secret.md"), dir.join("docs/link.md")).unwrap();
        match skill_from_folder(home.path(), "release-notes", Some("MIT")) {
            Err(ShareError::Refused { reason, message }) => {
                assert_eq!(reason, "unsafe_path");
                assert!(message.contains("docs/link.md"), "{message}");
            }
            other => panic!("expected a refusal naming the link, got {other:?}"),
        }
    }

    #[test]
    fn a_file_that_is_not_utf8_is_refused_with_its_path() {
        let home = TempDir::new().unwrap();
        let dir = own_skill(home.path(), "release-notes");
        fs::write(dir.join("docs/image.md"), [0xff, 0xfe, 0x00]).unwrap();
        match skill_from_folder(home.path(), "release-notes", Some("MIT")) {
            Err(ShareError::Refused { reason, message }) => {
                assert_eq!(reason, "not_utf8");
                assert!(message.contains("docs/image.md"), "{message}");
            }
            other => panic!("expected not_utf8, got {other:?}"),
        }
    }

    #[test]
    fn a_file_over_the_limit_is_refused_with_its_path() {
        let home = TempDir::new().unwrap();
        let dir = own_skill(home.path(), "release-notes");
        fs::write(dir.join("docs/huge.md"), repeat_chars('h', SKILL_BYTES_MAX + 1)).unwrap();
        match skill_from_folder(home.path(), "release-notes", Some("MIT")) {
            Err(ShareError::Refused { reason, message }) => {
                assert_eq!(reason, "too_large");
                assert!(message.contains("docs/huge.md"), "{message}");
            }
            other => panic!("expected too_large, got {other:?}"),
        }
    }

    #[test]
    fn a_file_whose_name_the_payload_does_not_allow_is_refused_with_its_path() {
        let home = TempDir::new().unwrap();
        let dir = own_skill(home.path(), "release-notes");
        fs::write(dir.join("docs/.env"), "x").unwrap();
        match skill_from_folder(home.path(), "release-notes", Some("MIT")) {
            Err(ShareError::Refused { reason, message }) => {
                assert_eq!(reason, "bad_path");
                assert!(message.contains("docs/.env"), "{message}");
            }
            other => panic!("expected bad_path, got {other:?}"),
        }
    }

    #[test]
    fn a_folder_without_a_description_is_invalid() {
        let home = TempDir::new().unwrap();
        let dir = own_skill(home.path(), "release-notes");
        fs::write(dir.join("SKILL.md"), "# no front matter\n").unwrap();
        assert_eq!(
            skill_from_folder(home.path(), "release-notes", Some("MIT")),
            Err(ShareError::invalid("description"))
        );
    }

    #[test]
    fn the_marker_is_never_exported() {
        let home = TempDir::new().unwrap();
        let dir = own_skill(home.path(), "release-notes");
        fs::write(dir.join(MARKER_NAME), r#"{"id":"release-notes"}"#).unwrap();
        let p = skill_from_folder(home.path(), "release-notes", Some("MIT")).unwrap();
        assert!(!p.files.contains_key(MARKER_NAME));
    }

    // ---- writing a shared skill ----

    fn payload() -> SkillPayload {
        parse_skill(skill()).unwrap()
    }

    fn marker_of(folder: &Path) -> Value {
        serde_json::from_str(&fs::read_to_string(folder.join(MARKER_NAME)).unwrap()).unwrap()
    }

    #[cfg(unix)]
    fn mode_of(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    #[test]
    #[cfg(unix)]
    fn install_writes_the_files_a_marker_and_modes_only_for_executables() {
        let base = TempDir::new().unwrap();
        let mut p = payload();
        p.files.insert("scripts/other.sh".into(), "#!/bin/sh\n".into());
        p.files
            .insert("tool".into(), "#!/bin/sh\nstill not executable\n".into());
        let (path, updated) = install_shared(base.path(), "release-notes", SHARE, 1, &p).unwrap();
        assert!(!updated);
        assert_eq!(path, base.path().join(".claude/skills/release-notes"));
        assert_eq!(fs::read_to_string(path.join("docs/notes.md")).unwrap(), "details");
        assert_eq!(mode_of(&path.join("scripts/run.sh")), 0o755, "listed as executable");
        assert_eq!(
            mode_of(&path.join("scripts/other.sh")),
            0o644,
            "under scripts but not listed"
        );
        assert_eq!(
            mode_of(&path.join("tool")),
            0o644,
            "a shebang alone does not make it executable"
        );
        assert_eq!(mode_of(&path.join("SKILL.md")), 0o644);
        assert_eq!(mode_of(&path.join(MARKER_NAME)), 0o644);
        let marker = marker_of(&path);
        assert_eq!(marker["id"], "release-notes");
        assert_eq!(marker["source"], format!("shared:{SHARE}"));
        assert_eq!(marker["version"], 1);
    }

    #[test]
    fn install_refuses_a_folder_that_is_not_its_own_and_touches_nothing() {
        let base = TempDir::new().unwrap();
        let mine = base.path().join(".claude/skills/release-notes");
        fs::create_dir_all(&mine).unwrap();
        fs::write(mine.join("SKILL.md"), "mine").unwrap();
        match install_shared(base.path(), "release-notes", SHARE, 1, &payload()) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "exists_not_ours"),
            other => panic!("expected exists_not_ours, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(mine.join("SKILL.md")).unwrap(), "mine");
        assert!(!mine.join(MARKER_NAME).exists());
    }

    #[test]
    fn a_shared_copy_is_updated_by_the_same_share_and_kept_from_others() {
        let base = TempDir::new().unwrap();
        install_shared(base.path(), "release-notes", SHARE, 1, &payload()).unwrap();
        let folder = base.path().join(".claude/skills/release-notes");
        fs::write(folder.join("stale.md"), "old").unwrap();

        let mut v2 = payload();
        v2.files.remove("docs/notes.md");
        v2.files.insert("SKILL.md".into(), skill_md() + "\nv2\n");
        v2.executable.clear();
        let (_, updated) = install_shared(base.path(), "release-notes", SHARE, 2, &v2).unwrap();
        assert!(updated, "the same share replaces its own copy");
        assert!(!folder.join("stale.md").exists(), "replaced as a whole");
        assert!(!folder.join("docs/notes.md").exists());
        assert_eq!(marker_of(&folder)["version"], 2);
        #[cfg(unix)]
        {
            assert_eq!(mode_of(&folder.join("scripts/run.sh")), 0o644, "no longer executable");
        }

        match install_shared(base.path(), "release-notes", OTHER_SHARE, 1, &payload()) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "exists_not_ours"),
            other => panic!("another share's copy is kept, got {other:?}"),
        }
        assert_eq!(marker_of(&folder)["source"], format!("shared:{SHARE}"));
    }

    #[test]
    fn a_catalog_name_is_refused_and_a_catalog_copy_is_not_replaced() {
        let base = TempDir::new().unwrap();
        let mut as_catalog = payload();
        as_catalog.name = "commit".into();
        match install_shared(base.path(), "commit", SHARE, 1, &as_catalog) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "catalog_skill"),
            other => panic!("expected catalog_skill, got {other:?}"),
        }
        let folder = base.path().join(".claude/skills/release-notes");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("SKILL.md"), "x").unwrap();
        fs::write(folder.join(MARKER_NAME), r#"{"id":"release-notes","commit":"abc"}"#).unwrap();
        match install_shared(base.path(), "release-notes", SHARE, 1, &payload()) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "exists_not_ours"),
            other => panic!("a catalog copy is not replaced, got {other:?}"),
        }
    }

    #[test]
    fn install_leaves_no_temporary_folder_behind() {
        let base = TempDir::new().unwrap();
        install_shared(base.path(), "release-notes", SHARE, 1, &payload()).unwrap();
        install_shared(base.path(), "release-notes", SHARE, 2, &payload()).unwrap();
        let names: Vec<String> = fs::read_dir(base.path().join(".claude/skills"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["release-notes".to_string()]);
    }

    #[test]
    #[cfg(unix)]
    fn install_never_writes_through_a_linked_skills_folder() {
        use std::os::unix::fs::symlink;
        let base = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        fs::create_dir_all(base.path().join(".claude")).unwrap();
        symlink(outside.path(), base.path().join(".claude/skills")).unwrap();
        match install_shared(base.path(), "release-notes", SHARE, 1, &payload()) {
            Err(ShareError::Refused { reason, .. }) => assert_eq!(reason, "unsafe_path"),
            other => panic!("expected unsafe_path, got {other:?}"),
        }
        assert!(fs::read_dir(outside.path()).unwrap().next().is_none());
    }

    /// The marker's file name, as the skills module names it.
    const MARKER_NAME: &str = ".bandito-skill";
}
