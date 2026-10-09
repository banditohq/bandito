//! Server-side file service for the app: browse folders, read and edit text
//! files, create, move, copy and trash entries, upload in chunks. Plain
//! `std::fs`; the RPC layer wraps these methods.

use crate::store::new_id;
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::{HashMap, VecDeque};
use std::ffi::{OsStr, OsString};
use std::fs::{self, File, Metadata, OpenOptions};
use std::io::{self, ErrorKind, Read, Seek, SeekFrom, Write};
use std::iter::Peekable;
use std::path::{Component, Path, PathBuf};
use std::str::Chars;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant, UNIX_EPOCH};

/// Largest text file `read_text` returns by default.
pub const TEXT_LIMIT: u64 = 2 * 1024 * 1024;
/// Most entries `list` returns for one folder.
const LIST_LIMIT: usize = 5000;
/// Entries `list` looks at before it stops collecting.
const LIST_SCAN_LIMIT: usize = 50_000;
/// Entries `search` looks at before it gives up.
const SEARCH_SCAN_LIMIT: usize = 50_000;
/// Entries `project_hints` looks at before it gives up.
const PROJECT_SCAN_LIMIT: usize = 20_000;
/// Bytes checked for NUL when telling binary from text.
const BINARY_PROBE: usize = 8 * 1024;
/// Most bytes `read_range` returns in one call.
const RANGE_LIMIT: u64 = 4 * 1024 * 1024;
/// How deep `project_hints` looks for repositories under home.
const PROJECT_DEPTH: usize = 3;
/// Deepest folder tree `copy` will create.
const MAX_TREE_DEPTH: usize = 64;
/// Largest upload (sum of all chunks).
const MAX_UPLOAD_BYTES: u64 = 4 * 1024 * 1024 * 1024;
/// Largest file moved to the trash across devices (copy, then remove).
#[cfg(any(target_os = "linux", target_os = "macos"))]
const MOVE_COPY_LIMIT: u64 = 1024 * 1024 * 1024;
/// Folders that `search` and `project_hints` never enter.
const SKIP_DIRS: [&str; 5] = [".git", "node_modules", "target", ".cache", "Library"];
/// Folders that `project_hints` also never enters: macOS keeps them closed to other processes, so a scan only
/// logs refusals for them.
const PROJECT_SKIP_DIRS: [&str; 1] = [".Trash"];
/// Name endings of folders that `project_hints` skips: the Photos library bundle.
const PROJECT_SKIP_SUFFIXES: [&str; 1] = [".photoslibrary"];
/// Names tried for a trash entry before giving up.
#[cfg(any(target_os = "linux", target_os = "macos"))]
const MAX_NAME_TRIES: u32 = 10_000;

