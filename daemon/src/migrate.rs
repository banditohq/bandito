//! Moving an agent to another server: the archive of an agent (settings, memory folder, history), its safe unpacking,
//! and the registry of the archives and uploads in flight. The methods are in `rpc/migrate.rs`; the rules and the
//! limits are in docs/ARCHITECTURE.md#agent-migration.
//!
//! An archive is a `tar.gz` with this layout, and nothing else is accepted:
//!
//! | entry | content |
//! |---|---|
//! | `manifest.json` | [`Manifest`]: the format, the agent's settings, and size and sha256 of every other file |
//! | `events.jsonl` | one JSON line per history event: `{seq, ts, kind, payload}` |
//! | `avatar.png` or `avatar.jpg` | the avatar picture, when the agent has one |
//! | `memory/...` | the agent's own folder: regular files and folders only |
//!
//! Unpacking never calls the tar crate's own extraction: every entry is checked and written here, into a fresh folder
//! the caller made, and only regular files and folders are ever created.

use crate::event::EventBody;
use crate::runtime::RuntimeKind;
use crate::store::{Agent, ApprovalMode, Avatar, Capability, Effort, MemoryMode, NewEvent, Store, validate_name};
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::{Arc, Mutex};

/// The archive format this daemon writes and reads.
pub const FORMAT: u32 = 1;
/// How long an archive, an upload or an unpacked folder lives (milliseconds). Older ones are removed on every call.
pub const TTL_MS: i64 = 60 * 60 * 1000;
/// The most bytes one `agents.migrate_read` returns.
pub const READ_MAX: usize = 1024 * 1024;
/// The most bytes one `agents.migrate_import_write` takes.
pub const WRITE_MAX: usize = 4 * 1024 * 1024;
/// Uploads that may be open at once.
pub const UPLOADS_MAX: usize = 2;
/// Exports that may wait to be read at once.
pub const EXPORTS_MAX: usize = 5;
/// The longest `moved_to`, in characters.
pub const MOVED_TO_MAX: usize = 64;
/// Files up to this size are read whole before they are written to the archive, so their size and hash are exact.
const SMALL_FILE: u64 = 16 * 1024 * 1024;
/// How many skipped paths the manifest names.
const SKIPPED_LISTED: usize = 200;
/// The longest part of a path (a file name).
const COMPONENT_MAX: usize = 255;

/// The history events that are carried over. Approvals, forms, connect requests and status events describe things that
/// do not exist on the new server (their records stay behind), so they would show as open questions nobody can answer.
pub const EVENT_KINDS: &[&str] = &[
    "turn.started",
    "message.user",
    "message.dropped",
    "message.assistant",
    "tool.call",
    "tool.result",
    "turn.completed",
    "session.rotated",
    "runtime.switched",
    "reaction",
    "error",
];

/// The limits of an archive. The defaults are the protocol's; tests use smaller ones.
#[derive(Debug, Clone)]
pub struct Limits {
    /// Files (and, separately, folders) in an archive.
    pub max_files: usize,
    /// Bytes of all files together, after unpacking.
    pub max_total_bytes: u64,
    /// The archive itself, and the upload.
    pub max_archive_bytes: u64,
    /// Bytes of a path.
    pub max_path_bytes: usize,
    /// Bytes of the manifest.
    pub max_manifest_bytes: u64,
    /// Bytes of one history line.
    pub max_line_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_files: 50_000,
            max_total_bytes: 2 * 1024 * 1024 * 1024,
            max_archive_bytes: 2 * 1024 * 1024 * 1024,
            max_path_bytes: 4096,
            max_manifest_bytes: 16 * 1024 * 1024,
            max_line_bytes: 8 * 1024 * 1024,
        }
    }
}

/// A refusal with a machine-readable `reason` (the RPC layer sends it as `error.data.reason`).
#[derive(Debug, Clone, PartialEq)]
pub struct MigrateError {
    pub reason: &'static str,
    pub message: String,
}

impl MigrateError {
    pub fn new(reason: &'static str, message: impl Into<String>) -> Self {
        Self {
            reason,
            message: message.into(),
        }
    }

    fn io(what: &str, e: &std::io::Error) -> Self {
        Self::new("io", format!("{what}: {e}"))
    }
}

impl std::fmt::Display for MigrateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.reason, self.message)
    }
}

impl std::error::Error for MigrateError {}

pub type Result<T> = std::result::Result<T, MigrateError>;

// ---- the manifest ----

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub format: u32,
    pub bandito_version: String,
    pub agent: AgentSpec,
    pub events_count: u64,
    pub files: Vec<FileEntry>,
    /// Paths that were left out of the archive and why (links, `.git` folders, files that could not be read). At most
    /// 200 are named.
    #[serde(default)]
    pub skipped: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    pub sha256: String,
}

