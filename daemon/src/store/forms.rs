use super::{Store, new_id, now_ms};
use anyhow::Result;
use rusqlite::{OptionalExtension, Row, ToSql, params};
use serde_json::Value;

/// Where a form stands: waiting for the human, answered, or closed without an answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormStatus {
    Pending,
    Submitted,
    Rejected,
    Replied,
    Expired,
}

impl FormStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            FormStatus::Pending => "pending",
            FormStatus::Submitted => "submitted",
            FormStatus::Rejected => "rejected",
            FormStatus::Replied => "replied",
            FormStatus::Expired => "expired",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(FormStatus::Pending),
            "submitted" => Some(FormStatus::Submitted),
            "rejected" => Some(FormStatus::Rejected),
            "replied" => Some(FormStatus::Replied),
            "expired" => Some(FormStatus::Expired),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Form {
    pub id: String,
    pub agent_id: String,
    /// The checked spec (see `forms::FormSpec`).
    pub spec: Value,
    pub status: FormStatus,
    /// `{action, values?, comment?}`, once answered.
    pub answer: Option<Value>,
    pub created_at: i64,
    pub answered_at: Option<i64>,
}

const COLS: &str = "id, agent_id, spec, status, answer, created_at, answered_at";

fn from_row(r: &Row) -> rusqlite::Result<Form> {
    let spec: String = r.get(2)?;
    let status: String = r.get(3)?;
    let answer: Option<String> = r.get(4)?;
    Ok(Form {
        id: r.get(0)?,
        agent_id: r.get(1)?,
        // A corrupt spec must not break listing; the form shows as it can.
        spec: serde_json::from_str(&spec).unwrap_or(Value::Null),
        // Unknown statuses read from the DB count as expired: nobody answered them.
        status: FormStatus::parse(&status).unwrap_or(FormStatus::Expired),
        answer: answer.and_then(|a| serde_json::from_str(&a).ok()),
        created_at: r.get(5)?,
        answered_at: r.get(6)?,
    })
}

impl Store {
    /// Insert a pending form with a fresh id, `created_at = now_ms()`.
    pub fn form_create(&self, agent_id: &str, spec: &Value) -> Result<Form> {
        let form = Form {
            id: new_id(),
            agent_id: agent_id.to_string(),
            spec: spec.clone(),
            status: FormStatus::Pending,
            answer: None,
            created_at: now_ms(),
            answered_at: None,
        };
        self.conn().execute(
            "INSERT INTO forms (id, agent_id, spec, status, answer, created_at, answered_at)
             VALUES (?1, ?2, ?3, ?4, NULL, ?5, NULL)",
            params![
                form.id,
                form.agent_id,
                form.spec.to_string(),
                form.status.as_str(),
                form.created_at
            ],
        )?;
        Ok(form)
    }