#[derive(Debug, thiserror::Error)]
pub enum FsError {
    #[error("not found: {0}")]
    NotFound(String),
    #[error("already exists: {0}")]
    AlreadyExists(String),
    #[error("not a directory: {0}")]
    NotADirectory(String),
    #[error("is a directory: {0}")]
    IsADirectory(String),
    #[error("not a regular file: {0}")]
    NotAFile(String),
    #[error("permission denied: {0}")]
    PermissionDenied(String),
    #[error("too large: {size} bytes, limit {limit}")]
    TooLarge { size: u64, limit: u64 },
    #[error("binary file")]
    Binary,
    #[error("file changed since it was read (current etag {etag})")]
    Conflict { etag: String },
    #[error("invalid path: {0}")]
    InvalidPath(String),
    #[error("path is outside the allowed roots: {0}")]
    OutsideRoots(String),
    #[error("cannot move across devices: {0}")]
    CrossDevice(String),
    #[error("io error: {0}")]
    Io(#[from] io::Error),
}

pub type Result<T> = std::result::Result<T, FsError>;

impl FsError {
    /// Short stable code for the app, e.g. `not_found`.
    pub fn code(&self) -> &'static str {
        match self {
            FsError::NotFound(_) => "not_found",
            FsError::AlreadyExists(_) => "exists",
            FsError::NotADirectory(_) => "not_a_directory",
            FsError::IsADirectory(_) => "is_a_directory",
            FsError::NotAFile(_) => "not_a_file",
            FsError::PermissionDenied(_) => "permission_denied",
            FsError::TooLarge { .. } => "too_large",
            FsError::Binary => "binary",
            FsError::Conflict { .. } => "conflict",
            FsError::InvalidPath(_) => "invalid_path",
            FsError::OutsideRoots(_) => "outside_roots",
            FsError::CrossDevice(_) => "cross_device",
            FsError::Io(_) => "io",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    Other,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    pub name: String,
    pub path: String,
    pub kind: EntryKind,
    pub size: u64,
    pub modified_ms: i64,
    pub hidden: bool,
    pub readonly: bool,
    pub symlink_target: Option<String>,
    /// Lowercase, without the dot.
    pub ext: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Listing {
    pub path: String,
    pub parent: Option<String>,
    pub entries: Vec<Entry>,
    pub truncated: bool,
    /// Entries left out because their names are not valid UTF-8.
    pub skipped: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TextFile {
    pub path: String,
    pub content: String,
    pub etag: String,
    pub size: u64,
    pub modified_ms: i64,
    pub readonly: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ProjectHint {
    pub path: String,
    pub name: String,
    pub is_git: bool,
    pub modified_ms: i64,
}

/// A chunked upload in progress. The bytes live in `tmp`, next to `dest`, until
/// `commit_upload` renames them into place (rename is atomic only on one filesystem).
struct Upload {
    dest: PathBuf,
    tmp: PathBuf,
    written: u64,
    touched: Instant,
}

/// File operations for the server owner.
///
/// Threat model: whoever calls this has owner-level access to the machine. `roots` is a
/// convenience guard that keeps the app inside some folders, not a sandbox. `resolve`
/// canonicalizes every path once (ancestors are resolved, a final symlink is kept as a
/// link and its target must also lie inside the roots), and every operation then works
/// on that canonical path. Races with other processes that can write inside the roots
/// are outside the model.
pub struct FileService {
    home: PathBuf,
    /// Canonical roots; `None` means the whole filesystem.
    roots: Option<Vec<PathBuf>>,
    uploads: Mutex<HashMap<String, Upload>>,
    /// One lock per path being written, so read-check-rename is not interleaved.
    write_locks: Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>,
    max_upload_bytes: u64,
}

impl FileService {
    /// `roots` are canonicalized here; a root that does not exist is dropped with a warning.
    pub fn new(home: PathBuf, roots: Option<Vec<PathBuf>>) -> Self {
        let roots = roots.map(|list| {
            list.into_iter()
                .filter_map(|root| match fs::canonicalize(&root) {
                    Ok(real) => Some(real),
                    Err(e) => {
                        tracing::warn!("files: root {} dropped: {e}", root.display());
                        None
                    }
                })
                .collect::<Vec<PathBuf>>()
        });
        Self {
            home: normalize(&home),
            roots,
            uploads: Mutex::new(HashMap::new()),
            write_locks: Mutex::new(HashMap::new()),
            max_upload_bytes: MAX_UPLOAD_BYTES,
        }
    }

    /// Turns what the app sent into the canonical absolute path used by every operation.
    /// `~` and `~/…` mean home; other paths must be absolute. Relative paths are rejected.
    pub fn resolve(&self, raw: &str) -> Result<PathBuf> {
        if raw.is_empty() || raw.contains('\0') {
            return Err(FsError::InvalidPath(raw.escape_debug().to_string()));
        }
        let lexical = if raw == "~" {
            self.home.clone()
        } else if let Some(rest) = raw.strip_prefix("~/") {
            self.home.join(rest.trim_start_matches('/'))
        } else if Path::new(raw).is_absolute() {
            PathBuf::from(raw)
        } else {
            return Err(FsError::InvalidPath(raw.to_string()));
        };
        let canonical = canonical_path(&normalize(&lexical))?;
        self.check_roots(&canonical)?;
        Ok(canonical)
    }

    /// `path` must be canonical (see `canonical_path`). A symlink must also point inside the roots.
    fn check_roots(&self, path: &Path) -> Result<()> {
        let Some(roots) = &self.roots else {
            return Ok(());
        };
        let inside = |p: &Path| roots.iter().any(|root| p.starts_with(root));
        if !inside(path) {
            return Err(FsError::OutsideRoots(path_str(path)));
        }
        if is_symlink(path) {
            let target = fs::read_link(path).map_err(|e| map_io(e, path))?;
            let target = match path.parent() {
                Some(parent) if target.is_relative() => parent.join(target),
                _ => target,
            };
            let real = real_path(&normalize(&target))?;
            if !inside(&real) {
                return Err(FsError::OutsideRoots(path_str(path)));
            }
        }
        Ok(())
    }

    /// Lists a folder: folders first, then names in natural case-insensitive order.
    /// Up to `LIST_SCAN_LIMIT` entries are collected, sorted, then cut to `LIST_LIMIT`.
    pub fn list(&self, raw: &str, show_hidden: bool) -> Result<Listing> {
        let dir = self.resolve(raw)?;
        let meta = fs::metadata(&dir).map_err(|e| map_io(e, &dir))?;
        if !meta.is_dir() {
            return Err(FsError::NotADirectory(path_str(&dir)));
        }
        let read = fs::read_dir(&dir).map_err(|e| map_io(e, &dir))?;
        // (sorts as a folder, lowercased name for natural order, entry)
        let mut items: Vec<(bool, String, Entry)> = Vec::new();
        let mut truncated = false;
        let mut skipped = 0u32;
        let mut scanned = 0usize;
        for item in read {
            let path = match item {
                Ok(item) => item.path(),
                Err(e) => {
                    tracing::warn!("files: unreadable entry in {}: {e}", dir.display());
                    continue;
                }
            };
            scanned += 1;
            if scanned > LIST_SCAN_LIMIT {
                truncated = true;
                break;
            }
            let Some(name) = path.file_name().and_then(OsStr::to_str).map(str::to_string) else {
                skipped += 1;
                tracing::warn!("files: skip non-UTF-8 name in {}", dir.display());
                continue;
            };
            if !show_hidden && name.starts_with('.') {
                continue;
            }
            match entry_at(&path) {
                Ok(entry) => {
                    let as_dir = entry.kind == EntryKind::Dir
                        || (entry.kind == EntryKind::Symlink && fs::metadata(&path).is_ok_and(|m| m.is_dir()));
                    items.push((as_dir, name.to_lowercase(), entry));
                }
                Err(e) => tracing::warn!("files: skip {}: {e}", path.display()),
            }
        }
        items.sort_by(|a, b| {
            b.0.cmp(&a.0)
                .then_with(|| natural_cmp(&a.1, &b.1))
                .then_with(|| a.2.name.cmp(&b.2.name))
        });
        if items.len() > LIST_LIMIT {
            truncated = true;
            items.truncate(LIST_LIMIT);
        }
        Ok(Listing {
            path: path_str(&dir),
            parent: dir.parent().map(path_str),
            entries: items.into_iter().map(|item| item.2).collect(),
            truncated,
            skipped,
        })
    }

    pub fn stat(&self, raw: &str) -> Result<Entry> {
        let path = self.resolve(raw)?;
        entry_at(&path)
    }

    /// Reads a UTF-8 text file of at most `limit` bytes. Binary files are refused.
    pub fn read_text(&self, raw: &str, limit: u64) -> Result<TextFile> {
        let path = self.resolve(raw)?;
        let meta = fs::metadata(&path).map_err(|e| map_io(e, &path))?;
        if meta.is_dir() {
            return Err(FsError::IsADirectory(path_str(&path)));
        }
        if !meta.is_file() {
            return Err(FsError::NotAFile(path_str(&path)));
        }
        let bytes = read_bounded(&path, limit)?;
        if is_binary(&bytes) {
            return Err(FsError::Binary);
        }
        let etag = etag_of(&bytes);
        let size = bytes.len() as u64;
        let content = String::from_utf8(bytes).map_err(|_| FsError::Binary)?;
        Ok(TextFile {
            path: path_str(&path),
            content,
            etag,
            size,
            modified_ms: modified_ms(&meta),
            readonly: meta.permissions().readonly(),
        })
    }

    /// Writes a text file atomically and returns its new etag.
    ///
    /// The read-check-rename runs under a per-path lock. Rules:
    /// - an existing file needs `expected_etag` equal to its current etag, else `Conflict`
    ///   (with `create`, an existing file is `AlreadyExists` instead when no etag is given);
    /// - `expected_etag` on a missing file is `NotFound`;
    /// - no etag and no file: created only with `create`, else `NotFound`.
    pub fn write_text(&self, raw: &str, content: &str, expected_etag: Option<&str>, create: bool) -> Result<String> {
        let path = self.write_target(&self.resolve(raw)?)?;
        let lock = self.path_lock(&path);
        let result = {
            let _guard = locked(&lock);
            write_locked(&path, content, expected_etag, create)
        };
        drop(lock);
        self.release_path_lock(&path);
        result
    }

    /// A symlink is written through: the write goes to its target, the link stays.
    fn write_target(&self, path: &Path) -> Result<PathBuf> {
        if !is_symlink(path) {
            return Ok(path.to_path_buf());
        }
        let target = fs::canonicalize(path).map_err(|e| map_io(e, path))?;
        self.check_roots(&target)?;
        Ok(target)
    }

    fn path_lock(&self, path: &Path) -> Arc<Mutex<()>> {
        let mut map = locked(&self.write_locks);
        map.entry(path.to_path_buf())
            .or_insert_with(|| Arc::new(Mutex::new(())))
            .clone()
    }

    /// Drops the path's lock entry once nobody else holds it.
    fn release_path_lock(&self, path: &Path) {
        let mut map = locked(&self.write_locks);
        if map.get(path).is_some_and(|lock| Arc::strong_count(lock) == 1) {
            map.remove(path);
        }
    }

    /// Creates an empty file. Fails if the name is taken.
    pub fn create_file(&self, raw: &str) -> Result<Entry> {
        let path = self.resolve(raw)?;
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|e| map_io(e, &path))?;
        entry_at(&path)
    }

    /// Creates one folder. The parent must exist.
    pub fn mkdir(&self, raw: &str) -> Result<Entry> {
        let path = self.resolve(raw)?;
        fs::create_dir(&path).map_err(|e| map_io(e, &path))?;
        entry_at(&path)
    }

    /// Renames without replacing: an existing `to` is `AlreadyExists`, checked by the kernel.
    /// Works on broken symlinks too (they are moved as links).
    pub fn rename(&self, from: &str, to: &str) -> Result<Entry> {
        let src = self.resolve(from)?;
        let dst = self.resolve(to)?;
        ensure_exists(&src)?;
        rename_noreplace(&src, &dst)?;
        entry_at(&dst)
    }

    /// Copies a file or a folder tree. Symlinks are copied as symlinks. A failed copy removes
    /// what it created and nothing else.
    pub fn copy(&self, from: &str, to: &str) -> Result<Entry> {
        let src = self.resolve(from)?;
        let dst = self.resolve(to)?;
        let meta = fs::symlink_metadata(&src).map_err(|e| map_io(e, &src))?;
        ensure_absent(&dst)?;
        if meta.is_dir() && dst.starts_with(&src) {
            return Err(FsError::InvalidPath(format!(
                "cannot copy {} into itself",
                path_str(&src)
            )));
        }
        let mut created = Vec::new();
        if let Err(e) = copy_tree(&src, &dst, &mut created, 0, device(&meta)) {
            rollback(&created);
            return Err(e);
        }
        entry_at(&dst)
    }

    /// Moves an entry to the trash and returns where it lies now.
    /// The trash is `<home>/.local/share/Trash` on Linux and `<home>/.Trash` on macOS.
    /// `XDG_DATA_HOME` is not read, so the location always follows the service's home.
    pub fn trash(&self, raw: &str) -> Result<String> {
        let path = self.resolve(raw)?;
        let home_real = real_path(&self.home).unwrap_or_else(|_| self.home.clone());
        if path.parent().is_none() || path == self.home || path == home_real {
            return Err(FsError::InvalidPath(format!("refusing to trash {}", path_str(&path))));
        }
        ensure_exists(&path)?;
        self.move_to_trash(&path)
    }

    #[cfg(target_os = "linux")]
    fn move_to_trash(&self, path: &Path) -> Result<String> {
        let base = self.home.join(".local/share/Trash");
        let files = base.join("files");
        let info_dir = base.join("info");
        fs::create_dir_all(&files).map_err(|e| map_io(e, &files))?;
        fs::create_dir_all(&info_dir).map_err(|e| map_io(e, &info_dir))?;
        let name = free_name(&files, file_name_of(path)?, Some(info_dir.as_path()))?;
        let mut info_name = name.clone();
        info_name.push(".trashinfo");
        let info_path = info_dir.join(info_name);
        write_new(&info_path, trash_info(path).as_bytes())?;
        let dest = files.join(&name);
        if let Err(e) = move_into(path, &dest) {
            if fs::symlink_metadata(&dest).is_err() {
                let _ = fs::remove_file(&info_path);
            }
            return Err(e);
        }
        Ok(path_str(&dest))
    }

    #[cfg(target_os = "macos")]
    fn move_to_trash(&self, path: &Path) -> Result<String> {
        let dir = self.home.join(".Trash");
        fs::create_dir_all(&dir).map_err(|e| map_io(e, &dir))?;
        let name = free_name(&dir, file_name_of(path)?, None)?;
        let dest = dir.join(name);
        move_into(path, &dest)?;
        Ok(path_str(&dest))
    }

    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    fn move_to_trash(&self, _path: &Path) -> Result<String> {
        Err(FsError::Io(io::Error::new(
            ErrorKind::Unsupported,
            "trash is supported on Linux and macOS only",
        )))
    }

    /// Finds entries whose name contains `query` (case-insensitive), breadth first.
    /// Does not follow symlinks, skips `SKIP_DIRS` and non-UTF-8 names.
    pub fn search(&self, raw: &str, query: &str, limit: usize) -> Result<Vec<Entry>> {
        let root = self.resolve(raw)?;
        let meta = fs::metadata(&root).map_err(|e| map_io(e, &root))?;
        if !meta.is_dir() {
            return Err(FsError::NotADirectory(path_str(&root)));
        }
        let mut found = Vec::new();
        let needle = query.to_lowercase();
        if needle.is_empty() || limit == 0 {
            return Ok(found);
        }
        let mut queue = VecDeque::from([root]);
        let mut scanned = 0usize;
        'walk: while let Some(dir) = queue.pop_front() {
            let read = match fs::read_dir(&dir) {
                Ok(read) => read,
                Err(e) => {
                    tracing::warn!("files: search skips {}: {e}", dir.display());
                    continue;
                }
            };
            for item in read {
                let item = match item {
                    Ok(item) => item,
                    Err(e) => {
                        tracing::warn!("files: search skips entry in {}: {e}", dir.display());
                        continue;
                    }
                };
                scanned += 1;
                if scanned > SEARCH_SCAN_LIMIT {
                    break 'walk;
                }
                let Ok(file_type) = item.file_type() else {
                    continue;
                };
                let Some(name) = item.file_name().to_str().map(str::to_string) else {
                    tracing::warn!("files: search skips non-UTF-8 name in {}", dir.display());
                    continue;
                };
                if file_type.is_dir() {
                    if SKIP_DIRS.contains(&name.as_str()) {
                        continue;
                    }
                    queue.push_back(item.path());
                }
                if name.to_lowercase().contains(&needle) {
                    match entry_at(&item.path()) {
                        Ok(entry) => found.push(entry),
                        Err(e) => tracing::warn!("files: search skips {name}: {e}"),
                    }
                    if found.len() >= limit {
                        break 'walk;
                    }
                }
            }
        }
        Ok(found)
    }

    /// Git repositories up to `PROJECT_DEPTH` levels under home, newest first. Only
    /// repositories whose canonical path passes the roots check are returned. A
    /// repository's own subfolders are not searched.
    pub fn project_hints(&self, limit: usize) -> Result<Vec<ProjectHint>> {
        let mut hints = Vec::new();
        let mut queue = VecDeque::from([(self.home.clone(), 0usize)]);
        let mut scanned = 0usize;
        'scan: while let Some((dir, depth)) = queue.pop_front() {
            if depth == PROJECT_DEPTH {
                continue;
            }
            let read = match fs::read_dir(&dir) {
                Ok(read) => read,
                // Refusals (macOS privacy folders, for one) are expected during a scan: debug, not warn.
                Err(e) if is_access_denied(&e) => {
                    tracing::debug!("files: project scan skips {} (no access): {e}", dir.display());
                    continue;
                }
                Err(e) => {
                    tracing::warn!("files: project scan skips {}: {e}", dir.display());
                    continue;
                }
            };
            for item in read {
                let Ok(item) = item else {
                    continue;
                };
                scanned += 1;
                if scanned > PROJECT_SCAN_LIMIT {
                    break 'scan;
                }
                let Ok(file_type) = item.file_type() else {
                    continue;
                };
                let Some(name) = item.file_name().to_str().map(str::to_string) else {
                    continue;
                };
                if !file_type.is_dir() || skipped_by_project_scan(&name) {
                    continue;
                }
                let path = item.path();
                if fs::symlink_metadata(path.join(".git")).is_ok() {
                    let real = match canonical_path(&path) {
                        Ok(real) => real,
                        Err(e) => {
                            tracing::warn!("files: project {} skipped: {e}", path.display());
                            continue;
                        }
                    };
                    if self.check_roots(&real).is_err() {
                        continue;
                    }
                    let mtime = fs::metadata(&real).map_or(0, |m| modified_ms(&m));
                    hints.push(ProjectHint {
                        path: path_str(&real),
                        name,
                        is_git: true,
                        modified_ms: mtime,
                    });
                } else {
                    queue.push_back((path, depth + 1));
                }
            }
        }
        hints.sort_by(|a, b| b.modified_ms.cmp(&a.modified_ms).then_with(|| a.path.cmp(&b.path)));
        hints.truncate(limit);
        Ok(hints)
    }

    /// Starts a chunked upload to `dest_raw` and returns its id. The parent folder must exist.
    pub fn begin_upload(&self, dest_raw: &str) -> Result<String> {
        let dest = self.resolve(dest_raw)?;
        let name = file_name_of(&dest)?;
        let parent = dest.parent().ok_or_else(|| FsError::InvalidPath(path_str(&dest)))?;
        let meta = fs::metadata(parent).map_err(|e| map_io(e, parent))?;
        if !meta.is_dir() {
            return Err(FsError::NotADirectory(path_str(parent)));
        }
        let id = new_id();
        let mut tmp_name = OsString::from(".");
        tmp_name.push(name);
        tmp_name.push(format!(".bandito-upload-{id}"));
        let tmp = parent.join(tmp_name);
        write_new(&tmp, &[])?;
        locked(&self.uploads).insert(
            id.clone(),
            Upload {
                dest,
                tmp,
                written: 0,
                touched: Instant::now(),
            },
        );
        Ok(id)
    }

    /// Appends one chunk. `offset` must equal the bytes already written, and the total may
    /// not exceed the upload limit (`TooLarge`; the upload stays). Returns the new total.
    pub fn append_upload(&self, id: &str, offset: u64, data: &[u8]) -> Result<u64> {
        let mut uploads = locked(&self.uploads);
        let upload = uploads.get_mut(id).ok_or_else(|| FsError::NotFound(id.to_string()))?;
        if offset != upload.written {
            return Err(FsError::InvalidPath(format!(
                "offset mismatch: expected {}, got {offset}",
                upload.written
            )));
        }
        let total = upload.written.saturating_add(data.len() as u64);
        if total > self.max_upload_bytes {
            return Err(FsError::TooLarge {
                size: total,
                limit: self.max_upload_bytes,
            });
        }
        let mut file = OpenOptions::new()
            .append(true)
            .open(&upload.tmp)
            .map_err(|e| map_io(e, &upload.tmp))?;
        if let Err(e) = file.write_all(data) {
            let _ = file.set_len(upload.written);
            return Err(map_io(e, &upload.tmp));
        }
        upload.written = total;
        upload.touched = Instant::now();
        Ok(total)
    }

    /// Moves the finished temp file into place. Without `overwrite`, an existing file is
    /// `AlreadyExists` (checked by the kernel). On error the upload stays, so the commit
    /// can be retried.
    pub fn commit_upload(&self, id: &str, overwrite: bool) -> Result<Entry> {
        let mut uploads = locked(&self.uploads);
        let upload = uploads.get_mut(id).ok_or_else(|| FsError::NotFound(id.to_string()))?;
        let dest = canonical_path(&upload.dest)?;
        self.check_roots(&dest)?;
        let tmp = upload.tmp.clone();
        upload.touched = Instant::now();
        OpenOptions::new()
            .write(true)
            .open(&tmp)
            .and_then(|file| file.sync_all())
            .map_err(|e| map_io(e, &tmp))?;
        if overwrite {
            fs::rename(&tmp, &dest).map_err(|e| map_rename(e, &tmp, &dest))?;
        } else {
            rename_noreplace(&tmp, &dest)?;
        }
        if let Some(parent) = dest.parent() {
            sync_dir(parent)?;
        }
        uploads.remove(id);
        entry_at(&dest)
    }

    /// Drops an upload and deletes its temp file.
    pub fn abort_upload(&self, id: &str) -> Result<()> {
        let mut uploads = locked(&self.uploads);
        let tmp = uploads
            .get(id)
            .map(|upload| upload.tmp.clone())
            .ok_or_else(|| FsError::NotFound(id.to_string()))?;
        match fs::remove_file(&tmp) {
            Ok(()) => {}
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => return Err(map_io(e, &tmp)),
        }
        uploads.remove(id);
        Ok(())
    }

    /// Removes uploads not touched for `idle` or longer, with their temp files. Returns how
    /// many were removed. A temp file that cannot be removed stays registered for the next sweep.
    pub fn sweep_uploads(&self, idle: Duration) -> usize {
        let mut uploads = locked(&self.uploads);
        let stale: Vec<String> = uploads
            .iter()
            .filter(|(_, upload)| upload.touched.elapsed() >= idle)
            .map(|(id, _)| id.clone())
            .collect();
        let mut removed = 0;
        for id in stale {
            if let Some(upload) = uploads.get(&id) {
                match fs::remove_file(&upload.tmp) {
                    Ok(()) => {}
                    Err(e) if e.kind() == ErrorKind::NotFound => {}
                    Err(e) => {
                        tracing::warn!("files: sweep could not remove {}: {e}", upload.tmp.display());
                        continue;
                    }
                }
            }
            uploads.remove(&id);
            removed += 1;
        }
        removed
    }

    /// Reads up to `len` bytes (at most `RANGE_LIMIT`) of a regular file, starting at
    /// `offset`. An offset past the end gives an empty vector.
    pub fn read_range(&self, raw: &str, offset: u64, len: u64) -> Result<Vec<u8>> {
        let path = self.resolve(raw)?;
        let meta = fs::metadata(&path).map_err(|e| map_io(e, &path))?;
        if meta.is_dir() {
            return Err(FsError::IsADirectory(path_str(&path)));
        }
        if !meta.is_file() {
            return Err(FsError::NotAFile(path_str(&path)));
        }
        if offset >= meta.len() {
            return Ok(Vec::new());
        }
        let mut file = File::open(&path).map_err(|e| map_io(e, &path))?;
        file.seek(SeekFrom::Start(offset)).map_err(|e| map_io(e, &path))?;
        let mut buf = Vec::new();
        file.take(len.min(RANGE_LIMIT))
            .read_to_end(&mut buf)
            .map_err(|e| map_io(e, &path))?;
        Ok(buf)
    }
}

/// Whether `project_hints` does not enter a folder named `name`.
fn skipped_by_project_scan(name: &str) -> bool {
    SKIP_DIRS.contains(&name)
        || PROJECT_SKIP_DIRS.contains(&name)
        || PROJECT_SKIP_SUFFIXES
            .iter()
            .any(|suffix| name.to_ascii_lowercase().ends_with(suffix))
}

/// EPERM and EACCES both come out as `PermissionDenied` in std on Unix.
fn is_access_denied(e: &io::Error) -> bool {
    e.kind() == ErrorKind::PermissionDenied
}

/// The read-check-rename of `write_text`. The caller holds the path lock.
fn write_locked(path: &Path, content: &str, expected: Option<&str>, create: bool) -> Result<String> {
    let existing = match fs::metadata(path) {
        Ok(meta) if meta.is_dir() => return Err(FsError::IsADirectory(path_str(path))),
        Ok(meta) if !meta.is_file() => return Err(FsError::NotAFile(path_str(path))),
        Ok(meta) => Some(meta),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => return Err(map_io(e, path)),
    };
    match (&existing, expected) {
        (None, Some(_)) => return Err(FsError::NotFound(path_str(path))),
        (None, None) if !create => return Err(FsError::NotFound(path_str(path))),
        (None, None) => {}
        (Some(_), None) if create => return Err(FsError::AlreadyExists(path_str(path))),
        (Some(_), None) => {
            return Err(FsError::Conflict {
                etag: current_etag(path)?,
            });
        }
        (Some(_), Some(expected)) => {
            let current = current_etag(path)?;
            if expected != current {
                return Err(FsError::Conflict { etag: current });
            }
        }
    }
    if existing.as_ref().is_some_and(|m| m.permissions().readonly()) {
        return Err(FsError::PermissionDenied(path_str(path)));
    }
    let dir = path.parent().ok_or_else(|| FsError::InvalidPath(path_str(path)))?;
    let mut tmp_name = OsString::from(".");
    tmp_name.push(file_name_of(path)?);
    tmp_name.push(format!(".bandito-tmp-{}", new_id()));
    let tmp = dir.join(tmp_name);
    let perms = existing.as_ref().map(Metadata::permissions);
    if let Err(e) = write_atomically(&tmp, path, content.as_bytes(), perms) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    Ok(etag_of(content.as_bytes()))
}

fn current_etag(path: &Path) -> Result<String> {
    Ok(etag_of(&read_bounded(path, TEXT_LIMIT)?))
}

/// Maps an io error to the matching `FsError`, keeping the path for the message.
fn map_io(e: io::Error, path: &Path) -> FsError {
    let p = path_str(path);
    match e.kind() {
        ErrorKind::NotFound => FsError::NotFound(p),
        ErrorKind::AlreadyExists => FsError::AlreadyExists(p),
        ErrorKind::PermissionDenied => FsError::PermissionDenied(p),
        ErrorKind::NotADirectory => FsError::NotADirectory(p),
        ErrorKind::IsADirectory => FsError::IsADirectory(p),
        _ => FsError::Io(e),
    }
}

/// Like `map_io` for a rename: a cross-device failure is reported as `CrossDevice`.
fn map_rename(e: io::Error, from: &Path, to: &Path) -> FsError {
    if is_cross_device(&e) {
        FsError::CrossDevice(path_str(from))
    } else {
        map_io(e, to)
    }
}

fn locked<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn path_str(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

fn file_name_text(path: &Path) -> String {
    path.file_name()
        .map_or_else(|| path_str(path), |n| n.to_string_lossy().into_owned())
}

fn file_name_of(path: &Path) -> Result<&OsStr> {
    path.file_name().ok_or_else(|| FsError::InvalidPath(path_str(path)))
}

/// Resolves `.` and `..` without touching the disk. `..` never climbs above `/`.
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for part in path.components() {
        match part {
            Component::Prefix(prefix) => out.push(prefix.as_os_str()),
            Component::RootDir => out.push(Component::RootDir.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            Component::Normal(name) => out.push(name),
        }
    }
    out
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok_and(|m| m.file_type().is_symlink())
}

/// The real location of `path` with every symlink resolved. For a path that does not exist
/// yet, the nearest existing ancestor is resolved and the missing tail is appended.
fn real_path(path: &Path) -> Result<PathBuf> {
    let mut tail: Vec<&OsStr> = Vec::new();
    let mut cur = path;
    loop {
        match fs::canonicalize(cur) {
            Ok(real) => {
                return Ok(tail.iter().rev().fold(real, |acc, part| acc.join(part)));
            }
            Err(e) if e.kind() == ErrorKind::NotFound && fs::symlink_metadata(cur).is_err() => {
                match (cur.file_name(), cur.parent()) {
                    (Some(name), Some(parent)) => {
                        tail.push(name);
                        cur = parent;
                    }
                    _ => return Err(map_io(e, path)),
                }
            }
            Err(e) => return Err(map_io(e, path)),
        }
    }
}

/// Canonical form used by `resolve`: every ancestor is resolved, the final component is
/// kept as is when it is a symlink (so rename and trash act on the link itself).
fn canonical_path(path: &Path) -> Result<PathBuf> {
    match (path.parent(), path.file_name()) {
        (Some(parent), Some(name)) if is_symlink(path) => Ok(real_path(parent)?.join(name)),
        _ => real_path(path),
    }
}

/// Reads at most `limit` bytes of a regular file. Longer files are `TooLarge`.
fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = File::open(path).map_err(|e| map_io(e, path))?;
    let mut buf = Vec::new();
    file.take(limit.saturating_add(1))
        .read_to_end(&mut buf)
        .map_err(|e| map_io(e, path))?;
    if buf.len() as u64 > limit {
        let size = fs::metadata(path).map_or(buf.len() as u64, |m| m.len());
        return Err(FsError::TooLarge { size, limit });
    }
    Ok(buf)
}

fn is_binary(bytes: &[u8]) -> bool {
    bytes[..bytes.len().min(BINARY_PROBE)].contains(&0)
}

/// First 16 hex characters of the SHA-256 of the content.
fn etag_of(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    hex::encode(&digest[..8])
}

fn modified_ms(meta: &Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

fn entry_at(path: &Path) -> Result<Entry> {
    let meta = fs::symlink_metadata(path).map_err(|e| map_io(e, path))?;
    let file_type = meta.file_type();
    let kind = if file_type.is_symlink() {
        EntryKind::Symlink
    } else if file_type.is_dir() {
        EntryKind::Dir
    } else if file_type.is_file() {
        EntryKind::File
    } else {
        EntryKind::Other
    };
    let name = file_name_text(path);
    let hidden = name.starts_with('.');
    let ext = match kind {
        EntryKind::Dir => None,
        _ => Path::new(&name).extension().map(|e| e.to_string_lossy().to_lowercase()),
    };
    let symlink_target = if kind == EntryKind::Symlink {
        let target = fs::read_link(path).map_err(|e| map_io(e, path))?;
        Some(path_str(&target))
    } else {
        None
    };
    Ok(Entry {
        name,
        path: path_str(path),
        kind,
        size: meta.len(),
        modified_ms: modified_ms(&meta),
        hidden,
        readonly: meta.permissions().readonly(),
        symlink_target,
        ext,
    })
}

fn ensure_exists(path: &Path) -> Result<()> {
    fs::symlink_metadata(path).map(|_| ()).map_err(|e| map_io(e, path))
}

fn ensure_absent(path: &Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(FsError::AlreadyExists(path_str(path))),
        Err(e) if e.kind() == ErrorKind::NotFound => Ok(()),
        Err(e) => Err(map_io(e, path)),
    }
}

/// Creates a new file and writes `bytes` into it. An existing file is an error.
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| map_io(e, path))?;
    if let Err(e) = file.write_all(bytes) {
        let _ = fs::remove_file(path);
        return Err(map_io(e, path));
    }
    Ok(())
}