/// The settings of the agent that move with it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentSpec {
    pub name: String,
    #[serde(default)]
    pub role: String,
    pub runtime: RuntimeKind,
    #[serde(default)]
    pub model: Option<String>,
    pub approval_mode: ApprovalMode,
    #[serde(default)]
    pub system_prompt: Option<String>,
    #[serde(default)]
    pub effort: Option<Effort>,
    pub memory_mode: MemoryMode,
    #[serde(default)]
    pub context_budget: Option<u32>,
    #[serde(default)]
    pub fallback_runtime: Option<RuntimeKind>,
    #[serde(default)]
    pub fallback_model: Option<String>,
    #[serde(default)]
    pub use_personal_settings: bool,
    /// Color, face and emoji. The picture is the archive's `avatar.*` file.
    #[serde(default)]
    pub avatar: Option<AvatarSpec>,
    /// `None`: all capabilities.
    #[serde(default)]
    pub capabilities: Option<Vec<Capability>>,
    /// Catalog ids of the services the agent used.
    #[serde(default)]
    pub services: Vec<String>,
    #[serde(default)]
    pub schedules: Vec<ScheduleSpec>,
    /// The agent's folder on the source server, to find its attachment files again.
    #[serde(default)]
    pub source_home: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AvatarSpec {
    pub color: String,
    pub face: String,
    #[serde(default)]
    pub emoji: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScheduleSpec {
    pub cron: String,
    pub tz: String,
    pub prompt: String,
    #[serde(default)]
    pub title: Option<String>,
}

impl AgentSpec {
    pub fn from_agent(agent: &Agent, services: Vec<String>, schedules: Vec<ScheduleSpec>) -> Self {
        Self {
            name: agent.name.clone(),
            role: agent.role.clone(),
            runtime: agent.runtime,
            model: agent.model.clone(),
            approval_mode: agent.approval_mode,
            system_prompt: agent.system_prompt.clone(),
            effort: agent.effort,
            memory_mode: agent.memory_mode,
            context_budget: agent.context_budget,
            fallback_runtime: agent.fallback_runtime,
            fallback_model: agent.fallback_model.clone(),
            use_personal_settings: agent.use_personal_settings,
            avatar: agent.avatar.as_ref().map(|a| AvatarSpec {
                color: a.color.clone(),
                face: a.face.clone(),
                emoji: a.emoji.clone(),
            }),
            capabilities: agent.capabilities.clone(),
            services,
            schedules,
            source_home: agent.home_dir.clone(),
        }
    }

    /// The avatar as the store takes it (the picture is set later, once the agent exists).
    pub fn avatar(&self) -> Option<Avatar> {
        self.avatar.as_ref().map(|a| {
            let mut avatar = Avatar::new(a.color.clone(), a.face.clone());
            avatar.emoji = a.emoji.clone();
            avatar
        })
    }
}

// ---- paths ----

/// The top-level names an archive may hold besides `memory/`.
const TOP_FILES: &[&str] = &["manifest.json", "events.jsonl", "avatar.png", "avatar.jpg"];
/// The marker that tells whose folder an agent's folder is: never carried, never accepted.
const MARKER: &str = ".bandito-agent";

fn bad_path(path: &str, why: &str) -> MigrateError {
    let shown: String = path.chars().take(120).collect();
    MigrateError::new("bad_path", format!("{why}: {shown}"))
}

/// Checks the path of an archive entry and returns it without a trailing `/`. Refuses an absolute path, `..`, `.`, an
/// empty part, a backslash, a NUL, a path or a part over its limit, a name that is not UTF-8, a `.git` part and the
/// agent marker, and anything outside the layout (`manifest.json`, `events.jsonl`, `avatar.*`, `memory/...`).
pub fn check_path(raw: &[u8], limits: &Limits) -> Result<String> {
    if raw.len() > limits.max_path_bytes {
        return Err(MigrateError::new("bad_path", "a path is over the length limit"));
    }
    let Ok(text) = std::str::from_utf8(raw) else {
        return Err(MigrateError::new("bad_path", "a path is not UTF-8"));
    };
    if text.starts_with('/') {
        return Err(bad_path(text, "absolute path"));
    }
    let path = text.strip_suffix('/').unwrap_or(text);
    if path.is_empty() {
        return Err(bad_path(text, "empty path"));
    }
    let parts: Vec<&str> = path.split('/').collect();
    for part in &parts {
        if part.is_empty() || *part == "." || *part == ".." {
            return Err(bad_path(text, "path with an empty, . or .. part"));
        }
        if part.contains('\\') || part.contains('\0') {
            return Err(bad_path(text, "path with a backslash or NUL"));
        }
        if part.len() > COMPONENT_MAX {
            return Err(bad_path(text, "a name in the path is too long"));
        }
    }
    match parts[0] {
        "memory" => {}
        top if TOP_FILES.contains(&top) && parts.len() == 1 => {}
        _ => return Err(bad_path(text, "path outside the archive layout")),
    }
    Ok(path.to_string())
}

/// Names that configure or run tools when an agent works in a folder (git hooks and config, the CLIs' settings, MCP
/// servers, editors, direnv): a moved folder must not bring them, whatever their case.
const EXCLUDED_NAMES: &[&str] = &[
    ".git",
    ".gitmodules",
    ".gitattributes",
    ".claude",
    ".codex",
    ".gemini",
    ".grok",
    ".cursor",
    ".vscode",
    ".idea",
    ".mcp.json",
    ".envrc",
    ".cargo",
    ".yarnrc.yml",
    ".yarnrc",
    ".npmrc",
    ".zed",
    ".opencode",
    ".windsurf",
    ".devcontainer",
    ".husky",
    ".pre-commit-config.yaml",
];

/// Names that are not carried when they start with one of these (the aider tool keeps several files).
const EXCLUDED_PREFIXES: &[&str] = &[".aider"];

/// A name as a file system that folds case and ignores some characters would see it: without zero-width and
/// direction marks and without combining marks (U+0300 to U+036F), the letters that fold to ASCII ones (long s,
/// Kelvin sign, dotted and dotless i) turned into them, then ASCII lowercase.
fn fold_name(part: &str) -> String {
    part.chars()
        .filter(|c| {
            !matches!(
                *c as u32,
                0x0300..=0x036F | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x206A..=0x206F | 0xFEFF | 0xAD
            )
        })
        .map(|c| match c {
            '\u{017F}' => 's',
            '\u{212A}' => 'k',
            '\u{0130}' | '\u{0131}' => 'i',
            other => other.to_ascii_lowercase(),
        })
        .collect()
}

/// Whether a folded name is one that is not carried.
fn excluded_name(folded: &str) -> bool {
    EXCLUDED_NAMES.contains(&folded) || EXCLUDED_PREFIXES.iter().any(|p| folded.starts_with(p))
}

/// Why a path below `memory/` is not carried, or `None`: a part that is one of [`EXCLUDED_NAMES`] (any depth, any
/// case), or the agent marker at the top. `CLAUDE.md` and `AGENTS.md` are the agent's memory and are carried.
pub fn excluded(rel: &str) -> Option<&'static str> {
    let mut parts = rel.split('/').filter(|p| !p.is_empty());
    if parts.clone().count() == 1 && fold_name(parts.clone().next()?) == MARKER {
        return Some("the agent marker is not carried");
    }
    if parts.any(|p| excluded_name(&fold_name(p))) {
        return Some("a tool configuration name is not carried");
    }
    None
}

// ---- writing the archive ----

/// A writer that hashes and counts what passes through and refuses more than `limit` bytes.
struct HashWriter<W> {
    inner: W,
    hasher: Sha256,
    written: u64,
    limit: u64,
    exceeded: Rc<Cell<bool>>,
}

impl<W: Write> Write for HashWriter<W> {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if self.written + buf.len() as u64 > self.limit {
            self.exceeded.set(true);
            return Err(std::io::Error::other("the archive is over the size limit"));
        }
        let n = self.inner.write(buf)?;
        self.hasher.update(&buf[..n]);
        self.written += n as u64;
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// Reads exactly `remaining` bytes of a file that may have changed since its size was read: a file that got shorter is
/// padded with zeros, one that got longer is cut. What was yielded is hashed, so the manifest matches the archive.
struct ExactReader {
    file: File,
    remaining: u64,
    hasher: Sha256,
    /// Set when the file ended before its size: the rest was padded with zeros.
    short: bool,
}

impl Read for ExactReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.remaining == 0 {
            return Ok(0);
        }
        let want = buf.len().min(self.remaining.min(usize::MAX as u64) as usize);
        let n = self.file.read(&mut buf[..want])?;
        let n = if n == 0 {
            self.short = true;
            buf[..want].fill(0);
            want
        } else {
            n
        };
        self.hasher.update(&buf[..n]);
        self.remaining -= n as u64;
        Ok(n)
    }
}

pub fn sha_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// The memory folder of an agent: what is in it and what is left out.
#[derive(Debug, Default)]
struct Walked {
    dirs: Vec<String>,
    /// Path below the folder and size at the time of the walk.
    files: Vec<(String, u64)>,
    skipped: Vec<String>,
}

fn skip(walked: &mut Walked, rel: &str, why: &str) {
    if walked.skipped.len() < SKIPPED_LISTED {
        walked.skipped.push(format!("{rel}: {why}"));
    }
}

// The folder is read through file descriptors: every part of every path is opened relative to the folder above it
// with O_NOFOLLOW, so a link put in place of a file or a folder after the walk is never followed.

fn from_fd(fd: i32) -> std::io::Result<OwnedFd> {
    if fd < 0 {
        Err(std::io::Error::last_os_error())
    } else {
        // SAFETY: `fd` is a new descriptor that nothing else owns.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }
}

fn c_name(name: &str) -> std::io::Result<CString> {
    CString::new(name).map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))
}

/// Opens the agent's folder itself (it may be reached through a link: it is the agent's own folder).
fn open_root(path: &Path) -> std::io::Result<OwnedFd> {
    let c = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    // SAFETY: `c` is a valid C string.
    from_fd(unsafe { libc::open(c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) })
}

fn open_at(dir: &OwnedFd, name: &str, flags: i32) -> std::io::Result<OwnedFd> {
    let c = c_name(name)?;
    // SAFETY: `dir` is an open descriptor and `c` a valid C string.
    from_fd(unsafe { libc::openat(dir.as_raw_fd(), c.as_ptr(), flags | libc::O_CLOEXEC | libc::O_NOFOLLOW) })
}

/// Opens `rel` below `root` one part at a time, never following a link. The last part is opened with `last`.
fn open_below(root: &OwnedFd, rel: &str, last: i32) -> std::io::Result<OwnedFd> {
    let parts: Vec<&str> = rel.split('/').filter(|p| !p.is_empty()).collect();
    let Some((final_part, folders)) = parts.split_last() else {
        return root.try_clone();
    };
    let mut cur = root.try_clone()?;
    for part in folders {
        cur = open_at(&cur, part, libc::O_RDONLY | libc::O_DIRECTORY)?;
    }
    open_at(&cur, final_part, last)
}

