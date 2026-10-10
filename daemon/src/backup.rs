//! Database copies in `<home>/backups`: taken at start, once a day while the daemon runs, and before a restore.
//! Each copy is a `VACUUM INTO` snapshot, so it holds the WAL content too. A copy is written under
//! `<name>.partial`, checked with `PRAGMA quick_check`, and only then renamed to its final name
//! (see docs/ARCHITECTURE.md#backups).

use anyhow::{Context, Result, bail};
use chrono::NaiveDateTime;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Newest copies kept; older ones are pruned.
pub const KEEP: usize = 14;

const DB_FILE: &str = "bandito.db";
const LAST_VERSION: &str = "last-version";
const LOCK_FILE: &str = "daemon.lock";
/// The file in `run/` that asks for a restore at the next start (see `request_restore`).
const RESTORE_MARKER: &str = "restore-pending";
/// The result of the last restore, in `run/` (see `write_last_restore`).
const LAST_RESTORE_FILE: &str = "last-restore.json";
const PARTIAL_SUFFIX: &str = ".partial";
const TS_FORMAT: &str = "%Y%m%d-%H%M%S";
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const HOUR_MS: i64 = 3_600_000;
/// A copy younger than this is good enough at start.
const START_MAX_AGE_MS: i64 = 20 * HOUR_MS;
/// The periodic check makes a copy once the newest one is older than this.
const DAILY_MAX_AGE_MS: i64 = 24 * HOUR_MS;
const BUSY_MSG: &str =
    "The daemon is running. Stop it first: bandito service uninstall; after the restore: bandito service install";

pub fn backups_dir(home: &Path) -> PathBuf {
    home.join("backups")
}

/// The daemon's lock: an exclusive `flock` on `<home>/run/daemon.lock`, held for the whole life of the daemon.
/// Restore takes the same lock, so it cannot run while a daemon is up. `None` when another process holds it.
/// The lock goes with the file descriptor, so a crashed daemon does not leave it behind.
pub fn try_daemon_lock(home: &Path) -> Result<Option<fs::File>> {
    let dir = home.join("run");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)
        .with_context(|| format!("create {}", dir.display()))?;
    let path = dir.join(LOCK_FILE);
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .with_context(|| format!("open {}", path.display()))?;
    match file.try_lock() {
        Ok(()) => Ok(Some(file)),
        Err(fs::TryLockError::WouldBlock) => Ok(None),
        Err(fs::TryLockError::Error(e)) => Err(e).with_context(|| format!("lock {}", path.display())),
    }
}

/// Writes a consistent copy of `db` to `<home>/backups/bandito-<UTC time>-<reason>.db` and returns its path.
/// A name already taken gets `-2`, `-3`, ... (two copies in the same second stay apart). The copy is
/// checked with `quick_check` before it gets its final name; a failed copy leaves nothing behind.
pub fn snapshot_file(db: &Path, home: &Path, reason: &str, now_ms: i64) -> Result<PathBuf> {
    if !valid_reason(reason) {
        bail!("invalid backup reason {reason:?}: use lowercase letters and '-'");
    }
    let dir = backups_dir(home);
    create_private_dir(&dir)?;
    let ts = timestamp(now_ms)?;
    let (target, partial) = reserve(&dir, &ts, reason)?;
    let result = check_fault("snapshot")
        .with_context(|| format!("write {}", partial.display()))
        .and_then(|()| write_copy(db, &partial))
        .and_then(|()| quick_check(&partial))
        .and_then(|()| fs::rename(&partial, &target).with_context(|| format!("rename {}", partial.display())));
    if let Err(e) = result {
        let _ = fs::remove_file(&partial);
        return Err(e);
    }
    Ok(target)
}

/// Keeps the `keep` newest copies in `<home>/backups`. Other files there are not touched; in particular the databases
/// a restore set aside (`replaced-*`, `broken-*`) are never removed: only a person cleans those up. A copy that cannot
/// be removed is logged, not returned as an error: the copy the caller made is already safe.
pub fn prune(home: &Path, keep: usize) {
    prune_except(home, keep, &[]);
}

/// Like `prune`, but a copy named in `protected` stays even when it is older than the `keep` newest. A restore
/// protects the copy it restores from and the copy it made before the swap.
pub fn prune_except(home: &Path, keep: usize, protected: &[&str]) {
    let dir = backups_dir(home);
    let entries = match entries(home) {
        Ok(entries) => entries,
        Err(e) => {
            tracing::warn!("list the backups to prune: {e:#}");
            return;
        }
    };
    for entry in entries.into_iter().skip(keep) {
        if protected.contains(&entry.name.as_str()) {
            continue;
        }
        if let Err(e) = remove_if_exists(&dir.join(&entry.name)) {
            tracing::warn!("prune backup {}: {e:#}", entry.name);
        }
    }
}

/// Age in ms of the newest copy, by the time in its name. `None` when there is no copy.
pub fn newest_age_ms(home: &Path, now_ms: i64) -> Option<i64> {
    entries(home).ok()?.first().map(|e| now_ms - e.ts_ms)
}

/// Name and size in bytes of every copy, newest first.
pub fn list(home: &Path) -> Result<Vec<(String, u64)>> {
    Ok(copies(home)?.into_iter().map(|c| (c.name, c.size)).collect())
}

/// One database copy, as `backups.list` shows it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupFile {
    pub name: String,
    pub size: u64,
    /// The time of the copy, from its name (UTC, Unix milliseconds).
    pub created_at_ms: i64,
    /// `start`, `upgrade`, `daily`, `manual` or `before-restore`; `replaced` or `broken` for a database that a
    /// restore set aside.
    pub reason: String,
}

/// Our copies and the databases a restore set aside, newest first, with their reasons. The set-aside ones have the
/// reason `replaced` (the live database before a restore) or `broken` (a live database that failed its check).
pub fn copies(home: &Path) -> Result<Vec<BackupFile>> {
    let mut out: Vec<BackupFile> = entries(home)?
        .into_iter()
        .map(|e| BackupFile {
            name: e.name,
            size: e.size,
            created_at_ms: e.ts_ms,
            reason: e.reason,
        })
        .collect();
    out.extend(saved_databases(home)?);
    out.sort_by(|a, b| (b.created_at_ms, &b.name).cmp(&(a.created_at_ms, &a.name)));
    Ok(out)
}

/// A copy name from `bandito backup list`: no folder parts, and it parses as one of our copies or as a database a
/// restore set aside.
pub fn validate_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.contains('/')
        || name.contains('\\')
        || name.contains("..")
        || (parse_name(name).is_none() && parse_saved(name).is_none())
    {
        bail!("invalid backup name {name:?}: give a file name from `bandito backup list`");
    }
    Ok(())
}

/// Checks that `name` is a regular copy in `<home>/backups` that passes `quick_check`. Changes nothing.
pub fn check_copy(home: &Path, name: &str) -> Result<()> {
    validate_name(name)?;
    check_regular_copy(&backups_dir(home).join(name), name)
}

fn check_regular_copy(src: &Path, name: &str) -> Result<()> {
    let meta = fs::symlink_metadata(src).map_err(|_| anyhow::anyhow!("no backup named {name}"))?;
    if !meta.file_type().is_file() {
        bail!("{name} is not a regular file: refusing to restore from it");
    }
    quick_check(src).with_context(|| format!("{name} failed the integrity check; the database was not changed"))
}

/// What a finished restore left behind.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreDone {
    /// The copy made of the live database just before the swap, if one was made.
    pub before: Option<String>,
    /// The name (`replaced-<time>.db` or `broken-<time>.db`) under which the old database files were set aside in
    /// `backups/`, if there were any. The restored file is in place only after they were moved there.
    pub saved: Option<String>,
}

/// Replaces `<home>/bandito.db` with the copy `name` from `<home>/backups`. The copy must pass `quick_check`.
/// The current database is copied first, with reason `before-restore`. Refused while the daemon holds its lock.
/// The guarantees are in `restore_locked`.
pub fn restore(home: &Path, name: &str, now_ms: i64) -> Result<RestoreDone> {
    validate_name(name)?;
    let Some(_lock) = try_daemon_lock(home)? else {
        bail!(BUSY_MSG);
    };
    restore_locked(home, name, now_ms)
}