/// Writes `bytes` to `tmp` (created new), syncs it, sets `perms`, renames it over `target`
/// and syncs the folder. Owner and extended attributes are not carried over.
fn write_atomically(tmp: &Path, target: &Path, bytes: &[u8], perms: Option<fs::Permissions>) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(tmp)
        .map_err(|e| map_io(e, tmp))?;
    file.write_all(bytes).map_err(|e| map_io(e, tmp))?;
    file.sync_all().map_err(|e| map_io(e, tmp))?;
    if let Some(perms) = perms {
        fs::set_permissions(tmp, perms).map_err(|e| map_io(e, tmp))?;
    }
    fs::rename(tmp, target).map_err(|e| map_rename(e, tmp, target))?;
    if let Some(dir) = target.parent() {
        sync_dir(dir)?;
    }
    Ok(())
}

#[cfg(unix)]
fn sync_dir(dir: &Path) -> Result<()> {
    File::open(dir)
        .and_then(|file| file.sync_all())
        .map_err(|e| map_io(e, dir))
}

#[cfg(not(unix))]
fn sync_dir(_dir: &Path) -> Result<()> {
    Ok(())
}

#[cfg(unix)]
fn device(meta: &Metadata) -> Option<u64> {
    use std::os::unix::fs::MetadataExt;
    Some(meta.dev())
}

