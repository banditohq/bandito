//! Push targets: where a paired phone wants push notifications (docs/ARCHITECTURE.md#push). The row goes with its
//! device (`ON DELETE CASCADE`, foreign keys are on).

use super::{Store, now_ms};
use anyhow::Result;
use rusqlite::{OptionalExtension, Row, params};
use zeroize::Zeroizing;

/// One phone's push registration. `key` is a secret: it is never serialized, printed or logged.
#[derive(Clone)]
pub struct PushTarget {
    pub device_id: String,
    /// The address at bandito.dev.
    pub handle: String,
    /// 32 bytes, zeroed when dropped.
    pub key: Zeroizing<Vec<u8>>,
    /// How the phone names this server.
    pub server_ref: String,
    /// The kinds the phone wants, comma separated (see `push::PushKind`).
    pub kinds: String,
    pub lang: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

impl std::fmt::Debug for PushTarget {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PushTarget")
            .field("device_id", &self.device_id)
            .field("kinds", &self.kinds)
            .finish_non_exhaustive()
    }
}

const COLS: &str = "device_id, handle, key, server_ref, kinds, lang, created_at, updated_at";

fn from_row(r: &Row) -> rusqlite::Result<PushTarget> {
    Ok(PushTarget {
        device_id: r.get(0)?,
        handle: r.get(1)?,
        key: Zeroizing::new(r.get::<_, Vec<u8>>(2)?),
        server_ref: r.get(3)?,
        kinds: r.get(4)?,
        lang: r.get(5)?,
        created_at: r.get(6)?,
        updated_at: r.get(7)?,
    })
}

impl Store {
    /// Registers or replaces the device's target (a phone that registers twice keeps one row; `created_at` stays).
    /// Fails when the device does not exist (it was revoked meanwhile).
    pub fn push_upsert(
        &self,
        device_id: &str,
        handle: &str,
        key: &[u8],
        server_ref: &str,
        kinds: &str,
        lang: Option<&str>,
    ) -> Result<()> {
        let now = now_ms();
        self.conn().execute(
            "INSERT INTO push_targets (device_id, handle, key, server_ref, kinds, lang, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
             ON CONFLICT(device_id) DO UPDATE SET handle = excluded.handle, key = excluded.key,
                 server_ref = excluded.server_ref, kinds = excluded.kinds, lang = excluded.lang,
                 updated_at = excluded.updated_at",
            params![device_id, handle, key, server_ref, kinds, lang, now],
        )?;
        Ok(())
    }

    /// Removes the device's target. Returns whether there was one.
    pub fn push_delete(&self, device_id: &str) -> Result<bool> {
        let n = self
            .conn()
            .execute("DELETE FROM push_targets WHERE device_id = ?1", [device_id])?;
        Ok(n > 0)
    }

    /// Removes the device's target only while it still holds `handle`: the cloud said that handle is gone, and the
    /// phone may have registered a new one since.
    pub fn push_delete_handle(&self, device_id: &str, handle: &str) -> Result<bool> {
        let n = self.conn().execute(
            "DELETE FROM push_targets WHERE device_id = ?1 AND handle = ?2",
            params![device_id, handle],
        )?;
        Ok(n > 0)
    }

    pub fn push_get(&self, device_id: &str) -> Result<Option<PushTarget>> {
        Ok(self
            .conn()
            .query_row(
                &format!("SELECT {COLS} FROM push_targets WHERE device_id = ?1"),
                [device_id],
                from_row,
            )
            .optional()?)
    }

    /// Every target, oldest registration first.
    pub fn push_list(&self) -> Result<Vec<PushTarget>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM push_targets ORDER BY created_at, device_id"
        ))?;
        let rows = stmt.query_map([], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_replaces_and_keeps_one_row_per_device() {
        let s = Store::open_in_memory().unwrap();
        let d = s.device_add("iPhone", "tok").unwrap();
        s.push_upsert(&d.id, "h1", &[1; 32], "srv", "approval,done", None)
            .unwrap();
        let first = s.push_get(&d.id).unwrap().unwrap();
        assert_eq!((first.handle.as_str(), first.kinds.as_str()), ("h1", "approval,done"));
        s.push_upsert(&d.id, "h2", &[2; 32], "srv2", "error", Some("ru"))
            .unwrap();
        let list = s.push_list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].handle, "h2");
        assert_eq!(list[0].key.as_slice(), &[2; 32]);
        assert_eq!(list[0].lang.as_deref(), Some("ru"));
        assert_eq!(list[0].created_at, first.created_at);
        assert!(list[0].updated_at >= first.updated_at);
    }

    #[test]
    fn unknown_device_is_refused_and_delete_reports() {
        let s = Store::open_in_memory().unwrap();
        assert!(s.push_upsert("nobody", "h", &[0; 32], "s", "done", None).is_err());
        let d = s.device_add("iPhone", "tok").unwrap();
        s.push_upsert(&d.id, "h", &[0; 32], "s", "done", None).unwrap();
        assert!(!s.push_delete_handle(&d.id, "other").unwrap());
        assert!(s.push_delete_handle(&d.id, "h").unwrap());
        assert!(!s.push_delete(&d.id).unwrap());
    }

    #[test]
    fn revoking_the_device_removes_its_target() {
        let s = Store::open_in_memory().unwrap();
        let a = s.device_add("A", "ta").unwrap();
        let b = s.device_add("B", "tb").unwrap();
        s.push_upsert(&a.id, "ha", &[1; 32], "s", "done", None).unwrap();
        s.push_upsert(&b.id, "hb", &[2; 32], "s", "done", None).unwrap();
        assert!(s.device_revoke(&a.id).unwrap());
        let list = s.push_list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].device_id, b.id);
    }

    #[test]
    fn debug_does_not_show_the_key_or_the_handle() {
        let s = Store::open_in_memory().unwrap();
        let d = s.device_add("iPhone", "tok").unwrap();
        s.push_upsert(&d.id, "secret-handle", &[7; 32], "s", "done", None)
            .unwrap();
        let shown = format!("{:?}", s.push_get(&d.id).unwrap().unwrap());
        assert!(!shown.contains("secret-handle") && !shown.contains("key"), "{shown}");
    }
}