/// The names in an open folder.
fn list_names(dir: &OwnedFd) -> std::io::Result<Vec<std::ffi::OsString>> {
    let fd = dir.try_clone()?.into_raw_fd();
    // SAFETY: `fd` is a descriptor we own; on success the directory stream owns it.
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        let e = std::io::Error::last_os_error();
        // SAFETY: fdopendir failed, so `fd` is still ours.
        unsafe { libc::close(fd) };
        return Err(e);
    }
    let mut names = Vec::new();
    loop {
        clear_errno();
        // SAFETY: `stream` is open; the entry is read before the next call.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            // The end of the folder leaves errno as it was; a read error sets it. A short list is not an answer.
            let e = std::io::Error::last_os_error();
            // SAFETY: `stream` is open and closed once.
            unsafe { libc::closedir(stream) };
            return match e.raw_os_error() {
                Some(code) if code != 0 => Err(e),
                _ => Ok(names),
            };
        }
        // SAFETY: `d_name` is a NUL-terminated name.
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            names.push(std::ffi::OsString::from_vec(name.to_vec()));
        }
    }
}

fn clear_errno() {
    // SAFETY: the errno location of this thread is always valid to write.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    unsafe {
        *libc::__errno_location() = 0;
    }
    // SAFETY: as above.
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    unsafe {
        *libc::__error() = 0;
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Dir,
    File,
    Other,
}

