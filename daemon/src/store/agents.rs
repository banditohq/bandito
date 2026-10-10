use super::{ApprovalMode, Effort, MemoryMode, SHARED_WORKSPACE, Store, new_id, now_ms};
use crate::event::AgentStatus;
use crate::runtime::RuntimeKind;
use crate::workspace::WorkspaceError;
use anyhow::{Result, anyhow, bail};
use rusqlite::types::Type;
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

/// Longest `LastMessage::text`, in characters.
pub const LAST_MESSAGE_CHARS: usize = 200;

/// The newest message of an agent, for the sidebar preview. Only user and assistant messages count; a message
/// Bandito sent itself (`source: "system"`) does not. See docs/ARCHITECTURE.md#team-preview.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LastMessage {
    /// `user` or `assistant`.
    pub role: String,
    /// The text, cut to `LAST_MESSAGE_CHARS` characters.
    pub text: String,
    /// When the message was recorded (Unix milliseconds).
    pub ts: i64,
}

/// The agent's avatar: the tile color and the face on it, named as the app names them (a `#RRGGBB` color is
/// taken as is). `emoji` is one grapheme; `image` says a picture is set (served by `agents.avatar_image_get`).
/// See docs/ARCHITECTURE.md#capabilities.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Avatar {
    pub color: String,
    pub face: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
    /// Set and cleared only by the picture methods; an `agents.update` keeps it. Left out of the wire when false.
    #[serde(default, skip_serializing_if = "is_false")]
    pub image: bool,
    /// Changes with every new picture, so a client can drop its cache. Only set while `image` is.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_rev: Option<i64>,
}

fn is_false(b: &bool) -> bool {
    !*b
}

impl Avatar {
    /// A name-and-face avatar with no emoji and no picture.
    pub fn new(color: impl Into<String>, face: impl Into<String>) -> Self {
        Self {
            color: color.into(),
            face: face.into(),
            emoji: None,
            image: false,
            image_rev: None,
        }
    }
}

/// What an agent may use. A session gets the tools of its capabilities only (see docs/ARCHITECTURE.md#capabilities).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Capability {
    /// The shell: Claude's `Bash`.
    Terminal,
    /// Changing files: Claude's `Edit`, `Write`, `MultiEdit` and `NotebookEdit`. Reading stays.
    Files,
    /// The browser on the server: the `browser_*` tools.
    Browser,
    /// The crew: `crew_list` and `crew_send`.
    Team,
    /// The server's screen: the `screen_*` tools.
    Screen,
}

/// Every capability, in the order the app lists them.
pub const ALL_CAPABILITIES: [Capability; 5] = [
    Capability::Terminal,
    Capability::Files,
    Capability::Browser,
    Capability::Team,
    Capability::Screen,
];

impl Capability {
    /// The wire name, also used in the daemon's own argument lists.
    pub fn as_str(self) -> &'static str {
        match self {
            Capability::Terminal => "terminal",
            Capability::Files => "files",
            Capability::Browser => "browser",
            Capability::Team => "team",
            Capability::Screen => "screen",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        ALL_CAPABILITIES.into_iter().find(|c| c.as_str() == s)
    }
}

