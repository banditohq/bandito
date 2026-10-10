//! Devices (paired apps) and one-time pairing codes. Only hashes are stored.

use super::{Store, new_id, now_ms};
use anyhow::Result;
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    pub name: String,
    pub created_at: i64,
    pub last_seen_at: Option<i64>,
}

/// Lowercase hex SHA-256 of `s`.
pub fn sha256_hex(s: &str) -> String {
    use sha2::{Digest, Sha256};
    hex::encode(Sha256::digest(s.as_bytes()))
}

fn from_row(r: &Row) -> rusqlite::Result<Device> {
    Ok(Device {
        id: r.get(0)?,
        name: r.get(1)?,
        created_at: r.get(2)?,
        last_seen_at: r.get(3)?,
    })
}

impl Store {
    /// Store `sha256_hex(code)` with `expires_at = now_ms() + ttl_ms`.
    /// Also deletes all already-expired codes.
    pub fn pairing_add(&self, code: &str, ttl_ms: i64) -> Result<()> {
        let now = now_ms();
        let code_hash = sha256_hex(&normalize_code(code));
        let conn = self.conn();
        conn.execute("DELETE FROM pairing WHERE expires_at <= ?1", params![now])?;
        conn.execute(
            "INSERT INTO pairing (code_hash, expires_at) VALUES (?1, ?2)
             ON CONFLICT(code_hash) DO UPDATE SET expires_at = excluded.expires_at",
            params![code_hash, now.saturating_add(ttl_ms)],
        )?;
        Ok(())
    }