/// What `name` in `dir` is, without following a link, and its size.
fn kind_at(dir: &OwnedFd, name: &str) -> std::io::Result<(Kind, u64)> {
    let c = c_name(name)?;
    // SAFETY: an all-zero `stat` is a valid value to fill in.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `dir` is open, `c` is a valid C string and `st` a valid out-pointer.
    if unsafe { libc::fstatat(dir.as_raw_fd(), c.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    let kind = match st.st_mode & libc::S_IFMT {
        libc::S_IFDIR => Kind::Dir,
        libc::S_IFREG => Kind::File,
        _ => Kind::Other,
    };
    Ok((kind, st.st_size.max(0) as u64))
}

#[cfg(test)]
type WalkHook = Box<dyn Fn(&str)>;

#[cfg(test)]
thread_local! {
    /// Called with the path of a folder right after its names were listed (a test puts a link in a file's place).
    pub(crate) static AFTER_LIST: std::cell::RefCell<Option<WalkHook>> = const { std::cell::RefCell::new(None) };
}

/// Lists the folder without following links. Only regular files and folders are taken. Links, sockets and the like,
/// the names of [`EXCLUDED_NAMES`] and names the archive cannot hold are skipped and named in `skipped`.
fn walk_memory(root: &OwnedFd, limits: &Limits) -> Result<Walked> {
    let mut walked = Walked::default();
    let mut total: u64 = 0;
    let mut stack: Vec<String> = vec![String::new()];
    while let Some(rel) = stack.pop() {
        let listed = open_below(root, &rel, libc::O_RDONLY | libc::O_DIRECTORY).and_then(|dir| {
            let names = list_names(&dir)?;
            Ok((dir, names))
        });
        let (dir, mut names) = match listed {
            Ok(v) => v,
            Err(e) => {
                skip(&mut walked, &rel, &format!("cannot be read: {e}"));
                continue;
            }
        };
        names.sort();
        #[cfg(test)]
        AFTER_LIST.with(|h| {
            if let Some(f) = h.borrow().as_ref() {
                f(&rel)
            }
        });
        for name in names {
            let Some(name) = name.to_str() else {
                skip(&mut walked, &rel, "a name that is not UTF-8");
                continue;
            };
            let child = if rel.is_empty() {
                name.to_string()
            } else {
                format!("{rel}/{name}")
            };
            if let Some(why) = excluded(&child) {
                skip(&mut walked, &child, why);
                continue;
            }
            let Ok((kind, size)) = kind_at(&dir, name) else {
                skip(&mut walked, &child, "cannot be read");
                continue;
            };
            if check_path(format!("memory/{child}").as_bytes(), limits).is_err() {
                skip(&mut walked, &child, "a name the archive cannot hold");
                continue;
            }
            match kind {
                Kind::Dir => {
                    if walked.dirs.len() >= limits.max_files {
                        return Err(MigrateError::new(
                            "too_many_files",
                            format!("the agent's folder has more than {} folders", limits.max_files),
                        ));
                    }
                    walked.dirs.push(child.clone());
                    stack.push(child);
                }
                Kind::File => {
                    if walked.files.len() >= limits.max_files {
                        return Err(MigrateError::new(
                            "too_many_files",
                            format!("the agent's folder has more than {} files", limits.max_files),
                        ));
                    }
                    total += size;
                    if total > limits.max_total_bytes {
                        return Err(MigrateError::new(
                            "too_large",
                            "the agent's folder is over the size limit",
                        ));
                    }
                    walked.files.push((child, size));
                }
                Kind::Other => skip(&mut walked, &child, "not a regular file or folder"),
            }
        }
    }
    walked.dirs.sort();
    walked.files.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(walked)
}

/// What an export made.
#[derive(Debug, Clone, PartialEq)]
pub struct Exported {
    pub size: u64,
    pub sha256: String,
    /// Files in the archive, `events.jsonl` and the avatar included, the manifest not.
    pub files: usize,
    pub events: u64,
    pub skipped: usize,
    /// The newest seq of the history at the time of the export: later events are not in the archive.
    pub upto: i64,
}

/// Everything an export reads about the agent.
pub struct ExportInput<'a> {
    pub store: &'a Store,
    pub agent: &'a Agent,
    pub services: Vec<String>,
    pub schedules: Vec<ScheduleSpec>,
    /// The picture's extension (`png` or `jpg`) and bytes.
    pub avatar: Option<(&'static str, Vec<u8>)>,
}

fn private_file(path: &Path) -> std::io::Result<File> {
    OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
}

fn tar_header(size: u64, mode: u32, mtime: u64) -> tar::Header {
    let mut header = tar::Header::new_gnu();
    header.set_size(size);
    header.set_mode(mode);
    header.set_mtime(mtime);
    header.set_uid(0);
    header.set_gid(0);
    header.set_entry_type(tar::EntryType::Regular);
    header
}

/// Writes `events.jsonl` for the agent up to the seq at the time of the call. Returns the file's hash and the count.
fn write_events(store: &Store, agent_id: &str, path: &Path, limits: &Limits) -> Result<(String, u64, i64)> {
    let upto = store
        .last_seq()
        .map_err(|e| MigrateError::new("io", format!("read the history: {e:#}")))?;
    let file = private_file(path).map_err(|e| MigrateError::io("create the history file", &e))?;
    let mut out = std::io::BufWriter::new(file);
    let mut hasher = Sha256::new();
    let mut after = 0;
    let mut count: u64 = 0;
    loop {
        let page = store
            .events_for_export(agent_id, after, upto, 2000)
            .map_err(|e| MigrateError::new("io", format!("read the history: {e:#}")))?;
        let Some(last) = page.last() else { break };
        after = last.seq;
        for event in &page {
            if !EVENT_KINDS.contains(&event.kind.as_str()) {
                continue;
            }
            let Ok(payload) = serde_json::from_str::<Value>(&event.payload) else {
                continue;
            };
            let mut line =
                serde_json::json!({ "seq": event.seq, "ts": event.ts, "kind": event.kind, "payload": payload })
                    .to_string();
            line.push('\n');
            if line.len() > limits.max_line_bytes {
                continue;
            }
            hasher.update(line.as_bytes());
            out.write_all(line.as_bytes())
                .map_err(|e| MigrateError::io("write the history file", &e))?;
            count += 1;
        }
    }
    out.flush()
        .map_err(|e| MigrateError::io("write the history file", &e))?;
    Ok((hex::encode(hasher.finalize()), count, upto))
}

/// Writes the agent's archive to `<dir>/<token>.tgz` (mode 0600) and returns its size and hash. A failure leaves no
/// file behind. `dir` must exist.
pub fn export_archive(input: ExportInput<'_>, dir: &Path, token: &str, limits: &Limits) -> Result<Exported> {
    let archive = dir.join(format!("{token}.tgz"));
    let events_tmp = dir.join(format!("ev-{token}.tmp"));
    let result = export_inner(&input, &archive, &events_tmp, limits);
    let _ = std::fs::remove_file(&events_tmp);
    if result.is_err() {
        let _ = std::fs::remove_file(&archive);
    }
    result
}

fn export_inner(input: &ExportInput<'_>, archive: &Path, events_tmp: &Path, limits: &Limits) -> Result<Exported> {
    let agent = input.agent;
    let (events_sha, events_count, upto) = write_events(input.store, &agent.id, events_tmp, limits)?;
    let events_size = std::fs::metadata(events_tmp)
        .map_err(|e| MigrateError::io("read the history file", &e))?
        .len();
    // No folder recorded, or one that is gone, means no memory files. Any other failure (no permission, not a
    // folder) is an error: the export must not go out silently without the memory.
    let root = match agent.home_dir.as_deref() {
        None => None,
        Some(home) => match open_root(Path::new(home)) {
            Ok(fd) => Some(fd),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(MigrateError::io("open the agent's folder", &e)),
        },
    };
    let walked = match &root {
        Some(root) => walk_memory(root, limits)?,
        None => Walked::default(),
    };

    let exceeded = Rc::new(Cell::new(false));
    let out = HashWriter {
        inner: private_file(archive).map_err(|e| MigrateError::io("create the archive", &e))?,
        hasher: Sha256::new(),
        written: 0,
        limit: limits.max_archive_bytes,
        exceeded: exceeded.clone(),
    };
    let mut builder = tar::Builder::new(GzEncoder::new(out, Compression::default()));
    let fail = |e: std::io::Error| {
        if exceeded.get() {
            MigrateError::new("too_large", "the archive is over the size limit")
        } else {
            MigrateError::io("write the archive", &e)
        }
    };
    let mut entries: Vec<FileEntry> = Vec::new();
    let mut skipped = walked.skipped.clone();
    let mut skipped_total = walked.skipped.len();

    // The history.
    {
        let mut file = File::open(events_tmp).map_err(|e| MigrateError::io("read the history file", &e))?;
        let mut header = tar_header(events_size, 0o644, 0);
        builder
            .append_data(&mut header, "events.jsonl", &mut file)
            .map_err(fail)?;
        entries.push(FileEntry {
            path: "events.jsonl".into(),
            size: events_size,
            sha256: events_sha,
        });
    }
    // The picture.
    if let Some((ext, bytes)) = &input.avatar {
        let path = format!("avatar.{ext}");
        let mut header = tar_header(bytes.len() as u64, 0o644, 0);
        builder
            .append_data(&mut header, &path, bytes.as_slice())
            .map_err(fail)?;
        entries.push(FileEntry {
            path,
            size: bytes.len() as u64,
            sha256: sha_hex(bytes),
        });
    }
    // The memory folder.
    tar_dir_checked(&mut builder, "memory", &fail)?;
    for dir in &walked.dirs {
        tar_dir_checked(&mut builder, &format!("memory/{dir}"), &fail)?;
    }
    for (rel, _) in &walked.files {
        let archive_path = format!("memory/{rel}");
        let mut note = |why: &str| {
            skipped_total += 1;
            if skipped.len() < SKIPPED_LISTED {
                skipped.push(format!("{rel}: {why}"));
            }
        };
        let Some(root) = &root else { continue };
        // No link is followed and nothing blocks: a pipe put in the file's place does not hang the export.
        let Ok(mut file) = open_below(root, rel, libc::O_RDONLY | libc::O_NONBLOCK).map(File::from) else {
            note("cannot be opened: a link, or gone since the walk");
            continue;
        };
        let size = match file.metadata() {
            Ok(meta) if meta.is_file() => meta.len(),
            Ok(_) => {
                note("not a regular file");
                continue;
            }
            Err(_) => {
                note("cannot be read");
                continue;
            }
        };
        if size <= SMALL_FILE {
            let mut bytes = Vec::with_capacity(size as usize);
            if (&mut file).take(size).read_to_end(&mut bytes).is_err() || bytes.len() as u64 != size {
                note("changed while it was read");
                continue;
            }
            let mut header = tar_header(size, 0o644, 0);
            builder
                .append_data(&mut header, &archive_path, bytes.as_slice())
                .map_err(fail)?;
            entries.push(FileEntry {
                path: archive_path,
                size,
                sha256: sha_hex(&bytes),
            });
        } else {
            let mut reader = ExactReader {
                file,
                remaining: size,
                hasher: Sha256::new(),
                short: false,
            };
            let mut header = tar_header(size, 0o644, 0);
            builder
                .append_data(&mut header, &archive_path, &mut reader)
                .map_err(fail)?;
            if reader.short {
                return Err(MigrateError::new(
                    "io",
                    format!("{rel} got shorter while it was packed: pause the agent and export again"),
                ));
            }
            entries.push(FileEntry {
                path: archive_path,
                size,
                sha256: hex::encode(reader.hasher.finalize()),
            });
        }
    }
    // The manifest comes last: it holds the hashes of everything before it.
    let files = entries.len();
    let manifest = Manifest {
        format: FORMAT,
        bandito_version: env!("CARGO_PKG_VERSION").to_string(),
        agent: AgentSpec::from_agent(agent, input.services.clone(), input.schedules.clone()),
        events_count,
        files: entries,
        skipped,
    };
    let json = serde_json::to_vec_pretty(&manifest).map_err(|e| MigrateError::new("io", e.to_string()))?;
    let mut header = tar_header(json.len() as u64, 0o644, 0);
    builder
        .append_data(&mut header, "manifest.json", json.as_slice())
        .map_err(fail)?;
    let encoder = builder.into_inner().map_err(fail)?;
    let mut out = encoder.finish().map_err(fail)?;
    out.flush().map_err(fail)?;
    out.inner.sync_all().map_err(fail)?;
    Ok(Exported {
        size: out.written,
        sha256: hex::encode(out.hasher.finalize()),
        files,
        events: events_count,
        skipped: skipped_total,
        upto,
    })
}

fn tar_dir_checked(
    builder: &mut tar::Builder<impl Write>,
    path: &str,
    fail: &dyn Fn(std::io::Error) -> MigrateError,
) -> Result<()> {
    let mut header = tar_header(0, 0o755, 0);
    header.set_entry_type(tar::EntryType::Directory);
    builder
        .append_data(&mut header, format!("{path}/"), std::io::empty())
        .map_err(fail)
}

// ---- unpacking ----

/// An archive unpacked into a folder, checked against its manifest.
#[derive(Debug)]
pub struct Unpacked {
    pub manifest: Manifest,
    /// The folder the archive was unpacked into.
    pub root: PathBuf,
    pub events: PathBuf,
    /// The unpacked `memory/` folder (it exists even when the agent had no files).
    pub memory: PathBuf,
    /// The avatar picture, when the archive has one.
    pub avatar: Option<PathBuf>,
    /// Entries of the archive that were not unpacked (tool configuration names), as "path: why". At most 200.
    pub skipped: Vec<String>,
}

fn bad_archive(why: impl std::fmt::Display) -> MigrateError {
    MigrateError::new("bad_archive", why.to_string())
}

/// A tar block.
const BLOCK: usize = 512;

/// One header of the archive, as read by [`for_each_entry`].
struct RawEntry {
    /// The path as bytes (the long name when the entry had one).
    path: Vec<u8>,
    kind: EntryKind,
    size: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EntryKind {
    File,
    Dir,
}

fn octal(field: &[u8]) -> Option<u64> {
    if field.first().is_some_and(|b| b & 0x80 != 0) {
        return None;
    }
    let text: Vec<u8> = field
        .iter()
        .copied()
        .take_while(|b| *b != 0)
        .filter(|b| *b != b' ')
        .collect();
    if text.is_empty() {
        return Some(0);
    }
    std::str::from_utf8(&text)
        .ok()
        .and_then(|t| u64::from_str_radix(t, 8).ok())
}

fn type_name(flag: u8) -> &'static str {
    match flag {
        b'1' => "a hard link",
        b'2' => "a symbolic link",
        b'3' | b'4' => "a device",
        b'6' => "a named pipe",
        b'x' | b'g' => "a pax header",
        b'K' => "a long link name",
        b'S' => "a sparse file",
        _ => "an entry that is not a regular file or folder",
    }
}

/// Reads a tar stream header by header. Only what this daemon writes is accepted: ustar and GNU headers with octal
/// sizes, regular files, folders and GNU long names. Anything else (links, devices, pipes, pax headers, sparse files)
/// is an error, not skipped. `f` gets each entry and a reader of exactly its data.
fn for_each_entry<R: Read>(
    mut r: R,
    limits: &Limits,
    mut f: impl FnMut(RawEntry, &mut dyn Read) -> Result<()>,
) -> Result<()> {
    let mut long_name: Option<Vec<u8>> = None;
    let mut block = [0u8; BLOCK];
    loop {
        let n = read_full(&mut r, &mut block).map_err(|e| bad_archive(format!("unreadable archive: {e}")))?;
        if n == 0 {
            break;
        }
        if n < BLOCK {
            return Err(bad_archive("the archive is cut short"));
        }
        if block.iter().all(|b| *b == 0) {
            break;
        }
        let sum: u64 = block
            .iter()
            .enumerate()
            .map(|(i, b)| {
                if (148..156).contains(&i) {
                    u64::from(b' ')
                } else {
                    u64::from(*b)
                }
            })
            .sum();
        if octal(&block[148..156]) != Some(sum) {
            return Err(bad_archive("a tar header has a wrong checksum"));
        }
        let flag = block[156];
        let size = octal(&block[124..136]).ok_or_else(|| bad_archive("a tar header has an unreadable size"))?;
        let name_len = block[..100].iter().position(|b| *b == 0).unwrap_or(100);
        let mut path = block[..name_len].to_vec();
        // POSIX headers keep the front of a long path in `prefix`; GNU headers use those bytes for other things.
        if &block[257..263] == b"ustar\0" {
            let prefix_len = block[345..500].iter().position(|b| *b == 0).unwrap_or(155);
            if prefix_len > 0 {
                let mut full = block[345..345 + prefix_len].to_vec();
                full.push(b'/');
                full.extend_from_slice(&path);
                path = full;
            }
        }
        let pad = (BLOCK - (size % BLOCK as u64) as usize) % BLOCK;
        if flag == b'L' {
            if long_name.is_some() {
                return Err(bad_archive("two long names for one entry"));
            }
            if size > limits.max_path_bytes as u64 + 1 {
                return Err(MigrateError::new("bad_path", "a path is over the length limit"));
            }
            let mut data = vec![0u8; size as usize + pad];
            r.read_exact(&mut data)
                .map_err(|_| bad_archive("the archive is cut short"))?;
            data.truncate(size as usize);
            while data.last() == Some(&0) {
                data.pop();
            }
            long_name = Some(data);
            continue;
        }
        let kind = match flag {
            b'0' | 0 => EntryKind::File,
            b'5' => EntryKind::Dir,
            other => {
                let shown: String = String::from_utf8_lossy(long_name.as_deref().unwrap_or(&path))
                    .chars()
                    .take(120)
                    .collect();
                return Err(bad_archive(format!("{shown} is not allowed ({})", type_name(other))));
            }
        };
        if kind == EntryKind::Dir && size != 0 {
            return Err(bad_archive("a folder entry has data"));
        }
        let entry = RawEntry {
            path: long_name.take().unwrap_or(path),
            kind,
            size,
        };
        let mut data = (&mut r).take(size);
        f(entry, &mut data)?;
        std::io::copy(&mut data, &mut std::io::sink()).map_err(|e| bad_archive(format!("unreadable archive: {e}")))?;
        if data.limit() != 0 {
            return Err(bad_archive("the archive is cut short"));
        }
        let mut skip = vec![0u8; pad];
        r.read_exact(&mut skip)
            .map_err(|_| bad_archive("the archive is cut short"))?;
    }
    Ok(())
}

/// Reads until `buf` is full or the stream ends. Returns how many bytes were read.
fn read_full(r: &mut impl Read, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0;
    while filled < buf.len() {
        let n = r.read(&mut buf[filled..])?;
        if n == 0 {
            break;
        }
        filled += n;
    }
    Ok(filled)
}

/// Unpacks the gzip tar at `archive` into the new folder `dest` (which must not exist; it is created here, mode
/// 0700), checking every entry as it passes. On any error `dest` is removed. Then reads the manifest and checks it
/// against what was written: the format, the settings, and the size and sha256 of every file.
pub fn unpack(archive: &Path, dest: &Path, limits: &Limits) -> Result<Unpacked> {
    std::fs::DirBuilder::new()
        .mode(0o700)
        .create(dest)
        .map_err(|e| MigrateError::io("create the unpack folder", &e))?;
    let result = unpack_into(archive, dest, limits);
    if result.is_err() {
        let _ = std::fs::remove_dir_all(dest);
    }
    result
}

fn unpack_into(archive: &Path, dest: &Path, limits: &Limits) -> Result<Unpacked> {
    let file = File::open(archive).map_err(|e| MigrateError::io("open the archive", &e))?;
    let mut seen: HashSet<String> = HashSet::new();
    let mut written: HashMap<String, (u64, String)> = HashMap::new();
    let mut dirs: usize = 0;
    let mut total: u64 = 0;
    let mut dropped: Vec<String> = Vec::new();
    let mut dropped_bytes: u64 = 0;
    for_each_entry(GzDecoder::new(BufReader::new(file)), limits, |entry, data| {
        let rel = check_path(&entry.path, limits)?;
        if let Some(sub) = rel.strip_prefix("memory/")
            && let Some(why) = excluded(sub)
        {
            // Not unpacked, and counted nowhere: not in the file, folder or byte limits. Its data is read past
            // (a few KiB at a time) and thrown away.
            if dropped.len() < SKIPPED_LISTED {
                dropped.push(format!("{sub}: {why}"));
            }
            // Only a budget of its own, so a compressed bomb behind such a name cannot keep the daemon reading.
            dropped_bytes = dropped_bytes.saturating_add(entry.size);
            if dropped_bytes > limits.max_total_bytes {
                return Err(MigrateError::new(
                    "too_large",
                    "the dropped files are over the size limit",
                ));
            }
            return Ok(());
        }
        if !seen.insert(rel.clone()) {
            return Err(bad_archive(format!("{rel} is in the archive twice")));
        }
        let target = dest.join(&rel);
        if entry.kind == EntryKind::Dir {
            dirs += 1;
            if dirs > limits.max_files {
                return Err(MigrateError::new("too_many_files", "the archive has too many folders"));
            }
            if rel != "memory" && !rel.starts_with("memory/") {
                return Err(bad_path(&rel, "a folder outside memory/"));
            }
            return make_dirs(&target);
        }
        if !rel.starts_with("memory/") && !TOP_FILES.contains(&rel.as_str()) {
            return Err(bad_path(&rel, "a file outside the archive layout"));
        }
        if written.len() >= limits.max_files {
            return Err(MigrateError::new(
                "too_many_files",
                format!("the archive has more than {} files", limits.max_files),
            ));
        }
        total = total.saturating_add(entry.size);
        if total > limits.max_total_bytes {
            return Err(MigrateError::new("too_large", "the files are over the size limit"));
        }
        if rel == "manifest.json" && entry.size > limits.max_manifest_bytes {
            return Err(MigrateError::new("bad_manifest", "the manifest is too large"));
        }
        if let Some(parent) = target.parent() {
            make_dirs(parent)?;
        }
        // Whatever the archive says, a file is the owner's alone and not executable.
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&target)
            .map_err(|e| bad_archive(format!("{rel} cannot be written: {e}")))?;
        let mut hasher = Sha256::new();
        let mut copied: u64 = 0;
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = data
                .read(&mut buf)
                .map_err(|e| bad_archive(format!("unreadable archive: {e}")))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            out.write_all(&buf[..n])
                .map_err(|e| MigrateError::io("write an unpacked file", &e))?;
            copied += n as u64;
        }
        if copied != entry.size {
            return Err(bad_archive(format!("{rel} is cut short")));
        }
        written.insert(rel, (copied, hex::encode(hasher.finalize())));
        Ok(())
    })?;
    check_unpacked(dest, written, dropped, limits)
}

