//! The server settings' table (`server_settings`): one text value per name. The rules are in `server_settings.rs`.
//! See docs/ARCHITECTURE.md#server-settings.

use super::Store;
use crate::server_settings::{ServerSettings, from_stored};
use anyhow::Result;
use rusqlite::{Connection, OpenFlags, params};
use std::collections::HashMap;
use std::path::Path;

impl Store {
    /// The stored values, by name. Names without a row are absent.
    pub fn server_setting_values(&self) -> Result<HashMap<String, String>> {
        let conn = self.conn();
        read_values(&conn)
    }

    /// The settings as they apply now. A failed read is logged and gives the defaults, so a broken read never stops
    /// the work that asks (a turn, a screen check, a backup).
    pub fn server_settings_or_default(&self) -> ServerSettings {
        match self.server_setting_values() {
            Ok(values) => from_stored(&values),
            Err(e) => {
                tracing::warn!("read the server settings: {e:#}");
                crate::server_settings::defaults()
            }
        }
    }

    /// The settings, read with the error kept (the RPC reads them this way).
    pub fn server_settings(&self) -> Result<ServerSettings> {
        Ok(from_stored(&self.server_setting_values()?))
    }

    /// Writes all `changes` in one transaction: all of them or none. Values must already be checked
    /// (`server_settings::check_patch`).
    pub fn server_settings_write(&self, changes: &[(&str, String)]) -> Result<()> {
        if changes.is_empty() {
            return Ok(());
        }
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        for (key, value) in changes {
            tx.execute(
                "INSERT INTO server_settings (key, value) VALUES (?1, ?2)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                params![key, value],
            )?;
        }
        tx.commit()?;
        Ok(())
    }
}

fn read_values(conn: &Connection) -> Result<HashMap<String, String>> {
    let mut stmt = conn.prepare("SELECT key, value FROM server_settings")?;
    let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
    Ok(rows.collect::<rusqlite::Result<HashMap<_, _>>>()?)
}

/// The settings of the database file at `path`, read without changing it (before the store opens, at start).
/// Absent when the file cannot be read or has no settings table yet: the caller then uses the defaults.
pub fn read_settings_file(path: &Path) -> Option<ServerSettings> {
    let conn =
        Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()?;
    let _ = conn.busy_timeout(std::time::Duration::from_secs(5));
    read_values(&conn).ok().map(|values| from_stored(&values))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server_settings::{AutoUpdate, check_patch, defaults};
    use serde_json::json;

    #[test]
    fn nothing_stored_means_the_defaults() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.server_settings().unwrap(), defaults());
        assert_eq!(s.server_settings_or_default(), defaults());
    }

    #[test]
    fn a_write_is_read_back_and_replaces_the_old_value() {
        let s = Store::open_in_memory().unwrap();
        let first = check_patch(
            json!({"screen_idle_minutes": 60, "auto_update": "off"})
                .as_object()
                .unwrap(),
        )
        .unwrap();
        s.server_settings_write(&first).unwrap();
        let second = check_patch(json!({"screen_idle_minutes": 90}).as_object().unwrap()).unwrap();
        s.server_settings_write(&second).unwrap();
        let read = s.server_settings().unwrap();
        assert_eq!(read.screen_idle_minutes, 90);
        assert_eq!(read.auto_update, AutoUpdate::Off);
        assert_eq!(s.server_setting_values().unwrap().len(), 2);
    }

    #[test]
    fn a_failed_write_changes_nothing() {
        let s = Store::open_in_memory().unwrap();
        s.break_for_test("DROP TABLE server_settings");
        let changes = [("screen_idle_minutes", "60".to_string())];
        assert!(s.server_settings_write(&changes).is_err());
        // With the table gone, reads fall back to the defaults instead of failing the caller.
        assert_eq!(s.server_settings_or_default(), defaults());
    }

    #[test]
    fn the_file_reader_gives_the_stored_values_and_defaults_for_a_missing_file() {
        // A folder of this test only: removed with it.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("bandito.db");
        assert!(read_settings_file(&path).is_none());
        {
            let s = Store::open(&path).unwrap();
            let changes = check_patch(json!({"backup_keep": 5}).as_object().unwrap()).unwrap();
            s.server_settings_write(&changes).unwrap();
        }
        let read = read_settings_file(&path).expect("the file has the settings table");
        assert_eq!(read.backup_keep, 5);
    }
}
