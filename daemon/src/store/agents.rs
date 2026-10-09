use super::{ApprovalMode, Store, new_id, now_ms};
use crate::runtime::RuntimeKind;
use anyhow::{Result, anyhow, bail};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Agent {
    pub id: String,
    pub name: String,
    pub role: String,
    pub runtime: RuntimeKind,
    pub model: Option<String>,
    pub cwd: String,
    pub approval_mode: ApprovalMode,
    pub system_prompt: Option<String>,
    pub runtime_session_id: Option<String>,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewAgent {
    pub name: String,
    #[serde(default)]
    pub role: String,
    pub runtime: RuntimeKind,
    #[serde(default)]
    pub model: Option<String>,
    pub cwd: String,
    #[serde(default = "default_mode")]
    pub approval_mode: ApprovalMode,
    #[serde(default)]
    pub system_prompt: Option<String>,
}

fn default_mode() -> ApprovalMode {
    ApprovalMode::Risky
}

/// Fields to change; `None` leaves a field as is. For nullable fields,
/// `Some(None)` clears them.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct AgentPatch {
    pub name: Option<String>,
    pub role: Option<String>,
    pub model: Option<Option<String>>,
    pub cwd: Option<String>,
    pub approval_mode: Option<ApprovalMode>,
    pub system_prompt: Option<Option<String>>,
}

const COLS: &str =
    "id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at";

fn from_row(r: &Row) -> rusqlite::Result<Agent> {
    let runtime: String = r.get(3)?;
    let mode: String = r.get(6)?;
    Ok(Agent {
        id: r.get(0)?,
        name: r.get(1)?,
        role: r.get(2)?,
        runtime: RuntimeKind::parse(&runtime).unwrap_or(RuntimeKind::Api),
        model: r.get(4)?,
        cwd: r.get(5)?,
        approval_mode: ApprovalMode::parse(&mode).unwrap_or(ApprovalMode::Always),
        system_prompt: r.get(7)?,
        runtime_session_id: r.get(8)?,
        created_at: r.get(9)?,
        updated_at: r.get(10)?,
    })
}

/// Agent names are shown in the UI and used in `crew_send{to}`: 1–32 chars,
/// letters, digits, space, `-`, `_`.
pub fn validate_name(name: &str) -> Result<()> {
    let n = name.trim();
    if n.is_empty() || n.chars().count() > 32 {
        bail!("agent name must be 1–32 characters");
    }
    if !n
        .chars()
        .all(|c| c.is_alphanumeric() || c == ' ' || c == '-' || c == '_')
    {
        bail!("agent name may contain letters, digits, spaces, '-' and '_'");
    }
    Ok(())
}

