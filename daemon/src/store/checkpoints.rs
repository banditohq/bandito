//! Points in an agent's folder history (see crate::checkpoint): one row per
//! snapshot, pointing at a commit of the agent's shadow repository.

use super::{Store, new_id, now_ms};
use anyhow::{Result, bail};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CheckpointKind {
    /// Before a turn started.
    Before,
    /// After a turn ended.
    After,
    /// Before a restore: restoring it undoes that restore.
    Restore,
}

impl CheckpointKind {
    pub fn as_str(self) -> &'static str {
        match self {
            CheckpointKind::Before => "before",
            CheckpointKind::After => "after",
            CheckpointKind::Restore => "restore",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "before" => CheckpointKind::Before,
            "after" => CheckpointKind::After,
            "restore" => CheckpointKind::Restore,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Checkpoint {
    pub id: String,
    pub agent_id: String,
    /// Commit of the agent's shadow repository.
    pub sha: String,
    pub label: String,
    pub kind: CheckpointKind,
    pub turn_id: Option<String>,
    pub created_at: i64,
}

const COLS: &str = "id, agent_id, sha, label, kind, turn_id, created_at";

fn from_row(r: &Row) -> rusqlite::Result<Checkpoint> {
    let kind: String = r.get(4)?;
    Ok(Checkpoint {
        id: r.get(0)?,
        agent_id: r.get(1)?,
        sha: r.get(2)?,
        label: r.get(3)?,
        // Only this daemon writes the table; an unknown kind would be a bug, so it shows as `before`.
        kind: CheckpointKind::parse(&kind).unwrap_or(CheckpointKind::Before),
        turn_id: r.get(5)?,
        created_at: r.get(6)?,
    })
}

impl Store {
    pub fn checkpoint_add(
        &self,
        agent_id: &str,
        sha: &str,
        label: &str,
        kind: CheckpointKind,
        turn_id: Option<&str>,
    ) -> Result<Checkpoint> {
        if sha.is_empty() {
            bail!("checkpoint without a commit");
        }
        let cp = Checkpoint {
            id: new_id(),
            agent_id: agent_id.to_string(),
            sha: sha.to_string(),
            label: label.to_string(),
            kind,
            turn_id: turn_id.map(str::to_string),
            created_at: now_ms(),
        };
        self.conn().execute(
            &format!("INSERT INTO checkpoints ({COLS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)"),
            params![
                cp.id,
                cp.agent_id,
                cp.sha,
                cp.label,
                cp.kind.as_str(),
                cp.turn_id,
                cp.created_at
            ],
        )?;
        Ok(cp)
    }

    /// One agent's checkpoints, newest first.
    pub fn checkpoint_list(&self, agent_id: &str, limit: u32) -> Result<Vec<Checkpoint>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {COLS} FROM checkpoints WHERE agent_id = ?1 ORDER BY created_at DESC, rowid DESC LIMIT ?2"
        ))?;
        let rows = stmt.query_map(params![agent_id, limit.clamp(1, 1000)], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// The newest checkpoint of one kind of one agent.
    pub fn checkpoint_latest(&self, agent_id: &str, kind: CheckpointKind) -> Result<Option<Checkpoint>> {
        Ok(self
            .conn()
            .query_row(
                &format!(
                    "SELECT {COLS} FROM checkpoints WHERE agent_id = ?1 AND kind = ?2
                     ORDER BY created_at DESC, rowid DESC LIMIT 1"
                ),
                params![agent_id, kind.as_str()],
                from_row,
            )
            .optional()?)
    }

    pub fn checkpoint_get(&self, id: &str) -> Result<Option<Checkpoint>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM checkpoints WHERE id = ?1"), [id], from_row)
            .optional()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_list_get_latest() {
        let s = Store::open_in_memory().unwrap();
        let a = s
            .checkpoint_add("agent-a", "aaa", "before: hi", CheckpointKind::Before, Some("t1"))
            .unwrap();
        let b = s
            .checkpoint_add("agent-a", "bbb", "after", CheckpointKind::After, Some("t1"))
            .unwrap();
        s.checkpoint_add("agent-b", "ccc", "before: other", CheckpointKind::Before, None)
            .unwrap();

        let list = s.checkpoint_list("agent-a", 50).unwrap();
        assert_eq!(
            list.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(),
            [b.id.as_str(), a.id.as_str()]
        );
        assert_eq!(list[0].kind, CheckpointKind::After);
        assert_eq!(list[1].turn_id.as_deref(), Some("t1"));
        assert_eq!(s.checkpoint_list("agent-a", 1).unwrap().len(), 1);

        assert_eq!(s.checkpoint_get(&a.id).unwrap(), Some(a.clone()));
        assert_eq!(s.checkpoint_get("nope").unwrap(), None);
        assert_eq!(
            s.checkpoint_latest("agent-a", CheckpointKind::Before)
                .unwrap()
                .map(|c| c.sha),
            Some("aaa".to_string())
        );
        assert_eq!(s.checkpoint_latest("agent-a", CheckpointKind::Restore).unwrap(), None);
    }

    #[test]
    fn deleting_an_agent_deletes_its_checkpoints() {
        use crate::runtime::RuntimeKind;
        use crate::store::{ApprovalMode, MemoryMode, NewAgent};
        let s = Store::open_in_memory().unwrap();
        let agent = s
            .agent_create(NewAgent {
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        s.checkpoint_add(&agent.id, "aaa", "before", CheckpointKind::Before, None)
            .unwrap();
        assert!(s.agent_delete(&agent.id).unwrap());
        assert!(s.checkpoint_list(&agent.id, 50).unwrap().is_empty());
    }
}