/// The restore itself, for a caller that holds the daemon lock already. The rule: the restore never makes the data
/// unreachable without a trace and a way back. In this order:
/// 1. `name` is checked (regular file, `quick_check`).
/// 2. The live database is copied (`before-restore`). When that fails, the live database is set aside only if its
///    own `quick_check` says it is damaged; for any other failure (disk full, too many files, busy) the restore
///    stops and nothing is touched.
/// 3. The restored file is written next to the database (`bandito.db.restore-tmp`) and synced. The live files are
///    still where they were.
/// 4. The live `-wal`, `-shm` and `bandito.db` are renamed, in that order, to `backups/replaced-<time>.db*` (or
///    `broken-<time>.db*` for a damaged one). When a step fails, the steps already done are undone.
/// 5. The restored file is renamed to `bandito.db`. When that fails, the old files are put back.
/// 6. The folders are synced and old copies pruned, keeping the ones this restore names.
fn restore_locked(home: &Path, name: &str, now_ms: i64) -> Result<RestoreDone> {
    validate_name(name)?;
    let src = backups_dir(home).join(name);
    check_regular_copy(&src, name)?;

    let db = home.join(DB_FILE);
    let live_files = SIDECARS
        .iter()
        .any(|s| fs::symlink_metadata(live_path(home, s)).is_ok());
    let mut before = None;
    let mut prefix = "replaced";
    if live_files {
        if db.exists() {
            match snapshot_file(&db, home, "before-restore", now_ms) {
                Ok(path) => {
                    before = path.file_name().and_then(|n| n.to_str()).map(str::to_string);
                }
                Err(e) => match health(&db) {
                    Ok(Health::Damaged(why)) => {
                        tracing::warn!("the current database is damaged ({why}), it is set aside, not copied: {e:#}");
                        prefix = "broken";
                    }
                    Ok(Health::Ok) | Err(_) => {
                        bail!(
                            "could not copy the current database before the restore ({e:#}); the database was not changed"
                        );
                    }
                },
            }
        } else {
            // Only a -wal or -shm without a database: nothing to copy; they are set aside below.
            prefix = "broken";
        }
    }

    let tmp = home.join(RESTORE_TMP);
    let _ = fs::remove_file(&tmp);
    if let Err(e) = write_restore_tmp(&src, name, &tmp) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }

    let mut saved = None;
    let mut moved = Vec::new();
    if live_files {
        let dir = backups_dir(home);
        create_private_dir(&dir)?;
        let target = free_saved_name(&dir, prefix, now_ms)?;
        match move_group(&db, &target, "aside") {
            Ok(done) => {
                moved = done;
                saved = target.file_name().and_then(|n| n.to_str()).map(str::to_string);
            }
            Err(e) => {
                let _ = fs::remove_file(&tmp);
                return Err(e);
            }
        }
    }
    let installed = check_fault("install")
        .and_then(|()| fs::rename(&tmp, &db))
        .with_context(|| format!("replace {}", db.display()));
    if let Err(e) = installed {
        let _ = fs::remove_file(&tmp);
        return Err(match undo_moves(&moved) {
            Ok(()) => e.context("the old database was put back"),
            Err(undo) => e.context(format!("and putting the old database back failed: {undo:#}")),
        });
    }
    for dir in [home, backups_dir(home).as_path()] {
        if let Err(e) = sync_dir(dir) {
            tracing::warn!("sync {}: {e:#}", dir.display());
        }
    }
    let mut protected = vec![name];
    protected.extend(before.as_deref());
    prune_except(home, KEEP, &protected);
    Ok(RestoreDone { before, saved })
}

/// The file names that go with `bandito.db`, in the order they are moved: the WAL and the shared-memory file
/// first, the database last. A database left without its WAL is never put in place of one with it.
const SIDECARS: [&str; 3] = ["-wal", "-shm", ""];
const RESTORE_TMP: &str = "bandito.db.restore-tmp";

fn live_path(home: &Path, suffix: &str) -> PathBuf {
    home.join(format!("{DB_FILE}{suffix}"))
}

fn with_suffix(path: &Path, suffix: &str) -> PathBuf {
    PathBuf::from(format!("{}{suffix}", path.display()))
}

/// Writes the file that will become `bandito.db`: a plain copy of a regular copy, a `VACUUM INTO` of a set-aside
/// database (so its WAL is applied). Mode 0600, synced, and it passes `quick_check`.
fn write_restore_tmp(src: &Path, name: &str, tmp: &Path) -> Result<()> {
    check_fault("tmp-write").with_context(|| format!("write {}", tmp.display()))?;
    if name.starts_with("bandito-") {
        copy_private(src, tmp)?;
    } else {
        write_copy(src, tmp)?;
        fs::set_permissions(tmp, fs::Permissions::from_mode(0o600))?;
    }
    fs::File::open(tmp)
        .and_then(|f| f.sync_all())
        .with_context(|| format!("sync {}", tmp.display()))?;
    quick_check(tmp).with_context(|| format!("the copy of {name} made for the restore failed the integrity check"))
}

/// The first free name `<prefix>-<UTC time>[-n].db`, free for the database and for its `-wal` and `-shm`.
fn free_saved_name(dir: &Path, prefix: &str, now_ms: i64) -> Result<PathBuf> {
    let ts = timestamp(now_ms)?;
    (1..=1000u32)
        .map(|n| {
            if n == 1 {
                dir.join(format!("{prefix}-{ts}.db"))
            } else {
                dir.join(format!("{prefix}-{ts}-{n}.db"))
            }
        })
        .find(|p| {
            SIDECARS
                .iter()
                .all(|s| fs::symlink_metadata(with_suffix(p, s)).is_err())
        })
        .with_context(|| format!("no free name for the set-aside database ({prefix}-{ts})"))
}

/// Renames `<from>{-wal,-shm,}` to `<to>{-wal,-shm,}` in that order, skipping files that do not exist. When a step
/// fails, the renames already done are undone, and the error says so. Returns the renames done.
/// `tag` names the fault points of the tests (`<tag>-wal`, `<tag>-shm`, `<tag>-db`).
fn move_group(from: &Path, to: &Path, tag: &str) -> Result<Vec<(PathBuf, PathBuf)>> {
    let mut done: Vec<(PathBuf, PathBuf)> = Vec::new();
    for suffix in SIDECARS {
        let (a, b) = (with_suffix(from, suffix), with_suffix(to, suffix));
        match fs::symlink_metadata(&a) {
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => {
                return Err(undo_with(
                    &done,
                    anyhow::Error::new(e).context(format!("stat {}", a.display())),
                ));
            }
        }
        let point = format!("{tag}-{}", if suffix.is_empty() { "db" } else { &suffix[1..] });
        match check_fault(&point).and_then(|()| fs::rename(&a, &b)) {
            Ok(()) => done.push((a, b)),
            Err(e) => {
                let err = anyhow::Error::new(e).context(format!("move {} to {}", a.display(), b.display()));
                return Err(undo_with(&done, err));
            }
        }
    }
    Ok(done)
}

/// Undoes `done` after `err`, and returns `err` with the outcome of the undo added.
fn undo_with(done: &[(PathBuf, PathBuf)], err: anyhow::Error) -> anyhow::Error {
    match undo_moves(done) {
        Ok(()) => err.context("the steps already made were undone"),
        Err(undo) => err.context(format!("and undoing the steps already made failed: {undo:#}")),
    }
}

/// Renames each `(from, to)` back, last first. Goes on after a failure, so as much as possible is put back.
fn undo_moves(done: &[(PathBuf, PathBuf)]) -> Result<()> {
    let mut failed = Vec::new();
    for (a, b) in done.iter().rev() {
        let point = format!("undo-{}", b.file_name().and_then(|n| n.to_str()).unwrap_or(""));
        if let Err(e) = check_fault(&point).and_then(|()| fs::rename(b, a)) {
            failed.push(format!("{} (kept as {}): {e}", a.display(), b.display()));
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        bail!("{}", failed.join("; "))
    }
}

fn sync_dir(dir: &Path) -> Result<()> {
    check_fault("sync-dir")?;
    fs::File::open(dir)
        .and_then(|d| d.sync_all())
        .with_context(|| format!("sync {}", dir.display()))
}

/// Test hook: an error at a named step. Compiled out of the daemon.
#[cfg(not(test))]
#[inline(always)]
fn check_fault(_point: &str) -> std::io::Result<()> {
    Ok(())
}

#[cfg(test)]
fn check_fault(point: &str) -> std::io::Result<()> {
    if let Some(code) = fault::hit(point) {
        return Err(std::io::Error::from_raw_os_error(code));
    }
    Ok(())
}

/// Fault points for the tests: a thread-local list, so tests running side by side do not see each other's.
#[cfg(test)]
mod fault {
    use std::cell::RefCell;
    thread_local! {
        static POINTS: RefCell<Vec<(String, i32)>> = const { RefCell::new(Vec::new()) };
    }
    /// Fails `point` with the OS error `code`. A name ending in `*` matches every point that starts with the rest.
    pub fn fail(point: &str, code: i32) {
        POINTS.with(|p| p.borrow_mut().push((point.to_string(), code)));
    }
    pub fn clear() {
        POINTS.with(|p| p.borrow_mut().clear());
    }
    pub fn hit(point: &str) -> Option<i32> {
        POINTS.with(|p| {
            p.borrow()
                .iter()
                .find(|(name, _)| match name.strip_suffix('*') {
                    Some(prefix) => point.starts_with(prefix),
                    None => name == point,
                })
                .map(|(_, code)| *code)
        })
    }
}

/// What a `quick_check` of a database said.
enum Health {
    Ok,
    /// The check ran and the database failed it (or is not a database). The text says how.
    Damaged(String),
}

/// Checks `path` with `quick_check`. `Err` means the check could not run (busy, too many open files, ...): that says
/// nothing about the database. `Ok(Damaged)` means it ran and the database is bad.
fn health(path: &Path) -> Result<Health> {
    use rusqlite::ErrorCode;
    let damaged = |e: &rusqlite::Error| {
        matches!(
            e,
            rusqlite::Error::SqliteFailure(f, _) if matches!(f.code, ErrorCode::NotADatabase | ErrorCode::DatabaseCorrupt)
        )
    };
    check_fault("health").with_context(|| format!("open {}", path.display()))?;
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("open {}", path.display()))?;
    conn.busy_timeout(BUSY_TIMEOUT)?;
    let rows = (|| -> rusqlite::Result<Vec<String>> {
        let mut stmt = conn.prepare("PRAGMA quick_check")?;
        stmt.query_map([], |r| r.get::<_, String>(0))?.collect()
    })();
    match rows {
        Ok(rows) if rows.len() == 1 && rows[0] == "ok" => Ok(Health::Ok),
        Ok(rows) => Ok(Health::Damaged(rows.join("; "))),
        Err(e) if damaged(&e) => Ok(Health::Damaged(e.to_string())),
        Err(e) => Err(e).with_context(|| format!("check {}", path.display())),
    }
}