    pub fn form_get(&self, id: &str) -> Result<Option<Form>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM forms WHERE id = ?1"), [id], from_row)
            .optional()?)
    }

    /// Forms, newest first; filtered by agent and by status when given. Each filter is a condition of its own (not
    /// `? IS NULL OR`), so the planner can use `forms_agent_status` or `forms_status`.
    pub fn form_list(&self, agent_id: Option<&str>, status: Option<FormStatus>) -> Result<Vec<Form>> {
        let mut conditions = Vec::new();
        let mut args: Vec<String> = Vec::new();
        if let Some(agent) = agent_id {
            conditions.push("agent_id = ?");
            args.push(agent.to_string());
        }
        if let Some(status) = status {
            conditions.push("status = ?");
            args.push(status.as_str().to_string());
        }
        let mut sql = format!("SELECT {COLS} FROM forms");
        if !conditions.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&conditions.join(" AND "));
        }
        sql.push_str(" ORDER BY created_at DESC, id DESC");
        let conn = self.conn();
        let mut stmt = conn.prepare(&sql)?;
        let rows = stmt.query_map(rusqlite::params_from_iter(args), from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Pending → `status` with `answer`, `answered_at = now_ms()`. `Ok(None)` if the form does not exist or is
    /// not pending (a second answer gets `None`).
    pub fn form_answer(&self, id: &str, status: FormStatus, answer: &Value) -> Result<Option<Form>> {
        // The guard is released at the end of this statement, before `form_get` takes the lock again.
        let changed = self.conn().execute(
            "UPDATE forms SET status = ?2, answer = ?3, answered_at = ?4 WHERE id = ?1 AND status = 'pending'",
            params![id, status.as_str(), answer.to_string(), now_ms()],
        )?;
        if changed == 0 {
            return Ok(None);
        }
        self.form_get(id)
    }

    /// Pending → Expired for one agent (its turn was cancelled, paused or deleted). Returns the expired forms.
    pub fn form_expire_agent(&self, agent_id: &str) -> Result<Vec<Form>> {
        self.expire_forms("agent_id = ?1", params![agent_id])
    }

    /// Pending → Expired for every form (the daemon restarted: nobody can answer them now).
    pub fn form_expire_all(&self) -> Result<Vec<Form>> {
        self.expire_forms("1 = 1", params![])
    }

    /// Selects pending forms matching `filter` and expires them in one transaction. `filter` is a fixed SQL
    /// fragment, never user input.
    fn expire_forms(&self, filter: &str, args: &[&dyn ToSql]) -> Result<Vec<Form>> {
        let now = now_ms();
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let mut rows: Vec<Form> = {
            let mut stmt = tx.prepare(&format!(
                "SELECT {COLS} FROM forms WHERE status = 'pending' AND {filter} ORDER BY created_at, id"
            ))?;
            stmt.query_map(args, from_row)?.collect::<rusqlite::Result<_>>()?
        };
        for f in &mut rows {
            tx.execute(
                "UPDATE forms SET status = 'expired', answered_at = ?2 WHERE id = ?1 AND status = 'pending'",
                params![f.id, now],
            )?;
            f.status = FormStatus::Expired;
            f.answered_at = Some(now);
        }
        tx.commit()?;
        Ok(rows)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spec() -> Value {
        json!({ "title": "Hi", "kind": "question", "fields": [{ "id": "a", "label": "A", "type": "text" }] })
    }

    #[test]
    fn a_form_is_created_pending_and_read_back() {
        let s = Store::open_in_memory().unwrap();
        let f = s.form_create("agent-a", &spec()).unwrap();
        let got = s.form_get(&f.id).unwrap().unwrap();
        assert_eq!(got.status, FormStatus::Pending);
        assert_eq!(got.spec, spec());
        assert_eq!(got.answer, None);
        assert_eq!(got.answered_at, None);
    }

    #[test]
    fn only_the_first_answer_counts() {
        let s = Store::open_in_memory().unwrap();
        let f = s.form_create("agent-a", &spec()).unwrap();
        let answer = json!({ "action": "submit", "values": { "a": "x" } });
        let done = s.form_answer(&f.id, FormStatus::Submitted, &answer).unwrap().unwrap();
        assert_eq!(done.status, FormStatus::Submitted);
        assert_eq!(done.answer, Some(answer));
        assert!(done.answered_at.is_some());
        assert!(
            s.form_answer(&f.id, FormStatus::Rejected, &json!({"action": "reject"}))
                .unwrap()
                .is_none()
        );
        assert!(
            s.form_answer("missing", FormStatus::Rejected, &json!({}))
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn expiry_closes_only_pending_forms_of_the_agent() {
        let s = Store::open_in_memory().unwrap();
        let mine = s.form_create("agent-a", &spec()).unwrap();
        let done = s.form_create("agent-a", &spec()).unwrap();
        s.form_answer(&done.id, FormStatus::Rejected, &json!({"action": "reject"}))
            .unwrap();
        let other = s.form_create("agent-b", &spec()).unwrap();
        let expired = s.form_expire_agent("agent-a").unwrap();
        assert_eq!(
            expired.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(),
            vec![mine.id.as_str()]
        );
        assert_eq!(s.form_get(&mine.id).unwrap().unwrap().status, FormStatus::Expired);
        assert_eq!(s.form_get(&done.id).unwrap().unwrap().status, FormStatus::Rejected);
        assert_eq!(s.form_get(&other.id).unwrap().unwrap().status, FormStatus::Pending);
        assert_eq!(s.form_expire_all().unwrap().len(), 1);
    }

    #[test]
    fn list_filters_by_agent_and_status() {
        let s = Store::open_in_memory().unwrap();
        let a = s.form_create("agent-a", &spec()).unwrap();
        s.form_create("agent-b", &spec()).unwrap();
        assert_eq!(s.form_list(None, None).unwrap().len(), 2);
        assert_eq!(s.form_list(Some("agent-a"), None).unwrap().len(), 1);
        assert_eq!(s.form_list(None, Some(FormStatus::Pending)).unwrap().len(), 2);
        s.form_answer(&a.id, FormStatus::Submitted, &json!({"action": "submit", "values": {}}))
            .unwrap();
        assert_eq!(s.form_list(None, Some(FormStatus::Pending)).unwrap().len(), 1);
        assert_eq!(s.form_list(None, Some(FormStatus::Submitted)).unwrap()[0].id, a.id);
    }
}
