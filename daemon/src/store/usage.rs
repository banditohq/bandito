//! Last rate-limit windows each runtime reported, so the app can show them
//! without starting a turn. One row per runtime.

use super::Store;
use crate::event::{LimitWindow, Plan};
use anyhow::Result;
use rusqlite::params;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageEntry {
    pub runtime: String,
    pub windows: Vec<LimitWindow>,
    /// Unix milliseconds of the last report.
    pub updated_at: i64,
    /// The account's subscription, once a runtime has said. `null` when unknown.
    pub plan: Option<Plan>,
}

impl Store {
    /// Replace the cached windows of `runtime`. The plan is left as it is.
    pub fn usage_set(&self, runtime: &str, windows: &[LimitWindow], at: i64) -> Result<()> {
        let json = serde_json::to_string(windows)?;
        self.conn().execute(
            "INSERT INTO usage_limits (runtime, windows, updated_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(runtime) DO UPDATE SET windows = excluded.windows, updated_at = excluded.updated_at",
            params![runtime, json, at],
        )?;
        Ok(())
    }

    /// Set the plan of `runtime`; `None` clears it. The windows stay as they are. A new row gets no
    /// windows, and `updated_at` (the time of the windows) is set only when the row is created.
    pub fn usage_set_plan(&self, runtime: &str, plan: Option<&Plan>, at: i64) -> Result<()> {
        let json = plan.map(serde_json::to_string).transpose()?;
        self.conn().execute(
            "INSERT INTO usage_limits (runtime, windows, updated_at, plan) VALUES (?1, '[]', ?2, ?3)
             ON CONFLICT(runtime) DO UPDATE SET plan = excluded.plan",
            params![runtime, at, json],
        )?;
        Ok(())
    }

    /// All cached runtimes, by name.
    pub fn usage_list(&self) -> Result<Vec<UsageEntry>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT runtime, windows, updated_at, plan FROM usage_limits ORDER BY runtime")?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, Option<String>>(3)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (runtime, windows, updated_at, plan) = row?;
            // A corrupt row shows no windows instead of failing the whole list.
            let windows = serde_json::from_str(&windows).unwrap_or_else(|e| {
                tracing::warn!(runtime, "bad usage_limits row: {e}");
                Vec::new()
            });
            // Likewise a corrupt plan shows no plan.
            let plan = plan.and_then(|json| match serde_json::from_str::<Plan>(&json) {
                Ok(plan) => Some(plan),
                Err(e) => {
                    tracing::warn!(runtime, "bad usage_limits plan: {e}");
                    None
                }
            });
            out.push(UsageEntry {
                runtime,
                windows,
                updated_at,
                plan,
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
                    plan: None,
                },
                UsageEntry {
                    runtime: "codex".into(),
                    windows: vec![window("5h", 0.25)],
                    updated_at: 100,
                    plan: None,
                },
            ]
        );
    }

    fn plan(id: &str, label: &str) -> Plan {
        Plan {
            id: id.into(),
            label: label.into(),
        }
    }

    #[test]
    fn set_plan_creates_the_row_without_windows() {
        let s = Store::open_in_memory().unwrap();
        s.usage_set_plan("claude", Some(&plan("max_20x", "Max ×20")), 100)
            .unwrap();
        assert_eq!(
            s.usage_list().unwrap(),
            vec![UsageEntry {
                runtime: "claude".into(),
                windows: Vec::new(),
                updated_at: 100,
                plan: Some(plan("max_20x", "Max ×20")),
            }]
        );
    }

    #[test]
    fn set_usage_keeps_the_plan() {
        let s = Store::open_in_memory().unwrap();
        s.usage_set_plan("codex", Some(&plan("pro", "Pro")), 1).unwrap();
        s.usage_set("codex", &[window("5h", 0.3)], 2).unwrap();
        let list = s.usage_list().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].plan, Some(plan("pro", "Pro")));
        assert_eq!(list[0].windows, vec![window("5h", 0.3)]);
        assert_eq!(list[0].updated_at, 2);
    }

    #[test]
    fn set_plan_keeps_the_windows_and_their_time() {
        let s = Store::open_in_memory().unwrap();
        s.usage_set("claude", &[window("5h", 0.1)], 1).unwrap();
        s.usage_set_plan("claude", Some(&plan("pro", "Pro")), 5).unwrap();
        let list = s.usage_list().unwrap();
        assert_eq!(list[0].windows, vec![window("5h", 0.1)]);
        assert_eq!(list[0].plan, Some(plan("pro", "Pro")));
        assert_eq!(list[0].updated_at, 1, "the plan does not refresh the windows' time");
    }

    #[test]
    fn plan_round_trips_and_can_be_cleared() {
        let s = Store::open_in_memory().unwrap();
        s.usage_set_plan("claude", Some(&plan("max_5x", "Max ×5")), 1).unwrap();
        assert_eq!(s.usage_list().unwrap()[0].plan, Some(plan("max_5x", "Max ×5")));
        s.usage_set_plan("claude", Some(&plan("team", "Team")), 2).unwrap();
        assert_eq!(s.usage_list().unwrap()[0].plan, Some(plan("team", "Team")));
        s.usage_set_plan("claude", None, 3).unwrap();
        assert_eq!(s.usage_list().unwrap()[0].plan, None);
    }

    #[test]
    fn corrupt_plan_json_lists_no_plan() {
        let s = Store::open_in_memory().unwrap();
        s.conn()
            .execute(
                "INSERT INTO usage_limits (runtime, windows, updated_at, plan) VALUES ('claude', '[]', 5, '{not json')",
                [],
            )
            .unwrap();
        assert_eq!(
            s.usage_list().unwrap(),
            vec![UsageEntry {
                runtime: "claude".into(),
                windows: Vec::new(),
                updated_at: 5,
                plan: None,
            }]
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
                plan: None,
            }]
        );
    }
}
