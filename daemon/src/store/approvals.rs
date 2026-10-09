use super::{Store, new_id, now_ms};
use crate::event::Decision;
use anyhow::Result;
use rusqlite::{OptionalExtension, Row, ToSql, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalStatus {
    Pending,
    Resolved,
    /// Never answered: timed out, or the session died first.
    Expired,
    /// The runtime took the request back (its CLI cancelled it): nobody answered it.
    Withdrawn,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Approval {
    pub id: String,
    pub agent_id: String,
    pub call_id: String,
    pub tool: String,
    pub title: String,
    /// `{command?, diff?, input, key}`; `key` is the runtime's opaque key.
    pub payload: Value,
    pub status: ApprovalStatus,
    pub decision: Option<Decision>,
    pub created_at: i64,
    pub resolved_at: Option<i64>,
}

const COLS: &str = "id, agent_id, call_id, tool, title, payload, status, decision, created_at, resolved_at";

fn status_str(s: ApprovalStatus) -> &'static str {
    match s {
        ApprovalStatus::Pending => "pending",
        ApprovalStatus::Resolved => "resolved",
        ApprovalStatus::Expired => "expired",
        ApprovalStatus::Withdrawn => "withdrawn",
    }
}

/// Unknown values read from the DB count as `Expired`: such a row is no
/// longer pending and nobody answered it.
fn parse_status(s: &str) -> ApprovalStatus {
    match s {
        "pending" => ApprovalStatus::Pending,
        "resolved" => ApprovalStatus::Resolved,
        "withdrawn" => ApprovalStatus::Withdrawn,
        _ => ApprovalStatus::Expired,
    }
}

fn decision_str(d: Decision) -> &'static str {
    match d {
        Decision::Allow => "allow",
        Decision::Deny => "deny",
    }
}

/// Unknown values read from the DB become `None`.
fn parse_decision(s: &str) -> Option<Decision> {
    match s {
        "allow" => Some(Decision::Allow),
        "deny" => Some(Decision::Deny),
        _ => None,
    }
}

fn from_row(r: &Row) -> rusqlite::Result<Approval> {
    let payload: String = r.get(5)?;
    let status: String = r.get(6)?;
    let decision: Option<String> = r.get(7)?;
    Ok(Approval {
        id: r.get(0)?,
        agent_id: r.get(1)?,
        call_id: r.get(2)?,
        tool: r.get(3)?,
        title: r.get(4)?,
        // A corrupt payload must not break listing; the approval stays usable.
        payload: serde_json::from_str(&payload).unwrap_or(Value::Null),
        status: parse_status(&status),
        decision: decision.as_deref().and_then(parse_decision),
        created_at: r.get(8)?,
        resolved_at: r.get(9)?,
    })
}

impl Store {
    /// Insert a pending approval with a fresh id (`new_id()`), `created_at = now_ms()`.
    pub fn approval_create(
        &self,
        agent_id: &str,
        call_id: &str,
        tool: &str,
        title: &str,
        payload: Value,
    ) -> Result<Approval> {
        let a = Approval {
            id: new_id(),
            agent_id: agent_id.to_string(),
            call_id: call_id.to_string(),
            tool: tool.to_string(),
            title: title.to_string(),
            payload,
            status: ApprovalStatus::Pending,
            decision: None,
            created_at: now_ms(),
            resolved_at: None,
        };
        self.conn().execute(
            "INSERT INTO approvals (id, agent_id, call_id, tool, title, payload, status, decision, created_at, resolved_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
            params![
                a.id,
                a.agent_id,
                a.call_id,
                a.tool,
                a.title,
                a.payload.to_string(),
                status_str(a.status),
                a.decision.map(decision_str),
                a.created_at,
                a.resolved_at
            ],
        )?;
        Ok(a)
    }

