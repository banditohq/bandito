//! SQLite store. One connection behind a mutex; calls are short, so callers
//! on the async side wrap heavy ones in `spawn_blocking` if needed.

use crate::event::{Event, EventBody};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;

mod agents;
mod approvals;
pub mod auth;
mod checkpoints;
mod forms;
mod history;
mod integrations;
mod reactions;
mod rules;
mod schedules;
mod secrets;
mod usage;
mod workspaces;

pub use agents::{ALL_CAPABILITIES, Agent, AgentPatch, Avatar, Capability, NewAgent, capabilities_csv, validate_name};
pub use approvals::{Approval, ApprovalStatus};
pub use auth::Device;
pub use checkpoints::{Checkpoint, CheckpointKind};
pub use forms::{Form, FormStatus};
pub use integrations::{
    Integration, IntegrationAuth, IntegrationKind, IntegrationPatch, IntegrationTool, NewIntegration, ToolMode,
    ToolOverride,
};
pub use reactions::Reaction;
pub use rules::{Rule, RuleAction};
pub use schedules::{NewSchedule, NextRun, Schedule, SchedulePatch};
pub use secrets::{SecretInfo, check_agents, check_name, check_value};
pub use usage::UsageEntry;
pub use workspaces::{Mount, Network, NewWorkspace, SHARED_WORKSPACE, Workspace, WorkspaceKind, WorkspacePatch};

const MIGRATIONS: &[&str] = &[
    include_str!("../../migrations/0001_init.sql"),
    include_str!("../../migrations/0002_memory.sql"),
    include_str!("../../migrations/0003_usage_plan.sql"),
    include_str!("../../migrations/0004_checkpoints.sql"),
    include_str!("../../migrations/0005_secrets.sql"),
    include_str!("../../migrations/0007_fallback.sql"),
    include_str!("../../migrations/0008_workspaces.sql"),
    include_str!("../../migrations/0009_agent_pause.sql"),
    include_str!("../../migrations/0010_events_agent_kind_seq.sql"),
    include_str!("../../migrations/0011_agent_personal_settings.sql"),
    include_str!("../../migrations/0012_agent_avatar_capabilities.sql"),
    include_str!("../../migrations/0013_forms_reactions.sql"),
    include_str!("../../migrations/0014_agent_avatar_extras.sql"),
    include_str!("../../migrations/0015_schedule_title.sql"),
    include_str!("../../migrations/0016_integrations.sql"),
    include_str!("../../migrations/0017_agent_lead.sql"),
    include_str!("../../migrations/0018_integration_auth.sql"),
    include_str!("../../migrations/0019_integration_tools.sql"),
    include_str!("../../migrations/0020_integration_tool_mode.sql"),
];

