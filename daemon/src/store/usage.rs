//! Last rate-limit windows each runtime reported, so the app can show them
//! without starting a turn. One row per runtime.

use super::Store;
use crate::event::LimitWindow;
use anyhow::Result;
use rusqlite::params;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageEntry {
    pub runtime: String,
    pub windows: Vec<LimitWindow>,
    /// Unix milliseconds of the last report.
    pub updated_at: i64,
}

impl Store {
    /// Replace the cached windows of `runtime`.
    pub fn usage_set(&self, runtime: &str, windows: &[LimitWindow], at: i64) -> Result<()> {
        let json = serde_json::to_string(windows)?;
        self.conn().execute(
            "INSERT INTO usage_limits (runtime, windows, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(runtime) DO UPDATE SET windows = excluded.windows, updated_at = excluded.updated_at",
            params![runtime, json, at],
        )?;
        Ok(())
    }

    /// All cached runtimes, by name.
    pub fn usage_list(&self) -> Result<Vec<UsageEntry>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT runtime, windows, updated_at FROM usage_limits ORDER BY runtime")?;
        let rows = stmt.query_map([], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (runtime, windows, updated_at) = row?;
            // A corrupt row shows no windows instead of failing the whole list.
            let windows = serde_json::from_str(&windows).unwrap_or_else(|e| {
                tracing::warn!(runtime, "bad usage_limits row: {e}");
                Vec::new()
            });
            out.push(UsageEntry {
                runtime,
                windows,
                updated_at,
            });
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn window(name: &str, utilization: f64) -> LimitWindow {
        LimitWindow {
            name: name.into(),
            utilization,
            resets_at: Some(1_900_000_000),
        }
    }

    #[test]
    fn set_then_list() {
        let s = Store::open_in_memory().unwrap();
        assert!(s.usage_list().unwrap().is_empty());
        s.usage_set("codex", &[window("5h", 0.25)], 100).unwrap();
        s.usage_set("claude", &[window("weekly", 0.5)], 200).unwrap();
        assert_eq!(
            s.usage_list().unwrap(),
            vec![
                UsageEntry {
                    runtime: "claude".into(),
                    windows: vec![window("weekly", 0.5)],
                    updated_at: 200,
                },
                UsageEntry {
                    runtime: "codex".into(),
                    windows: vec![window("5h", 0.25)],
                    updated_at: 100,
                },
            ]
        );
    }

    #[test]
    fn set_replaces_the_runtime_row() {
        let s = Store::open_in_memory().unwrap();
        s.usage_set("claude", &[window("5h", 0.1)], 1).unwrap();
        s.usage_set("claude", &[window("5h", 0.9), window("weekly", 0.2)], 2)
            .unwrap();
        let list = s.usage_list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].windows.len(), 2);
        assert_eq!(list[0].windows[0].utilization, 0.9);
        assert_eq!(list[0].updated_at, 2);
    }

    #[test]
    fn corrupt_json_lists_no_windows() {
        let s = Store::open_in_memory().unwrap();
        s.conn()
            .execute(
                "INSERT INTO usage_limits (runtime, windows, updated_at) VALUES ('grok', '{not json', 5)",
                [],
            )
            .unwrap();
        assert_eq!(
            s.usage_list().unwrap(),
            vec![UsageEntry {
                runtime: "grok".into(),
                windows: Vec::new(),
                updated_at: 5,
            }]
        );
    }
}