    /// If an unexpired code with this hash exists: delete it (one-time) and
    /// return true. Otherwise false. Codes are compared after
    /// `normalize_code` (lowercase, words joined by single '-').
    pub fn pairing_take(&self, code: &str) -> Result<bool> {
        let now = now_ms();
        let code_hash = sha256_hex(&normalize_code(code));
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let valid: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM pairing WHERE code_hash = ?1 AND expires_at > ?2)",
            params![code_hash, now],
            |r| r.get(0),
        )?;
        if valid {
            tx.execute("DELETE FROM pairing WHERE code_hash = ?1", params![code_hash])?;
        }
        tx.commit()?;
        Ok(valid)
    }

    /// A throwaway in-memory store for safe mode (the real database could not be opened). It holds the paired
    /// devices of `live_db` when those can be read, so the app can still connect; everything else is empty and is
    /// never written back. The live file is opened read-only and not changed. Failing to read it is not an error.
    pub fn open_safe_mode(live_db: &Path) -> Result<Self> {
        let store = Self::open_in_memory()?;
        if live_db.is_file()
            && let Err(e) = store.import_devices_from(live_db)
        {
            tracing::warn!(
                "safe mode: could not read the paired devices from {}: {e:#}",
                live_db.display()
            );
        }
        Ok(store)
    }

    /// Reads the paired devices from a private copy of `live_db` (the file and its `-wal`, copied to a temporary
    /// folder), so nothing is opened, created or changed next to the live file: no `-shm`, no checkpoint.
    fn import_devices_from(&self, live_db: &Path) -> Result<()> {
        use std::os::unix::fs::DirBuilderExt;
        let dir = std::env::temp_dir().join(format!("bandito-safe-{}", new_id()));
        std::fs::DirBuilder::new().mode(0o700).create(&dir)?;
        let result = (|| -> Result<()> {
            let copy = dir.join("live.db");
            std::fs::copy(live_db, &copy)?;
            let wal = PathBuf::from(format!("{}-wal", live_db.display()));
            if wal.is_file() {
                std::fs::copy(&wal, dir.join("live.db-wal"))?;
            }
            let conn = self.conn();
            conn.execute("ATTACH DATABASE ?1 AS live", [copy.to_string_lossy().as_ref()])?;
            let copied = conn.execute(
                "INSERT OR IGNORE INTO devices (id, name, token_hash, created_at, last_seen_at)
                 SELECT id, name, token_hash, created_at, last_seen_at FROM live.devices",
                [],
            );
            let _ = conn.execute("DETACH DATABASE live", []);
            copied?;
            Ok(())
        })();
        let _ = std::fs::remove_dir_all(&dir);
        result
    }

    /// Insert a device with `token_hash = sha256_hex(token)`.
    pub fn device_add(&self, name: &str, token: &str) -> Result<Device> {
        let device = Device {
            id: new_id(),
            name: name.to_string(),
            created_at: now_ms(),
            last_seen_at: None,
        };
        let token_hash = sha256_hex(token);
        self.conn().execute(
            "INSERT INTO devices (id, name, token_hash, created_at, last_seen_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                device.id,
                device.name,
                token_hash,
                device.created_at,
                device.last_seen_at
            ],
        )?;
        Ok(device)
    }

    /// Find the device by `sha256_hex(token)`, set `last_seen_at = now_ms()`,
    /// return it. `None` if unknown (revoked).
    pub fn device_auth(&self, token: &str) -> Result<Option<Device>> {
        let token_hash = sha256_hex(token);
        let now = now_ms();
        // One statement: the update and the read cannot interleave with a revoke.
        Ok(self
            .conn()
            .query_row(
                "UPDATE devices SET last_seen_at = ?2 WHERE token_hash = ?1
                 RETURNING id, name, created_at, last_seen_at",
                params![token_hash, now],
                from_row,
            )
            .optional()?)
    }

    pub fn device_list(&self) -> Result<Vec<Device>> {
        let conn = self.conn();
        let mut stmt =
            conn.prepare("SELECT id, name, created_at, last_seen_at FROM devices ORDER BY created_at, id")?;
        let rows = stmt.query_map([], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn device_revoke(&self, id: &str) -> Result<bool> {
        let n = self.conn().execute("DELETE FROM devices WHERE id = ?1", [id])?;
        Ok(n > 0)
    }
}

/// `"Brave Otter-Lamp  kite"` → `"brave-otter-lamp-kite"`: lowercase, any run
/// of whitespace or '-' becomes one '-', trimmed.
pub fn normalize_code(code: &str) -> String {
    code.to_lowercase()
        .split(|c: char| c.is_whitespace() || c == '-')
        .filter(|word| !word.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_mode_store_keeps_the_paired_devices_of_the_live_database_and_changes_nothing_there() {
        let dir = tempfile::tempdir().unwrap();
        let live = dir.path().join("bandito.db");
        {
            let store = Store::open(&live).unwrap();
            store.device_add("laptop", "token-1").unwrap();
        }
        let before = std::fs::read(&live).unwrap();
        let safe = Store::open_safe_mode(&live).unwrap();
        assert_eq!(safe.device_auth("token-1").unwrap().unwrap().name, "laptop");
        assert!(safe.device_auth("other").unwrap().is_none());
        assert_eq!(
            std::fs::read(&live).unwrap(),
            before,
            "the live file is read, never written"
        );
    }

    #[test]
    fn safe_mode_store_reads_a_copy_and_leaves_the_live_folder_as_it_was() {
        let dir = tempfile::tempdir().unwrap();
        let live = dir.path().join("bandito.db");
        // A device that exists only in the WAL: a connection that never closed.
        let store = Store::open(&live).unwrap();
        store.device_add("laptop", "token-1").unwrap();
        std::mem::forget(store);
        let listing = || {
            let mut names: Vec<(String, u64)> = std::fs::read_dir(dir.path())
                .unwrap()
                .map(|e| {
                    let e = e.unwrap();
                    (
                        e.file_name().to_string_lossy().into_owned(),
                        e.metadata().unwrap().len(),
                    )
                })
                .collect();
            names.sort();
            names
        };
        let before = listing();
        assert!(before.iter().any(|(n, _)| n.ends_with("-wal")), "{before:?}");
        let safe = Store::open_safe_mode(&live).unwrap();
        assert_eq!(safe.device_auth("token-1").unwrap().unwrap().name, "laptop");
        assert_eq!(listing(), before, "no file appeared, none changed size");
    }

    #[test]
    fn safe_mode_store_opens_when_the_live_database_is_missing_or_damaged() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("none.db");
        assert!(
            Store::open_safe_mode(&missing)
                .unwrap()
                .device_auth("t")
                .unwrap()
                .is_none()
        );
        let bad = dir.path().join("bad.db");
        std::fs::write(&bad, vec![9u8; 4096]).unwrap();
        assert!(Store::open_safe_mode(&bad).unwrap().device_auth("t").unwrap().is_none());
        assert_eq!(std::fs::read(&bad).unwrap(), vec![9u8; 4096]);
    }

    #[test]
    fn normalize_code_examples() {
        assert_eq!(normalize_code("Brave Otter-Lamp  kite"), "brave-otter-lamp-kite");
        assert_eq!(normalize_code("  -a--b- "), "a-b");
        assert_eq!(normalize_code("\tX\n y"), "x-y");
        assert_eq!(normalize_code(" - "), "");
    }

    #[test]
    fn sha256_hex_known_vector() {
        assert_eq!(
            sha256_hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn pairing_take_is_one_time_and_normalized() {
        let s = Store::open_in_memory().unwrap();
        s.pairing_add("Brave Otter-Lamp  kite", 60_000).unwrap();
        assert!(s.pairing_take("BRAVE otter lamp kite").unwrap());
        assert!(!s.pairing_take("brave-otter-lamp-kite").unwrap());
    }

    #[test]
    fn pairing_take_wrong_code_is_false_and_keeps_real_one() {
        let s = Store::open_in_memory().unwrap();
        s.pairing_add("brave-otter-lamp-kite", 60_000).unwrap();
        assert!(!s.pairing_take("brave-otter-lamp-tree").unwrap());
        assert!(s.pairing_take("brave-otter-lamp-kite").unwrap());
    }

    #[test]
    fn pairing_take_expired_is_false() {
        let s = Store::open_in_memory().unwrap();
        s.pairing_add("brave-otter", -1).unwrap();
        assert!(!s.pairing_take("brave-otter").unwrap());
    }

    #[test]
    fn pairing_add_drops_expired_codes() {
        let s = Store::open_in_memory().unwrap();
        s.pairing_add("old-code", -1).unwrap();
        s.pairing_add("new-code", 60_000).unwrap();
        let n: i64 = s
            .conn()
            .query_row("SELECT COUNT(*) FROM pairing", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
        assert!(s.pairing_take("new-code").unwrap());
    }

    #[test]
    fn pairing_add_same_code_refreshes_instead_of_duplicating() {
        let s = Store::open_in_memory().unwrap();
        s.pairing_add("c-d", 1_000).unwrap();
        s.pairing_add("C D", 60_000).unwrap();
        let n: i64 = s
            .conn()
            .query_row("SELECT COUNT(*) FROM pairing", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
        assert!(s.pairing_take("c-d").unwrap());
    }

    #[test]
    fn device_add_then_auth_sets_last_seen() {
        let s = Store::open_in_memory().unwrap();
        let d = s.device_add("iPhone", "tok-123").unwrap();
        assert_eq!(d.last_seen_at, None);
        let got = s.device_auth("tok-123").unwrap().unwrap();
        assert_eq!(got.id, d.id);
        assert_eq!(got.name, "iPhone");
        assert_eq!(got.created_at, d.created_at);
        assert!(got.last_seen_at.is_some());
        assert_eq!(s.device_list().unwrap()[0].last_seen_at, got.last_seen_at);
    }

    #[test]
    fn device_auth_wrong_token_is_none_and_token_is_not_normalized() {
        let s = Store::open_in_memory().unwrap();
        s.device_add("iPhone", "Tok-Case").unwrap();
        assert_eq!(s.device_auth("tok-999").unwrap(), None);
        assert_eq!(s.device_auth("tok-case").unwrap(), None);
        assert!(s.device_auth("Tok-Case").unwrap().is_some());
    }

    #[test]
    fn device_revoke_then_auth_is_none() {
        let s = Store::open_in_memory().unwrap();
        let d = s.device_add("iPhone", "tok").unwrap();
        assert!(s.device_revoke(&d.id).unwrap());
        assert_eq!(s.device_auth("tok").unwrap(), None);
        assert!(!s.device_revoke(&d.id).unwrap());
        assert!(s.device_list().unwrap().is_empty());
    }

    #[test]
    fn device_list_ordered_by_created_at() {
        let s = Store::open_in_memory().unwrap();
        let late = s.device_add("late", "t1").unwrap();
        let early = s.device_add("early", "t2").unwrap();
        s.conn()
            .execute("UPDATE devices SET created_at = 200 WHERE id = ?1", params![late.id])
            .unwrap();
        s.conn()
            .execute("UPDATE devices SET created_at = 100 WHERE id = ?1", params![early.id])
            .unwrap();
        let names: Vec<String> = s.device_list().unwrap().into_iter().map(|d| d.name).collect();
        assert_eq!(names, vec!["early".to_string(), "late".to_string()]);
    }
}