fn make_dirs(path: &Path) -> Result<()> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .map_err(|e| bad_archive(format!("a folder cannot be made ({e}): the archive's paths clash")))
}

/// Reads the manifest and holds the written files up against it.
fn check_unpacked(
    dest: &Path,
    mut written: HashMap<String, (u64, String)>,
    skipped: Vec<String>,
    limits: &Limits,
) -> Result<Unpacked> {
    let Some(_) = written.remove("manifest.json") else {
        return Err(MigrateError::new("bad_manifest", "the archive has no manifest.json"));
    };
    let bytes = std::fs::read(dest.join("manifest.json")).map_err(|e| MigrateError::io("read the manifest", &e))?;
    let value: Value = serde_json::from_slice(&bytes)
        .map_err(|e| MigrateError::new("bad_manifest", format!("the manifest is not JSON: {e}")))?;
    match value.get("format").and_then(Value::as_u64) {
        Some(f) if f == u64::from(FORMAT) => {}
        Some(f) => {
            return Err(MigrateError::new(
                "unsupported_format",
                format!("the archive is format {f}; this server reads format {FORMAT}. Update Bandito on this server"),
            ));
        }
        None => return Err(MigrateError::new("bad_manifest", "the manifest has no format")),
    }
    let manifest: Manifest = serde_json::from_value(value)
        .map_err(|e| MigrateError::new("bad_manifest", format!("the manifest is not valid: {e}")))?;
    validate_manifest(&manifest, limits)?;

    let mut listed: HashSet<&str> = HashSet::new();
    for entry in &manifest.files {
        let path =
            check_path(entry.path.as_bytes(), limits).map_err(|e| MigrateError::new("bad_manifest", e.message))?;
        if path != entry.path || path == "manifest.json" || path == "memory" {
            return Err(MigrateError::new(
                "bad_manifest",
                format!("{} cannot be listed", entry.path),
            ));
        }
        if !listed.insert(entry.path.as_str()) {
            return Err(MigrateError::new(
                "bad_manifest",
                format!("{} is listed twice", entry.path),
            ));
        }
        if entry
            .path
            .strip_prefix("memory/")
            .is_some_and(|sub| excluded(sub).is_some())
        {
            // A name that is not carried: the archive may list it, and it was not unpacked.
            continue;
        }
        let Some((size, sha)) = written.get(&entry.path) else {
            return Err(MigrateError::new(
                "bad_manifest",
                format!("{} is listed but not in the archive", entry.path),
            ));
        };
        if *size != entry.size {
            return Err(MigrateError::new(
                "hash_mismatch",
                format!("{} has another size than the manifest says", entry.path),
            ));
        }
        if !sha.eq_ignore_ascii_case(&entry.sha256) {
            return Err(MigrateError::new(
                "hash_mismatch",
                format!("{} does not match its sha256 in the manifest", entry.path),
            ));
        }
    }
    if let Some(extra) = written.keys().find(|p| !listed.contains(p.as_str())) {
        return Err(MigrateError::new(
            "bad_manifest",
            format!("{extra} is in the archive but not in the manifest"),
        ));
    }
    if !listed.contains("events.jsonl") {
        return Err(MigrateError::new(
            "bad_manifest",
            "the manifest does not list events.jsonl",
        ));
    }
    let avatar = ["avatar.png", "avatar.jpg"]
        .into_iter()
        .find(|p| listed.contains(p))
        .map(|p| dest.join(p));
    let memory = dest.join("memory");
    make_dirs(&memory)?;
    Ok(Unpacked {
        root: dest.to_path_buf(),
        events: dest.join("events.jsonl"),
        memory,
        avatar,
        skipped,
        manifest,
    })
}