impl Store {
    pub fn agent_create(&self, a: NewAgent) -> Result<Agent> {
        validate_name(&a.name)?;
        let now = now_ms();
        let agent = Agent {
            id: new_id(),
            name: a.name.trim().to_string(),
            role: a.role,
            runtime: a.runtime,
            model: a.model,
            cwd: a.cwd,
            approval_mode: a.approval_mode,
            system_prompt: a.system_prompt,
            runtime_session_id: None,
            created_at: now,
            updated_at: now,
        };
        let res = self.conn().execute(
            &format!("INSERT INTO agents ({COLS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)"),
            params![
                agent.id,
                agent.name,
                agent.role,
                agent.runtime.as_str(),
                agent.model,
                agent.cwd,
                agent.approval_mode.as_str(),
                agent.system_prompt,
                agent.runtime_session_id,
                agent.created_at,
                agent.updated_at
            ],
        );
        match res {
            Ok(_) => Ok(agent),
            Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
                Err(anyhow!("an agent named '{}' already exists", agent.name))
            }
            Err(e) => Err(e.into()),
        }
    }

    pub fn agent_get(&self, id: &str) -> Result<Option<Agent>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM agents WHERE id = ?1"), [id], from_row)
            .optional()?)
    }

    /// Case-insensitive lookup by name (for crew messages).
    pub fn agent_by_name(&self, name: &str) -> Result<Option<Agent>> {
        Ok(self
            .conn()
            .query_row(
                &format!("SELECT {COLS} FROM agents WHERE lower(name) = lower(?1)"),
                [name.trim()],
                from_row,
            )
            .optional()?)
    }

    pub fn agent_list(&self) -> Result<Vec<Agent>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!("SELECT {COLS} FROM agents ORDER BY created_at"))?;
        let rows = stmt.query_map([], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn agent_update(&self, id: &str, p: AgentPatch) -> Result<Agent> {
        let mut a = self.agent_get(id)?.ok_or_else(|| anyhow!("no agent {id}"))?;
        if let Some(n) = p.name {
            validate_name(&n)?;
            a.name = n.trim().to_string();
        }
        if let Some(v) = p.role {
            a.role = v;
        }
        if let Some(v) = p.model {
            a.model = v;
        }
        if let Some(v) = p.cwd {
            a.cwd = v;
        }
        if let Some(v) = p.approval_mode {
            a.approval_mode = v;
        }
        if let Some(v) = p.system_prompt {
            a.system_prompt = v;
        }
        a.updated_at = now_ms();
        let res = self.conn().execute(
            "UPDATE agents SET name=?2, role=?3, model=?4, cwd=?5, approval_mode=?6, system_prompt=?7, updated_at=?8 WHERE id=?1",
            params![a.id, a.name, a.role, a.model, a.cwd, a.approval_mode.as_str(), a.system_prompt, a.updated_at],
        );
        match res {
            Ok(_) => Ok(a),
            Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
                Err(anyhow!("an agent named '{}' already exists", a.name))
            }
            Err(e) => Err(e.into()),
        }
    }

    pub fn agent_set_session(&self, id: &str, session_id: Option<&str>) -> Result<()> {
        self.conn().execute(
            "UPDATE agents SET runtime_session_id=?2, updated_at=?3 WHERE id=?1",
            params![id, session_id, now_ms()],
        )?;
        Ok(())
    }

    /// Deletes the agent with its approvals, rules and schedules. Events stay
    /// (history), keyed by the old id.
    pub fn agent_delete(&self, id: &str) -> Result<bool> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let n = tx.execute("DELETE FROM agents WHERE id=?1", [id])?;
        tx.execute("DELETE FROM approvals WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM rules WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM schedules WHERE agent_id=?1", [id])?;
        tx.commit()?;
        Ok(n > 0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new(name: &str) -> NewAgent {
        NewAgent {
            name: name.into(),
            role: "builder".into(),
            runtime: RuntimeKind::Claude,
            model: None,
            cwd: "/tmp".into(),
            approval_mode: ApprovalMode::Risky,
            system_prompt: None,
        }
    }

    #[test]
    fn crud() {
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        assert_eq!(s.agent_get(&a.id).unwrap().unwrap(), a);
        assert_eq!(s.agent_by_name("forge").unwrap().unwrap().id, a.id);
        assert!(
            s.agent_create(new("Forge"))
                .unwrap_err()
                .to_string()
                .contains("already exists")
        );

        let b = s
            .agent_update(
                &a.id,
                AgentPatch {
                    model: Some(Some("opus".into())),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(b.model.as_deref(), Some("opus"));
        assert_eq!(b.name, "Forge");

        s.agent_set_session(&a.id, Some("sess-1")).unwrap();
        assert_eq!(
            s.agent_get(&a.id).unwrap().unwrap().runtime_session_id.as_deref(),
            Some("sess-1")
        );

        assert_eq!(s.agent_list().unwrap().len(), 1);
        assert!(s.agent_delete(&a.id).unwrap());
        assert!(!s.agent_delete(&a.id).unwrap());
        assert!(s.agent_get(&a.id).unwrap().is_none());
    }

    #[test]
    fn name_rules() {
        assert!(validate_name("Night Owl").is_ok());
        assert!(validate_name("Ёж_2-b").is_ok());
        assert!(validate_name("  ").is_err());
        assert!(validate_name("a/b").is_err());
        assert!(validate_name(&"x".repeat(33)).is_err());
    }
}
