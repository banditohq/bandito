use super::{Store, new_id, now_ms};
use anyhow::{Result, bail};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Schedule {
    pub id: String,
    pub agent_id: String,
    /// 5-field cron (`min hour dom mon dow`).
    pub cron: String,
    /// IANA zone name, e.g. `Asia/Tokyo`, or `UTC`.
    pub tz: String,
    pub prompt: String,
    pub enabled: bool,
    pub last_run_at: Option<i64>,
    pub next_run_at: Option<i64>,
    pub created_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewSchedule {
    pub agent_id: String,
    pub cron: String,
    #[serde(default = "utc")]
    pub tz: String,
    pub prompt: String,
    #[serde(default = "yes")]
    pub enabled: bool,
}

fn utc() -> String {
    "UTC".into()
}
fn yes() -> bool {
    true
}

/// What [`Store::schedule_update`] does with `next_run_at`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NextRun {
    /// Leave the stored value.
    Keep,
    Set(Option<i64>),
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SchedulePatch {
    pub cron: Option<String>,
    pub tz: Option<String>,
    pub prompt: Option<String>,
    pub enabled: Option<bool>,
}

const COLS: &str = "id, agent_id, cron, tz, prompt, enabled, last_run_at, next_run_at, created_at";

fn from_row(r: &Row) -> rusqlite::Result<Schedule> {
    let enabled: i64 = r.get(5)?;
    Ok(Schedule {
        id: r.get(0)?,
        agent_id: r.get(1)?,
        cron: r.get(2)?,
        tz: r.get(3)?,
        prompt: r.get(4)?,
        enabled: enabled != 0,
        last_run_at: r.get(6)?,
        next_run_at: r.get(7)?,
        created_at: r.get(8)?,
    })
}

impl Store {
    /// Insert; `next_run_at` is given by the caller (the scheduler computes it).
    pub fn schedule_create(&self, s: NewSchedule, next_run_at: Option<i64>) -> Result<Schedule> {
        let sch = Schedule {
            id: new_id(),
            agent_id: s.agent_id,
            cron: s.cron,
            tz: s.tz,
            prompt: s.prompt,
            enabled: s.enabled,
            last_run_at: None,
            next_run_at,
            created_at: now_ms(),
        };
        self.conn().execute(
            "INSERT INTO schedules (id, agent_id, cron, tz, prompt, enabled, last_run_at, next_run_at, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                sch.id,
                sch.agent_id,
                sch.cron,
                sch.tz,
                sch.prompt,
                i64::from(sch.enabled),
                sch.last_run_at,
                sch.next_run_at,
                sch.created_at
            ],
        )?;
        Ok(sch)
    }

    pub fn schedule_get(&self, id: &str) -> Result<Option<Schedule>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM schedules WHERE id = ?1"), [id], from_row)
            .optional()?)
    }

    /// All schedules, or one agent's; ordered by `created_at`.
    pub fn schedule_list(&self, agent_id: Option<&str>) -> Result<Vec<Schedule>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM schedules WHERE (?1 IS NULL OR agent_id = ?1) ORDER BY created_at, id"
        ))?;
        let rows = stmt.query_map([agent_id], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Apply the patch in one transaction. `next` either sets `next_run_at` or
    /// leaves the stored value alone, so an edit can't undo a concurrent claim.
    /// Error if missing.
    pub fn schedule_update(&self, id: &str, p: SchedulePatch, next: NextRun) -> Result<Schedule> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let Some(mut s) = tx
            .query_row(&format!("SELECT {COLS} FROM schedules WHERE id = ?1"), [id], from_row)
            .optional()?
        else {
            bail!("no schedule {id}");
        };
        if let Some(v) = p.cron {
            s.cron = v;
        }
        if let Some(v) = p.tz {
            s.tz = v;
        }
        if let Some(v) = p.prompt {
            s.prompt = v;
        }
        if let Some(v) = p.enabled {
            s.enabled = v;
        }
        if let NextRun::Set(v) = next {
            s.next_run_at = v;
        }
        tx.execute(
            "UPDATE schedules SET cron = ?2, tz = ?3, prompt = ?4, enabled = ?5, next_run_at = ?6 WHERE id = ?1",
            params![s.id, s.cron, s.tz, s.prompt, i64::from(s.enabled), s.next_run_at],
        )?;
        tx.commit()?;
        Ok(s)
    }

    /// Record a manual run: only `last_run_at` changes.
    pub fn schedule_mark_ran(&self, id: &str, ran_at: i64) -> Result<()> {
        self.conn().execute(
            "UPDATE schedules SET last_run_at = ?2 WHERE id = ?1",
            params![id, ran_at],
        )?;
        Ok(())
    }

    /// Record a run: `last_run_at = ran_at`, `next_run_at = next`.
    pub fn schedule_mark_run(&self, id: &str, ran_at: i64, next: Option<i64>) -> Result<()> {
        self.conn().execute(
            "UPDATE schedules SET last_run_at = ?2, next_run_at = ?3 WHERE id = ?1",
            params![id, ran_at, next],
        )?;
        Ok(())
    }

    /// Claim a due run (compare-and-set). Succeeds only if the schedule is still enabled and
    /// its `next_run_at` is still `due_at`; then records `last_run_at = ran_at`, `next_run_at = next`.
    /// `false` means the schedule was changed or disabled since it was read, so nothing is recorded.
    pub fn schedule_claim(&self, id: &str, due_at: i64, ran_at: i64, next: Option<i64>) -> Result<bool> {
        let n = self.conn().execute(
            "UPDATE schedules SET last_run_at = ?3, next_run_at = ?4
             WHERE id = ?1 AND enabled = 1 AND next_run_at = ?2",
            params![id, due_at, ran_at, next],
        )?;
        Ok(n == 1)
    }

    /// Move a due run that is skipped as missed (compare-and-set on `next_run_at`).
    /// `last_run_at` is not touched. `false` if `next_run_at` is no longer `due_at`.
    pub fn schedule_reschedule(&self, id: &str, due_at: i64, next: Option<i64>) -> Result<bool> {
        let n = self.conn().execute(
            "UPDATE schedules SET next_run_at = ?3 WHERE id = ?1 AND next_run_at = ?2",
            params![id, due_at, next],
        )?;
        Ok(n == 1)
    }

    /// Enabled schedules with `next_run_at <= now`, ordered by `next_run_at`.
    pub fn schedule_due(&self, now: i64) -> Result<Vec<Schedule>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM schedules WHERE enabled = 1 AND next_run_at <= ?1 ORDER BY next_run_at, id"
        ))?;
        let rows = stmt.query_map([now], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn schedule_delete(&self, id: &str) -> Result<bool> {
        let n = self.conn().execute("DELETE FROM schedules WHERE id = ?1", [id])?;
        Ok(n > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new(agent: &str) -> NewSchedule {
        NewSchedule {
            agent_id: agent.into(),
            cron: "0 9 * * *".into(),
            tz: "UTC".into(),
            prompt: "report".into(),
            enabled: true,
        }
    }

    #[test]
    fn mark_ran_touches_only_last_run() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(5000)).unwrap();
        s.schedule_mark_ran(&a.id, 42).unwrap();
        let b = s.schedule_get(&a.id).unwrap().unwrap();
        assert_eq!(b.last_run_at, Some(42));
        assert_eq!(b.next_run_at, Some(5000));
    }

    #[test]
    fn create_get_and_list_by_agent() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(1000)).unwrap();
        assert_eq!(a.last_run_at, None);
        assert_eq!(a.next_run_at, Some(1000));
        assert!(a.enabled);
        assert_eq!(s.schedule_get(&a.id).unwrap(), Some(a.clone()));
        assert_eq!(s.schedule_get("missing").unwrap(), None);

        let b = s.schedule_create(new("agent-2"), None).unwrap();
        assert_eq!(s.schedule_list(None).unwrap().len(), 2);
        assert_eq!(s.schedule_list(Some("agent-1")).unwrap(), vec![a]);
        assert_eq!(s.schedule_list(Some("agent-2")).unwrap(), vec![b]);
    }

    #[test]
    fn update_changes_only_given_fields() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(1000)).unwrap();
        let patch = SchedulePatch {
            cron: Some("*/5 * * * *".into()),
            tz: Some("Asia/Tokyo".into()),
            prompt: Some("new prompt".into()),
            enabled: Some(false),
        };
        let b = s.schedule_update(&a.id, patch, NextRun::Set(Some(2000))).unwrap();
        assert_eq!(b.cron, "*/5 * * * *");
        assert_eq!(b.tz, "Asia/Tokyo");
        assert_eq!(b.prompt, "new prompt");
        assert!(!b.enabled);
        assert_eq!(b.next_run_at, Some(2000));
        assert_eq!(b.agent_id, a.agent_id);
        assert_eq!(b.created_at, a.created_at);
        assert_eq!(b.last_run_at, a.last_run_at);
        assert_eq!(s.schedule_get(&a.id).unwrap(), Some(b));

        let c = s
            .schedule_update(
                &a.id,
                SchedulePatch {
                    prompt: Some("only prompt".into()),
                    ..Default::default()
                },
                NextRun::Keep,
            )
            .unwrap();
        assert_eq!(c.next_run_at, Some(2000), "Keep leaves next_run_at alone");
        assert_eq!(c.cron, "*/5 * * * *");
        assert_eq!(c.tz, "Asia/Tokyo");
        assert!(!c.enabled);
        assert_eq!(c.prompt, "only prompt");
    }

    #[test]
    fn update_sets_next_run_as_given_even_to_none() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(1000)).unwrap();
        let b = s
            .schedule_update(&a.id, SchedulePatch::default(), NextRun::Set(None))
            .unwrap();
        assert_eq!(b.next_run_at, None);
        assert_eq!(s.schedule_get(&a.id).unwrap().unwrap().next_run_at, None);
    }

    #[test]
    fn update_missing_is_err() {
        let s = Store::open_in_memory().unwrap();
        let err = s
            .schedule_update("missing", SchedulePatch::default(), NextRun::Set(None))
            .unwrap_err();
        assert!(err.to_string().contains("no schedule missing"));
    }

    #[test]
    fn due_skips_disabled_and_unscheduled() {
        let s = Store::open_in_memory().unwrap();
        let on = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        let off = s
            .schedule_create(
                NewSchedule {
                    enabled: false,
                    ..new("agent-1")
                },
                Some(100),
            )
            .unwrap();
        let none = s.schedule_create(new("agent-1"), None).unwrap();
        assert!(!off.enabled);
        assert_eq!(none.next_run_at, None);

        let due = s.schedule_due(100).unwrap();
        assert_eq!(due, vec![on]);
    }

    #[test]
    fn due_includes_equal_now_and_orders_by_next_run() {
        let s = Store::open_in_memory().unwrap();
        // Created in the "wrong" order on purpose: ordering must come from next_run_at.
        let exact = s.schedule_create(new("agent-1"), Some(200)).unwrap();
        let early = s.schedule_create(new("agent-1"), Some(50)).unwrap();
        let _late = s.schedule_create(new("agent-1"), Some(300)).unwrap();
        let _future = s.schedule_create(new("agent-1"), Some(201)).unwrap();

        let due = s.schedule_due(200).unwrap();
        assert_eq!(due, vec![early, exact]);
    }

    #[test]
    fn mark_run_updates_last_and_next() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        s.schedule_mark_run(&a.id, 105, Some(500)).unwrap();
        let b = s.schedule_get(&a.id).unwrap().unwrap();
        assert_eq!(b.last_run_at, Some(105));
        assert_eq!(b.next_run_at, Some(500));
        assert!(s.schedule_due(100).unwrap().is_empty());
        assert_eq!(s.schedule_due(500).unwrap().len(), 1);
    }

    #[test]
    fn delete_true_then_false() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        assert!(s.schedule_delete(&a.id).unwrap());
        assert!(!s.schedule_delete(&a.id).unwrap());
        assert_eq!(s.schedule_get(&a.id).unwrap(), None);
    }

    #[test]
    fn claim_records_run_once_for_the_due_value() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        assert!(s.schedule_claim(&a.id, 100, 105, Some(500)).unwrap());
        let b = s.schedule_get(&a.id).unwrap().unwrap();
        assert_eq!(b.last_run_at, Some(105));
        assert_eq!(b.next_run_at, Some(500));
        // The same due value is gone now: a second claim (same tick or a racing one) loses.
        assert!(!s.schedule_claim(&a.id, 100, 106, Some(600)).unwrap());
        assert_eq!(s.schedule_get(&a.id).unwrap(), Some(b));
    }

    #[test]
    fn claim_is_false_when_disabled() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        let patch = SchedulePatch {
            enabled: Some(false),
            ..Default::default()
        };
        s.schedule_update(&a.id, patch, NextRun::Set(Some(100))).unwrap();
        assert!(!s.schedule_claim(&a.id, 100, 105, Some(500)).unwrap());
        let b = s.schedule_get(&a.id).unwrap().unwrap();
        assert_eq!(b.last_run_at, None);
        assert_eq!(b.next_run_at, Some(100));
    }

    #[test]
    fn claim_is_false_when_next_run_changed() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        let patch = SchedulePatch {
            cron: Some("*/5 * * * *".into()),
            ..Default::default()
        };
        s.schedule_update(&a.id, patch, NextRun::Set(Some(900))).unwrap();
        assert!(!s.schedule_claim(&a.id, 100, 105, Some(500)).unwrap());
        assert_eq!(s.schedule_get(&a.id).unwrap().unwrap().next_run_at, Some(900));
        assert!(!s.schedule_claim("missing", 100, 105, Some(500)).unwrap());
    }

    #[test]
    fn reschedule_moves_next_and_keeps_last_run() {
        let s = Store::open_in_memory().unwrap();
        let a = s.schedule_create(new("agent-1"), Some(100)).unwrap();
        assert!(s.schedule_reschedule(&a.id, 100, Some(500)).unwrap());
        let b = s.schedule_get(&a.id).unwrap().unwrap();
        assert_eq!(b.next_run_at, Some(500));
        assert_eq!(b.last_run_at, None);
        // Stale due value: no longer matches, nothing changes.
        assert!(!s.schedule_reschedule(&a.id, 100, Some(900)).unwrap());
        assert_eq!(s.schedule_get(&a.id).unwrap().unwrap().next_run_at, Some(500));
    }
}