#[cfg(not(unix))]
fn device(_meta: &Metadata) -> Option<u64> {
    None
}

/// Copies `src` to the new path `dst`. Each entry is pushed to `created` right after it is
/// created, so the caller can roll back exactly what this call made. Symlinks are copied as
/// links. With `root_dev`, the walk does not enter other devices (mount points) and warns.
fn copy_tree(src: &Path, dst: &Path, created: &mut Vec<PathBuf>, depth: usize, root_dev: Option<u64>) -> Result<()> {
    if depth > MAX_TREE_DEPTH {
        return Err(FsError::InvalidPath(format!(
            "folder tree deeper than {MAX_TREE_DEPTH} levels: {}",
            path_str(src)
        )));
    }
    let meta = fs::symlink_metadata(src).map_err(|e| map_io(e, src))?;
    let kind = meta.file_type();
    if kind.is_symlink() {
        let target = fs::read_link(src).map_err(|e| map_io(e, src))?;
        symlink_path(&target, dst)?;
        created.push(dst.to_path_buf());
    } else if kind.is_dir() {
        fs::create_dir(dst).map_err(|e| map_io(e, dst))?;
        created.push(dst.to_path_buf());
        let children = fs::read_dir(src).map_err(|e| map_io(e, src))?;
        for child in children {
            let child = child.map_err(|e| map_io(e, src))?;
            let child_path = child.path();
            let child_meta = child.metadata().map_err(|e| map_io(e, &child_path))?;
            if root_dev.is_some() && device(&child_meta) != root_dev {
                tracing::warn!("files: not copying {} (another device)", child_path.display());
                continue;
            }
            copy_tree(&child_path, &dst.join(child.file_name()), created, depth + 1, root_dev)?;
        }
    } else if kind.is_file() {
        copy_file_new(src, dst, created)?;
    } else {
        return Err(FsError::Io(io::Error::new(
            ErrorKind::Unsupported,
            "special files cannot be copied",
        )));
    }
    Ok(())
}

fn copy_file_new(src: &Path, dst: &Path, created: &mut Vec<PathBuf>) -> Result<()> {
    let mut input = File::open(src).map_err(|e| map_io(e, src))?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dst)
        .map_err(|e| map_io(e, dst))?;
    created.push(dst.to_path_buf());
    io::copy(&mut input, &mut output).map_err(|e| map_io(e, dst))?;
    let perms = input.metadata().map_err(|e| map_io(e, src))?.permissions();
    output.set_permissions(perms).map_err(|e| map_io(e, dst))
}

/// Removes what `copy_tree` created, newest first. Nothing else is touched.
fn rollback(created: &[PathBuf]) {
    for path in created.iter().rev() {
        let is_dir = fs::symlink_metadata(path).is_ok_and(|m| m.is_dir());
        let removed = if is_dir {
            fs::remove_dir(path)
        } else {
            fs::remove_file(path)
        };
        if let Err(e) = removed {
            tracing::warn!("files: rollback could not remove {}: {e}", path.display());
        }
    }
}

#[cfg(unix)]
fn symlink_path(target: &Path, link: &Path) -> Result<()> {
    std::os::unix::fs::symlink(target, link).map_err(|e| map_io(e, link))
}

#[cfg(not(unix))]
fn symlink_path(_target: &Path, _link: &Path) -> Result<()> {
    Err(FsError::Io(io::Error::new(
        ErrorKind::Unsupported,
        "symlinks are not supported on this platform",
    )))
}

/// Removes a file, a symlink or a folder tree. Symlinks are not followed.
fn remove_path(path: &Path) -> Result<()> {
    let meta = fs::symlink_metadata(path).map_err(|e| map_io(e, path))?;
    let removed = if meta.is_dir() {
        fs::remove_dir_all(path)
    } else {
        fs::remove_file(path)
    };
    removed.map_err(|e| map_io(e, path))
}

#[cfg(unix)]
fn is_cross_device(e: &io::Error) -> bool {
    e.kind() == ErrorKind::CrossesDevices || e.raw_os_error() == Some(libc::EXDEV)
}

#[cfg(not(unix))]
fn is_cross_device(e: &io::Error) -> bool {
    e.kind() == ErrorKind::CrossesDevices
}

/// Renames `from` to `to`, failing with `AlreadyExists` if `to` exists. The kernel does the
/// check (no race). Filesystems without the flag fall back to a checked rename.
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn rename_noreplace(from: &Path, to: &Path) -> Result<()> {
    match rename_exclusive(from, to) {
        Ok(()) => Ok(()),
        Err(e)
            if matches!(
                e.raw_os_error(),
                Some(libc::EINVAL) | Some(libc::ENOSYS) | Some(libc::EOPNOTSUPP)
            ) =>
        {
            rename_checked(from, to)
        }
        Err(e) => Err(map_rename(e, from, to)),
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn rename_noreplace(from: &Path, to: &Path) -> Result<()> {
    rename_checked(from, to)
}

/// Fallback: check, then rename. Not atomic, used only where the kernel flag is missing.
fn rename_checked(from: &Path, to: &Path) -> Result<()> {
    ensure_absent(to)?;
    fs::rename(from, to).map_err(|e| map_rename(e, from, to))
}

#[cfg(unix)]
fn c_path(path: &Path) -> io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|e| io::Error::new(ErrorKind::InvalidInput, e))
}

