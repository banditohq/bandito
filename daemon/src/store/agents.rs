use super::{ApprovalMode, Effort, MemoryMode, SHARED_WORKSPACE, Store, new_id, now_ms};
use crate::runtime::RuntimeKind;
use crate::workspace::WorkspaceError;
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
    pub effort: Option<Effort>,
    pub memory_mode: MemoryMode,
    /// Tokens; `None` = `DEFAULT_CONTEXT_BUDGET`. Used by `smart` memory.
    pub context_budget: Option<u32>,
    /// The agent's own folder for memory and files (absolute path on the server).
    pub home_dir: Option<String>,
    /// Size of the current chapter's context after the last turn, in tokens.
    pub context_tokens: u64,
    /// Chapter number of the current session, from 1.
    pub chapter: u32,
    pub last_turn_at: Option<i64>,
    /// The workspace the agent's CLI runs in (see docs/ARCHITECTURE.md#workspaces).
    pub workspace_id: String,
    /// The runtime used when the primary one is out of usage. `None`: no fallback.
    pub fallback_runtime: Option<RuntimeKind>,
    pub fallback_model: Option<String>,
    /// The runtime the agent runs on now, when it is not the primary one (see docs/ARCHITECTURE.md#fallback-subscription).
    /// `None` means the primary `runtime`.
    pub active_runtime: Option<RuntimeKind>,
    /// A paused agent takes messages into its history but starts no session, and its scheduled
    /// runs are skipped (see docs/ARCHITECTURE.md#pause).
    pub paused: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NewAgent {
    pub name: String,
    #[serde(default)]
    pub role: String,
    pub runtime: RuntimeKind,
    #[serde(default)]
    pub model: Option<String>,
    /// Where the CLI runs. Empty: the agent's own folder (set by `agents.create` once it exists).
    #[serde(default)]
    pub cwd: String,
    #[serde(default = "default_mode")]
    pub approval_mode: ApprovalMode,
    #[serde(default)]
    pub system_prompt: Option<String>,
    #[serde(default)]
    pub effort: Option<Effort>,
    #[serde(default = "default_memory")]
    pub memory_mode: MemoryMode,
    #[serde(default)]
    pub context_budget: Option<u32>,
    #[serde(default)]
    pub fallback_runtime: Option<RuntimeKind>,
    #[serde(default)]
    pub fallback_model: Option<String>,
}

fn default_memory() -> MemoryMode {
    MemoryMode::Smart
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
    pub effort: Option<Option<Effort>>,
    pub memory_mode: Option<MemoryMode>,
    pub context_budget: Option<Option<u32>>,
    /// Moves the agent to another workspace. The next session starts a new chapter.
    pub workspace_id: Option<String>,
    pub runtime: Option<RuntimeKind>,
    pub fallback_runtime: Option<Option<RuntimeKind>>,
    pub fallback_model: Option<Option<String>>,
}

const COLS: &str = "id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at, effort, memory_mode, context_budget, home_dir, context_tokens, chapter, last_turn_at, fallback_runtime, fallback_model, active_runtime, workspace_id, paused";