/// The capabilities as one comma-separated list (`browser,team`), for the crew server's `--capabilities`.
pub fn capabilities_csv(list: &[Capability]) -> String {
    list.iter().map(|c| c.as_str()).collect::<Vec<_>>().join(",")
}

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
    /// Whether the agent's CLI also loads the owner's own Claude settings (see docs/ARCHITECTURE.md#personal-settings).
    /// Read when a session starts.
    pub use_personal_settings: bool,
    /// The avatar the app draws; `null` = derived from the name.
    pub avatar: Option<Avatar>,
    /// What the agent may use; `null` = all of it. Read when a session starts (see docs/ARCHITECTURE.md#capabilities).
    pub capabilities: Option<Vec<Capability>>,
    /// The integrations the agent may use, by id; `null` = every enabled one. Read when a session starts
    /// (see docs/ARCHITECTURE.md#integrations).
    pub integrations: Option<Vec<String>>,
    /// The main agent of the crew; at most one agent has it (see docs/ARCHITECTURE.md#lead-agent). Set only by
    /// `Store::agent_set_lead`, never by a patch.
    #[serde(default)]
    pub lead: bool,
    /// The newest user or assistant message; `null` when there is none. Only set by `agent_view` and
    /// `agent_list_view`, the reads the wire uses (see docs/ARCHITECTURE.md#team-preview).
    #[serde(default)]
    pub last_message: Option<LastMessage>,
    /// The status of the agent's newest `agent.status` event; `null` before any. Only set by the view reads.
    #[serde(default)]
    pub status: Option<AgentStatus>,
    /// Ids of this agent's approvals that wait for an answer, oldest first. Only set by the view reads. The app keeps a
    /// set of them, so a replayed `approval.requested` does not count twice.
    #[serde(default)]
    pub pending_approval_ids: Vec<String>,
    /// How many approvals wait for an answer: the length of `pending_approval_ids`. Kept for clients that only count.
    #[serde(default)]
    pub pending_approvals: u32,
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
    /// Loads the owner's own Claude settings in new sessions (see docs/ARCHITECTURE.md#personal-settings).
    #[serde(default)]
    pub use_personal_settings: bool,
    /// The avatar to start with; `null` or missing = derived from the name.
    #[serde(default)]
    pub avatar: Option<Avatar>,
    /// What the agent may use; `null` or missing = all of it.
    #[serde(default)]
    pub capabilities: Option<Vec<Capability>>,
    /// The integrations it may use; `null` or missing = every enabled one.
    #[serde(default)]
    pub integrations: Option<Vec<String>>,
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
    pub use_personal_settings: Option<bool>,
    pub avatar: Option<Option<Avatar>>,
    pub capabilities: Option<Option<Vec<Capability>>>,
    pub integrations: Option<Option<Vec<String>>>,
    /// Makes the agent the main one (`true`: the old one loses it in the same transaction) or takes the role away.
    pub lead: Option<bool>,
}

const COLS: &str = "id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at, effort, memory_mode, context_budget, home_dir, context_tokens, chapter, last_turn_at, fallback_runtime, fallback_model, active_runtime, workspace_id, paused, use_personal_settings, avatar_color, avatar_face, capabilities, avatar_emoji, avatar_image, avatar_image_rev, integrations, lead";

/// The newest message of the agent in `agents.id`, as one JSON array `[kind, ts, text]` (text cut to
/// `LAST_MESSAGE_CHARS` in SQL too, so a long message is not read in full). One correlated subquery per agent, served by
/// `events_agent_kind_seq`. The message rules match `history_search`.
const LAST_MESSAGE_SQL: &str = "(SELECT json_array(kind, ts, substr(json_extract(payload, '$.text'), 1, 200)) FROM events \
    WHERE agent_id = agents.id AND kind IN ('message.user','message.assistant') \
    AND (kind <> 'message.user' OR json_extract(payload, '$.source') IS NOT 'system') \
    ORDER BY seq DESC LIMIT 1)";

/// The status of the agent's newest `agent.status` event (`events_agent_kind_seq`).
const STATUS_SQL: &str = "(SELECT json_extract(payload, '$.status') FROM events \
    WHERE agent_id = agents.id AND kind = 'agent.status' ORDER BY seq DESC LIMIT 1)";

/// Ids of the agent's approvals still waiting for an answer, oldest first, as a JSON array (`approvals_agent_status`).
const PENDING_IDS_SQL: &str = "(SELECT json_group_array(id) FROM (SELECT id FROM approvals \
    WHERE agent_id = agents.id AND status = 'pending' ORDER BY created_at, id))";

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
        use_personal_settings: r.get(23)?,
        avatar: avatar_column(r)?,
        capabilities: capabilities_column(r, 26)?,
        integrations: integrations_column(r, 30)?,
        lead: r.get::<_, i64>(31)? != 0,
        last_message: None,
        status: None,
        pending_approval_ids: Vec::new(),
        pending_approvals: 0,
    })
}