fn validate_manifest(m: &Manifest, limits: &Limits) -> Result<()> {
    let bad = |why: &str| MigrateError::new("bad_manifest", why.to_string());
    validate_name(&m.agent.name).map_err(|_| bad("the agent's name is not valid"))?;
    if m.files.len() > limits.max_files.saturating_add(2) {
        return Err(bad("the manifest lists too many files"));
    }
    if m.agent.services.len() > 100 || m.agent.services.iter().any(|s| s.is_empty() || s.len() > 64) {
        return Err(bad("the services are not valid"));
    }
    if m.agent.schedules.len() > 100 {
        return Err(bad("the manifest has too many schedules"));
    }
    if m.files
        .iter()
        .any(|f| f.sha256.len() != 64 || !f.sha256.bytes().all(|b| b.is_ascii_hexdigit()))
    {
        return Err(bad("a sha256 in the manifest is not valid"));
    }
    Ok(())
}

// ---- the history ----

#[derive(Deserialize)]
struct EventLine {
    seq: i64,
    ts: i64,
    kind: String,
    payload: Value,
}

/// Reads the next line of at most `max` bytes. `None` at the end; an error for a longer line.
fn read_line_capped(reader: &mut impl BufRead, max: usize, buf: &mut Vec<u8>) -> Result<Option<()>> {
    buf.clear();
    let n = reader
        .by_ref()
        .take(max as u64 + 1)
        .read_until(b'\n', buf)
        .map_err(|e| MigrateError::io("read the history", &e))?;
    if n == 0 {
        return Ok(None);
    }
    if buf.len() > max {
        return Err(MigrateError::new("bad_events", "a history line is too long"));
    }
    Ok(Some(()))
}

fn parse_line(buf: &[u8]) -> Result<EventLine> {
    let bad = |why: String| MigrateError::new("bad_events", why);
    let line: EventLine = serde_json::from_slice(buf).map_err(|e| bad(format!("a history line is not valid: {e}")))?;
    if !EVENT_KINDS.contains(&line.kind.as_str()) {
        return Err(bad(format!(
            "a history event has the kind {}, which is not carried",
            line.kind
        )));
    }
    if EventBody::from_parts(&line.kind, line.payload.clone()).is_err() {
        return Err(bad(format!("a {} event does not decode", line.kind)));
    }
    Ok(line)
}

/// Checks all of `events.jsonl` before anything is created: every line is a known, decodable event, the seqs rise, and
/// the count is the manifest's. Returns the count.
pub fn check_events(path: &Path, expected: u64, limits: &Limits) -> Result<u64> {
    let mut reader = BufReader::new(File::open(path).map_err(|e| MigrateError::io("open the history", &e))?);
    let mut buf = Vec::new();
    let mut count: u64 = 0;
    let mut last = i64::MIN;
    while read_line_capped(&mut reader, limits.max_line_bytes, &mut buf)?.is_some() {
        let line = parse_line(&buf)?;
        if line.seq <= last {
            return Err(MigrateError::new("bad_events", "the history is not in order"));
        }
        last = line.seq;
        count += 1;
    }
    if count != expected {
        return Err(MigrateError::new(
            "bad_events",
            format!("the manifest says {expected} events and the history has {count}"),
        ));
    }
    Ok(count)
}

/// The events of `events.jsonl` for `Store::events_import`, one by one.
pub fn read_events(path: &Path, limits: &Limits) -> Result<impl Iterator<Item = anyhow::Result<NewEvent>>> {
    let reader = BufReader::new(File::open(path).map_err(|e| MigrateError::io("open the history", &e))?);
    let max = limits.max_line_bytes;
    let mut reader = reader;
    let mut buf = Vec::new();
    Ok(std::iter::from_fn(move || {
        match read_line_capped(&mut reader, max, &mut buf) {
            Ok(None) => None,
            Ok(Some(())) => Some(match parse_line(&buf) {
                Ok(line) => Ok(NewEvent {
                    old_seq: line.seq,
                    ts: line.ts,
                    kind: line.kind,
                    payload: line.payload,
                }),
                Err(e) => Err(anyhow::Error::new(e)),
            }),
            Err(e) => Some(Err(anyhow::Error::new(e))),
        }
    }))
}