    pub fn approval_get(&self, id: &str) -> Result<Option<Approval>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM approvals WHERE id = ?1"), [id], from_row)
            .optional()?)
    }

    /// Pending approvals, oldest first; all agents when `agent_id` is `None`.
    pub fn approval_list_pending(&self, agent_id: Option<&str>) -> Result<Vec<Approval>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM approvals
             WHERE status = 'pending' AND (?1 IS NULL OR agent_id = ?1)
             ORDER BY created_at, id"
        ))?;
        let rows = stmt.query_map([agent_id], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Pending → Resolved with `decision`, `resolved_at = now_ms()`.
    /// Returns `Ok(None)` if the approval does not exist or is not pending
    /// (so two devices answering at once: the second gets `None`).
    pub fn approval_resolve(&self, id: &str, decision: Decision) -> Result<Option<Approval>> {
        // The guard is released at the end of this statement, before
        // `approval_get` takes the lock again.
        let changed = self.conn().execute(
            "UPDATE approvals SET status='resolved', decision=?2, resolved_at=?3 WHERE id=?1 AND status='pending'",
            params![id, decision_str(decision), now_ms()],
        )?;
        if changed == 0 {
            return Ok(None);
        }
        self.approval_get(id)
    }

    /// Pending → Withdrawn, `resolved_at = now_ms()`: the runtime took the request back, so there is no
    /// decision. Returns `Ok(None)` if the approval is not pending.
    pub fn approval_withdraw(&self, id: &str) -> Result<Option<Approval>> {
        let changed = self.conn().execute(
            "UPDATE approvals SET status='withdrawn', resolved_at=?2 WHERE id=?1 AND status='pending'",
            params![id, now_ms()],
        )?;
        if changed == 0 {
            return Ok(None);
        }
        self.approval_get(id)
    }

    /// Pending → Expired for one agent (session died). Returns the expired rows.
    pub fn approval_expire_agent(&self, agent_id: &str) -> Result<Vec<Approval>> {
        self.expire_pending("agent_id = ?1", params![agent_id])
    }

    /// Pending → Expired where `created_at < before_ms`. Returns the expired rows.
    pub fn approval_expire_older_than(&self, before_ms: i64) -> Result<Vec<Approval>> {
        self.expire_pending("created_at < ?1", params![before_ms])
    }

    /// Selects pending rows matching `filter` and expires them in one
    /// transaction. `filter` is a fixed SQL fragment, never user input.
    fn expire_pending(&self, filter: &str, args: &[&dyn ToSql]) -> Result<Vec<Approval>> {
        let now = now_ms();
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let mut rows = {
            let mut stmt = tx.prepare(&format!(
                "SELECT {COLS} FROM approvals WHERE status = 'pending' AND {filter} ORDER BY created_at, id"
            ))?;
            let found: Vec<Approval> = stmt.query_map(args, from_row)?.collect::<rusqlite::Result<_>>()?;
            found
        };
        for a in &mut rows {
            tx.execute(
                "UPDATE approvals SET status='expired', resolved_at=?2 WHERE id=?1 AND status='pending'",
                params![a.id, now],
            )?;
            a.status = ApprovalStatus::Expired;
            a.resolved_at = Some(now);
        }
        tx.commit()?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn create(s: &Store, agent: &str, call: &str) -> Approval {
        s.approval_create(agent, call, "Bash", "git push", json!({"command": "git push"}))
            .unwrap()
    }

    fn set_created_at(s: &Store, id: &str, ts: i64) {
        s.conn()
            .execute("UPDATE approvals SET created_at = ?2 WHERE id = ?1", params![id, ts])
            .unwrap();
    }

    #[test]
    fn withdrawn_approval_is_closed_without_a_decision() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        let w = s.approval_withdraw(&a.id).unwrap().expect("pending, so withdrawn");
        assert_eq!(w.status, ApprovalStatus::Withdrawn);
        assert_eq!(w.decision, None);
        assert!(w.resolved_at.is_some());
        assert_eq!(
            s.approval_get(&a.id).unwrap().unwrap().status,
            ApprovalStatus::Withdrawn
        );
        assert!(s.approval_list_pending(None).unwrap().is_empty());
        // Closed once: a second withdrawal or an answer finds nothing pending.
        assert_eq!(s.approval_withdraw(&a.id).unwrap(), None);
        assert_eq!(s.approval_resolve(&a.id, Decision::Allow).unwrap(), None);
        assert_eq!(s.approval_withdraw("missing").unwrap(), None);
    }

    #[test]
    fn create_then_get_roundtrip() {
        let s = Store::open_in_memory().unwrap();
        let a = s
            .approval_create("agent-1", "call-1", "Bash", "git push", json!({"command": "git push"}))
            .unwrap();
        assert_eq!(a.status, ApprovalStatus::Pending);
        assert_eq!(a.decision, None);
        assert_eq!(a.resolved_at, None);
        let got = s.approval_get(&a.id).unwrap().unwrap();
        assert_eq!(got, a);
        assert_eq!(got.payload, json!({"command": "git push"}));
        assert_eq!(s.approval_get("missing").unwrap(), None);
    }

    #[test]
    fn list_pending_filters_by_agent_oldest_first() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        let b = create(&s, "agent-2", "c2");
        let c = create(&s, "agent-1", "c3");
        set_created_at(&s, &a.id, 100);
        set_created_at(&s, &b.id, 50);
        set_created_at(&s, &c.id, 200);

        let all: Vec<String> = s
            .approval_list_pending(None)
            .unwrap()
            .into_iter()
            .map(|x| x.id)
            .collect();
        assert_eq!(all, vec![b.id.clone(), a.id.clone(), c.id.clone()]);

        let one = s.approval_list_pending(Some("agent-1")).unwrap();
        let ids: Vec<&str> = one.iter().map(|x| x.id.as_str()).collect();
        assert_eq!(ids, vec![a.id.as_str(), c.id.as_str()]);
        assert!(s.approval_list_pending(Some("nobody")).unwrap().is_empty());
    }

    #[test]
    fn resolve_twice_second_is_none() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        let r = s.approval_resolve(&a.id, Decision::Allow).unwrap().unwrap();
        assert_eq!(r.status, ApprovalStatus::Resolved);
        assert_eq!(r.decision, Some(Decision::Allow));
        assert!(r.resolved_at.is_some());

        assert_eq!(s.approval_resolve(&a.id, Decision::Deny).unwrap(), None);
        let stored = s.approval_get(&a.id).unwrap().unwrap();
        assert_eq!(
            stored.decision,
            Some(Decision::Allow),
            "second answer must not overwrite"
        );
        assert!(s.approval_list_pending(None).unwrap().is_empty());
    }

    #[test]
    fn resolve_missing_is_none() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.approval_resolve("missing", Decision::Deny).unwrap(), None);
    }

    #[test]
    fn resolve_deny_is_stored_as_deny() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        let r = s.approval_resolve(&a.id, Decision::Deny).unwrap().unwrap();
        assert_eq!(r.decision, Some(Decision::Deny));
        assert_eq!(s.approval_get(&a.id).unwrap().unwrap().decision, Some(Decision::Deny));
    }

    #[test]
    fn expire_agent_touches_only_pending_of_that_agent() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        let b = create(&s, "agent-1", "c2");
        let other = create(&s, "agent-2", "c3");
        let done = create(&s, "agent-1", "c4");
        s.approval_resolve(&done.id, Decision::Allow).unwrap();

        let expired = s.approval_expire_agent("agent-1").unwrap();
        let mut ids: Vec<String> = expired.iter().map(|x| x.id.clone()).collect();
        ids.sort();
        let mut want = vec![a.id.clone(), b.id.clone()];
        want.sort();
        assert_eq!(ids, want);
        for x in &expired {
            assert_eq!(x.status, ApprovalStatus::Expired);
            assert!(x.resolved_at.is_some());
            assert_eq!(
                s.approval_get(&x.id).unwrap().unwrap(),
                *x,
                "returned rows match stored rows"
            );
        }

        let resolved = s.approval_get(&done.id).unwrap().unwrap();
        assert_eq!(resolved.status, ApprovalStatus::Resolved);
        assert_eq!(resolved.decision, Some(Decision::Allow));
        assert_eq!(
            s.approval_get(&other.id).unwrap().unwrap().status,
            ApprovalStatus::Pending
        );
    }

    #[test]
    fn expire_older_than_boundary_is_strict() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        set_created_at(&s, &a.id, 1000);

        // created_at == before_ms is NOT older than before_ms.
        assert!(s.approval_expire_older_than(1000).unwrap().is_empty());
        assert_eq!(s.approval_get(&a.id).unwrap().unwrap().status, ApprovalStatus::Pending);

        let expired = s.approval_expire_older_than(1001).unwrap();
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].id, a.id);
        assert_eq!(expired[0].status, ApprovalStatus::Expired);
    }

    #[test]
    fn expire_older_than_skips_resolved() {
        let s = Store::open_in_memory().unwrap();
        let old_resolved = create(&s, "agent-1", "c1");
        let old_pending = create(&s, "agent-1", "c2");
        set_created_at(&s, &old_resolved.id, 10);
        set_created_at(&s, &old_pending.id, 20);
        s.approval_resolve(&old_resolved.id, Decision::Deny).unwrap();

        let expired = s.approval_expire_older_than(100).unwrap();
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].id, old_pending.id);
        assert_eq!(
            s.approval_get(&old_resolved.id).unwrap().unwrap().status,
            ApprovalStatus::Resolved
        );
    }

    #[test]
    fn unknown_db_status_and_decision_fall_back() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        s.conn()
            .execute(
                "UPDATE approvals SET status = 'weird', decision = 'maybe' WHERE id = ?1",
                params![a.id],
            )
            .unwrap();
        let got = s.approval_get(&a.id).unwrap().unwrap();
        assert_eq!(got.status, ApprovalStatus::Expired);
        assert_eq!(got.decision, None);
    }

    #[test]
    fn invalid_payload_json_becomes_null() {
        let s = Store::open_in_memory().unwrap();
        let a = create(&s, "agent-1", "c1");
        s.conn()
            .execute("UPDATE approvals SET payload = 'not json' WHERE id = ?1", params![a.id])
            .unwrap();
        assert_eq!(s.approval_get(&a.id).unwrap().unwrap().payload, Value::Null);
    }
}