pub struct Store {
    conn: Mutex<Connection>,
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

pub fn new_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        restrict_to_owner(path)?;
        let conn = Connection::open(path).with_context(|| format!("open {}", path.display()))?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version as usize > MIGRATIONS.len() {
            bail!("database is newer ({version}) than this bandito ({})", MIGRATIONS.len());
        }
        for (i, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
            let tx = conn.unchecked_transaction()?;
            tx.execute_batch(sql).with_context(|| format!("migration {}", i + 1))?;
            tx.pragma_update(None, "user_version", (i + 1) as i64)?;
            tx.commit()?;
        }
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// Runs a statement that breaks the database, for a test of what the daemon does when it cannot read it.
    #[cfg(test)]
    pub fn break_for_test(&self, sql: &str) {
        self.conn().execute_batch(sql).unwrap();
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    // ---- events ----

    /// Persist an event and return it with its `seq`. Deltas are not stored
    /// and come back with `seq = 0`.
    pub fn append_event(&self, agent_id: &str, body: EventBody) -> Result<Event> {
        let ts = now_ms();
        if !body.is_persisted() {
            return Ok(Event {
                seq: 0,
                agent_id: agent_id.to_string(),
                ts,
                body,
            });
        }
        let (kind, payload) = body.to_parts();
        let conn = self.conn();
        conn.execute(
            "INSERT INTO events (agent_id, ts, kind, payload) VALUES (?1, ?2, ?3, ?4)",
            params![agent_id, ts, kind, payload.to_string()],
        )?;
        Ok(Event {
            seq: conn.last_insert_rowid(),
            agent_id: agent_id.to_string(),
            ts,
            body,
        })
    }

    /// Messages shown as waiting (`queued: true`) that no `turn.started` has taken and no `message.dropped` has
    /// closed, as `(agent_id, seq)`. After a daemon restart these have lost their place in the in-memory queue.
    pub fn queued_messages_unresolved(&self) -> Result<Vec<(String, i64)>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT e.agent_id, e.seq FROM events e
             WHERE e.kind = 'message.user' AND json_extract(e.payload, '$.queued') = 1
               AND NOT EXISTS (
                 SELECT 1 FROM events t WHERE t.agent_id = e.agent_id AND t.seq > e.seq
                   AND ((t.kind = 'turn.started' AND json_extract(t.payload, '$.message_seq') = e.seq)
                     OR (t.kind = 'message.dropped' AND json_extract(t.payload, '$.seq') = e.seq)))
             ORDER BY e.seq",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Events with `seq > after`, oldest first.
    pub fn events_since(&self, after: i64, limit: u32, agent_id: Option<&str>) -> Result<Vec<Event>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT seq, agent_id, ts, kind, payload FROM events
             WHERE seq > ?1 AND (?2 IS NULL OR agent_id = ?2)
             ORDER BY seq LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![after, agent_id, limit.min(5000)], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (seq, agent_id, ts, kind, payload) = row?;
            let body = EventBody::from_parts(&kind, serde_json::from_str(&payload)?)
                .with_context(|| format!("decode event {seq} ({kind})"))?;
            out.push(Event {
                seq,
                agent_id,
                ts,
                body,
            });
        }
        Ok(out)
    }

    /// One agent's newest events before `before` (exclusive; `None` = latest),
    /// returned oldest first. For scrolling a thread back page by page.
    pub fn events_page(&self, agent_id: &str, before: Option<i64>, limit: u32) -> Result<Vec<Event>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT seq, agent_id, ts, kind, payload FROM events
             WHERE agent_id = ?1 AND (?2 IS NULL OR seq < ?2)
             ORDER BY seq DESC LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![agent_id, before, limit.clamp(1, 1000)], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
                r.get::<_, String>(3)?,
                r.get::<_, String>(4)?,
            ))
        })?;
        let mut out = Vec::new();
        for row in rows {
            let (seq, agent_id, ts, kind, payload) = row?;
            let body = EventBody::from_parts(&kind, serde_json::from_str(&payload)?)
                .with_context(|| format!("decode event {seq} ({kind})"))?;
            out.push(Event {
                seq,
                agent_id,
                ts,
                body,
            });
        }
        out.reverse();
        Ok(out)
    }

    pub fn last_seq(&self) -> Result<i64> {
        Ok(self
            .conn()
            .query_row("SELECT COALESCE(MAX(seq), 0) FROM events", [], |r| r.get(0))?)
    }

    /// One event of an agent by its seq, if it is stored.
    pub fn event_at(&self, agent_id: &str, seq: i64) -> Result<Option<Event>> {
        let row = self
            .conn()
            .query_row(
                "SELECT seq, agent_id, ts, kind, payload FROM events WHERE agent_id = ?1 AND seq = ?2",
                params![agent_id, seq],
                |r| {
                    Ok((
                        r.get::<_, i64>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, i64>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, String>(4)?,
                    ))
                },
            )
            .optional()?;
        let Some((seq, agent_id, ts, kind, payload)) = row else {
            return Ok(None);
        };
        let payload: Value = serde_json::from_str(&payload)?;
        Ok(Some(Event {
            seq,
            agent_id,
            ts,
            body: EventBody::from_parts(&kind, payload)?,
        }))
    }

    /// The seq of the human message the agent is answering: the one the newest human turn took
    /// (`turn.started.message_seq`, or else the message written right after that `turn.started`). A message that
    /// still waits behind the turn is not it. Before any human turn: the newest message that did not wait.
    pub fn current_user_message_seq(&self, agent_id: &str) -> Result<Option<i64>> {
        let conn = self.conn();
        let turn: Option<(i64, Option<i64>)> = conn
            .query_row(
                "SELECT seq, json_extract(payload, '$.message_seq') FROM events
                   WHERE agent_id = ?1 AND kind = 'turn.started'
                   AND json_extract(payload, '$.source') = 'user' ORDER BY seq DESC LIMIT 1",
                [agent_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((_, Some(taken))) = turn {
            return Ok(Some(taken));
        }
        let after = turn.map_or(0, |(seq, _)| seq);
        // Not queued: written when its turn began (right after `turn.started`), or sent to an idle agent.
        let not_queued = "SELECT seq FROM events WHERE agent_id = ?1 AND kind = 'message.user'
                   AND json_extract(payload, '$.source') = 'user'
                   AND COALESCE(json_extract(payload, '$.queued'), 0) = 0";
        let first_after: Option<i64> = conn
            .query_row(
                &format!("{not_queued} AND seq > ?2 ORDER BY seq ASC LIMIT 1"),
                params![agent_id, after],
                |r| r.get(0),
            )
            .optional()?;
        if first_after.is_some() && after > 0 {
            return Ok(first_after);
        }
        Ok(conn
            .query_row(&format!("{not_queued} ORDER BY seq DESC LIMIT 1"), [agent_id], |r| {
                r.get(0)
            })
            .optional()?)
    }

    /// When the agent's last turn that a human message started was started (`turn.started`, source `user`).
    pub fn user_reactions_mark(&self, agent_id: &str) -> Result<Option<i64>> {
        Ok(self
            .conn()
            .query_row(
                "SELECT COALESCE(json_extract(payload, '$.reactions_until'), ts) FROM events
                   WHERE agent_id = ?1 AND kind = 'turn.started'
                   AND json_extract(payload, '$.source') = 'user' ORDER BY seq DESC LIMIT 1",
                [agent_id],
                |r| r.get(0),
            )
            .optional()?)
    }
}

/// The database holds secrets, so only the daemon's user may read it. A new file is created
/// private from the start; an existing one is tightened. SQLite gives its journal and WAL
/// files the database file's mode.
#[cfg(unix)]
fn restrict_to_owner(path: &Path) -> Result<()> {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e).with_context(|| format!("create {}", path.display())),
    }
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .with_context(|| format!("chmod {}", path.display()))
}