/// `from_row` for `view_sql()`: the agent columns, then the message, the status and the pending count.
fn from_row_view(r: &Row) -> rusqlite::Result<Agent> {
    let mut agent = from_row(r)?;
    agent.last_message = last_message_column(r, 32)?;
    agent.status = status_column(r, 33)?;
    agent.pending_approval_ids = pending_ids_column(r, 34)?;
    agent.pending_approvals = agent.pending_approval_ids.len() as u32;
    Ok(agent)
}

/// The avatar from its columns: color and face both set, or none (the app derives it from the name).
/// The emoji and the picture columns belong to it and are read only with it.
fn avatar_column(r: &Row) -> rusqlite::Result<Option<Avatar>> {
    Ok(
        match (r.get::<_, Option<String>>(24)?, r.get::<_, Option<String>>(25)?) {
            (Some(color), Some(face)) => Some(Avatar {
                color,
                face,
                emoji: r.get(27)?,
                image: r.get::<_, i64>(28)? != 0,
                image_rev: r.get(29)?,
            }),
            _ => None,
        },
    )
}

fn capabilities_column(r: &Row, i: usize) -> rusqlite::Result<Option<Vec<Capability>>> {
    let Some(json) = r.get::<_, Option<String>>(i)? else {
        return Ok(None);
    };
    serde_json::from_str(&json)
        .map(Some)
        .map_err(|e| rusqlite::Error::FromSqlConversionFailure(i, Type::Text, Box::new(e)))
}

/// The stored form of a capability list: a JSON array, or NULL for all of them.
/// The integration ids from their column: a JSON array, or NULL (every enabled one).
fn integrations_column(r: &Row, i: usize) -> rusqlite::Result<Option<Vec<String>>> {
    let Some(json) = r.get::<_, Option<String>>(i)? else {
        return Ok(None);
    };
    Ok(Some(serde_json::from_str(&json).unwrap_or_default()))
}

fn integrations_json(list: Option<&[String]>) -> Result<Option<String>> {
    Ok(match list {
        Some(ids) => Some(serde_json::to_string(ids)?),
        None => None,
    })
}

fn capabilities_json(list: Option<&[Capability]>) -> Result<Option<String>> {
    Ok(match list {
        Some(list) => Some(serde_json::to_string(list)?),
        None => None,
    })
}

fn pending_ids_column(r: &Row, i: usize) -> rusqlite::Result<Vec<String>> {
    let json: String = r.get(i)?;
    serde_json::from_str(&json).map_err(|e| rusqlite::Error::FromSqlConversionFailure(i, Type::Text, Box::new(e)))
}

/// The agent columns plus the wire-only fields, in the order `from_row_view` reads them.
fn view_sql(filter: &str) -> String {
    format!("SELECT {COLS}, {LAST_MESSAGE_SQL}, {STATUS_SQL}, {PENDING_IDS_SQL} FROM agents {filter}")
}

fn status_column(r: &Row, i: usize) -> rusqlite::Result<Option<AgentStatus>> {
    let Some(text) = r.get::<_, Option<String>>(i)? else {
        return Ok(None);
    };
    serde_json::from_value(serde_json::Value::String(text))
        .map(Some)
        .map_err(|e| rusqlite::Error::FromSqlConversionFailure(i, Type::Text, Box::new(e)))
}