/// How an imported event is changed to fit the new server, for `Store::events_import`:
/// - seqs in `reply_to`, `message_seq`, `message.dropped.seq` and `reaction.seq` become the new seqs. A reply or a turn
///   whose message was not carried loses the link; a drop or a reaction of such a message is left out;
/// - a message that waited (`queued`) no longer waits: nothing on the new server would ever take it;
/// - an attachment whose file is in the agent's moved folder keeps pointing at it (the new path); any other
///   attachment becomes a line of text in the message, so the history still reads.
pub struct Remap {
    /// The agent's folder on the source server.
    pub old_home: Option<String>,
    /// The agent's folder on this server.
    pub new_home: PathBuf,
}

impl Remap {
    pub fn apply(&self, kind: &str, payload: &mut Value, map: &HashMap<i64, i64>) -> bool {
        let Some(object) = payload.as_object_mut() else {
            return true;
        };
        let mapped = |v: Option<&Value>| v.and_then(Value::as_i64).and_then(|old| map.get(&old).copied());
        match kind {
            "message.user" => {
                object.remove("queued");
                match mapped(object.get("reply_to")) {
                    Some(new) => {
                        object.insert("reply_to".into(), Value::from(new));
                    }
                    None => {
                        object.remove("reply_to");
                    }
                }
                let attachments = match object.remove("attachments") {
                    Some(Value::Array(list)) => list,
                    _ => Vec::new(),
                };
                let mut kept: Vec<Value> = Vec::new();
                let mut lines = String::new();
                for attachment in attachments {
                    match self.attachment_path(&attachment) {
                        Some(path) => {
                            let mut a = attachment;
                            a["path"] = Value::from(path);
                            kept.push(a);
                        }
                        None => {
                            let name: String = attachment["name"]
                                .as_str()
                                .unwrap_or("file")
                                .chars()
                                .filter(|c| !c.is_control())
                                .take(200)
                                .collect();
                            lines.push_str(&format!("\n[attachment not moved: {name}]"));
                        }
                    }
                }
                if !kept.is_empty() {
                    object.insert("attachments".into(), Value::Array(kept));
                }
                if !lines.is_empty() {
                    let text = object
                        .get("text")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    object.insert("text".into(), Value::from(format!("{text}{lines}")));
                }
                true
            }
            "turn.started" => {
                match mapped(object.get("message_seq")) {
                    Some(new) => {
                        object.insert("message_seq".into(), Value::from(new));
                    }
                    None => {
                        object.remove("message_seq");
                    }
                }
                true
            }
            "message.dropped" | "reaction" => match mapped(object.get("seq")) {
                Some(new) => {
                    object.insert("seq".into(), Value::from(new));
                    true
                }
                None => false,
            },
            _ => true,
        }
    }

    /// The new path of an attachment that lives in the agent's old folder and exists in the moved one.
    fn attachment_path(&self, attachment: &Value) -> Option<String> {
        let old = self.old_home.as_deref()?.trim_end_matches('/');
        let rel = attachment["path"].as_str()?.strip_prefix(old)?.strip_prefix('/')?;
        if rel.is_empty() || rel.split('/').any(|p| p.is_empty() || p == "." || p == "..") {
            return None;
        }
        if !self.new_home.is_absolute() {
            return None;
        }
        let new = self.new_home.join(rel);
        let meta = std::fs::symlink_metadata(&new).ok()?;
        meta.file_type().is_file().then(|| new.display().to_string())
    }
}

// ---- moving the memory into the agent's folder ----

fn is_cross_device(e: &std::io::Error) -> bool {
    e.raw_os_error() == Some(libc::EXDEV)
}

fn copy_tree(src: &Path, dst: &Path) -> std::io::Result<()> {
    let meta = std::fs::symlink_metadata(src)?;
    if meta.file_type().is_dir() {
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dst)?;
        for entry in std::fs::read_dir(src)? {
            let entry = entry?;
            copy_tree(&entry.path(), &dst.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(src, dst).map(|_| ())
    }
}

/// Moves one file or folder: a rename, or (across file systems) a copy and a removal.
fn move_path(src: &Path, dst: &Path) -> std::io::Result<()> {
    match std::fs::rename(src, dst) {
        Ok(()) => Ok(()),
        Err(e) if is_cross_device(&e) => {
            copy_tree(src, dst)?;
            if std::fs::symlink_metadata(src)?.file_type().is_dir() {
                std::fs::remove_dir_all(src)
            } else {
                std::fs::remove_file(src)
            }
        }
        Err(e) => Err(e),
    }
}

/// Puts the unpacked memory into the agent's folder `home`. Each file or folder is moved in by a rename (the folder
/// the archive was unpacked into is in `<home>/run`, so across file systems it is a copy). A file replaces the one
/// that is there (the new agent's `MEMORY.md` template); folders are merged. Returns how many files were moved.
pub fn install_memory(memory: &Path, home: &Path) -> std::io::Result<usize> {
    let mut moved = 0;
    for entry in std::fs::read_dir(memory)? {
        let entry = entry?;
        let src = entry.path();
        let dst = home.join(entry.file_name());
        let is_dir = entry.file_type()?.is_dir();
        match std::fs::symlink_metadata(&dst) {
            Ok(meta) if is_dir && meta.file_type().is_dir() => {
                moved += install_memory(&src, &dst)?;
            }
            Ok(meta) => {
                // A file over a folder or a folder over a file: the new agent's own entry is the one given up.
                if meta.file_type().is_dir() {
                    std::fs::remove_dir_all(&dst)?;
                } else if is_dir {
                    std::fs::remove_file(&dst)?;
                }
                move_path(&src, &dst)?;
                moved += count_files(&dst);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                move_path(&src, &dst)?;
                moved += count_files(&dst);
            }
            Err(e) => return Err(e),
        }
    }
    Ok(moved)
}

fn count_files(path: &Path) -> usize {
    match std::fs::symlink_metadata(path) {
        Ok(m) if m.file_type().is_dir() => std::fs::read_dir(path)
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| count_files(&e.path())).sum())
            .unwrap_or(0),
        Ok(_) => 1,
        Err(_) => 0,
    }
}

// ---- the registry of archives and uploads in flight ----

/// An archive that waits to be read.
#[derive(Debug, Clone)]
pub struct Export {
    pub agent_id: String,
    pub path: PathBuf,
    pub size: u64,
    pub sha256: String,
    pub created_ms: i64,
    /// The newest seq of the agent's history that is in the archive (see [`Exported::upto`]).
    pub upto: i64,
}

struct Upload {
    path: PathBuf,
    size: u64,
    sha256: String,
    written: u64,
    hasher: Sha256,
    touched_ms: i64,
    /// When the commit began (milliseconds), or `None`.
    committing: Option<i64>,
}

/// What `take_for_commit` hands to the commit: the verified upload file.
#[derive(Debug)]
pub struct Committing {
    pub path: PathBuf,
}

/// The exports and uploads of one daemon. Its files are in `<home>/run/migrate`.
#[derive(Default)]
pub struct Registry {
    exports: Mutex<HashMap<String, Export>>,
    /// Export places taken by exports that are being built.
    reserved: Mutex<usize>,
    uploads: Mutex<HashMap<String, Arc<Mutex<Upload>>>>,
    limits: Limits,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A fresh id: `<prefix>` and 16 random bytes in hex. Paths are made from these and never from request input.
pub fn new_token(prefix: &str) -> String {
    let bytes: [u8; 16] = rand::random();
    format!("{prefix}{}", hex::encode(bytes))
}

/// The folder of the temporary files, made (mode 0700) when missing.
pub fn migrate_dir(data_home: &Path) -> Result<PathBuf> {
    let dir = data_home.join("run").join("migrate");
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)
        .map_err(|e| MigrateError::io("create the migration folder", &e))?;
    Ok(dir)
}