#[cfg(not(unix))]
fn restrict_to_owner(_path: &Path) -> Result<()> {
    Ok(())
}

/// How hard the model thinks. Mapped per runtime (see docs/ARCHITECTURE.md#memory-and-context).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Effort {
    Low,
    Medium,
    High,
    Xhigh,
    Max,
}

impl Effort {
    pub fn as_str(self) -> &'static str {
        match self {
            Effort::Low => "low",
            Effort::Medium => "medium",
            Effort::High => "high",
            Effort::Xhigh => "xhigh",
            Effort::Max => "max",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "low" => Effort::Low,
            "medium" => Effort::Medium,
            "high" => Effort::High,
            "xhigh" => Effort::Xhigh,
            "max" => Effort::Max,
            _ => return None,
        })
    }
}

/// When an agent's chat starts a new chapter (a fresh CLI session).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MemoryMode {
    Smart,
    Daily,
    Full,
}

impl MemoryMode {
    pub fn as_str(self) -> &'static str {
        match self {
            MemoryMode::Smart => "smart",
            MemoryMode::Daily => "daily",
            MemoryMode::Full => "full",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "smart" => MemoryMode::Smart,
            "daily" => MemoryMode::Daily,
            "full" => MemoryMode::Full,
            _ => return None,
        })
    }
}

/// Default context budget for `smart` memory, in tokens.
pub const DEFAULT_CONTEXT_BUDGET: u32 = 120_000;

/// Status string helpers shared by sub-modules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ApprovalMode {
    Risky,
    Always,
    Never,
}