fn last_message_column(r: &Row, i: usize) -> rusqlite::Result<Option<LastMessage>> {
    let Some(json) = r.get::<_, Option<String>>(i)? else {
        return Ok(None);
    };
    let (kind, ts, text): (String, i64, Option<String>) = serde_json::from_str(&json)
        .map_err(|e| rusqlite::Error::FromSqlConversionFailure(i, Type::Text, Box::new(e)))?;
    Ok(Some(LastMessage {
        role: if kind == "message.user" { "user" } else { "assistant" }.to_string(),
        text: text.unwrap_or_default().chars().take(LAST_MESSAGE_CHARS).collect(),
        ts,
    }))
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
            use_personal_settings: a.use_personal_settings,
            avatar: a.avatar,
            capabilities: a.capabilities,
            integrations: a.integrations,
            lead: false,
            last_message: None,
            status: None,
            pending_approval_ids: Vec::new(),
            pending_approvals: 0,
        };
        let capabilities = capabilities_json(agent.capabilities.as_deref())?;
        let integrations = integrations_json(agent.integrations.as_deref())?;
        let res = self.conn().execute(
            &format!(
                "INSERT INTO agents ({COLS}) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32)"
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
                agent.paused,
                agent.use_personal_settings,
                agent.avatar.as_ref().map(|v| v.color.as_str()),
                agent.avatar.as_ref().map(|v| v.face.as_str()),
                capabilities,
                agent.avatar.as_ref().and_then(|v| v.emoji.as_deref()),
                agent.avatar.as_ref().is_some_and(|v| v.image),
                agent.avatar.as_ref().and_then(|v| v.image_rev),
                integrations,
                agent.lead,
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

    /// The agent as stored, without the wire-only fields (`last_message`, `status`, `pending_approvals`).
    /// For the daemon's own checks; the RPC reads use `agent_view`.
    pub fn agent_get(&self, id: &str) -> Result<Option<Agent>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM agents WHERE id = ?1"), [id], from_row)
            .optional()?)
    }

    /// The agent with the fields the team needs: its newest message, its status and its pending approvals.
    /// What `agents.get`, `agents.create` and `agents.update` return.
    pub fn agent_view(&self, id: &str) -> Result<Option<Agent>> {
        Ok(self
            .conn()
            .query_row(&view_sql("WHERE id = ?1"), [id], from_row_view)
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

    /// Every agent with the wire-only fields (see `agent_view`), oldest first. What `agents.list` returns.
    pub fn agent_list_view(&self) -> Result<Vec<Agent>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&view_sql("ORDER BY created_at"))?;
        let rows = stmt.query_map([], from_row_view)?;
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
        if let Some(v) = p.use_personal_settings {
            a.use_personal_settings = v;
        }
        if let Some(v) = p.avatar {
            // A new name-and-face keeps the picture; `null` (derived again) drops it.
            a.avatar = v.map(|mut new| {
                let old = a.avatar.as_ref();
                new.image = old.is_some_and(|o| o.image);
                new.image_rev = old.and_then(|o| o.image_rev);
                new
            });
        }
        if let Some(v) = p.capabilities {
            a.capabilities = v;
        }
        if let Some(v) = p.integrations {
            a.integrations = v;
        }
        a.updated_at = now_ms();
        let capabilities = capabilities_json(a.capabilities.as_deref())?;
        let integrations = integrations_json(a.integrations.as_deref())?;
        // The role and the other fields are written together: a refused name leaves the main agent as it was.
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        if let Some(lead) = p.lead {
            if lead {
                tx.execute("UPDATE agents SET lead = 0 WHERE lead = 1 AND id <> ?1", [id])?;
            }
            a.lead = lead;
        }
        let res = tx.execute(
            "UPDATE agents SET name=?2, role=?3, model=?4, cwd=?5, approval_mode=?6, system_prompt=?7, updated_at=?8,
             effort=?9, memory_mode=?10, context_budget=?11, runtime=?12, fallback_runtime=?13, fallback_model=?14,
             active_runtime=?15, workspace_id=?16, use_personal_settings=?17,
             avatar_color=?18, avatar_face=?19, capabilities=?20, avatar_emoji=?21, avatar_image=?22,
             avatar_image_rev=?23, integrations=?24, lead=?25 WHERE id=?1",
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
                a.workspace_id,
                a.use_personal_settings,
                a.avatar.as_ref().map(|v| v.color.as_str()),
                a.avatar.as_ref().map(|v| v.face.as_str()),
                capabilities,
                a.avatar.as_ref().and_then(|v| v.emoji.as_deref()),
                a.avatar.as_ref().is_some_and(|v| v.image),
                a.avatar.as_ref().and_then(|v| v.image_rev),
                integrations,
                i64::from(a.lead),
            ],
        );
        match res {
            Ok(_) => {
                tx.commit()?;
                Ok(a)
            }
            Err(rusqlite::Error::SqliteFailure(e, _)) if e.code == rusqlite::ErrorCode::ConstraintViolation => {
                Err(anyhow!("an agent named '{}' already exists", a.name))
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Makes the agent the main one, or takes the role away. Making one main takes it from the old one in the same
    /// transaction, so the crew never has two. Returns the ids whose flag changed (the new main agent last), and
    /// none when nothing changed or the agent does not exist.
    pub fn agent_set_lead(&self, id: &str, lead: bool) -> Result<Vec<String>> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let exists: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM agents WHERE id = ?1)", [id], |r| r.get(0))?;
        if !exists {
            return Ok(Vec::new());
        }
        let mut changed: Vec<String> = Vec::new();
        if lead {
            let mut stmt = tx.prepare("SELECT id FROM agents WHERE lead = 1 AND id <> ?1")?;
            changed = stmt.query_map([id], |r| r.get(0))?.collect::<rusqlite::Result<_>>()?;
            drop(stmt);
            tx.execute("UPDATE agents SET lead = 0 WHERE lead = 1 AND id <> ?1", [id])?;
        }
        let own = tx.execute(
            "UPDATE agents SET lead = ?2 WHERE id = ?1 AND lead <> ?2",
            params![id, i64::from(lead)],
        )?;
        if own > 0 {
            changed.push(id.to_string());
        }
        tx.commit()?;
        Ok(changed)
    }

    /// The newest thing the agent said, in full: when, and the text. For the main agent's status read.
    pub fn last_assistant_message(&self, id: &str) -> Result<Option<(i64, String)>> {
        Ok(self
            .conn()
            .query_row(
                "SELECT ts, json_extract(payload, '$.text') FROM events
                 WHERE agent_id = ?1 AND kind = 'message.assistant' ORDER BY seq DESC LIMIT 1",
                [id],
                |r| Ok((r.get(0)?, r.get::<_, Option<String>>(1)?.unwrap_or_default())),
            )
            .optional()?)
    }

    /// The main agent of the crew, if there is one.
    pub fn agent_lead(&self) -> Result<Option<Agent>> {
        Ok(self
            .conn()
            .query_row(&format!("SELECT {COLS} FROM agents WHERE lead = 1"), [], from_row)
            .optional()?)
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
    /// Set or clear the avatar's picture flag and revision (`None` clears both). The avatar must be set:
    /// the picture belongs to it. `false` if the agent is missing or has no avatar.
    pub fn agent_set_avatar_image(&self, id: &str, rev: Option<i64>) -> Result<bool> {
        let n = self.conn().execute(
            "UPDATE agents SET avatar_image = ?2, avatar_image_rev = ?3
             WHERE id = ?1 AND avatar_color IS NOT NULL AND avatar_face IS NOT NULL",
            params![id, i64::from(rev.is_some()), rev],
        )?;
        Ok(n == 1)
    }

    pub fn agent_delete(&self, id: &str) -> Result<bool> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let n = tx.execute("DELETE FROM agents WHERE id=?1", [id])?;
        tx.execute("DELETE FROM approvals WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM rules WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM schedules WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM checkpoints WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM forms WHERE agent_id=?1", [id])?;
        tx.execute("DELETE FROM reactions WHERE agent_id=?1", [id])?;
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
            use_personal_settings: false,
            avatar: None,
            capabilities: None,
            integrations: None,
        }
    }

    #[test]
    fn avatar_and_capabilities_are_stored_and_patched_like_the_other_fields() {
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        assert_eq!((a.avatar.clone(), a.capabilities.clone()), (None, None));

        let mut with = new("Scout");
        with.avatar = Some(Avatar::new("sky", "dots"));
        with.capabilities = Some(vec![Capability::Team, Capability::Browser]);
        let scout = s.agent_create(with).unwrap();
        let stored = s.agent_get(&scout.id).unwrap().unwrap();
        assert_eq!(stored.avatar, scout.avatar);
        assert_eq!(stored.capabilities, Some(vec![Capability::Team, Capability::Browser]));
        let view = s.agent_view(&scout.id).unwrap().unwrap();
        assert_eq!((view.avatar, view.capabilities), (stored.avatar, stored.capabilities));

        // A patch that does not mention them keeps them.
        let renamed = s
            .agent_update(
                &scout.id,
                AgentPatch {
                    role: Some("reviewer".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(renamed.avatar.is_some() && renamed.capabilities.is_some());

        // An empty list is a real choice: no capabilities at all. Explicit null goes back to all of them.
        let none = s
            .agent_update(
                &scout.id,
                AgentPatch {
                    capabilities: Some(Some(vec![])),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!(none.capabilities, Some(vec![]));
        assert_eq!(s.agent_get(&scout.id).unwrap().unwrap().capabilities, Some(vec![]));
        let reset = s
            .agent_update(
                &scout.id,
                AgentPatch {
                    avatar: Some(None),
                    capabilities: Some(None),
                    ..Default::default()
                },
            )
            .unwrap();
        assert_eq!((reset.avatar, reset.capabilities), (None, None));
        let listed = s.agent_list_view().unwrap();
        let back = listed.iter().find(|x| x.id == scout.id).unwrap();
        assert_eq!((back.avatar.clone(), back.capabilities.clone()), (None, None));
    }

    #[test]
    fn capability_names_are_the_wire_names() {
        for c in ALL_CAPABILITIES {
            assert_eq!(Capability::parse(c.as_str()), Some(c));
            assert_eq!(serde_json::to_value(c).unwrap(), serde_json::json!(c.as_str()));
        }
        assert_eq!(Capability::parse("shell"), None);
        assert_eq!(Capability::parse("Browser"), None);
        assert_eq!(
            capabilities_csv(&[Capability::Browser, Capability::Team]),
            "browser,team"
        );
        assert_eq!(capabilities_csv(&[]), "");
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
    fn personal_settings_are_off_by_default_and_stored_per_agent() {
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        assert!(!a.use_personal_settings);
        let on = s
            .agent_update(
                &a.id,
                AgentPatch {
                    use_personal_settings: Some(true),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(on.use_personal_settings);
        assert!(s.agent_get(&a.id).unwrap().unwrap().use_personal_settings);
        // A patch that does not mention it keeps it.
        let renamed = s
            .agent_update(
                &a.id,
                AgentPatch {
                    role: Some("reviewer".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(renamed.use_personal_settings);
        let off = s
            .agent_update(
                &a.id,
                AgentPatch {
                    use_personal_settings: Some(false),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(!off.use_personal_settings);
        assert!(!s.agent_view(&a.id).unwrap().unwrap().use_personal_settings);
        // Created with the flag set.
        let mut with_flag = new("Scout");
        with_flag.use_personal_settings = true;
        assert!(s.agent_create(with_flag).unwrap().use_personal_settings);
    }

    #[test]
    fn name_rules() {
        assert!(validate_name("Night Owl").is_ok());
        assert!(validate_name("Ёж_2-b").is_ok());
        assert!(validate_name("  ").is_err());
        assert!(validate_name("a/b").is_err());
        assert!(validate_name(&"x".repeat(33)).is_err());
    }

    #[test]
    fn last_message_is_the_newest_user_or_assistant_message() {
        use crate::event::{EventBody, Source};
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        assert!(s.agent_view(&a.id).unwrap().unwrap().last_message.is_none());

        let user = |text: &str, source| EventBody::MessageUser {
            text: text.into(),
            source,
            from_agent: None,
            command: None,
            reply_to: None,
            attachments: Vec::new(),
            queued: false,
        };
        s.append_event(&a.id, user("hi", Source::User)).unwrap();
        let reply = s
            .append_event(&a.id, EventBody::MessageAssistant { text: "hello".into() })
            .unwrap();
        // Bandito's own wrap-up message and a tool call are not the preview.
        s.append_event(&a.id, user("save memory", Source::System)).unwrap();
        s.append_event(
            &a.id,
            EventBody::ToolCall {
                call_id: "c1".into(),
                tool: "shell".into(),
                title: "ls".into(),
                input: serde_json::json!({}),
            },
        )
        .unwrap();

        let want = LastMessage {
            role: "assistant".into(),
            text: "hello".into(),
            ts: reply.ts,
        };
        assert_eq!(s.agent_view(&a.id).unwrap().unwrap().last_message, Some(want.clone()));
        assert_eq!(s.agent_list_view().unwrap()[0].last_message, Some(want));

        s.append_event(&a.id, user("and you?", Source::Crew)).unwrap();
        let got = s.agent_list_view().unwrap()[0].last_message.clone().unwrap();
        assert_eq!((got.role.as_str(), got.text.as_str()), ("user", "and you?"));
    }

    #[test]
    fn last_message_is_cut_to_200_characters_on_a_character_boundary() {
        use crate::event::EventBody;
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        let long = "я".repeat(250) + "🙂 конец";
        s.append_event(&a.id, EventBody::MessageAssistant { text: long.clone() })
            .unwrap();

        let got = s.agent_view(&a.id).unwrap().unwrap().last_message.unwrap();
        assert_eq!(got.text.chars().count(), LAST_MESSAGE_CHARS);
        assert!(long.starts_with(&got.text), "the cut text is a prefix, not re-encoded");
    }

    #[test]
    fn last_message_belongs_to_its_own_agent() {
        use crate::event::EventBody;
        let s = Store::open_in_memory().unwrap();
        let forge = s.agent_create(new("Forge")).unwrap();
        let scout = s.agent_create(new("Scout")).unwrap();
        s.append_event(
            &forge.id,
            EventBody::MessageAssistant {
                text: "forge says".into(),
            },
        )
        .unwrap();
        s.append_event(
            &scout.id,
            EventBody::MessageAssistant {
                text: "scout says".into(),
            },
        )
        .unwrap();

        let list = s.agent_list_view().unwrap();
        let text_of = |id: &str| {
            list.iter()
                .find(|x| x.id == id)
                .unwrap()
                .last_message
                .as_ref()
                .map(|m| m.text.clone())
        };
        assert_eq!(text_of(&forge.id).as_deref(), Some("forge says"));
        assert_eq!(text_of(&scout.id).as_deref(), Some("scout says"));
    }

    #[test]
    fn view_carries_status_and_pending_approvals_for_agents_without_a_loaded_thread() {
        use crate::event::{AgentStatus, EventBody};
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        let view = |s: &Store| s.agent_list_view().unwrap().remove(0);
        assert_eq!(view(&s).status, None);
        assert_eq!(view(&s).pending_approvals, 0);

        s.append_event(
            &a.id,
            EventBody::AgentStatus {
                status: AgentStatus::Working,
                detail: None,
            },
        )
        .unwrap();
        s.append_event(
            &a.id,
            EventBody::AgentStatus {
                status: AgentStatus::NeedsYou,
                detail: None,
            },
        )
        .unwrap();
        assert_eq!(
            s.agent_view(&a.id).unwrap().unwrap().status,
            Some(AgentStatus::NeedsYou)
        );
        assert_eq!(view(&s).status, Some(AgentStatus::NeedsYou), "the newest status wins");

        let first = s
            .approval_create(&a.id, "c1", "Bash", "git push", serde_json::json!({}))
            .unwrap();
        let second = s
            .approval_create(&a.id, "c2", "Bash", "rm", serde_json::json!({}))
            .unwrap();
        assert_eq!(view(&s).pending_approvals, 2);
        assert_eq!(
            view(&s).pending_approval_ids,
            vec![first.id.clone(), second.id.clone()],
            "oldest first"
        );
        s.approval_resolve(&first.id, crate::event::Decision::Allow).unwrap();
        let after = s.agent_view(&a.id).unwrap().unwrap();
        assert_eq!(
            (after.pending_approvals, after.pending_approval_ids),
            (1, vec![second.id])
        );
    }

    #[test]
    fn plain_reads_leave_the_wire_only_fields_empty() {
        use crate::event::{AgentStatus, EventBody};
        let s = Store::open_in_memory().unwrap();
        let a = s.agent_create(new("Forge")).unwrap();
        s.append_event(
            &a.id,
            EventBody::AgentStatus {
                status: AgentStatus::Idle,
                detail: None,
            },
        )
        .unwrap();
        s.approval_create(&a.id, "c1", "Bash", "x", serde_json::json!({}))
            .unwrap();
        let plain = s.agent_get(&a.id).unwrap().unwrap();
        assert_eq!(
            (plain.status, plain.pending_approvals, plain.last_message.is_none()),
            (None, 0, true)
        );
    }

    #[test]
    fn one_agent_is_main_and_the_change_comes_in_one_step() {
        let store = Store::open_in_memory().unwrap();
        let a = store.agent_create(new("Forge")).unwrap();
        let b = store.agent_create(new("Scout")).unwrap();
        assert!(!a.lead && !b.lead);
        assert!(store.agent_lead().unwrap().is_none());

        assert_eq!(store.agent_set_lead(&a.id, true).unwrap(), vec![a.id.clone()]);
        assert_eq!(store.agent_lead().unwrap().unwrap().id, a.id);
        // Setting it again changes nothing.
        assert!(store.agent_set_lead(&a.id, true).unwrap().is_empty());

        // Another one takes over: the old one is first in the list of changes, the new one last.
        assert_eq!(
            store.agent_set_lead(&b.id, true).unwrap(),
            vec![a.id.clone(), b.id.clone()]
        );
        let leads: Vec<String> = store
            .agent_list()
            .unwrap()
            .into_iter()
            .filter(|x| x.lead)
            .map(|x| x.id)
            .collect();
        assert_eq!(leads, vec![b.id.clone()]);
        // The wire reads carry the flag.
        assert!(store.agent_view(&b.id).unwrap().unwrap().lead);
        assert!(
            !store
                .agent_list_view()
                .unwrap()
                .iter()
                .find(|x| x.id == a.id)
                .unwrap()
                .lead
        );

        // Taking it away from one that is not main changes nothing; from the main one, it does.
        assert!(store.agent_set_lead(&a.id, false).unwrap().is_empty());
        assert_eq!(store.agent_set_lead(&b.id, false).unwrap(), vec![b.id.clone()]);
        assert!(store.agent_lead().unwrap().is_none());
        // A missing agent changes nothing, and does not take the role from the main one.
        store.agent_set_lead(&a.id, true).unwrap();
        assert!(store.agent_set_lead("nobody", true).unwrap().is_empty());
        assert_eq!(store.agent_lead().unwrap().unwrap().id, a.id);
    }

    #[test]
    fn the_database_refuses_a_second_main_agent_and_an_update_keeps_the_role() {
        let store = Store::open_in_memory().unwrap();
        let a = store.agent_create(new("Forge")).unwrap();
        let b = store.agent_create(new("Scout")).unwrap();
        store.agent_set_lead(&a.id, true).unwrap();
        // The unique index is the last line of defence, below the transaction.
        let err = store
            .conn()
            .execute("UPDATE agents SET lead = 1 WHERE id = ?1", [&b.id]);
        assert!(err.is_err());
        // An ordinary update does not touch the flag; deleting the main agent leaves none.
        let patch = AgentPatch {
            role: Some("boss".into()),
            ..Default::default()
        };
        assert!(store.agent_update(&a.id, patch).unwrap().lead);
        assert!(store.agent_get(&a.id).unwrap().unwrap().lead);
        store.agent_delete(&a.id).unwrap();
        assert!(store.agent_lead().unwrap().is_none());
    }

    #[test]
    fn last_assistant_message_is_the_newest_in_full() {
        let store = Store::open_in_memory().unwrap();
        let a = store.agent_create(new("Forge")).unwrap();
        assert_eq!(store.last_assistant_message(&a.id).unwrap(), None);
        let long = "y".repeat(500);
        for text in ["first".to_string(), long.clone()] {
            store
                .append_event(&a.id, crate::event::EventBody::MessageAssistant { text })
                .unwrap();
        }
        assert_eq!(store.last_assistant_message(&a.id).unwrap().unwrap().1, long);
    }
}