/// Makes a copy now with `reason`, keeps the newest `KEEP`, and returns the new copy (`backups.create`).
pub fn make_copy(home: &Path, reason: &str, now_ms: i64) -> Result<BackupFile> {
    let db = home.join(DB_FILE);
    if !db.is_file() {
        bail!("there is no database to copy yet");
    }
    let path = snapshot_file(&db, home, reason, now_ms)?;
    prune(home, KEEP);
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .context("the backup name is not valid UTF-8")?
        .to_string();
    let (created_at_ms, reason, _) = parse_full(&name).context("the new copy has no backup name")?;
    let size = fs::metadata(&path)
        .with_context(|| format!("stat {}", path.display()))?
        .len();
    Ok(BackupFile {
        name,
        size,
        created_at_ms,
        reason,
    })
}

/// The marker that asks the daemon to restore a copy at its next start: `<home>/run/restore-pending`.
pub fn restore_marker(home: &Path) -> PathBuf {
    home.join("run").join(RESTORE_MARKER)
}

/// Checks `name` with `check_copy` and writes the restore marker, a small JSON file with the name and a new id for
/// this operation. Returns the id; `daemon.info.last_restore.id` carries it back, so the app can tell this restore's
/// result from an older one. The daemon applies the marker at its next start (`apply_pending_restore`). Nothing is
/// replaced here: the daemon is still running. A marker that is already there is removed first, and the new one is
/// created exclusively and without following a link, so nobody else's file or link is written through.
pub fn request_restore(home: &Path, name: &str) -> Result<String> {
    check_copy(home, name)?;
    let path = restore_marker(home);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    }
    remove_marker(&path)?;
    let id = crate::store::new_id();
    let body = serde_json::to_vec(&Marker {
        id: id.clone(),
        name: name.to_string(),
    })
    .context("encode the restore request")?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .custom_flags(libc::O_NOFOLLOW)
        .mode(0o600)
        .open(&path)
        .with_context(|| format!("open {}", path.display()))?;
    file.write_all(&body)
        .and_then(|()| file.sync_all())
        .with_context(|| format!("write {}", path.display()))?;
    Ok(id)
}

/// The content of the restore marker.
#[derive(Debug, Serialize, Deserialize)]
struct Marker {
    id: String,
    name: String,
}

/// Removes the restore marker, whatever is there (a file, a folder, a link), when there is one.
pub fn clear_restore_request(home: &Path) -> Result<()> {
    remove_marker(&restore_marker(home))
}

/// A restore the daemon applied at its start. `before` names the copy of the database from before it, if one was made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppliedRestore {
    /// The id of the operation (from the marker).
    pub id: String,
    pub name: String,
    pub before: Option<String>,
    /// The name under which the old database files were set aside in `backups/` (`replaced-*` or `broken-*`).
    pub saved: Option<String>,
}

/// What the last restore did, as `daemon.info` reports it. Kept in `<home>/run/last-restore.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LastRestore {
    /// The id of the operation: the one `backups.restore` returned. Empty in a record written by an older daemon.
    #[serde(default)]
    pub id: String,
    /// The copy the request named (empty when the request could not be read).
    pub name: String,
    pub ok: bool,
    /// Why it failed, in one short sentence. None on success.
    pub error: Option<String>,
    /// When the daemon applied it (Unix milliseconds).
    pub at_ms: i64,
}

fn last_restore_path(home: &Path) -> PathBuf {
    home.join("run").join(LAST_RESTORE_FILE)
}

/// Writes the result of a restore (atomically: a temporary file, then a rename).
pub fn write_last_restore(home: &Path, record: &LastRestore) -> Result<()> {
    let path = last_restore_path(home);
    let dir = path.parent().context("the run folder has no parent")?;
    fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    let tmp = dir.join(format!("{LAST_RESTORE_FILE}.tmp"));
    let json = serde_json::to_vec(record).context("encode the restore result")?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .with_context(|| format!("open {}", tmp.display()))?;
    file.write_all(&json)
        .with_context(|| format!("write {}", tmp.display()))?;
    drop(file);
    fs::rename(&tmp, &path).with_context(|| format!("replace {}", path.display()))?;
    Ok(())
}

/// The result of the last restore, or None when there is none or the file cannot be read.
pub fn read_last_restore(home: &Path) -> Option<LastRestore> {
    let raw = fs::read(last_restore_path(home)).ok()?;
    serde_json::from_slice(&raw).ok()
}

/// Records a restore result. A failure to write it is logged: the restore itself has already happened or not.
fn record_restore(home: &Path, record: LastRestore) {
    if let Err(e) = write_last_restore(home, &record) {
        tracing::warn!("record the restore result: {e:#}");
    }
}

/// The id and the name in the marker. A marker of an older daemon holds the bare name: it gets a new id.
/// Anything that is not text is an error (the caller removes the marker anyway).
fn read_marker(marker: &Path) -> Result<(String, String)> {
    let bytes = fs::read(marker).with_context(|| format!("read {}", marker.display()))?;
    let text = String::from_utf8(bytes).context("the restore request is not text")?;
    let text = text.trim();
    if text.starts_with('{') {
        let m: Marker = serde_json::from_str(text).context("the restore request is not valid")?;
        return Ok((m.id, m.name.trim().to_string()));
    }
    Ok((crate::store::new_id(), text.to_string()))
}

/// Removes the marker whatever it is: a file, a folder someone put there, or a link.
fn remove_marker(marker: &Path) -> Result<()> {
    match fs::symlink_metadata(marker) {
        Ok(meta) if meta.is_dir() => fs::remove_dir_all(marker).with_context(|| format!("remove {}", marker.display())),
        Ok(_) => remove_if_exists(marker),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("stat {}", marker.display())),
    }
}

/// Applies the restore marker, if there is one. Called by the daemon with its lock held, before the store opens.
/// The marker is removed in every case, whatever it holds, so a bad one is not retried on each start. The result is
/// recorded in `run/last-restore.json`. Returns None when there was no marker.
pub fn apply_pending_restore(home: &Path, now_ms: i64) -> Result<Option<AppliedRestore>> {
    let marker = restore_marker(home);
    if fs::symlink_metadata(&marker).is_err() {
        return Ok(None);
    }
    let (id, name, outcome) = match read_marker(&marker) {
        Ok((id, name)) => {
            let outcome = restore_locked(home, &name, now_ms);
            (id, name, outcome)
        }
        Err(e) => (crate::store::new_id(), String::new(), Err(e)),
    };
    // The marker goes only after the swap is over: a crash in the middle leaves it, and the next start tries again.
    if let Err(e) = remove_marker(&marker) {
        tracing::warn!("remove the restore request: {e:#}");
    }
    match outcome {
        Ok(done) => {
            record_restore(
                home,
                LastRestore {
                    id: id.clone(),
                    name: name.clone(),
                    ok: true,
                    error: None,
                    at_ms: now_ms,
                },
            );
            Ok(Some(AppliedRestore {
                id,
                name,
                before: done.before,
                saved: done.saved,
            }))
        }
        Err(e) => {
            record_restore(
                home,
                LastRestore {
                    id,
                    name,
                    ok: false,
                    error: Some(format!("{e:#}")),
                    at_ms: now_ms,
                },
            );
            Err(e)
        }
    }
}

/// The restored database does not open: puts the old one back and records the failure. Called by the daemon with
/// its lock held. The way back, in order: the old database files the restore set aside (`saved`, the exact files,
/// WAL included), then the copy made before the restore. The restored files that did not open are kept as
/// `broken-*`. Fails when there is no way back or it failed; the daemon then runs in safe mode (see main).
pub fn roll_back_restore(home: &Path, applied: &AppliedRestore, reason: &str, now_ms: i64) -> Result<()> {
    let record = |error: String| {
        record_restore(
            home,
            LastRestore {
                id: applied.id.clone(),
                name: applied.name.clone(),
                ok: false,
                error: Some(error),
                at_ms: now_ms,
            },
        );
    };
    let back = if let Some(saved) = applied.saved.as_deref() {
        put_back_saved(home, saved, now_ms)
    } else if let Some(before) = applied.before.as_deref() {
        restore_locked(home, before, now_ms).map(|_| ())
    } else {
        let error =
            format!("the restored database does not open ({reason}), and there is no copy from before the restore");
        record(error.clone());
        bail!(error);
    };
    match back {
        Ok(()) => {
            record(format!(
                "the restored database does not open ({reason}); the database from before the restore is back"
            ));
            Ok(())
        }
        Err(e) => {
            let error = format!(
                "the restored database does not open ({reason}), and putting back the old database failed: {e:#}"
            );
            record(error.clone());
            Err(anyhow::anyhow!(error))
        }
    }
}

/// Puts the database files set aside as `saved` back in place. The files now in place (the restored database that
/// does not open) are set aside as `broken-*` first; when putting the old ones back fails, those are put back too.
fn put_back_saved(home: &Path, saved: &str, now_ms: i64) -> Result<()> {
    let dir = backups_dir(home);
    let db = home.join(DB_FILE);
    let saved_db = dir.join(saved);
    let target = free_saved_name(&dir, "broken", now_ms)?;
    let aside = move_group(&db, &target, "unrestore-aside")?;
    match move_group(&saved_db, &db, "unrestore-back") {
        Ok(_) => Ok(()),
        Err(e) => Err(match undo_moves(&aside) {
            Ok(()) => e.context("the restored database was put back in place"),
            Err(undo) => e.context(format!("and putting the restored database back failed: {undo:#}")),
        }),
    }
}

