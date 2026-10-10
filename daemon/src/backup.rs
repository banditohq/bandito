//! Database copies in `<home>/backups`: taken at start, once a day while the daemon runs, and before a restore.
//! Each copy is a `VACUUM INTO` snapshot, so it holds the WAL content too (see docs/ARCHITECTURE.md#backups).

use anyhow::{Context, Result, bail};
use chrono::NaiveDateTime;
use rusqlite::{Connection, OpenFlags};
use std::fs;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// Newest copies kept; older ones are pruned.
pub const KEEP: usize = 14;

const DB_FILE: &str = "bandito.db";
const LAST_VERSION: &str = "last-version";
const TS_FORMAT: &str = "%Y%m%d-%H%M%S";
const HOUR_MS: i64 = 3_600_000;
/// A copy younger than this is good enough at start.
const START_MAX_AGE_MS: i64 = 20 * HOUR_MS;
/// The periodic check makes a copy once the newest one is older than this.
const DAILY_MAX_AGE_MS: i64 = 24 * HOUR_MS;

pub fn backups_dir(home: &Path) -> PathBuf {
    home.join("backups")
}

/// Writes a consistent copy of `db` to `<home>/backups/bandito-<UTC time>-<reason>.db` and returns its path.
/// A name already taken gets `-2`, `-3`, ... (two copies in the same second stay apart).
pub fn snapshot_file(db: &Path, home: &Path, reason: &str, now_ms: i64) -> Result<PathBuf> {
    if !valid_reason(reason) {
        bail!("invalid backup reason {reason:?}: use lowercase letters and '-'");
    }
    let dir = backups_dir(home);
    create_private_dir(&dir)?;
    let ts = timestamp(now_ms)?;
    let target = reserve(&dir, &ts, reason)?;
    let written = (|| -> Result<()> {
        // Read-only: the live daemon keeps its own writer connection; this one only reads.
        let src = Connection::open_with_flags(db, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .with_context(|| format!("open {} for backup", db.display()))?;
        let out = target.to_str().context("backup path is not valid UTF-8")?;
        // VACUUM INTO accepts an existing empty file: `reserve` created it with mode 0600.
        src.execute("VACUUM INTO ?1", [out]).context("VACUUM INTO")?;
        Ok(())
    })();
    if let Err(e) = written {
        let _ = fs::remove_file(&target);
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

/// Replaces `<home>/bandito.db` with the copy `name` from `<home>/backups`. The current database is copied
/// first, with reason `before-restore`. The daemon must be stopped: the caller checks that.
pub fn restore(home: &Path, name: &str, now_ms: i64) -> Result<()> {
    if name.is_empty() || name.contains('/') || name.contains('\\') || name.contains("..") || parse_name(name).is_none()
    {
        bail!("invalid backup name {name:?}: give a file name from `bandito backup list`");
    }
    let src = backups_dir(home).join(name);
    if !src.is_file() {
        bail!("no backup named {name}");
    }
    let db = home.join(DB_FILE);
    if db.exists() {
        snapshot_file(&db, home, "before-restore", now_ms).context("copy the current database before restore")?;
    }
    let tmp = home.join("bandito.db.restore-tmp");
    if let Err(e) = copy_private(&src, &tmp) {
        let _ = fs::remove_file(&tmp);
        return Err(e);
    }
    // A WAL left by the old database must not be applied to the restored file.
    remove_if_exists(&home.join("bandito.db-wal"))?;
    remove_if_exists(&home.join("bandito.db-shm"))?;
    fs::rename(&tmp, &db).with_context(|| format!("replace {}", db.display()))?;
    Ok(())
}

/// Start of the daemon: copies the database when there is no copy, the newest is older than 20 h, or the
/// version recorded in `last-version` differs from `version`. Returns the new copy, if any.
/// Does nothing when the database does not exist yet.
pub fn on_start(home: &Path, version: &str, now_ms: i64) -> Result<Option<PathBuf>> {
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
    create_private_dir(&dir)?;
    fs::write(dir.join(LAST_VERSION), version).context("record the version of the last start")?;
    fs::set_permissions(dir.join(LAST_VERSION), fs::Permissions::from_mode(0o600))?;
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

/// Our copies in `<home>/backups`, newest first. Files that do not have our name are left out.
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
        if !item.file_type()?.is_file() {
            continue;
        }
        let size = item.metadata()?.len();
        out.push(Entry { name, ts_ms, n, size });
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

/// Creates the first free name for this second and reason as an empty 0600 file.
fn reserve(dir: &Path, ts: &str, reason: &str) -> Result<PathBuf> {
    for n in 1..=1000u32 {
        let name = if n == 1 {
            format!("bandito-{ts}-{reason}.db")
        } else {
            format!("bandito-{ts}-{reason}-{n}.db")
        };
        let path = dir.join(name);
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
        {
            Ok(_) => return Ok(path),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e).with_context(|| format!("create {}", path.display())),
        }
    }
    bail!("no free backup name for {ts}-{reason}")
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
        let names: Vec<String> = list(home.path()).unwrap().into_iter().map(|(n, _)| n).collect();
        assert_eq!(
            names,
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
        let before = list(home.path()).unwrap();
        let before_name = before
            .iter()
            .map(|(n, _)| n)
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