#[cfg(target_os = "linux")]
fn rename_exclusive(from: &Path, to: &Path) -> io::Result<()> {
    const RENAME_NOREPLACE: libc::c_uint = 1;
    let (a, b) = (c_path(from)?, c_path(to)?);
    // SAFETY: both pointers come from NUL-terminated CStrings that outlive the call.
    let rc = unsafe { libc::renameat2(libc::AT_FDCWD, a.as_ptr(), libc::AT_FDCWD, b.as_ptr(), RENAME_NOREPLACE) };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(target_os = "macos")]
fn rename_exclusive(from: &Path, to: &Path) -> io::Result<()> {
    let (a, b) = (c_path(from)?, c_path(to)?);
    // SAFETY: both pointers come from NUL-terminated CStrings that outlive the call.
    let rc = unsafe { libc::renamex_np(a.as_ptr(), b.as_ptr(), libc::RENAME_EXCL) };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Moves `src` to `dest` (which must not exist). Across devices a regular file of at most
/// `MOVE_COPY_LIMIT` is copied and then the original is removed; folders are not copied
/// (`CrossDevice`). If the copy fails, what it created is removed and the original stays.
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn move_into(src: &Path, dest: &Path) -> Result<()> {
    match fs::rename(src, dest) {
        Ok(()) => Ok(()),
        Err(e) if is_cross_device(&e) => {
            let meta = fs::symlink_metadata(src).map_err(|e| map_io(e, src))?;
            if meta.is_dir() || meta.len() > MOVE_COPY_LIMIT {
                return Err(FsError::CrossDevice(path_str(src)));
            }
            let mut created = Vec::new();
            if let Err(err) = copy_tree(src, dest, &mut created, 0, None) {
                rollback(&created);
                return Err(err);
            }
            // The copy is kept if removing the original fails: never delete the only good copy.
            remove_path(src)
        }
        Err(e) => Err(map_io(e, src)),
    }
}

/// A name in `dir` that is free (and, with `info_dir`, has no `.trashinfo` either):
/// `name`, then `stem 2.ext`, `stem 3.ext`…
#[cfg(any(target_os = "linux", target_os = "macos"))]
fn free_name(dir: &Path, name: &OsStr, info_dir: Option<&Path>) -> Result<OsString> {
    let path = Path::new(name);
    let stem = path.file_stem().unwrap_or(name);
    let ext = path.extension();
    for n in 1..=MAX_NAME_TRIES {
        let candidate: OsString = if n == 1 {
            name.to_os_string()
        } else {
            let mut s = stem.to_os_string();
            s.push(format!(" {n}"));
            if let Some(ext) = ext {
                s.push(".");
                s.push(ext);
            }
            s
        };
        let mut info_name = candidate.clone();
        info_name.push(".trashinfo");
        let taken = fs::symlink_metadata(dir.join(&candidate)).is_ok()
            || info_dir.is_some_and(|d| fs::symlink_metadata(d.join(&info_name)).is_ok());
        if !taken {
            return Ok(candidate);
        }
    }
    Err(FsError::AlreadyExists(path_str(&dir.join(name))))
}

/// Body of a freedesktop `.trashinfo` file.
#[cfg(target_os = "linux")]
fn trash_info(path: &Path) -> String {
    let deleted = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S");
    format!("[Trash Info]\nPath={}\nDeletionDate={deleted}\n", percent_encode(path))
}

/// Percent-encodes a path for `.trashinfo`. Unreserved ASCII and `/` stay as they are.
#[cfg(target_os = "linux")]
fn percent_encode(path: &Path) -> String {
    let mut out = String::new();
    for &b in path.as_os_str().as_encoded_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' | b'/' => {
                out.push(char::from(b));
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Compares names so that `file2` sorts before `file10`. Digit runs compare as numbers.
fn natural_cmp(a: &str, b: &str) -> Ordering {
    let mut a = a.chars().peekable();
    let mut b = b.chars().peekable();
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let ord = cmp_digit_runs(&take_digits(&mut a), &take_digits(&mut b));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(x), Some(y)) => {
                if x != y {
                    return x.cmp(&y);
                }
                a.next();
                b.next();
            }
        }
    }
}

fn take_digits(chars: &mut Peekable<Chars<'_>>) -> String {
    let mut out = String::new();
    while let Some(c) = chars.next_if(char::is_ascii_digit) {
        out.push(c);
    }
    out
}