/// Start of the daemon, called with the daemon lock held: copies the database when there is no copy, the newest
/// is older than 20 h, or the version recorded in `last-version` differs from `version`. Returns the new copy.
/// Does nothing when the database does not exist yet. Leftover `.partial` files from a crash are removed first.
pub fn on_start(home: &Path, version: &str, now_ms: i64) -> Result<Option<PathBuf>> {
    remove_stale_partials(home)?;
    let db = home.join(DB_FILE);
    if !db.is_file() {
        return Ok(None);
    }
    let dir = backups_dir(home);
    let recorded = fs::read_to_string(dir.join(LAST_VERSION))
        .ok()
        .map(|s| s.trim().to_string());
    let due =
        newest_age_ms(home, now_ms).is_none_or(|age| age > START_MAX_AGE_MS) || recorded.as_deref() != Some(version);
    if !due {
        return Ok(None);
    }
    let reason = match recorded.as_deref() {
        Some(old) if old != version => "upgrade",
        _ => "start",
    };
    let path = snapshot_file(&db, home, reason, now_ms)?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(dir.join(LAST_VERSION))
        .context("open the last-version file")?;
    file.write_all(version.as_bytes())
        .context("record the version of the last start")?;
    prune(home, KEEP);
    Ok(Some(path))
}

/// The periodic check: copies the database (reason `daily`) when the newest copy is older than 24 h
/// or there is none, then prunes. Returns the new copy, if any.
pub fn snapshot_if_due(home: &Path, now_ms: i64) -> Result<Option<PathBuf>> {
    let db = home.join(DB_FILE);
    if !db.is_file() {
        return Ok(None);
    }
    if newest_age_ms(home, now_ms).is_some_and(|age| age <= DAILY_MAX_AGE_MS) {
        return Ok(None);
    }
    let path = snapshot_file(&db, home, "daily", now_ms)?;
    prune(home, KEEP);
    Ok(Some(path))
}

struct Entry {
    name: String,
    ts_ms: i64,
    reason: String,
    /// The `-n` suffix of a name taken in the same second (1 when there is none).
    n: u32,
    size: u64,
}

/// Our copies in `<home>/backups`, newest first. Files that do not have our name, `.partial` files,
/// symlinks and files that vanish during the scan are left out.
fn entries(home: &Path) -> Result<Vec<Entry>> {
    let dir = backups_dir(home);
    let read = match fs::read_dir(&dir) {
        Ok(read) => read,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("read {}", dir.display())),
    };
    let mut out = Vec::new();
    for item in read {
        let item = item?;
        let name = item.file_name().to_string_lossy().into_owned();
        let Some((ts_ms, reason, n)) = parse_full(&name) else {
            continue;
        };
        // `DirEntry::metadata` does not follow symlinks; a file removed since readdir is skipped.
        let meta = match item.metadata() {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e).with_context(|| format!("stat {name}")),
        };
        if !meta.file_type().is_file() {
            continue;
        }
        out.push(Entry {
            name,
            ts_ms,
            reason,
            n,
            size: meta.len(),
        });
    }
    out.sort_by(|a, b| (b.ts_ms, b.n, &b.name).cmp(&(a.ts_ms, a.n, &a.name)));
    Ok(out)
}

/// `(time in ms, suffix)` of a copy name `bandito-<YYYYMMDD-HHMMSS>-<reason>[-<n>].db`; `None` for other files.
fn parse_name(name: &str) -> Option<(i64, u32)> {
    parse_full(name).map(|(ts_ms, _, n)| (ts_ms, n))
}

/// `(time in ms, reason, suffix)` of a copy name; `None` for other files.
fn parse_full(name: &str) -> Option<(i64, String, u32)> {
    let stem = name.strip_prefix("bandito-")?.strip_suffix(".db")?;
    let ts = stem.get(..15)?;
    let rest = stem.get(15..)?.strip_prefix('-')?;
    let ts_ms = NaiveDateTime::parse_from_str(ts, TS_FORMAT)
        .ok()?
        .and_utc()
        .timestamp_millis();
    let (reason, n) = match rest.rsplit_once('-') {
        Some((reason, digits)) if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) => {
            (reason, digits.parse::<u32>().ok()?)
        }
        _ => (rest, 1),
    };
    valid_reason(reason).then(|| (ts_ms, reason.to_string(), n))
}

/// `(time in ms, kind, suffix)` of the name of a database a restore set aside: `replaced-<YYYYMMDD-HHMMSS>[-n].db`
/// or `broken-<...>[-n].db`. `kind` is `replaced` or `broken`. `None` for other files (and for `-wal`/`-shm`).
fn parse_saved_full(name: &str) -> Option<(i64, &'static str, u32)> {
    let (kind, rest) = if let Some(rest) = name.strip_prefix("replaced-") {
        ("replaced", rest)
    } else {
        ("broken", name.strip_prefix("broken-")?)
    };
    let stem = rest.strip_suffix(".db")?;
    let ts = stem.get(..15)?;
    let ts_ms = NaiveDateTime::parse_from_str(ts, TS_FORMAT)
        .ok()?
        .and_utc()
        .timestamp_millis();
    let n = match stem.get(15..)? {
        "" => 1,
        tail => {
            let digits = tail.strip_prefix('-')?;
            if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            digits.parse::<u32>().ok()?
        }
    };
    Some((ts_ms, kind, n))
}

fn parse_saved(name: &str) -> Option<(i64, u32)> {
    parse_saved_full(name).map(|(ts_ms, _, n)| (ts_ms, n))
}

/// The databases a restore set aside, as list rows. The size counts the `-wal` next to the file too.
fn saved_databases(home: &Path) -> Result<Vec<BackupFile>> {
    let dir = backups_dir(home);
    let read = match fs::read_dir(&dir) {
        Ok(read) => read,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("read {}", dir.display())),
    };
    let mut out = Vec::new();
    for item in read {
        let item = item?;
        let name = item.file_name().to_string_lossy().into_owned();
        let Some((ts_ms, kind, _)) = parse_saved_full(&name) else {
            continue;
        };
        let meta = match item.metadata() {
            Ok(meta) => meta,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e).with_context(|| format!("stat {name}")),
        };
        if !meta.file_type().is_file() {
            continue;
        }
        let wal = fs::metadata(with_suffix(&item.path(), "-wal"))
            .map(|m| m.len())
            .unwrap_or(0);
        out.push(BackupFile {
            name,
            size: meta.len() + wal,
            created_at_ms: ts_ms,
            reason: kind.to_string(),
        });
    }
    Ok(out)
}

/// Whether `backups/` holds a database that a restore set aside. When it cannot be read, says yes: the caller
/// uses this to avoid starting on an empty database.
pub fn has_set_aside(home: &Path) -> bool {
    saved_databases(home).map(|v| !v.is_empty()).unwrap_or(true)
}

fn valid_reason(reason: &str) -> bool {
    !reason.is_empty() && reason.bytes().all(|b| b.is_ascii_lowercase() || b == b'-')
}

fn timestamp(now_ms: i64) -> Result<String> {
    let at = chrono::DateTime::from_timestamp_millis(now_ms).context("timestamp out of range")?;
    Ok(at.format(TS_FORMAT).to_string())
}

/// Takes the first free name for this second and reason: returns the final path and an empty `.partial`
/// file next to it (created 0600, so the name is ours). The final name must not exist yet.
fn reserve(dir: &Path, ts: &str, reason: &str) -> Result<(PathBuf, PathBuf)> {
    for n in 1..=1000u32 {
        let name = if n == 1 {
            format!("bandito-{ts}-{reason}.db")
        } else {
            format!("bandito-{ts}-{reason}-{n}.db")
        };
        let target = dir.join(&name);
        if fs::symlink_metadata(&target).is_ok() {
            continue;
        }
        let partial = dir.join(format!("{name}{PARTIAL_SUFFIX}"));
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&partial)
        {
            Ok(_) => return Ok((target, partial)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e).with_context(|| format!("create {}", partial.display())),
        }
    }
    bail!("no free backup name for {ts}-{reason}")
}

/// Writes a `VACUUM INTO` snapshot of `db` to `out`, which must be new or empty.
fn write_copy(db: &Path, out: &Path) -> Result<()> {
    // Read-only: the live daemon keeps its own writer connection; this one only reads.
    let src = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("open {} for backup", db.display()))?;
    src.busy_timeout(BUSY_TIMEOUT)?;
    let out = out.to_str().context("backup path is not valid UTF-8")?;
    src.execute("VACUUM INTO ?1", [out]).context("VACUUM INTO")?;
    Ok(())
}

/// `PRAGMA quick_check` must answer exactly `ok`.
fn quick_check(path: &Path) -> Result<()> {
    let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("open {}", path.display()))?;
    conn.busy_timeout(BUSY_TIMEOUT)?;
    let mut stmt = conn.prepare("PRAGMA quick_check")?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))?
        .collect::<rusqlite::Result<Vec<String>>>()?;
    if rows.len() == 1 && rows[0] == "ok" {
        return Ok(());
    }
    bail!("integrity check of {} failed: {}", path.display(), rows.join("; "))
}

/// Removes `.partial` files of our names. Called under the daemon lock, so none of them is being written.
fn remove_stale_partials(home: &Path) -> Result<()> {
    let read = match fs::read_dir(backups_dir(home)) {
        Ok(read) => read,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e).context("read the backups folder"),
    };
    for item in read.flatten() {
        let name = item.file_name().to_string_lossy().into_owned();
        let ours = name
            .strip_suffix(PARTIAL_SUFFIX)
            .is_some_and(|stem| parse_name(stem).is_some());
        if ours {
            let _ = fs::remove_file(item.path());
        }
    }
    Ok(())
}