fn runtime_column(r: &Row, i: usize) -> rusqlite::Result<Option<RuntimeKind>> {
    Ok(r.get::<_, Option<String>>(i)?.as_deref().and_then(RuntimeKind::parse))
}

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
        effort: r.get::<_, Option<String>>(11)?.as_deref().and_then(Effort::parse),
        memory_mode: MemoryMode::parse(&r.get::<_, String>(12)?).unwrap_or(MemoryMode::Smart),
        context_budget: r.get::<_, Option<i64>>(13)?.map(|v| v.clamp(0, u32::MAX as i64) as u32),
        home_dir: r.get(14)?,
        context_tokens: r.get::<_, i64>(15)?.max(0) as u64,
        chapter: r.get::<_, i64>(16)?.clamp(1, u32::MAX as i64) as u32,
        last_turn_at: r.get(17)?,
        fallback_runtime: runtime_column(r, 18)?,
        fallback_model: r.get(19)?,
        active_runtime: runtime_column(r, 20)?,
        workspace_id: r.get(21)?,
        paused: r.get(22)?,
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
        self.agent_create_in(a, SHARED_WORKSPACE)
    }

    /// Creates an agent that runs in the given workspace. The workspace must exist.
    pub fn agent_create_in(&self, a: NewAgent, workspace_id: &str) -> Result<Agent> {
        validate_name(&a.name)?;
        if self.workspace_get(workspace_id)?.is_none() {
            return Err(WorkspaceError::NotFound(workspace_id.to_string()).into());
        }
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
            effort: a.effort,
            memory_mode: a.memory_mode,
            context_budget: a.context_budget,
            home_dir: None,
            context_tokens: 0,
            chapter: 1,
            last_turn_at: None,
            fallback_runtime: a.fallback_runtime,
            fallback_model: a.fallback_model,
            active_runtime: None,
            workspace_id: workspace_id.to_string(),
            paused: false,
        };
        let res = self.conn().execute(
            &format!(
                "INSERT INTO agents ({COLS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23)"
            ),
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
                agent.updated_at,
                agent.effort.map(Effort::as_str),
                agent.memory_mode.as_str(),
                agent.context_budget,
                agent.home_dir,
                agent.context_tokens as i64,
                agent.chapter,
                agent.last_turn_at,
                agent.fallback_runtime.map(RuntimeKind::as_str),
                agent.fallback_model,
                agent.active_runtime.map(RuntimeKind::as_str),
                agent.workspace_id,
                agent.paused
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
        if let Some(v) = p.effort {
            a.effort = v;
        }
        if let Some(v) = p.memory_mode {
            a.memory_mode = v;
        }
        if let Some(v) = p.context_budget {
            a.context_budget = v;
        }
        if let Some(v) = p.workspace_id {
            if self.workspace_get(&v)?.is_none() {
                return Err(WorkspaceError::NotFound(v).into());
            }
            a.workspace_id = v;
        }
        if let Some(v) = p.runtime
            && v != a.runtime
        {
            // The CLI session belongs to its runtime, and so does a fallback that is now the primary one.
            a.runtime = v;
            a.active_runtime = None;
        }
        if let Some(v) = p.fallback_runtime {
            a.fallback_runtime = v;
        }
        if let Some(v) = p.fallback_model {
            a.fallback_model = v;
        }
        a.updated_at = now_ms();
        let res = self.conn().execute(
            "UPDATE agents SET name=?2, role=?3, model=?4, cwd=?5, approval_mode=?6, system_prompt=?7, updated_at=?8,
             effort=?9, memory_mode=?10, context_budget=?11, runtime=?12, fallback_runtime=?13, fallback_model=?14,
             active_runtime=?15, workspace_id=?16 WHERE id=?1",
            params![
                a.id,
                a.name,
                a.role,
                a.model,
                a.cwd,
                a.approval_mode.as_str(),
                a.system_prompt,
                a.updated_at,
                a.effort.map(Effort::as_str),
                a.memory_mode.as_str(),
                a.context_budget,
                a.runtime.as_str(),
                a.fallback_runtime.map(RuntimeKind::as_str),
                a.fallback_model,
                a.active_runtime.map(RuntimeKind::as_str),
                a.workspace_id
            ],
        );
        match res {
            Ok(_) => Ok(a),
            Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
                Err(anyhow!("an agent named '{}' already exists", a.name))
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Sets the pause flag. Returns `false` when the agent is missing or already has that value.
    pub fn agent_set_paused(&self, id: &str, paused: bool) -> Result<bool> {
        let changed = self.conn().execute(
            "UPDATE agents SET paused = ?2, updated_at = ?3 WHERE id = ?1 AND paused != ?2",
            params![id, paused, now_ms()],
        )?;
        Ok(changed > 0)
    }

    /// Remember the agent's own folder (set once, when it is created).
    pub fn agent_set_home(&self, id: &str, home_dir: &str) -> Result<()> {
        self.conn()
            .execute("UPDATE agents SET home_dir=?2 WHERE id=?1", params![id, home_dir])?;
        Ok(())
    }

    /// After a turn: the chapter's context size and when it happened.
    pub fn agent_note_turn(&self, id: &str, context_tokens: u64, at: i64) -> Result<()> {
        self.conn().execute(
            "UPDATE agents SET context_tokens=?2, last_turn_at=?3 WHERE id=?1",
            params![id, context_tokens as i64, at],
        )?;
        Ok(())
    }

    /// Close the current chapter: forget the CLI session, reset the context
    /// size, bump the chapter number. Returns the new chapter number.
    pub fn agent_next_chapter(&self, id: &str) -> Result<u32> {
        let conn = self.conn();
        conn.execute(
            "UPDATE agents SET runtime_session_id=NULL, context_tokens=0, chapter=chapter+1, updated_at=?2 WHERE id=?1",
            params![id, now_ms()],
        )?;
        let chapter: i64 = conn.query_row("SELECT chapter FROM agents WHERE id=?1", [id], |r| r.get(0))?;
        Ok(chapter.clamp(1, u32::MAX as i64) as u32)
    }

    /// Which runtime the agent runs on: `None` for the primary one, `Some` for a fallback.
    pub fn agent_set_active_runtime(&self, id: &str, active: Option<RuntimeKind>) -> Result<()> {
        self.conn().execute(
            "UPDATE agents SET active_runtime=?2, updated_at=?3 WHERE id=?1",
            params![id, active.map(RuntimeKind::as_str), now_ms()],
        )?;
        Ok(())
    }

    pub fn agent_set_session(&self, id: &str, session_id: Option<&str>) -> Result<()> {
        self.conn().execute(
            "UPDATE agents SET runtime_session_id=?2, updated_at=?3 WHERE id=?1",
            params![id, session_id, now_ms()],
        )?;
        Ok(())
    }

    /// Deletes the agent with its approvals, rules, schedules and checkpoints. Events stay
    /// (history), keyed by the old id.
    pub fn agent_delete(&self, id: &str) -> Result<bool> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let n = tx.execute("DELETE FROM agents WHERE id=?1", [id])?;
        tx.execute("DELETE FROM approvals WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM rules WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM schedules WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM checkpoints WHERE agent_id=?1", [id])?;
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
            effort: None,
            memory_mode: crate::store::MemoryMode::Smart,
            context_budget: None,
            fallback_runtime: None,
            fallback_model: None,
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
    fn pause_flag_is_stored_and_reported_once() {
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        assert!(!a.paused);
        assert!(s.agent_set_paused(&a.id, true).unwrap());
        assert!(s.agent_get(&a.id).unwrap().unwrap().paused);
        // Setting the value it already has changes nothing.
        assert!(!s.agent_set_paused(&a.id, true).unwrap());
        // A patch that does not mention `paused` keeps it.
        let renamed = s
            .agent_update(
                &a.id,
                AgentPatch {
                    role: Some("reviewer".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(renamed.paused);
        assert!(s.agent_set_paused(&a.id, false).unwrap());
        assert!(!s.agent_get(&a.id).unwrap().unwrap().paused);
        assert!(!s.agent_set_paused("missing", true).unwrap());
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