fn cmp_digit_runs(a: &str, b: &str) -> Ordering {
    let a = a.trim_start_matches('0');
    let b = b.trim_start_matches('0');
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs::{self, File};
    use std::io::{self, ErrorKind};
    use std::time::{Duration, SystemTime};

    fn service(home: &Path) -> FileService {
        FileService::new(home.to_path_buf(), None)
    }

    /// Canonical path of the temp dir: on macOS /var is a symlink to /private/var.
    fn real(dir: &tempfile::TempDir) -> PathBuf {
        fs::canonicalize(dir.path()).unwrap()
    }

    fn path_str(path: &Path) -> String {
        path.to_string_lossy().into_owned()
    }

    fn write_file(path: &Path, content: &[u8]) {
        fs::write(path, content).unwrap();
    }

    fn names(listing: &Listing) -> Vec<&str> {
        listing.entries.iter().map(|e| e.name.as_str()).collect()
    }

    fn find<'a>(listing: &'a Listing, name: &str) -> &'a Entry {
        listing.entries.iter().find(|e| e.name == name).unwrap()
    }

    fn dir_names(dir: &Path) -> Vec<String> {
        let mut out: Vec<String> = fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        out.sort();
        out
    }

    fn make_repo(dir: &Path, mtime: SystemTime) {
        fs::create_dir_all(dir.join(".git")).unwrap();
        File::open(dir).unwrap().set_modified(mtime).unwrap();
    }

    #[test]
    fn resolve_expands_tilde() {
        let dir = tempfile::tempdir().unwrap();
        let home = real(&dir);
        let svc = service(&home);
        assert_eq!(svc.resolve("~").unwrap(), home);
        assert_eq!(svc.resolve("~/a/b.txt").unwrap(), home.join("a/b.txt"));
    }

    #[test]
    fn resolve_treats_double_slash_after_tilde_as_home() {
        let dir = tempfile::tempdir().unwrap();
        let home = real(&dir);
        let svc = service(&home);
        assert_eq!(svc.resolve("~//x").unwrap(), home.join("x"));
        assert_eq!(svc.resolve("~//").unwrap(), home);
    }

    #[test]
    fn resolve_rejects_relative_empty_and_nul() {
        let dir = tempfile::tempdir().unwrap();
        let svc = service(dir.path());
        for raw in ["", "docs/a.txt", "~user/x", "./x", "/tmp/a\0b"] {
            assert!(matches!(svc.resolve(raw), Err(FsError::InvalidPath(_))), "{raw:?}");
        }
    }

    #[test]
    fn resolve_normalizes_dot_segments() {
        let dir = tempfile::tempdir().unwrap();
        let home = real(&dir);
        let svc = service(&home);
        assert_eq!(svc.resolve("/a/./b/../c").unwrap(), Path::new("/a/c"));
        assert_eq!(svc.resolve("/..").unwrap(), Path::new("/"));
        assert_eq!(svc.resolve("~/x/../../y").unwrap(), home.parent().unwrap().join("y"));
    }

    #[cfg(unix)]
    #[test]
    fn resolve_returns_canonical_path_for_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let home = real(&dir);
        let svc = service(&home);
        // The file does not exist; its folder is a symlink to a real folder.
        fs::create_dir(home.join("real")).unwrap();
        std::os::unix::fs::symlink(home.join("real"), home.join("alias")).unwrap();
        assert_eq!(svc.resolve("~/alias/new.txt").unwrap(), home.join("real/new.txt"));
    }

    #[test]
    fn resolve_outside_roots_is_rejected() {
        let inside = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let svc = FileService::new(real(&inside), Some(vec![real(&inside)]));
        let err = svc.resolve(&path_str(&real(&outside).join("x.txt"))).unwrap_err();
        assert!(matches!(err, FsError::OutsideRoots(_)));
    }

    #[test]
    fn resolve_allows_paths_inside_roots_including_new_files() {
        let dir = tempfile::tempdir().unwrap();
        let root = real(&dir);
        fs::create_dir(root.join("sub")).unwrap();
        // A root that does not exist is dropped, the real one still works.
        let roots = vec![PathBuf::from("/bandito-no-such-root-for-tests"), root.clone()];
        let svc = FileService::new(root.clone(), Some(roots));
        assert!(svc.resolve(&path_str(&root)).is_ok());
        assert!(svc.resolve(&path_str(&root.join("sub/new-file.txt"))).is_ok());
        assert!(matches!(
            svc.resolve("/bandito-no-such-root-for-tests/x"),
            Err(FsError::OutsideRoots(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn resolve_rejects_symlink_that_escapes_roots() {
        let root_dir = tempfile::tempdir().unwrap();
        let root = real(&root_dir);
        let outside_dir = tempfile::tempdir().unwrap();
        let outside = real(&outside_dir);
        write_file(&outside.join("secret.txt"), b"x");
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        let svc = FileService::new(root.clone(), Some(vec![root.clone()]));
        let err = svc.resolve(&path_str(&root.join("link/secret.txt"))).unwrap_err();
        assert!(matches!(err, FsError::OutsideRoots(_)));
        // The link itself points outside, so it is refused as a whole.
        let err = svc.resolve(&path_str(&root.join("link"))).unwrap_err();
        assert!(matches!(err, FsError::OutsideRoots(_)));
    }

    #[test]
    fn resolve_without_roots_allows_any_absolute_path() {
        let dir = tempfile::tempdir().unwrap();
        assert!(service(dir.path()).resolve("/").is_ok());
    }

    #[test]
    fn list_puts_dirs_first_and_sorts_names_naturally() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        for d in ["zdir", "Adir"] {
            fs::create_dir(p.join(d)).unwrap();
        }
        for f in ["file10", "file2", "B.txt", "a.txt"] {
            write_file(&p.join(f), b"");
        }
        let listing = service(&p).list(&path_str(&p), false).unwrap();
        assert_eq!(names(&listing), ["Adir", "zdir", "a.txt", "B.txt", "file2", "file10"]);
        assert_eq!(listing.entries[0].kind, EntryKind::Dir);
        assert_eq!(listing.parent, Some(path_str(p.parent().unwrap())));
        assert!(!listing.truncated);
        assert_eq!(listing.skipped, 0);
    }

    #[cfg(unix)]
    #[test]
    fn list_sorts_symlink_to_dir_with_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        fs::create_dir(p.join("target")).unwrap();
        std::os::unix::fs::symlink(p.join("target"), p.join("link")).unwrap();
        write_file(&p.join("a.txt"), b"");
        let listing = service(&p).list(&path_str(&p), false).unwrap();
        assert_eq!(names(&listing), ["link", "target", "a.txt"]);
        let link = &listing.entries[0];
        assert_eq!(link.kind, EntryKind::Symlink);
        assert_eq!(link.symlink_target, Some(path_str(&p.join("target"))));
    }

    #[test]
    fn list_hides_dotfiles_unless_asked() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join("readme"), b"");
        write_file(&p.join(".env"), b"");
        let svc = service(&p);

        let shown = svc.list(&path_str(&p), false).unwrap();
        assert_eq!(names(&shown), ["readme"]);

        let all = svc.list(&path_str(&p), true).unwrap();
        assert_eq!(names(&all), [".env", "readme"]);
        assert!(all.entries[0].hidden);
        assert!(!all.entries[1].hidden);
    }

    #[test]
    fn list_rejects_file_and_root_has_no_parent() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("f.txt");
        write_file(&file, b"x");
        let svc = service(&p);
        assert!(matches!(
            svc.list(&path_str(&file), false),
            Err(FsError::NotADirectory(_))
        ));
        let root = svc.list("/", false).unwrap();
        assert_eq!(root.path, "/");
        assert_eq!(root.parent, None);
    }

    #[test]
    fn list_truncates_after_limit() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        for i in 0..=LIST_LIMIT {
            write_file(&p.join(format!("f{i:05}")), b"");
        }
        let listing = service(&p).list(&path_str(&p), false).unwrap();
        assert_eq!(listing.entries.len(), LIST_LIMIT);
        assert!(listing.truncated);
    }

    // APFS refuses non-UTF-8 names (EILSEQ), so this runs on Linux only.
    #[cfg(target_os = "linux")]
    #[test]
    fn list_skips_non_utf8_names_and_counts_them() {
        use std::ffi::OsStr;
        use std::os::unix::ffi::OsStrExt;
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join(OsStr::from_bytes(b"bad\xffname.txt")), b"");
        write_file(&p.join("ok.txt"), b"");
        let listing = service(&p).list(&path_str(&p), false).unwrap();
        assert_eq!(names(&listing), ["ok.txt"]);
        assert_eq!(listing.skipped, 1);
    }

    #[test]
    fn list_reports_lowercase_extension_without_dot() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join("Photo.JPG"), b"");
        write_file(&p.join("archive.tar.GZ"), b"");
        write_file(&p.join("Makefile"), b"");
        write_file(&p.join(".bashrc"), b"");
        fs::create_dir(p.join("docs.d")).unwrap();
        let listing = service(&p).list(&path_str(&p), true).unwrap();
        assert_eq!(find(&listing, "Photo.JPG").ext.as_deref(), Some("jpg"));
        assert_eq!(find(&listing, "archive.tar.GZ").ext.as_deref(), Some("gz"));
        assert_eq!(find(&listing, "Makefile").ext, None);
        assert_eq!(find(&listing, ".bashrc").ext, None);
        assert_eq!(find(&listing, "docs.d").ext, None);
    }

    #[cfg(unix)]
    #[test]
    fn stat_reports_size_kind_and_symlink_target() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join("data.bin"), b"12345");
        std::os::unix::fs::symlink(p.join("data.bin"), p.join("alias")).unwrap();
        let svc = service(&p);

        let file = svc.stat(&path_str(&p.join("data.bin"))).unwrap();
        assert_eq!(file.kind, EntryKind::File);
        assert_eq!(file.size, 5);
        assert_eq!(file.ext.as_deref(), Some("bin"));
        assert_eq!(file.symlink_target, None);

        let link = svc.stat(&path_str(&p.join("alias"))).unwrap();
        assert_eq!(link.kind, EntryKind::Symlink);
        assert_eq!(link.symlink_target, Some(path_str(&p.join("data.bin"))));

        assert!(matches!(
            svc.stat(&path_str(&p.join("missing"))),
            Err(FsError::NotFound(_))
        ));
    }

    #[test]
    fn read_text_returns_content_with_stable_etag() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("note.md");
        write_file(&file, "привет\n".as_bytes());
        let svc = service(&p);
        let a = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap();
        let b = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap();
        assert_eq!(a.content, "привет\n");
        assert_eq!(a.size, "привет\n".len() as u64);
        assert_eq!(a.etag, b.etag);
        assert_eq!(a.etag.len(), 16);
        assert!(a.etag.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(!a.readonly);
    }

    #[test]
    fn read_text_rejects_files_over_limit_and_accepts_exact_size() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let big = p.join("big.txt");
        write_file(&big, b"0123456789");
        let svc = service(&p);
        let err = svc.read_text(&path_str(&big), 4).unwrap_err();
        assert!(matches!(err, FsError::TooLarge { size: 10, limit: 4 }));
        let exact = p.join("exact.txt");
        write_file(&exact, b"abcd");
        assert_eq!(svc.read_text(&path_str(&exact), 4).unwrap().content, "abcd");
    }

    #[test]
    fn read_text_detects_binary_by_nul_and_invalid_utf8() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let svc = service(&p);
        let nul = p.join("nul.dat");
        write_file(&nul, b"abc\0def");
        assert!(matches!(
            svc.read_text(&path_str(&nul), TEXT_LIMIT),
            Err(FsError::Binary)
        ));
        let bad = p.join("bad.dat");
        write_file(&bad, &[0xff, 0xfe, b'a']);
        assert!(matches!(
            svc.read_text(&path_str(&bad), TEXT_LIMIT),
            Err(FsError::Binary)
        ));
    }

    #[test]
    fn read_text_rejects_directory_and_missing_file() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let svc = service(&p);
        assert!(matches!(
            svc.read_text(&path_str(&p), TEXT_LIMIT),
            Err(FsError::IsADirectory(_))
        ));
        assert!(matches!(
            svc.read_text(&path_str(&p.join("nope.txt")), TEXT_LIMIT),
            Err(FsError::NotFound(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn read_and_write_refuse_device_files() {
        let dir = tempfile::tempdir().unwrap();
        let svc = service(dir.path());
        // /dev/zero never ends: it must be refused before any read happens.
        assert!(matches!(
            svc.read_text("/dev/zero", TEXT_LIMIT),
            Err(FsError::NotAFile(_))
        ));
        assert!(matches!(
            svc.write_text("/dev/zero", "x", None, false),
            Err(FsError::NotAFile(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn fifo_is_not_a_file_for_read_or_write() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let fifo = p.join("pipe");
        let c = std::ffi::CString::new(path_str(&fifo)).unwrap();
        // SAFETY: plain libc call with a valid NUL-terminated path.
        let rc = unsafe { libc::mkfifo(c.as_ptr(), 0o600) };
        assert_eq!(rc, 0);
        let svc = service(&p);
        // Opening a FIFO would block; these must return before that.
        assert!(matches!(
            svc.read_text(&path_str(&fifo), TEXT_LIMIT),
            Err(FsError::NotAFile(_))
        ));
        assert!(matches!(
            svc.write_text(&path_str(&fifo), "x", None, false),
            Err(FsError::NotAFile(_))
        ));
    }

    #[test]
    fn write_text_creates_file_when_allowed() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("new.txt");
        let svc = service(&p);
        let etag = svc.write_text(&path_str(&file), "hi", None, true).unwrap();
        assert_eq!(fs::read_to_string(&file).unwrap(), "hi");
        assert_eq!(svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag, etag);
    }

    #[test]
    fn write_text_missing_without_create_is_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("missing.txt");
        let svc = service(&p);
        assert!(matches!(
            svc.write_text(&path_str(&file), "x", None, false),
            Err(FsError::NotFound(_))
        ));
        assert!(!file.exists());
    }

    #[test]
    fn write_text_create_over_existing_without_etag_is_already_exists() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("old.txt");
        write_file(&file, b"old");
        let svc = service(&p);
        assert!(matches!(
            svc.write_text(&path_str(&file), "new", None, true),
            Err(FsError::AlreadyExists(_))
        ));
        assert_eq!(fs::read_to_string(&file).unwrap(), "old");
    }

    #[test]
    fn write_text_without_etag_over_existing_is_conflict() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("doc.txt");
        write_file(&file, b"one");
        let svc = service(&p);
        let current = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag;
        match svc.write_text(&path_str(&file), "blind", None, false) {
            Err(FsError::Conflict { etag }) => assert_eq!(etag, current),
            other => panic!("expected Conflict, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(&file).unwrap(), "one");
    }

    #[test]
    fn write_text_with_etag_on_missing_file_is_not_found() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("gone.txt");
        let svc = service(&p);
        let etag = etag_of("x".as_bytes());
        assert!(matches!(
            svc.write_text(&path_str(&file), "x", Some(&etag), true),
            Err(FsError::NotFound(_))
        ));
        assert!(matches!(
            svc.write_text(&path_str(&file), "x", Some(&etag), false),
            Err(FsError::NotFound(_))
        ));
        assert!(!file.exists());
    }

    #[test]
    fn write_text_conflict_reports_current_etag() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("doc.txt");
        write_file(&file, b"one");
        let svc = service(&p);
        let current = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag;
        let err = svc
            .write_text(&path_str(&file), "two", Some("0000000000000000"), false)
            .unwrap_err();
        match err {
            FsError::Conflict { etag } => assert_eq!(etag, current),
            other => panic!("expected Conflict, got {other:?}"),
        }
        assert_eq!(fs::read_to_string(&file).unwrap(), "one");
    }

    #[test]
    fn concurrent_writes_with_same_etag_conflict_once() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("race.txt");
        write_file(&file, b"start");
        let svc = service(&p);
        let etag = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag;
        let file_str = path_str(&file);
        let results: Vec<Result<String>> = std::thread::scope(|s| {
            let handles: Vec<_> = (0..2)
                .map(|i| {
                    let svc = &svc;
                    let etag = etag.clone();
                    let file_str = file_str.clone();
                    s.spawn(move || svc.write_text(&file_str, &format!("writer {i}"), Some(&etag), false))
                })
                .collect();
            handles.into_iter().map(|h| h.join().unwrap()).collect()
        });
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|r| matches!(r, Err(FsError::Conflict { .. })))
                .count(),
            1
        );
    }

    #[test]
    fn write_text_with_current_etag_replaces_content() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("doc.txt");
        write_file(&file, b"one");
        let svc = service(&p);
        let e1 = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag;
        let e2 = svc.write_text(&path_str(&file), "two", Some(&e1), false).unwrap();
        assert_eq!(e2, etag_of("two".as_bytes()));
        assert_ne!(e2, e1);
        assert_eq!(fs::read_to_string(&file).unwrap(), "two");
    }

    #[cfg(unix)]
    #[test]
    fn write_text_keeps_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("secret.conf");
        write_file(&file, b"a=1");
        fs::set_permissions(&file, fs::Permissions::from_mode(0o640)).unwrap();
        let svc = service(&p);
        let etag = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag;
        svc.write_text(&path_str(&file), "a=2", Some(&etag), false).unwrap();
        let mode = fs::metadata(&file).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o640);
    }

    #[test]
    fn write_text_leaves_no_temp_files() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("doc.txt");
        write_file(&file, b"one");
        let svc = service(&p);
        let etag = svc.read_text(&path_str(&file), TEXT_LIMIT).unwrap().etag;
        svc.write_text(&path_str(&file), "two", Some(&etag), false).unwrap();
        assert_eq!(dir_names(&p), ["doc.txt"]);
    }

    #[test]
    fn write_text_refuses_readonly_file() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("locked.txt");
        write_file(&file, b"keep");
        let mut perms = fs::metadata(&file).unwrap().permissions();
        perms.set_readonly(true);
        fs::set_permissions(&file, perms).unwrap();
        let svc = service(&p);
        let etag = etag_of(b"keep");
        let err = svc
            .write_text(&path_str(&file), "lost", Some(&etag), false)
            .unwrap_err();
        assert!(matches!(err, FsError::PermissionDenied(_)));
        assert_eq!(fs::read_to_string(&file).unwrap(), "keep");
    }

    #[test]
    fn create_file_and_mkdir_report_duplicates_and_missing_parents() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let svc = service(&p);
        let created = svc.create_file(&path_str(&p.join("new.txt"))).unwrap();
        assert_eq!(created.kind, EntryKind::File);
        assert_eq!(created.size, 0);
        assert!(matches!(
            svc.create_file(&path_str(&p.join("new.txt"))),
            Err(FsError::AlreadyExists(_))
        ));
        assert!(matches!(
            svc.mkdir(&path_str(&p.join("a/b"))),
            Err(FsError::NotFound(_))
        ));
        assert_eq!(svc.mkdir(&path_str(&p.join("a"))).unwrap().kind, EntryKind::Dir);
        assert!(matches!(
            svc.mkdir(&path_str(&p.join("a"))),
            Err(FsError::AlreadyExists(_))
        ));
    }

    #[test]
    fn rename_refuses_existing_target_and_missing_source() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join("a.txt"), b"a");
        write_file(&p.join("c.txt"), b"c");
        let svc = service(&p);
        let moved = svc
            .rename(&path_str(&p.join("a.txt")), &path_str(&p.join("b.txt")))
            .unwrap();
        assert_eq!(moved.name, "b.txt");
        assert!(!p.join("a.txt").exists());
        assert!(matches!(
            svc.rename(&path_str(&p.join("c.txt")), &path_str(&p.join("b.txt"))),
            Err(FsError::AlreadyExists(_))
        ));
        assert_eq!(fs::read_to_string(p.join("b.txt")).unwrap(), "a");
        assert!(matches!(
            svc.rename(&path_str(&p.join("a.txt")), &path_str(&p.join("d.txt"))),
            Err(FsError::NotFound(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn broken_symlink_can_be_renamed_and_trashed() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        std::os::unix::fs::symlink(p.join("missing-target"), p.join("dangling")).unwrap();
        let svc = service(&p);
        let moved = svc
            .rename(&path_str(&p.join("dangling")), &path_str(&p.join("renamed")))
            .unwrap();
        assert_eq!(moved.kind, EntryKind::Symlink);
        let in_trash = svc.trash(&path_str(&p.join("renamed"))).unwrap();
        assert!(fs::symlink_metadata(&in_trash).unwrap().file_type().is_symlink());
        assert!(fs::symlink_metadata(p.join("renamed")).is_err());
    }

    #[test]
    fn copy_file_refuses_existing_target() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join("src.txt"), b"data");
        let svc = service(&p);
        let src = path_str(&p.join("src.txt"));
        let dst = path_str(&p.join("dst.txt"));
        assert_eq!(svc.copy(&src, &dst).unwrap().kind, EntryKind::File);
        assert_eq!(fs::read_to_string(p.join("dst.txt")).unwrap(), "data");
        assert!(matches!(svc.copy(&src, &dst), Err(FsError::AlreadyExists(_))));
        assert!(matches!(
            svc.copy(&path_str(&p.join("missing")), &path_str(&p.join("x"))),
            Err(FsError::NotFound(_))
        ));
    }

    #[test]
    fn copy_directory_is_recursive() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        fs::create_dir_all(p.join("src/sub")).unwrap();
        write_file(&p.join("src/top.txt"), b"top");
        write_file(&p.join("src/sub/deep.txt"), b"deep");
        let entry = service(&p)
            .copy(&path_str(&p.join("src")), &path_str(&p.join("dst")))
            .unwrap();
        assert_eq!(entry.kind, EntryKind::Dir);
        assert_eq!(fs::read_to_string(p.join("dst/top.txt")).unwrap(), "top");
        assert_eq!(fs::read_to_string(p.join("dst/sub/deep.txt")).unwrap(), "deep");
    }

    #[cfg(unix)]
    #[test]
    fn copy_keeps_symlinks_as_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        fs::create_dir(p.join("src")).unwrap();
        write_file(&p.join("target.txt"), b"t");
        std::os::unix::fs::symlink(p.join("target.txt"), p.join("src/link")).unwrap();
        service(&p)
            .copy(&path_str(&p.join("src")), &path_str(&p.join("dst")))
            .unwrap();
        assert_eq!(fs::read_link(p.join("dst/link")).unwrap(), p.join("target.txt"));
    }

    #[test]
    fn copy_folder_into_itself_is_invalid_path() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        fs::create_dir(p.join("d")).unwrap();
        assert!(matches!(
            service(&p).copy(&path_str(&p.join("d")), &path_str(&p.join("d/copy"))),
            Err(FsError::InvalidPath(_))
        ));
    }

    #[test]
    fn copy_tree_keeps_existing_destination() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        fs::create_dir(p.join("src")).unwrap();
        write_file(&p.join("src/a.txt"), b"a");
        fs::create_dir(p.join("dst")).unwrap();
        write_file(&p.join("dst/keep.txt"), b"keep");
        let mut created = Vec::new();
        let err = copy_tree(&p.join("src"), &p.join("dst"), &mut created, 0, None).unwrap_err();
        assert!(matches!(err, FsError::AlreadyExists(_)));
        assert!(created.is_empty());
        assert_eq!(fs::read_to_string(p.join("dst/keep.txt")).unwrap(), "keep");
    }

    #[test]
    fn copy_failure_rolls_back_partial_tree() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let mut deep = p.join("src");
        for i in 0..70 {
            deep = deep.join(format!("d{i}"));
        }
        fs::create_dir_all(&deep).unwrap();
        let svc = service(&p);
        let err = svc
            .copy(&path_str(&p.join("src")), &path_str(&p.join("dst")))
            .unwrap_err();
        assert!(matches!(err, FsError::InvalidPath(_)));
        assert!(!p.join("dst").exists(), "partial copy must be removed");
        assert!(deep.is_dir(), "the source is untouched");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn trash_moves_file_into_freedesktop_trash() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        write_file(&h.join("my file.txt"), b"x");
        let svc = service(&h);
        let where_ = svc.trash("~/my file.txt").unwrap();
        let expected = h.join(".local/share/Trash/files/my file.txt");
        assert_eq!(where_, path_str(&expected));
        assert!(expected.exists());
        assert!(!h.join("my file.txt").exists());
        let info = fs::read_to_string(h.join(".local/share/Trash/info/my file.txt.trashinfo")).unwrap();
        assert!(info.starts_with("[Trash Info]\nPath="), "{info}");
        assert!(
            info.contains(&format!("Path={}/my%20file.txt\n", path_str(&h))),
            "{info}"
        );
        assert!(info.contains("\nDeletionDate="), "{info}");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn trash_moves_file_into_home_trash() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        write_file(&h.join("note.txt"), b"x");
        let where_ = service(&h).trash("~/note.txt").unwrap();
        assert!(Path::new(&where_).starts_with(h.join(".Trash")));
        assert!(Path::new(&where_).exists());
        assert!(!h.join("note.txt").exists());
    }

    #[test]
    fn trash_renames_colliding_names() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        let svc = service(&h);
        write_file(&h.join("name.txt"), b"1");
        let first = svc.trash("~/name.txt").unwrap();
        write_file(&h.join("name.txt"), b"2");
        let second = svc.trash("~/name.txt").unwrap();
        assert_ne!(first, second);
        assert!(second.ends_with("name 2.txt"), "{second}");
        assert_eq!(fs::read_to_string(&second).unwrap(), "2");
    }

    #[test]
    fn trash_refuses_home_root_and_missing_paths() {
        let home = tempfile::tempdir().unwrap();
        let svc = service(&real(&home));
        for raw in ["~", "~/", "/"] {
            assert!(matches!(svc.trash(raw), Err(FsError::InvalidPath(_))), "{raw}");
        }
        assert!(matches!(svc.trash("~/nope.txt"), Err(FsError::NotFound(_))));
    }

    #[test]
    fn search_matches_case_insensitively_and_skips_heavy_dirs() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        write_file(&p.join("Report.md"), b"");
        write_file(&p.join("other.txt"), b"");
        fs::create_dir_all(p.join("sub")).unwrap();
        write_file(&p.join("sub/report-final.txt"), b"");
        fs::create_dir(p.join("node_modules")).unwrap();
        write_file(&p.join("node_modules/report.js"), b"");
        fs::create_dir(p.join(".git")).unwrap();
        write_file(&p.join(".git/report-head"), b"");
        let hits = service(&p).search(&path_str(&p), "REPORT", 50).unwrap();
        let mut found: Vec<String> = hits.iter().map(|e| e.name.clone()).collect();
        found.sort();
        assert_eq!(found, ["Report.md", "report-final.txt"]);
    }

    #[test]
    fn search_stops_at_limit() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        for i in 1..=5 {
            write_file(&p.join(format!("hit-{i}.txt")), b"");
        }
        let svc = service(&p);
        assert_eq!(svc.search(&path_str(&p), "hit", 2).unwrap().len(), 2);
        assert!(svc.search(&path_str(&p), "hit", 0).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn search_does_not_follow_symlinked_dirs() {
        let root_dir = tempfile::tempdir().unwrap();
        let root = real(&root_dir);
        let outside_dir = tempfile::tempdir().unwrap();
        let outside = real(&outside_dir);
        write_file(&outside.join("needle.txt"), b"");
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        let hits = service(&root).search(&path_str(&root), "needle", 10).unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn project_hints_lists_repos_up_to_depth_three_newest_first() {
        let home = tempfile::tempdir().unwrap();
        let p = real(&home);
        let now = SystemTime::now();
        make_repo(&p.join("old-repo"), now - Duration::from_secs(2 * 86_400));
        fs::create_dir(p.join("group")).unwrap();
        make_repo(&p.join("group/new-repo"), now - Duration::from_secs(3_600));
        make_repo(&p.join("a/b/c/too-deep"), now);
        let svc = service(&p);

        let hints = svc.project_hints(10).unwrap();
        let found: Vec<&str> = hints.iter().map(|h| h.name.as_str()).collect();
        assert_eq!(found, ["new-repo", "old-repo"]);
        assert!(hints.iter().all(|h| h.is_git));

        let top = svc.project_hints(1).unwrap();
        assert_eq!(top.len(), 1);
        assert_eq!(top[0].name, "new-repo");
    }

    #[test]
    fn project_hints_skips_system_folders() {
        let home = tempfile::tempdir().unwrap();
        let p = real(&home);
        let now = SystemTime::now();
        make_repo(&p.join("real-repo"), now);
        make_repo(&p.join(".Trash/trashed-repo"), now);
        make_repo(&p.join("Photos Library.photoslibrary/library-repo"), now);
        make_repo(&p.join("Upper.PHOTOSLIBRARY/upper-repo"), now);
        make_repo(&p.join(".cache/cache-repo"), now);
        make_repo(&p.join("node_modules/dep-repo"), now);
        let svc = service(&p);
        let hints = svc.project_hints(10).unwrap();
        let found: Vec<&str> = hints.iter().map(|h| h.name.as_str()).collect();
        assert_eq!(found, ["real-repo"]);
    }

    #[test]
    fn project_hints_filters_by_roots() {
        let home = tempfile::tempdir().unwrap();
        let p = real(&home);
        let now = SystemTime::now();
        make_repo(&p.join("allowed/ok-repo"), now);
        make_repo(&p.join("other/bad-repo"), now);
        let svc = FileService::new(p.clone(), Some(vec![p.join("allowed")]));
        let hints = svc.project_hints(10).unwrap();
        let found: Vec<&str> = hints.iter().map(|h| h.name.as_str()).collect();
        assert_eq!(found, ["ok-repo"]);
    }

    #[test]
    fn upload_assembles_chunks_then_commits() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        fs::create_dir(h.join("up")).unwrap();
        let svc = service(&h);
        let id = svc.begin_upload(&path_str(&h.join("up/out.bin"))).unwrap();
        assert_eq!(svc.append_upload(&id, 0, b"hello ").unwrap(), 6);
        assert_eq!(svc.append_upload(&id, 6, b"world").unwrap(), 11);
        let entry = svc.commit_upload(&id, false).unwrap();
        assert_eq!(entry.size, 11);
        assert_eq!(fs::read(h.join("up/out.bin")).unwrap(), b"hello world");
        assert_eq!(dir_names(&h.join("up")), ["out.bin"]);
    }

    #[test]
    fn upload_rejects_offset_mismatch_and_keeps_state() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        fs::create_dir(h.join("up")).unwrap();
        let svc = service(&h);
        let id = svc.begin_upload(&path_str(&h.join("up/out.txt"))).unwrap();
        assert_eq!(svc.append_upload(&id, 0, b"abc").unwrap(), 3);
        assert!(matches!(svc.append_upload(&id, 1, b"x"), Err(FsError::InvalidPath(_))));
        assert_eq!(svc.append_upload(&id, 3, b"def").unwrap(), 6);
        svc.commit_upload(&id, false).unwrap();
        assert_eq!(fs::read_to_string(h.join("up/out.txt")).unwrap(), "abcdef");
    }

    #[test]
    fn upload_over_limit_is_too_large_and_upload_stays() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        fs::create_dir(h.join("up")).unwrap();
        let mut svc = service(&h);
        svc.max_upload_bytes = 4;
        let id = svc.begin_upload(&path_str(&h.join("up/out.txt"))).unwrap();
        assert_eq!(svc.append_upload(&id, 0, b"abc").unwrap(), 3);
        assert!(matches!(
            svc.append_upload(&id, 3, b"de"),
            Err(FsError::TooLarge { size: 5, limit: 4 })
        ));
        assert_eq!(svc.append_upload(&id, 3, b"d").unwrap(), 4);
        svc.commit_upload(&id, false).unwrap();
        assert_eq!(fs::read_to_string(h.join("up/out.txt")).unwrap(), "abcd");
    }

    #[test]
    fn upload_commit_refuses_existing_target_until_overwrite() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        fs::create_dir(h.join("up")).unwrap();
        write_file(&h.join("up/out.txt"), b"old");
        let svc = service(&h);
        let id = svc.begin_upload(&path_str(&h.join("up/out.txt"))).unwrap();
        svc.append_upload(&id, 0, b"new").unwrap();
        assert!(matches!(svc.commit_upload(&id, false), Err(FsError::AlreadyExists(_))));
        assert_eq!(dir_names(&h.join("up")).len(), 2, "temp file must stay for retry");
        assert_eq!(fs::read_to_string(h.join("up/out.txt")).unwrap(), "old");
        svc.commit_upload(&id, true).unwrap();
        assert_eq!(fs::read_to_string(h.join("up/out.txt")).unwrap(), "new");
        assert_eq!(dir_names(&h.join("up")), ["out.txt"]);
    }

    #[test]
    fn upload_abort_removes_temp_file() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        fs::create_dir(h.join("up")).unwrap();
        let svc = service(&h);
        let id = svc.begin_upload(&path_str(&h.join("up/out.bin"))).unwrap();
        svc.append_upload(&id, 0, b"partial").unwrap();
        svc.abort_upload(&id).unwrap();
        assert!(dir_names(&h.join("up")).is_empty());
        assert!(matches!(svc.append_upload(&id, 7, b"x"), Err(FsError::NotFound(_))));
        assert!(matches!(svc.abort_upload(&id), Err(FsError::NotFound(_))));
        assert!(matches!(svc.commit_upload(&id, true), Err(FsError::NotFound(_))));
    }

    #[test]
    fn sweep_uploads_removes_abandoned_temp_files() {
        let home = tempfile::tempdir().unwrap();
        let h = real(&home);
        fs::create_dir(h.join("up")).unwrap();
        let svc = service(&h);
        let id = svc.begin_upload(&path_str(&h.join("up/out.bin"))).unwrap();
        svc.append_upload(&id, 0, b"stale").unwrap();
        assert_eq!(svc.sweep_uploads(Duration::from_secs(3600)), 0);
        assert_eq!(dir_names(&h.join("up")).len(), 1);
        assert_eq!(svc.sweep_uploads(Duration::ZERO), 1);
        assert!(dir_names(&h.join("up")).is_empty());
        assert!(matches!(svc.append_upload(&id, 5, b"x"), Err(FsError::NotFound(_))));
    }

    #[test]
    fn upload_begin_requires_existing_parent() {
        let home = tempfile::tempdir().unwrap();
        let svc = service(&real(&home));
        assert!(matches!(
            svc.begin_upload(&path_str(&real(&home).join("missing/out.bin"))),
            Err(FsError::NotFound(_))
        ));
    }

    #[test]
    fn read_range_returns_slice_and_clamps_at_end() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("digits.txt");
        write_file(&file, b"0123456789");
        let svc = service(&p);
        let f = path_str(&file);
        assert_eq!(svc.read_range(&f, 3, 4).unwrap(), b"3456");
        assert_eq!(svc.read_range(&f, 8, 100).unwrap(), b"89");
        assert!(svc.read_range(&f, 10, 5).unwrap().is_empty());
        assert!(svc.read_range(&f, 50, 5).unwrap().is_empty());
    }

    #[test]
    fn read_range_caps_length_at_four_mib() {
        let dir = tempfile::tempdir().unwrap();
        let p = real(&dir);
        let file = p.join("big.bin");
        File::create(&file).unwrap().set_len(5 * 1024 * 1024).unwrap();
        let bytes = service(&p).read_range(&path_str(&file), 0, u64::MAX).unwrap();
        assert_eq!(bytes.len(), 4 * 1024 * 1024);
    }

    #[test]
    fn error_codes_are_stable() {
        assert_eq!(FsError::NotFound(String::new()).code(), "not_found");
        assert_eq!(FsError::AlreadyExists(String::new()).code(), "exists");
        assert_eq!(FsError::NotADirectory(String::new()).code(), "not_a_directory");
        assert_eq!(FsError::IsADirectory(String::new()).code(), "is_a_directory");
        assert_eq!(FsError::NotAFile(String::new()).code(), "not_a_file");
        assert_eq!(FsError::PermissionDenied(String::new()).code(), "permission_denied");
        assert_eq!(FsError::TooLarge { size: 2, limit: 1 }.code(), "too_large");
        assert_eq!(FsError::Binary.code(), "binary");
        assert_eq!(FsError::Conflict { etag: String::new() }.code(), "conflict");
        assert_eq!(FsError::InvalidPath(String::new()).code(), "invalid_path");
        assert_eq!(FsError::OutsideRoots(String::new()).code(), "outside_roots");
        assert_eq!(FsError::CrossDevice(String::new()).code(), "cross_device");
        assert_eq!(FsError::Io(io::Error::other("x")).code(), "io");
    }

    #[test]
    fn io_errors_map_by_kind() {
        let p = Path::new("/x");
        assert!(matches!(
            map_io(io::Error::from(ErrorKind::NotFound), p),
            FsError::NotFound(_)
        ));
        assert!(matches!(
            map_io(io::Error::from(ErrorKind::AlreadyExists), p),
            FsError::AlreadyExists(_)
        ));
        assert!(matches!(
            map_io(io::Error::from(ErrorKind::PermissionDenied), p),
            FsError::PermissionDenied(_)
        ));
        assert!(matches!(
            map_io(io::Error::from(ErrorKind::NotADirectory), p),
            FsError::NotADirectory(_)
        ));
        assert!(matches!(
            map_io(io::Error::from(ErrorKind::IsADirectory), p),
            FsError::IsADirectory(_)
        ));
        assert!(matches!(map_io(io::Error::from(ErrorKind::Other), p), FsError::Io(_)));
    }
}