fn create_private_dir(dir: &Path) -> Result<()> {
    fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

fn copy_private(src: &Path, dst: &Path) -> Result<()> {
    fs::copy(src, dst).with_context(|| format!("copy {} to {}", src.display(), dst.display()))?;
    fs::set_permissions(dst, fs::Permissions::from_mode(0o600))?;
    Ok(())
}

fn remove_if_exists(path: &Path) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e).with_context(|| format!("remove {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 2027-01-15 08:00:00 UTC, in ms.
    const BASE_MS: i64 = 1_800_000_000_000;
    const VERSION: &str = "0.1.5";

    /// A temp home; the real `~/.bandito` is never touched.
    fn temp_home() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    /// A database with one row per `value`, in WAL mode as the daemon uses it.
    fn make_db(path: &Path, values: &[&str]) {
        let conn = Connection::open(path).unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS t(v TEXT);")
            .unwrap();
        for v in values {
            conn.execute("INSERT INTO t(v) VALUES (?1)", [v]).unwrap();
        }
    }

    fn rows(path: &Path) -> Vec<String> {
        let conn = Connection::open(path).unwrap();
        let mut stmt = conn.prepare("SELECT v FROM t ORDER BY rowid").unwrap();
        stmt.query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .map(|r| r.unwrap())
            .collect()
    }

    fn names(home: &Path) -> Vec<String> {
        list(home).unwrap().into_iter().map(|(n, _)| n).collect()
    }

    #[test]
    fn backups_dir_is_a_subfolder_of_home() {
        assert_eq!(backups_dir(Path::new("/h")), PathBuf::from("/h/backups"));
    }

    #[test]
    fn name_round_trips_through_parse() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        let path = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let name = path.file_name().unwrap().to_str().unwrap().to_string();
        assert_eq!(name, "bandito-20270115-080000-start.db");
        assert_eq!(parse_name(&name), Some((BASE_MS, 1)));
        assert_eq!(parse_name("bandito-20270115-080000-start-2.db"), Some((BASE_MS, 2)));
        assert_eq!(parse_name("bandito-20270115-080000-start.db.partial"), None);
        assert_eq!(parse_name("notes.txt"), None);
        assert_eq!(parse_name("bandito-notes.db"), None);
    }

    #[test]
    fn missing_database_makes_no_copy_and_no_error() {
        let home = temp_home();
        assert!(on_start(home.path(), VERSION, BASE_MS).unwrap().is_none());
        assert!(snapshot_if_due(home.path(), BASE_MS).unwrap().is_none());
        assert!(list(home.path()).unwrap().is_empty());
        assert!(!backups_dir(home.path()).exists());
    }

    #[test]
    fn two_copies_in_the_same_second_get_different_names() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        let first = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let second = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let third = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        assert_ne!(first, second);
        assert_eq!(second.file_name().unwrap(), "bandito-20270115-080000-start-2.db");
        assert_eq!(third.file_name().unwrap(), "bandito-20270115-080000-start-3.db");
        assert_eq!(list(home.path()).unwrap().len(), 3);
    }

    #[test]
    fn copy_goes_through_partial_and_leaves_no_partial_behind() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let dir_names: Vec<String> = fs::read_dir(backups_dir(home.path()))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(dir_names, ["bandito-20270115-080000-start.db"]);
    }

    #[test]
    fn failed_copy_leaves_no_file_under_the_final_name() {
        let home = temp_home();
        // Not a database: VACUUM INTO fails, and nothing may stay in the folder.
        let bogus = home.path().join(DB_FILE);
        fs::write(&bogus, "this is not sqlite").unwrap();
        assert!(snapshot_file(&bogus, home.path(), "start", BASE_MS).is_err());
        let left: Vec<String> = fs::read_dir(backups_dir(home.path()))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert!(left.is_empty(), "{left:?}");
    }

    #[test]
    fn partial_files_are_not_copies() {
        let home = temp_home();
        let dir = backups_dir(home.path());
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("bandito-20270115-080000-start.db.partial"), "cut off").unwrap();
        assert_eq!(newest_age_ms(home.path(), BASE_MS), None);
        assert!(list(home.path()).unwrap().is_empty());
        prune(home.path(), 0);
        assert!(dir.join("bandito-20270115-080000-start.db.partial").exists());
    }

    #[test]
    fn start_removes_stale_partials_from_a_crash() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        let dir = backups_dir(home.path());
        fs::create_dir_all(&dir).unwrap();
        let stale = dir.join("bandito-20270114-080000-daily.db.partial");
        fs::write(&stale, "cut off").unwrap();
        on_start(home.path(), VERSION, BASE_MS).unwrap();
        assert!(!stale.exists());
        assert_eq!(names(home.path()).len(), 1);
    }

    #[test]
    fn invalid_reason_is_refused() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        for bad in ["", "Start", "a/b", "x.db", "start 2", "../x"] {
            assert!(snapshot_file(&db, home.path(), bad, BASE_MS).is_err(), "reason {bad:?}");
        }
        assert!(list(home.path()).unwrap().is_empty());
    }

    #[test]
    fn copies_and_folder_get_private_modes() {
        use std::os::unix::fs::PermissionsExt;
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        let path = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let dir_mode = fs::metadata(backups_dir(home.path())).unwrap().permissions().mode() & 0o777;
        let file_mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(dir_mode, 0o700);
        assert_eq!(file_mode, 0o600);
    }

    #[test]
    fn last_version_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        on_start(home.path(), VERSION, BASE_MS).unwrap();
        let mode = fs::metadata(backups_dir(home.path()).join(LAST_VERSION))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn prune_keeps_exactly_keep_newest_and_leaves_other_files() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        let mut made = Vec::new();
        for i in 0..(KEEP as i64 + 2) {
            made.push(snapshot_file(&db, home.path(), "daily", BASE_MS + i * HOUR_MS).unwrap());
        }
        let dir = backups_dir(home.path());
        fs::write(dir.join("notes.txt"), "mine").unwrap();
        prune(home.path(), KEEP);

        let kept = list(home.path()).unwrap();
        assert_eq!(kept.len(), KEEP);
        // The two oldest went; the newest is still there.
        assert!(!made[0].exists() && !made[1].exists());
        assert!(made.last().unwrap().exists());
        assert!(dir.join("notes.txt").exists(), "a foreign file must not be pruned");
    }

    #[test]
    fn newest_age_and_list_follow_the_names() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        assert_eq!(newest_age_ms(home.path(), BASE_MS), None);
        snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        snapshot_file(&db, home.path(), "daily", BASE_MS + 5 * HOUR_MS).unwrap();
        assert_eq!(newest_age_ms(home.path(), BASE_MS + 6 * HOUR_MS), Some(HOUR_MS));
        assert_eq!(
            names(home.path()),
            ["bandito-20270115-130000-daily.db", "bandito-20270115-080000-start.db"]
        );
        assert!(list(home.path()).unwrap().iter().all(|(_, size)| *size > 0));
    }

    #[test]
    fn snapshot_contains_rows_still_in_the_wal() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        // The writer stays open, so the row is only in the -wal file.
        let writer = Connection::open(&db).unwrap();
        writer
            .execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE t(v TEXT);")
            .unwrap();
        writer.execute("INSERT INTO t(v) VALUES ('in-wal')", []).unwrap();
        assert!(db.with_extension("db-wal").metadata().unwrap().len() > 0);

        let path = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        drop(writer);
        assert_eq!(rows(&path), ["in-wal"]);
    }

    #[test]
    fn restore_rejects_names_outside_backups() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let outside = home.path().join("x.db");
        make_db(&outside, &["outside"]);
        snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        for bad in [
            "../x.db",
            "../../x.db",
            "a/b.db",
            "..",
            "",
            "notes.txt",
            "bandito-20270115-080000-start-x.db",
        ] {
            assert!(restore(home.path(), bad, BASE_MS).is_err(), "name {bad:?}");
        }
        assert_eq!(rows(&db), ["live"], "the live database must stay as it was");
    }

    #[test]
    fn restore_saves_current_database_and_replaces_it() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old-1", "old-2"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();

        make_db(&db, &["new"]);
        restore(home.path(), &saved_name, BASE_MS + HOUR_MS).unwrap();

        assert_eq!(rows(&db), ["old-1", "old-2"]);
        let before_name = names(home.path())
            .into_iter()
            .find(|n| n.contains("before-restore"))
            .unwrap();
        assert_eq!(
            rows(&backups_dir(home.path()).join(before_name)),
            ["old-1", "old-2", "new"]
        );
        assert!(!home.path().join("bandito.db.restore-tmp").exists());
    }

    #[test]
    fn restore_drops_stale_wal_and_shm() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        // Crash simulation: the connection is leaked, so its -wal and -shm stay on disk.
        let writer = Connection::open(&db).unwrap();
        writer.execute("INSERT INTO t(v) VALUES ('stale-wal')", []).unwrap();
        std::mem::forget(writer);
        assert!(
            home.path().join("bandito.db-wal").exists(),
            "the leaked connection must leave a -wal"
        );

        let done = restore(home.path(), &saved_name, BASE_MS).unwrap();
        assert!(!home.path().join("bandito.db-wal").exists());
        assert!(!home.path().join("bandito.db-shm").exists());
        assert_eq!(rows(&db), ["old"]);
        // Not deleted: the old WAL is in backups/ with its database.
        let aside = done.saved.unwrap();
        assert_eq!(rows(&backups_dir(home.path()).join(aside)), ["old", "stale-wal"]);
    }

    #[test]
    fn restore_refuses_a_damaged_copy_and_keeps_the_live_database() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let dir = backups_dir(home.path());
        fs::create_dir_all(&dir).unwrap();
        let damaged = dir.join("bandito-20270115-080000-start.db");
        fs::write(&damaged, vec![0x42u8; 8192]).unwrap();

        assert!(restore(home.path(), "bandito-20270115-080000-start.db", BASE_MS).is_err());
        assert_eq!(rows(&db), ["live"]);
        assert!(!names(home.path()).iter().any(|n| n.contains("before-restore")));
        assert!(!home.path().join("bandito.db.restore-tmp").exists());
    }

    #[test]
    fn restore_refuses_a_symlink_in_backups() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let link = backups_dir(home.path()).join("bandito-20270115-090000-daily.db");
        std::os::unix::fs::symlink(&saved, &link).unwrap();

        let err = restore(home.path(), "bandito-20270115-090000-daily.db", BASE_MS).unwrap_err();
        assert!(format!("{err:#}").contains("not a regular file"), "{err:#}");
        assert_eq!(rows(&db), ["live"]);
        assert!(!names(home.path()).iter().any(|n| n.contains("before-restore")));
    }

    #[test]
    fn restore_is_refused_while_the_daemon_lock_is_held() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();

        let held = try_daemon_lock(home.path()).unwrap().expect("first lock is free");
        assert!(
            try_daemon_lock(home.path()).unwrap().is_none(),
            "a second holder must be refused"
        );
        let err = restore(home.path(), &saved_name, BASE_MS).unwrap_err();
        assert_eq!(format!("{err:#}"), BUSY_MSG);
        assert_eq!(rows(&db), ["live"]);

        drop(held);
        restore(home.path(), &saved_name, BASE_MS).unwrap();
    }

    #[test]
    fn restore_prunes_back_to_keep() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        for i in 0..KEEP as i64 {
            snapshot_file(&db, home.path(), "daily", BASE_MS + i * HOUR_MS).unwrap();
        }
        let oldest = names(home.path()).last().unwrap().clone();
        restore(home.path(), &oldest, BASE_MS + 100 * HOUR_MS).unwrap();
        // The newest KEEP stay, and so does the copy that was restored from, even though it is the oldest.
        assert_eq!(entries(home.path()).unwrap().len(), KEEP + 1);
        assert!(names(home.path()).contains(&oldest));
    }

    #[test]
    fn start_copies_once_per_version_and_names_upgrades() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        let first = on_start(home.path(), "0.1.4", BASE_MS).unwrap().unwrap();
        assert!(first.file_name().unwrap().to_str().unwrap().ends_with("-start.db"));
        // Same version, copy is fresh: nothing to do.
        assert!(on_start(home.path(), "0.1.4", BASE_MS + HOUR_MS).unwrap().is_none());
        // New version: a copy named upgrade.
        let upgraded = on_start(home.path(), VERSION, BASE_MS + 2 * HOUR_MS).unwrap().unwrap();
        assert!(upgraded.file_name().unwrap().to_str().unwrap().ends_with("-upgrade.db"));
        assert_eq!(
            fs::read_to_string(backups_dir(home.path()).join(LAST_VERSION)).unwrap(),
            VERSION
        );
        // A copy older than 20 h is taken on the next start even with the same version.
        assert!(
            on_start(home.path(), VERSION, BASE_MS + 2 * HOUR_MS + 21 * HOUR_MS)
                .unwrap()
                .is_some()
        );
    }

    #[test]
    fn periodic_check_copies_only_when_the_newest_is_over_a_day_old() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        // No copy yet: one is made.
        assert!(snapshot_if_due(home.path(), BASE_MS).unwrap().is_some());
        assert!(snapshot_if_due(home.path(), BASE_MS + 23 * HOUR_MS).unwrap().is_none());
        let due = snapshot_if_due(home.path(), BASE_MS + 25 * HOUR_MS).unwrap().unwrap();
        assert!(due.file_name().unwrap().to_str().unwrap().ends_with("-daily.db"));
    }

    #[test]
    fn copies_carry_their_reason_newest_first() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        snapshot_file(&db, home.path(), "upgrade", BASE_MS + HOUR_MS).unwrap();
        snapshot_file(&db, home.path(), "before-restore", BASE_MS + 2 * HOUR_MS).unwrap();
        // Same second, other reason: the name differs by reason, so there is no `-n` suffix.
        snapshot_file(&db, home.path(), "manual", BASE_MS + 2 * HOUR_MS).unwrap();
        let got: Vec<(String, i64)> = copies(home.path())
            .unwrap()
            .into_iter()
            .map(|c| (c.reason, c.created_at_ms))
            .collect();
        assert_eq!(
            got,
            [
                ("manual".to_string(), BASE_MS + 2 * HOUR_MS),
                ("before-restore".to_string(), BASE_MS + 2 * HOUR_MS),
                ("upgrade".to_string(), BASE_MS + HOUR_MS),
                ("start".to_string(), BASE_MS),
            ]
        );
    }

    #[test]
    fn make_copy_is_manual_and_described() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a", "b"]);
        let file = make_copy(home.path(), "manual", BASE_MS).unwrap();
        assert_eq!(file.name, "bandito-20270115-080000-manual.db");
        assert_eq!(file.reason, "manual");
        assert_eq!(file.created_at_ms, BASE_MS);
        assert!(file.size > 0);
        assert_eq!(list(home.path()).unwrap().len(), 1);
    }

    #[test]
    fn make_copy_without_a_database_is_an_error() {
        let home = temp_home();
        assert!(make_copy(home.path(), "manual", BASE_MS).is_err());
        assert!(list(home.path()).unwrap().is_empty());
    }

    #[test]
    fn request_restore_refuses_bad_and_missing_names_and_writes_no_marker() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        for bad in ["../x.db", "a/b.db", "", "bandito-20270115-080000-start-x.db"] {
            assert!(request_restore(home.path(), bad).is_err(), "name {bad:?}");
        }
        assert!(request_restore(home.path(), "bandito-20270115-090000-daily.db").is_err());
        assert!(!restore_marker(home.path()).exists());
    }

    #[test]
    fn pending_restore_is_applied_at_start_and_the_marker_goes() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old-1", "old-2"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        make_db(&db, &["new"]);

        request_restore(home.path(), &saved_name).unwrap();
        assert!(restore_marker(home.path()).exists());
        // The start of the daemon, lock held: the copy replaces the database.
        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap();
        assert_eq!(applied.as_ref().map(|a| a.name.as_str()), Some(saved_name.as_str()));
        assert_eq!(rows(&db), ["old-1", "old-2"]);
        assert!(!restore_marker(home.path()).exists());
        // The database as it was before the restore is kept, as with the CLI.
        assert!(names(home.path()).iter().any(|n| n.contains("before-restore")));
        // No marker any more: nothing to apply.
        assert_eq!(apply_pending_restore(home.path(), BASE_MS + 2 * HOUR_MS).unwrap(), None);
    }

    #[test]
    fn pending_restore_with_a_bad_name_fails_and_still_clears_the_marker() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&marker, "../x.db").unwrap();

        assert!(apply_pending_restore(home.path(), BASE_MS).is_err());
        assert!(!marker.exists(), "a failed restore must not be retried on every start");
        assert_eq!(rows(&db), ["live"]);
    }

    #[test]
    fn pending_restore_of_a_missing_copy_fails_and_keeps_the_database() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&marker, "bandito-20270115-080000-start.db").unwrap();

        let err = apply_pending_restore(home.path(), BASE_MS).unwrap_err();
        assert!(format!("{err:#}").contains("no backup named"), "{err:#}");
        assert!(!marker.exists());
        assert_eq!(rows(&db), ["live"]);
    }

    #[test]
    fn clear_restore_request_removes_the_marker_only() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        request_restore(home.path(), &saved_name).unwrap();
        clear_restore_request(home.path()).unwrap();
        assert!(!restore_marker(home.path()).exists());
        assert!(saved.exists(), "the copy itself stays");
        clear_restore_request(home.path()).unwrap();
    }

    #[test]
    fn a_successful_restore_is_recorded_as_ok() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        make_db(&db, &["new"]);
        let id = request_restore(home.path(), &saved_name).unwrap();

        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();
        assert_eq!(applied.id, id);
        assert_eq!(
            read_last_restore(home.path()),
            Some(LastRestore {
                id,
                name: saved_name,
                ok: true,
                error: None,
                at_ms: BASE_MS + HOUR_MS,
            })
        );
    }

    #[test]
    fn a_failed_restore_is_recorded_with_its_error() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&marker, "bandito-20270115-080000-start.db").unwrap();

        assert!(apply_pending_restore(home.path(), BASE_MS).is_err());
        let record = read_last_restore(home.path()).expect("the failure is recorded");
        assert_eq!(record.name, "bandito-20270115-080000-start.db");
        assert!(!record.ok);
        assert!(record.error.unwrap().contains("no backup named"));
        assert_eq!(rows(&db), ["live"]);
    }

    #[test]
    fn roll_back_puts_back_the_copy_from_before_the_restore() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        make_db(&db, &["new"]);
        request_restore(home.path(), &saved_name).unwrap();
        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();
        assert_eq!(rows(&db), ["old"]);
        assert!(applied.before.is_some());

        // The restored database did not open in the daemon: the database from before the restore comes back.
        roll_back_restore(home.path(), &applied, "file is not a database", BASE_MS + 2 * HOUR_MS).unwrap();
        // `make_db` appends, so the database from before the restore holds both rows.
        assert_eq!(rows(&db), ["old", "new"]);
        let record = read_last_restore(home.path()).unwrap();
        assert_eq!(record.name, saved_name);
        assert!(!record.ok);
        assert!(
            record
                .error
                .unwrap()
                .contains("the database from before the restore is back")
        );
    }

    #[test]
    fn roll_back_without_a_copy_from_before_is_an_error_and_is_recorded() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let applied = AppliedRestore {
            id: "op-1".into(),
            name: "bandito-20270115-080000-start.db".into(),
            before: None,
            saved: None,
        };
        assert!(roll_back_restore(home.path(), &applied, "file is not a database", BASE_MS).is_err());
        let record = read_last_restore(home.path()).unwrap();
        assert!(!record.ok);
        assert!(record.error.unwrap().contains("no copy from before the restore"));
    }

    #[test]
    fn a_damaged_live_database_is_moved_aside_and_the_restore_goes_on() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["good"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        // The live database is damaged: the copy before the restore cannot be made.
        fs::write(&db, "this is not sqlite").unwrap();
        request_restore(home.path(), &saved_name).unwrap();

        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();
        assert_eq!(applied.before, None, "no copy of the damaged database");
        assert_eq!(rows(&db), ["good"]);
        let moved: Vec<PathBuf> = fs::read_dir(backups_dir(home.path()))
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.file_name().unwrap().to_str().unwrap().starts_with("broken-"))
            .filter(|p| p.extension().is_some_and(|e| e == "db"))
            .collect();
        assert_eq!(moved.len(), 1, "{moved:?}");
        assert_eq!(fs::read_to_string(&moved[0]).unwrap(), "this is not sqlite");
        // Moved, not copied, and listed so that a person can find it.
        let listed = copies(home.path()).unwrap();
        assert!(
            listed
                .iter()
                .any(|c| c.name.starts_with("broken-") && c.reason == "broken")
        );
        assert!(read_last_restore(home.path()).unwrap().ok);
    }

    #[test]
    fn a_marker_that_is_a_folder_is_removed_and_refused() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.join("inside")).unwrap();

        assert!(apply_pending_restore(home.path(), BASE_MS).is_err());
        assert!(!marker.exists(), "a folder in the marker's place must go");
        assert_eq!(rows(&db), ["live"]);
    }

    #[test]
    fn a_marker_that_is_not_text_is_removed_and_refused() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&marker, [0xffu8, 0xfe, 0x00]).unwrap();

        assert!(apply_pending_restore(home.path(), BASE_MS).is_err());
        assert!(!marker.exists());
        assert_eq!(rows(&db), ["live"]);
    }

    #[test]
    fn an_empty_marker_is_removed_and_refused() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&marker, "  \n").unwrap();

        assert!(apply_pending_restore(home.path(), BASE_MS).is_err());
        assert!(!marker.exists());
        assert_eq!(rows(&db), ["live"]);
    }

    // ---- the restore guarantees (docs/ARCHITECTURE.md#backups) ----

    /// Clears the fault points of this thread when the test ends, even by a panic.
    struct Faults;
    impl Faults {
        fn on(points: &[(&str, i32)]) -> Self {
            for (point, code) in points {
                fault::fail(point, *code);
            }
            Faults
        }
    }
    impl Drop for Faults {
        fn drop(&mut self) {
            fault::clear();
        }
    }

    /// A live database with rows in the WAL that no connection has flushed: `bandito.db`, `-wal` and `-shm` on disk.
    /// Returns the name of a good copy to restore. The writer is leaked, like a crashed daemon's.
    fn live_with_wal(home: &Path) -> String {
        let db = home.join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home, "start", BASE_MS).unwrap();
        let writer = Connection::open(&db).unwrap();
        writer.execute("INSERT INTO t(v) VALUES ('in-wal')", []).unwrap();
        std::mem::forget(writer);
        assert!(home.join("bandito.db-wal").exists() && home.join("bandito.db-shm").exists());
        saved.file_name().unwrap().to_str().unwrap().to_string()
    }

    /// The live database is as `live_with_wal` left it, and the restore left nothing of its own in the way.
    fn assert_live_untouched(home: &Path) {
        assert_eq!(rows(&home.join(DB_FILE)), ["old", "in-wal"]);
        assert!(home.join("bandito.db-wal").exists(), "-wal is back");
        assert!(home.join("bandito.db-shm").exists(), "-shm is back");
        assert!(!home.join(RESTORE_TMP).exists());
        assert!(
            saved_databases(home).unwrap().is_empty(),
            "nothing is left set aside when the restore did not happen"
        );
    }

    fn set_aside(home: &Path) -> Vec<BackupFile> {
        saved_databases(home).unwrap()
    }

    #[test]
    fn a_failed_snapshot_of_a_healthy_database_stops_the_restore_and_changes_nothing() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        for code in [libc::ENOSPC, libc::EMFILE, libc::EIO] {
            let _faults = Faults::on(&[("snapshot", code)]);
            let err = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap_err();
            let text = format!("{err:#}");
            assert!(text.contains("the database was not changed"), "{text}");
            assert_live_untouched(home.path());
            assert!(!names(home.path()).iter().any(|n| n.contains("before-restore")));
        }
    }

    #[test]
    fn a_snapshot_that_fails_while_the_check_cannot_run_stops_the_restore_too() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        // The copy fails and so does the check of the live database (busy, too many files): that proves nothing.
        let _faults = Faults::on(&[("snapshot", libc::ENOSPC), ("health", libc::EMFILE)]);
        assert!(restore(home.path(), &name, BASE_MS + HOUR_MS).is_err());
        assert_live_untouched(home.path());
    }

    #[test]
    fn a_live_database_that_fails_its_own_check_is_set_aside_as_broken_and_the_restore_goes_on() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["good"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let name = saved.file_name().unwrap().to_str().unwrap().to_string();
        fs::write(&db, vec![0x42u8; 8192]).unwrap();

        let done = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap();
        assert_eq!(done.before, None);
        assert_eq!(done.saved.as_deref(), Some("broken-20270115-090000.db"));
        assert_eq!(rows(&db), ["good"]);
        assert_eq!(
            fs::read(backups_dir(home.path()).join("broken-20270115-090000.db")).unwrap(),
            vec![0x42u8; 8192],
            "the damaged file is kept byte for byte"
        );
    }

    #[test]
    fn the_old_files_are_set_aside_before_the_restored_one_takes_their_place() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let done = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap();

        assert_eq!(rows(&home.path().join(DB_FILE)), ["old"]);
        let saved = done.saved.unwrap();
        assert_eq!(saved, "replaced-20270115-090000.db");
        // The WAL went with the database: what was only in it is still readable there.
        assert_eq!(rows(&backups_dir(home.path()).join(&saved)), ["old", "in-wal"]);
        assert!(backups_dir(home.path()).join(format!("{saved}-wal")).exists());
        assert!(backups_dir(home.path()).join(format!("{saved}-shm")).exists());
        assert!(!home.path().join(RESTORE_TMP).exists());
    }

    #[test]
    fn a_rename_that_fails_at_any_step_puts_back_what_was_moved() {
        for point in ["aside-wal", "aside-shm", "aside-db", "install"] {
            let home = temp_home();
            let name = live_with_wal(home.path());
            let _faults = Faults::on(&[(point, libc::EIO)]);
            let err = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap_err();
            let text = format!("{err:#}");
            assert!(
                text.contains("undone") || text.contains("put back"),
                "{point}: the error says what was done about it: {text}"
            );
            assert_live_untouched(home.path());
        }
    }

    #[test]
    fn the_wal_and_shm_move_before_the_database() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        // The database rename fails: the -wal and -shm that moved before it were put back, so the database never
        // sat without its WAL for good.
        let _faults = Faults::on(&[("aside-db", libc::EIO)]);
        assert!(restore(home.path(), &name, BASE_MS + HOUR_MS).is_err());
        assert_live_untouched(home.path());
        // A failing -wal step leaves everything, the database too, where it was: it comes first.
        fault::clear();
        let _faults = Faults::on(&[("aside-wal", libc::EIO)]);
        assert!(restore(home.path(), &name, BASE_MS + HOUR_MS).is_err());
        assert_live_untouched(home.path());
    }

    #[test]
    fn when_even_the_undo_fails_nothing_is_lost_and_the_error_says_where_the_files_are() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let _faults = Faults::on(&[("aside-db", libc::EIO), ("undo-*", libc::EIO)]);
        let err = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap_err();
        let text = format!("{err:#}");
        assert!(
            text.contains("kept as") && text.contains("replaced-20270115-090000.db-wal"),
            "{text}"
        );
        // The -wal and -shm are in backups/ under the set-aside name, the database file is still in place.
        let dir = backups_dir(home.path());
        assert!(dir.join("replaced-20270115-090000.db-wal").exists());
        assert!(dir.join("replaced-20270115-090000.db-shm").exists());
        assert!(home.path().join(DB_FILE).exists());
        assert!(!home.path().join(RESTORE_TMP).exists());
    }

    #[test]
    fn a_failed_install_with_a_failed_undo_keeps_the_old_files_under_their_set_aside_name() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let _faults = Faults::on(&[("install", libc::EIO), ("undo-*", libc::EIO)]);
        let err = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap_err();
        assert!(
            format!("{err:#}").contains("putting the old database back failed"),
            "{err:#}"
        );
        let aside = set_aside(home.path());
        assert_eq!(aside.len(), 1);
        assert_eq!(rows(&backups_dir(home.path()).join(&aside[0].name)), ["old", "in-wal"]);
    }

    #[test]
    fn a_failed_temporary_copy_touches_no_live_file() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let _faults = Faults::on(&[("tmp-write", libc::ENOSPC)]);
        assert!(restore(home.path(), &name, BASE_MS + HOUR_MS).is_err());
        assert_live_untouched(home.path());
    }

    #[test]
    fn a_failing_directory_sync_does_not_undo_a_finished_restore() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let _faults = Faults::on(&[("sync-dir", libc::EIO)]);
        restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap();
        assert_eq!(rows(&home.path().join(DB_FILE)), ["old"]);
    }

    #[test]
    fn prune_keeps_the_copies_a_restore_names_and_never_touches_set_aside_databases() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        for i in 0..20i64 {
            snapshot_file(&db, home.path(), "daily", BASE_MS + i * HOUR_MS).unwrap();
        }
        let dir = backups_dir(home.path());
        for name in [
            "replaced-20200101-000000.db",
            "replaced-20200101-000000.db-wal",
            "broken-20200101-000000.db",
            "broken-20200101-000000-2.db",
        ] {
            fs::write(dir.join(name), "kept").unwrap();
        }
        let oldest = names(home.path())
            .into_iter()
            .rfind(|n| n.starts_with("bandito-"))
            .unwrap();
        prune_except(home.path(), KEEP, &[&oldest]);
        assert!(dir.join(&oldest).exists(), "the named copy stays");
        let ours = entries(home.path()).unwrap().len();
        assert_eq!(ours, KEEP + 1);
        for name in [
            "replaced-20200101-000000.db",
            "replaced-20200101-000000.db-wal",
            "broken-20200101-000000.db",
            "broken-20200101-000000-2.db",
        ] {
            assert!(dir.join(name).exists(), "{name} is only ever removed by a person");
        }
        prune(home.path(), 1);
        assert!(dir.join("broken-20200101-000000.db").exists());
    }

    #[test]
    fn a_restore_keeps_its_source_and_its_before_copy_when_they_are_old() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["a"]);
        // 20 copies, all newer than the one we restore from.
        for i in 1..=20i64 {
            snapshot_file(&db, home.path(), "daily", BASE_MS + i * HOUR_MS).unwrap();
        }
        let oldest = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let oldest = oldest.file_name().unwrap().to_str().unwrap().to_string();
        // The before-restore copy is made at an older time than all the others, so plain pruning would drop it.
        let done = restore(home.path(), &oldest, BASE_MS - 10 * HOUR_MS).unwrap();
        let before = done.before.unwrap();
        let listed = names(home.path());
        assert!(listed.contains(&oldest), "the copy that was restored from stays");
        assert!(listed.contains(&before), "the copy made before the restore stays");
    }

    #[test]
    fn set_aside_databases_are_listed_with_their_reason_and_can_be_restored() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let done = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap();
        let saved = done.saved.unwrap();

        let all = copies(home.path()).unwrap();
        let row = all.iter().find(|c| c.name == saved).expect("listed");
        assert_eq!(row.reason, "replaced");
        assert_eq!(row.created_at_ms, BASE_MS + HOUR_MS);
        assert!(row.size > 0);
        assert!(validate_name(&saved).is_ok());
        assert!(validate_name("replaced-nonsense.db").is_err());
        assert!(validate_name("replaced-20270115-090000.db-wal").is_err());
        // `entries` (what prune and the age check use) does not see them.
        assert!(entries(home.path()).unwrap().iter().all(|e| e.name != saved));

        // Restoring one gets back the rows that were only in its WAL.
        restore(home.path(), &saved, BASE_MS + 2 * HOUR_MS).unwrap();
        assert_eq!(rows(&home.path().join(DB_FILE)), ["old", "in-wal"]);
        assert!(backups_dir(home.path()).join(&saved).exists(), "the source stays");
    }

    #[test]
    fn a_damaged_set_aside_database_is_not_restored() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["live"]);
        let dir = backups_dir(home.path());
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("broken-20270115-080000.db"), vec![7u8; 4096]).unwrap();
        assert!(restore(home.path(), "broken-20270115-080000.db", BASE_MS).is_err());
        assert_eq!(rows(&db), ["live"]);
    }

    #[test]
    fn every_restore_gets_its_own_id_and_the_record_carries_it() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let name = saved.file_name().unwrap().to_str().unwrap().to_string();

        let first = request_restore(home.path(), &name).unwrap();
        let second = request_restore(home.path(), &name).unwrap();
        assert_ne!(first, second);
        assert!(!first.is_empty());
        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();
        assert_eq!(applied.id, second, "the later request replaced the earlier marker");
        assert_eq!(read_last_restore(home.path()).unwrap().id, second);

        // A failed one carries its id too.
        let third = request_restore(home.path(), &name).unwrap();
        fs::remove_file(backups_dir(home.path()).join(&name)).unwrap();
        assert!(apply_pending_restore(home.path(), BASE_MS + 2 * HOUR_MS).is_err());
        let record = read_last_restore(home.path()).unwrap();
        assert_eq!((record.id.as_str(), record.ok), (third.as_str(), false));
    }

    #[test]
    fn a_record_from_an_older_daemon_reads_with_an_empty_id() {
        let record: LastRestore =
            serde_json::from_str(r#"{"name":"bandito-20270115-080000-start.db","ok":true,"error":null,"at_ms":5}"#)
                .unwrap();
        assert_eq!(record.id, "");
    }

    #[test]
    fn a_marker_with_just_a_name_from_an_older_daemon_still_works() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let name = saved.file_name().unwrap().to_str().unwrap().to_string();
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();
        fs::write(&marker, format!("{name}\n")).unwrap();
        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();
        assert_eq!(applied.name, name);
        assert!(!applied.id.is_empty());
    }

    #[test]
    fn request_restore_does_not_write_through_a_link_or_a_folder_at_the_marker() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let name = saved.file_name().unwrap().to_str().unwrap().to_string();
        let marker = restore_marker(home.path());
        fs::create_dir_all(marker.parent().unwrap()).unwrap();

        let victim = home.path().join("victim.txt");
        fs::write(&victim, "precious").unwrap();
        std::os::unix::fs::symlink(&victim, &marker).unwrap();
        request_restore(home.path(), &name).unwrap();
        assert_eq!(
            fs::read_to_string(&victim).unwrap(),
            "precious",
            "the link target is not written"
        );
        assert!(fs::symlink_metadata(&marker).unwrap().file_type().is_file());
        assert_eq!(fs::metadata(&marker).unwrap().permissions().mode() & 0o777, 0o600);

        // A dangling link, and a folder.
        fs::remove_file(&marker).unwrap();
        std::os::unix::fs::symlink(home.path().join("nowhere"), &marker).unwrap();
        request_restore(home.path(), &name).unwrap();
        assert!(!home.path().join("nowhere").exists());
        fs::remove_file(&marker).unwrap();
        fs::create_dir_all(marker.join("inside")).unwrap();
        request_restore(home.path(), &name).unwrap();
        assert!(fs::symlink_metadata(&marker).unwrap().file_type().is_file());
    }

    #[test]
    fn roll_back_puts_back_the_exact_old_files_and_keeps_the_restored_ones_as_broken() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        let id = request_restore(home.path(), &name).unwrap();
        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();
        assert_eq!(rows(&home.path().join(DB_FILE)), ["old"]);

        roll_back_restore(home.path(), &applied, "boom", BASE_MS + 2 * HOUR_MS).unwrap();
        // The WAL rows are back too: they were never merged away.
        assert_eq!(rows(&home.path().join(DB_FILE)), ["old", "in-wal"]);
        let aside = set_aside(home.path());
        assert!(aside.iter().any(|c| c.reason == "broken"), "{aside:?}");
        assert!(
            !aside.iter().any(|c| c.name == applied.saved.clone().unwrap()),
            "the replaced files moved back"
        );
        let record = read_last_restore(home.path()).unwrap();
        assert_eq!((record.id.as_str(), record.ok), (id.as_str(), false));
    }

    #[test]
    fn roll_back_that_fails_leaves_the_restored_database_in_place_and_everything_else_aside() {
        let home = temp_home();
        let name = live_with_wal(home.path());
        request_restore(home.path(), &name).unwrap();
        let applied = apply_pending_restore(home.path(), BASE_MS + HOUR_MS).unwrap().unwrap();

        let _faults = Faults::on(&[("unrestore-back-db", libc::EIO)]);
        let err = roll_back_restore(home.path(), &applied, "boom", BASE_MS + 2 * HOUR_MS).unwrap_err();
        assert!(
            format!("{err:#}").contains("putting back the old database failed"),
            "{err:#}"
        );
        // No database is lost: the restored one is still in place, the old files are still set aside.
        assert_eq!(rows(&home.path().join(DB_FILE)), ["old"]);
        let saved = applied.saved.unwrap();
        assert_eq!(rows(&backups_dir(home.path()).join(saved)), ["old", "in-wal"]);
        let record = read_last_restore(home.path()).unwrap();
        assert!(!record.ok);
        assert!(record.error.unwrap().contains("failed"));
    }

    #[test]
    fn roll_back_goes_to_the_copy_from_before_when_the_set_aside_files_are_unknown() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        make_db(&db, &["old"]);
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let name = saved.file_name().unwrap().to_str().unwrap().to_string();
        make_db(&db, &["new"]);
        let done = restore(home.path(), &name, BASE_MS + HOUR_MS).unwrap();
        let applied = AppliedRestore {
            id: "op".into(),
            name,
            before: done.before,
            saved: None,
        };
        roll_back_restore(home.path(), &applied, "boom", BASE_MS + 2 * HOUR_MS).unwrap();
        assert_eq!(rows(&db), ["old", "new"]);
    }

    #[test]
    fn a_restore_into_an_empty_home_has_no_way_back_and_roll_back_says_so() {
        let home = temp_home();
        let other = temp_home();
        let src = other.path().join(DB_FILE);
        make_db(&src, &["x"]);
        let saved = snapshot_file(&src, other.path(), "start", BASE_MS).unwrap();
        fs::create_dir_all(backups_dir(home.path())).unwrap();
        let name = saved.file_name().unwrap().to_str().unwrap().to_string();
        fs::copy(&saved, backups_dir(home.path()).join(&name)).unwrap();

        let done = restore(home.path(), &name, BASE_MS).unwrap();
        assert_eq!((done.before, done.saved), (None, None));
        assert!(!has_set_aside(home.path()));
        let applied = AppliedRestore {
            id: "op".into(),
            name,
            before: None,
            saved: None,
        };
        assert!(roll_back_restore(home.path(), &applied, "boom", BASE_MS).is_err());
        // The restored file is not deleted: the person can still look at it.
        assert_eq!(rows(&home.path().join(DB_FILE)), ["x"]);
    }
}