impl ApprovalMode {
    pub fn as_str(self) -> &'static str {
        match self {
            ApprovalMode::Risky => "risky",
            ApprovalMode::Always => "always",
            ApprovalMode::Never => "never",
        }
    }
    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "risky" => ApprovalMode::Risky,
            "always" => ApprovalMode::Always,
            "never" => ApprovalMode::Never,
            _ => return None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{AgentStatus, EventBody};

    #[test]
    fn migrates_and_reopens() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("b.db");
        Store::open(&p).unwrap();
        let s = Store::open(&p).unwrap();
        assert_eq!(s.last_seq().unwrap(), 0);
    }

    #[test]
    fn events_append_and_since() {
        let s = Store::open_in_memory().unwrap();
        let e1 = s
            .append_event("a", EventBody::MessageAssistant { text: "hi".into() })
            .unwrap();
        let d = s
            .append_event("a", EventBody::MessageDelta { text: "h".into() })
            .unwrap();
        let e2 = s
            .append_event(
                "b",
                EventBody::AgentStatus {
                    status: AgentStatus::Idle,
                    detail: None,
                },
            )
            .unwrap();
        assert_eq!(d.seq, 0);
        assert!(e2.seq > e1.seq);
        assert_eq!(s.events_since(0, 100, None).unwrap().len(), 2);
        assert_eq!(s.events_since(e1.seq, 100, None).unwrap(), vec![e2.clone()]);
        assert_eq!(s.events_since(0, 100, Some("a")).unwrap(), vec![e1]);
        assert_eq!(s.last_seq().unwrap(), e2.seq);
    }

    #[test]
    fn events_page_walks_back() {
        let s = Store::open_in_memory().unwrap();
        let mut seqs = Vec::new();
        for i in 0..5 {
            seqs.push(
                s.append_event("a", EventBody::MessageAssistant { text: format!("{i}") })
                    .unwrap()
                    .seq,
            );
            s.append_event("b", EventBody::MessageAssistant { text: "x".into() })
                .unwrap();
        }
        let last2: Vec<i64> = s.events_page("a", None, 2).unwrap().iter().map(|e| e.seq).collect();
        assert_eq!(last2, vec![seqs[3], seqs[4]], "newest page, oldest first");
        let before: Vec<i64> = s
            .events_page("a", Some(seqs[3]), 10)
            .unwrap()
            .iter()
            .map(|e| e.seq)
            .collect();
        assert_eq!(before, vec![seqs[0], seqs[1], seqs[2]]);
        assert!(s.events_page("a", Some(seqs[0]), 10).unwrap().is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn database_file_is_private() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;

        let fresh = dir.path().join("fresh.db");
        Store::open(&fresh).unwrap();
        assert_eq!(mode(&fresh), 0o600, "a new database is created private");

        let old = dir.path().join("old.db");
        std::fs::write(&old, b"").unwrap();
        std::fs::set_permissions(&old, std::fs::Permissions::from_mode(0o644)).unwrap();
        Store::open(&old).unwrap();
        assert_eq!(mode(&old), 0o600, "an existing database is tightened");
    }

    #[test]
    fn workspace_migration_gives_existing_agents_the_shared_workspace() {
        // A database as the previous release left it: migrations 1 to 5, with an agent.
        let conn = Connection::open_in_memory().unwrap();
        for sql in &MIGRATIONS[..5] {
            conn.execute_batch(sql).unwrap();
        }
        conn.pragma_update(None, "user_version", 5).unwrap();
        conn.execute(
            "INSERT INTO agents (id, name, runtime, cwd, created_at, updated_at) VALUES ('old', 'Old', 'claude', '/work', 1, 1)",
            [],
        )
        .unwrap();

        let s = Store::init(conn).unwrap();
        assert_eq!(s.agent_get("old").unwrap().unwrap().workspace_id, SHARED_WORKSPACE);
        assert_eq!(
            s.workspace_get(SHARED_WORKSPACE).unwrap().unwrap().kind,
            WorkspaceKind::Shared
        );
    }

    #[test]
    fn avatar_migration_leaves_existing_agents_on_the_derived_avatar_and_all_capabilities() {
        // A database as the previous release left it: every migration but the newest, with an agent.
        let before = MIGRATIONS.len() - 1;
        let conn = Connection::open_in_memory().unwrap();
        for sql in &MIGRATIONS[..before] {
            conn.execute_batch(sql).unwrap();
        }
        conn.pragma_update(None, "user_version", before as i64).unwrap();
        conn.execute(
            "INSERT INTO agents (id, name, runtime, cwd, created_at, updated_at) VALUES ('old', 'Old', 'claude', '/work', 1, 1)",
            [],
        )
        .unwrap();

        let s = Store::init(conn).unwrap();
        let old = s.agent_view("old").unwrap().unwrap();
        assert_eq!((old.avatar, old.capabilities), (None, None));
        assert_eq!(s.agent_get("old").unwrap().unwrap().name, "Old");
    }

    #[test]
    fn plan_migration_applies_to_a_version_2_database() {
        // A database as the previous release left it: migrations 1 and 2 applied, usage rows present.
        let conn = Connection::open_in_memory().unwrap();
        for sql in &MIGRATIONS[..2] {
            conn.execute_batch(sql).unwrap();
        }
        conn.pragma_update(None, "user_version", 2).unwrap();
        conn.execute(
            "INSERT INTO usage_limits (runtime, windows, updated_at) VALUES ('codex', '[]', 7)",
            [],
        )
        .unwrap();

        let s = Store::init(conn).unwrap();
        let version: i64 = s.conn().query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
        assert_eq!(
            s.usage_list().unwrap(),
            vec![UsageEntry {
                runtime: "codex".into(),
                windows: Vec::new(),
                updated_at: 7,
                plan: None,
            }]
        );
    }
}