/// Removes everything in `dir` that has not been touched for `ttl_ms`, except the paths in `keep`.
fn sweep_dir(dir: &Path, now: i64, ttl_ms: i64, keep: &HashSet<PathBuf>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    for entry in read.filter_map(|e| e.ok()) {
        let path = entry.path();
        if keep.contains(&path) {
            continue;
        }
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        let modified = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_millis() as i64);
        if now - modified < ttl_ms {
            continue;
        }
        if meta.file_type().is_dir() {
            let _ = std::fs::remove_dir_all(&path);
        } else {
            let _ = std::fs::remove_file(&path);
        }
    }
}

impl Registry {
    /// A registry with other limits than the protocol's (for tests).
    pub fn with_limits(limits: Limits) -> Self {
        Self {
            limits,
            ..Self::default()
        }
    }

    pub fn limits(&self) -> &Limits {
        &self.limits
    }

    /// Removes the exports and uploads older than `ttl_ms` and every file in `dir` that old. Runs on every call.
    pub fn sweep(&self, dir: &Path, now: i64, ttl_ms: i64) {
        let mut keep: HashSet<PathBuf> = HashSet::new();
        {
            let mut exports = lock(&self.exports);
            exports.retain(|_, e| {
                let live = now - e.created_ms < ttl_ms;
                if !live {
                    let _ = std::fs::remove_file(&e.path);
                }
                live
            });
        }
        {
            let mut uploads = lock(&self.uploads);
            uploads.retain(|_, u| {
                let u = lock(u);
                // A commit that began over an hour ago is stuck: its upload goes too.
                let live = match u.committing {
                    Some(since) => now - since < ttl_ms,
                    None => now - u.touched_ms < ttl_ms,
                };
                if !live {
                    let _ = std::fs::remove_file(&u.path);
                } else if u.committing.is_some() {
                    keep.insert(u.path.clone());
                }
                live
            });
        }
        sweep_dir(dir, now, ttl_ms, &keep);
    }

    /// Takes a place for an export that is about to be built, so that the limit holds while it is built. Give it back
    /// with [`Registry::cancel_reservation`] when the export fails; [`Registry::add_export`] uses it up.
    pub fn reserve_export(&self) -> Result<()> {
        let exports = lock(&self.exports);
        let mut reserved = lock(&self.reserved);
        if exports.len() + *reserved >= EXPORTS_MAX {
            return Err(MigrateError::new(
                "too_many_exports",
                format!("{EXPORTS_MAX} exports already wait to be read: finish one first"),
            ));
        }
        *reserved += 1;
        Ok(())
    }

    pub fn cancel_reservation(&self) {
        let mut reserved = lock(&self.reserved);
        *reserved = reserved.saturating_sub(1);
    }

    /// Records a finished export in the place `reserve_export` took.
    pub fn add_export(&self, token: String, export: Export) {
        let mut exports = lock(&self.exports);
        self.cancel_reservation();
        exports.insert(token, export);
    }

    pub fn export(&self, token: &str) -> Option<Export> {
        lock(&self.exports).get(token).cloned()
    }

    /// Forgets the export and removes its file.
    pub fn remove_export(&self, token: &str) -> Option<Export> {
        let export = lock(&self.exports).remove(token)?;
        let _ = std::fs::remove_file(&export.path);
        Some(export)
    }

    /// Opens an upload of `size` bytes whose sha256 must be `sha256`. Returns its id.
    pub fn begin_upload(&self, dir: &Path, size: u64, sha256: &str, limits: &Limits, now: i64) -> Result<String> {
        if size == 0 {
            return Err(MigrateError::new("size_mismatch", "size must be more than 0"));
        }
        if size > limits.max_archive_bytes {
            return Err(MigrateError::new("too_large", "the archive is over the size limit"));
        }
        if sha256.len() != 64 || !sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(MigrateError::new(
                "checksum_mismatch",
                "sha256 must be 64 hex characters",
            ));
        }
        let mut uploads = lock(&self.uploads);
        if uploads.len() >= UPLOADS_MAX {
            return Err(MigrateError::new(
                "too_many_uploads",
                format!("{UPLOADS_MAX} uploads are open already: finish one first"),
            ));
        }
        let id = new_token("up_");
        let path = dir.join(format!("in-{id}.tgz"));
        private_file(&path).map_err(|e| MigrateError::io("create the upload file", &e))?;
        uploads.insert(
            id.clone(),
            Arc::new(Mutex::new(Upload {
                path,
                size,
                sha256: sha256.to_ascii_lowercase(),
                written: 0,
                hasher: Sha256::new(),
                touched_ms: now,
                committing: None,
            })),
        );
        Ok(id)
    }

    fn upload(&self, id: &str) -> Result<Arc<Mutex<Upload>>> {
        lock(&self.uploads)
            .get(id)
            .cloned()
            .ok_or_else(|| MigrateError::new("unknown_upload", "no such upload (it may have expired)"))
    }

    /// Appends `data` at `offset`, which must be the size so far. Returns the new size.
    pub fn write_upload(&self, id: &str, offset: u64, data: &[u8], now: i64) -> Result<u64> {
        let upload = self.upload(id)?;
        let mut u = lock(&upload);
        if u.committing.is_some() {
            return Err(MigrateError::new("busy", "the upload is being unpacked"));
        }
        if offset != u.written {
            return Err(MigrateError::new(
                "bad_offset",
                format!("offset must be {} (the size so far)", u.written),
            ));
        }
        if u.written + data.len() as u64 > u.size {
            return Err(MigrateError::new("size_mismatch", "more data than the upload's size"));
        }
        let mut file = OpenOptions::new()
            .append(true)
            .open(&u.path)
            .map_err(|e| MigrateError::io("open the upload file", &e))?;
        // Written at the end of what we know is ours: a file of another length means something else touched it.
        let on_disk = file
            .metadata()
            .map_err(|e| MigrateError::io("read the upload file", &e))?
            .len();
        if on_disk != u.written {
            return Err(MigrateError::new("io", "the upload file changed"));
        }
        file.write_all(data)
            .map_err(|e| MigrateError::io("write the upload file", &e))?;
        u.hasher.update(data);
        u.written += data.len() as u64;
        u.touched_ms = now;
        Ok(u.written)
    }

    /// Checks the upload is whole and has the announced hash, and marks it as being committed (no second commit and no
    /// more writes). A wrong hash removes the upload.
    pub fn take_for_commit(&self, id: &str) -> Result<Committing> {
        let upload = self.upload(id)?;
        let mut u = lock(&upload);
        if u.committing.is_some() {
            return Err(MigrateError::new("busy", "the upload is already being unpacked"));
        }
        if u.written != u.size {
            return Err(MigrateError::new(
                "size_mismatch",
                format!("{} of {} bytes were uploaded", u.written, u.size),
            ));
        }
        let sha = hex::encode(u.hasher.clone().finalize());
        if sha != u.sha256 {
            let path = u.path.clone();
            drop(u);
            lock(&self.uploads).remove(id);
            let _ = std::fs::remove_file(path);
            return Err(MigrateError::new(
                "checksum_mismatch",
                "the uploaded archive does not match its sha256: upload it again",
            ));
        }
        u.committing = Some(crate::store::now_ms());
        Ok(Committing { path: u.path.clone() })
    }

    /// A guard that forgets the upload and removes its file when it is dropped: when the commit ends, however it ends,
    /// and when the call is cancelled half way (the caller went away), so an upload never stays stuck as "committing".
    pub fn commit_guard(&self, id: &str) -> CommitGuard<'_> {
        CommitGuard {
            registry: self,
            id: id.to_string(),
        }
    }

    /// Forgets the upload and removes its file.
    pub fn finish_upload(&self, id: &str) {
        if let Some(upload) = lock(&self.uploads).remove(id) {
            let _ = std::fs::remove_file(&lock(&upload).path);
        }
    }

    #[cfg(test)]
    pub fn counts(&self) -> (usize, usize) {
        (lock(&self.exports).len(), lock(&self.uploads).len())
    }
}

/// See [`Registry::commit_guard`].
pub struct CommitGuard<'a> {
    registry: &'a Registry,
    id: String,
}

impl Drop for CommitGuard<'_> {
    fn drop(&mut self) {
        self.registry.finish_upload(&self.id);
    }
}

#[cfg(test)]
pub(crate) mod tests;
