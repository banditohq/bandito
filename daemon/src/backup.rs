//! Database copies in `<home>/backups`: taken at start, once a day while the daemon runs, and before a restore.
//! Each copy is a `VACUUM INTO` snapshot, so it holds the WAL content too. A copy is written under
//! `<name>.partial`, checked with `PRAGMA quick_check`, and only then renamed to its final name
//! (see docs/ARCHITECTURE.md#backups).

use anyhow::{Context, Result, bail};
use chrono::NaiveDateTime;
use rusqlite::{Connection, OpenFlags};
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
    let result = write_copy(db, &partial)
        .and_then(|()| quick_check(&partial))
        .and_then(|()| fs::rename(&partial, &target).with_context(|| format!("rename {}", partial.display())));
    if let Err(e) = result {
        let _ = fs::remove_file(&partial);
        return Err(e);
    }
    Ok(target)
}

/// Keeps the `keep` newest copies in `<home>/backups`. Other files there are not touched.
pub fn prune(home: &Path, keep: usize) -> Result<()> {
    let dir = backups_dir(home);
    for entry in entries(home)?.into_iter().skip(keep) {
        fs::remove_file(dir.join(&entry.name)).with_context(|| format!("remove backup {}", entry.name))?;
    }
    Ok(())
}

/// Age in ms of the newest copy, by the time in its name. `None` when there is no copy.
pub fn newest_age_ms(home: &Path, now_ms: i64) -> Option<i64> {
    entries(home).ok()?.first().map(|e| now_ms - e.ts_ms)
}

/// Name and size in bytes of every copy, newest first.
pub fn list(home: &Path) -> Result<Vec<(String, u64)>> {
    Ok(entries(home)?.into_iter().map(|e| (e.name, e.size)).collect())
}

/// Replaces `<home>/bandito.db` with the copy `name` from `<home>/backups`. The copy must pass `quick_check`.
/// The current database is copied first, with reason `before-restore`. Refused while the daemon holds its lock.
pub fn restore(home: &Path, name: &str, now_ms: i64) -> Result<()> {
    if name.is_empty() || name.contains('/') || name.contains('\\') || name.contains("..") || parse_name(name).is_none()
    {
        bail!("invalid backup name {name:?}: give a file name from `bandito backup list`");
    }
    let Some(_lock) = try_daemon_lock(home)? else {
        bail!(BUSY_MSG);
    };
    let src = backups_dir(home).join(name);
    let meta = fs::symlink_metadata(&src).map_err(|_| anyhow::anyhow!("no backup named {name}"))?;
    if !meta.file_type().is_file() {
        bail!("{name} is not a regular file: refusing to restore from it");
    }
    quick_check(&src).with_context(|| format!("{name} failed the integrity check; the database was not changed"))?;

    let db = home.join(DB_FILE);
    if db.exists() {
        snapshot_file(&db, home, "before-restore", now_ms).context("copy the current database before restore")?;
    }
    let tmp = home.join("bandito.db.restore-tmp");
    let swap = || -> Result<()> {
        copy_private(&src, &tmp)?;
        // A WAL left by the old database must not be applied to the restored file.
        remove_if_exists(&home.join("bandito.db-wal"))?;
        remove_if_exists(&home.join("bandito.db-shm"))?;
        fs::rename(&tmp, &db).with_context(|| format!("replace {}", db.display()))?;
        Ok(())
    };
    if let Err(e) = swap() {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    prune(home, KEEP)?;
    Ok(())
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
    prune(home, KEEP)?;
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
    prune(home, KEEP)?;
    Ok(Some(path))
}

struct Entry {
    name: String,
    ts_ms: i64,
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
        let Some((ts_ms, n)) = parse_name(&name) else { continue };
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
            n,
            size: meta.len(),
        });
    }
    out.sort_by(|a, b| (b.ts_ms, b.n, &b.name).cmp(&(a.ts_ms, a.n, &a.name)));
    Ok(out)
}

/// `(time in ms, suffix)` of a copy name `bandito-<YYYYMMDD-HHMMSS>-<reason>[-<n>].db`; `None` for other files.
fn parse_name(name: &str) -> Option<(i64, u32)> {
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
    valid_reason(reason).then_some((ts_ms, n))
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
        prune(home.path(), 0).unwrap();
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
        prune(home.path(), KEEP).unwrap();

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

        restore(home.path(), &saved_name, BASE_MS).unwrap();
        assert!(!home.path().join("bandito.db-wal").exists());
        assert!(!home.path().join("bandito.db-shm").exists());
        assert_eq!(rows(&db), ["old"]);
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
    fn a_failed_swap_removes_the_temporary_file() {
        let home = temp_home();
        let db = home.path().join(DB_FILE);
        // A rollback-journal database: no -wal file is involved, so the copy before the swap goes through.
        {
            let conn = Connection::open(&db).unwrap();
            conn.execute_batch("CREATE TABLE t(v TEXT); INSERT INTO t(v) VALUES ('live');")
                .unwrap();
        }
        let saved = snapshot_file(&db, home.path(), "start", BASE_MS).unwrap();
        let saved_name = saved.file_name().unwrap().to_str().unwrap().to_string();
        // A folder where the -shm file should be: the -wal step passes (no file), the -shm removal fails
        // after the temporary copy was made.
        let shm = home.path().join("bandito.db-shm");
        fs::create_dir_all(shm.join("blocked")).unwrap();

        let err = restore(home.path(), &saved_name, BASE_MS).unwrap_err();
        assert!(format!("{err:#}").contains("bandito.db-shm"), "{err:#}");
        assert!(!home.path().join("bandito.db.restore-tmp").exists());
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
        assert_eq!(list(home.path()).unwrap().len(), KEEP);
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
}
