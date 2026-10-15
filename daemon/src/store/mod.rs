//! SQLite store. One connection behind a mutex; calls are short, so callers
//! on the async side wrap heavy ones in `spawn_blocking` if needed.

use crate::event::{Event, EventBody};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;
use std::sync::Mutex;
use std::sync::atomic::AtomicU64;

mod agents;
mod approvals;
pub mod auth;
mod checkpoints;
mod forms;
mod history;
mod integrations;
mod migrate;
mod push;
mod reactions;
mod read_marks;
mod rules;
mod schedules;
mod secrets;
mod server_settings;
mod telegram;
mod tool_calls;
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
pub use migrate::{ExportedEvent, NewEvent};
pub use push::PushTarget;
pub use reactions::Reaction;
pub use rules::{Rule, RuleAction};
pub use schedules::{NewSchedule, NextRun, Schedule, SchedulePatch};
pub use secrets::{SecretInfo, check_agents, check_name, check_value};
pub use server_settings::read_settings_file;
pub use telegram::{ANSWER_MODES, TgChat, TgLink, TgMessage};
pub use tool_calls::{CallFilter, CallStats, ERROR_MAX_CHARS, ToolCall};
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
    include_str!("../../migrations/0021_tool_calls.sql"),
    include_str!("../../migrations/0022_agent_template_id.sql"),
    include_str!("../../migrations/0023_telegram.sql"),
    include_str!("../../migrations/0024_integration_auth_device.sql"),
    include_str!("../../migrations/0025_agent_migrated.sql"),
    include_str!("../../migrations/0026_query_indexes.sql"),
    include_str!("../../migrations/0027_server_settings.sql"),
    include_str!("../../migrations/0028_device_noise_key.sql"),
    include_str!("../../migrations/0029_push.sql"),
    include_str!("../../migrations/0030_read_marks.sql"),
];

pub struct Store {
    conn: Mutex<Connection>,
    /// Calls recorded since this store opened: the call journal's cap is counted every `CAP_CHECK_EVERY` of them.
    tool_inserts: AtomicU64,
}

pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

pub fn new_id() -> String {
    uuid::Uuid::now_v7().to_string()
}

/// What [`Store::mark_quiet_turn`] found and did.
#[derive(Debug, Clone, PartialEq)]
pub enum QuietMark {
    /// No turn runs for the agent.
    NoTurn,
    /// The running turn was not started by a schedule: only a scheduled run may end quietly.
    NotScheduled,
    /// The turn is quiet already: nothing is added.
    Already,
    /// The mark was stored (and published).
    Marked(Box<Event>),
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
        // WAL with synchronous=NORMAL: a crash of the process loses nothing, a power loss may drop the last commits but
        // never corrupts the file. FULL (the default) also fsyncs every commit, i.e. every event. busy_timeout makes a
        // second process on the same file (the CLI's backup or restore) wait up to 5 s instead of failing with SQLITE_BUSY.
        // cache_size: 16 MB of pages instead of 2 MB, for the hot reads of a history of hundreds of thousands of events.
        // temp_store=MEMORY: the sorts of the list queries stay in RAM. mmap_size stays off (not measured to help).
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
             PRAGMA cache_size=-16000; PRAGMA temp_store=MEMORY;",
        )?;
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
        // The call journal's cap is checked every CAP_CHECK_EVERY calls; a start is the other moment it is checked.
        tool_calls::prune(&conn, now_ms(), true)?;
        Ok(Self {
            conn: Mutex::new(conn),
            tool_inserts: AtomicU64::new(0),
        })
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

    /// Connect requests (`integration_requested`) that no `integration_request_ended` has closed, as
    /// `(agent_id, request_id)`. After a daemon restart no call waits for them any more.
    pub fn connect_requests_unresolved(&self) -> Result<Vec<(String, String)>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT e.agent_id, json_extract(e.payload, '$.request_id') FROM events e
             WHERE e.kind = 'integration_requested'
               AND NOT EXISTS (
                 SELECT 1 FROM events t WHERE t.agent_id = e.agent_id AND t.seq > e.seq
                   AND t.kind = 'integration_request_ended'
                   AND json_extract(t.payload, '$.request_id') = json_extract(e.payload, '$.request_id'))
             ORDER BY e.seq",
        )?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Events with `seq > after`, oldest first. With an agent, only that agent's events, read through
    /// `events_agent_seq`: the cost follows the rows returned, not the history after `after`.
    pub fn events_since(&self, after: i64, limit: u32, agent_id: Option<&str>) -> Result<Vec<Event>> {
        let conn = self.conn();
        let limit = limit.min(5000);
        let rows = match agent_id {
            Some(agent) => {
                let mut stmt = conn.prepare(
                    "SELECT seq, agent_id, ts, kind, payload FROM events
                     WHERE agent_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3",
                )?;
                stmt.query_map(params![agent, after, limit], history::map_row)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            }
            None => {
                let mut stmt = conn.prepare(
                    "SELECT seq, agent_id, ts, kind, payload FROM events
                     WHERE seq > ?1 ORDER BY seq LIMIT ?2",
                )?;
                stmt.query_map(params![after, limit], history::map_row)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            }
        };
        rows.into_iter().map(history::decode).collect()
    }

    /// One agent's newest events before `before` (exclusive; `None` = latest),
    /// returned oldest first. For scrolling a thread back page by page. Served by `events_agent_seq`, the `seq`
    /// bound included, so a deep page does not walk the newer events first.
    pub fn events_page(&self, agent_id: &str, before: Option<i64>, limit: u32) -> Result<Vec<Event>> {
        let conn = self.conn();
        let limit = limit.clamp(1, 1000);
        let rows = match before {
            Some(before) => {
                let mut stmt = conn.prepare(
                    "SELECT seq, agent_id, ts, kind, payload FROM events
                     WHERE agent_id = ?1 AND seq < ?2 ORDER BY seq DESC LIMIT ?3",
                )?;
                stmt.query_map(params![agent_id, before, limit], history::map_row)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            }
            None => {
                let mut stmt = conn.prepare(
                    "SELECT seq, agent_id, ts, kind, payload FROM events
                     WHERE agent_id = ?1 ORDER BY seq DESC LIMIT ?2",
                )?;
                stmt.query_map(params![agent_id, limit], history::map_row)?
                    .collect::<rusqlite::Result<Vec<_>>>()?
            }
        };
        let mut out: Vec<Event> = rows.into_iter().map(history::decode).collect::<Result<_>>()?;
        out.reverse();
        Ok(out)
    }

    pub fn last_seq(&self) -> Result<i64> {
        Ok(self
            .conn()
            .query_row("SELECT COALESCE(MAX(seq), 0) FROM events", [], |r| r.get(0))?)
    }

    /// Stores `turn.quiet` for the turn that runs for the agent. Only a turn a schedule started can end quietly, and
    /// only while it runs. The checks and the write happen under one hold of the connection, so no turn ends between
    /// them, and two calls cannot store two marks. `publish` gets the stored event while the connection is still held,
    /// so the subscribers see the events of the agent in `seq` order.
    pub fn mark_quiet_turn(
        &self,
        agent_id: &str,
        reason: Option<String>,
        publish: impl FnOnce(&Event),
    ) -> Result<QuietMark> {
        let conn = self.conn();
        let started: Option<(i64, String)> = conn
            .query_row(
                "SELECT seq, payload FROM events WHERE agent_id = ?1 AND kind = 'turn.started' ORDER BY seq DESC LIMIT 1",
                params![agent_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let Some((started_seq, payload)) = started else {
            return Ok(QuietMark::NoTurn);
        };
        let started = crate::event::EventBody::from_parts("turn.started", serde_json::from_str(&payload)?)?;
        let crate::event::EventBody::TurnStarted { turn_id, source, .. } = started else {
            return Ok(QuietMark::NoTurn);
        };
        let ended: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE agent_id = ?1 AND kind = 'turn.completed' AND seq > ?2)",
            params![agent_id, started_seq],
            |r| r.get(0),
        )?;
        if ended {
            return Ok(QuietMark::NoTurn);
        }
        if source != crate::event::Source::Schedule {
            return Ok(QuietMark::NotScheduled);
        }
        let marked: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM events WHERE agent_id = ?1 AND kind = 'turn.quiet' AND seq > ?2)",
            params![agent_id, started_seq],
            |r| r.get(0),
        )?;
        if marked {
            return Ok(QuietMark::Already);
        }
        let body = crate::event::EventBody::TurnQuiet { turn_id, reason };
        let (kind, payload) = body.to_parts();
        let ts = now_ms();
        conn.execute(
            "INSERT INTO events (agent_id, ts, kind, payload) VALUES (?1, ?2, ?3, ?4)",
            params![agent_id, ts, kind, payload.to_string()],
        )?;
        let event = Event {
            seq: conn.last_insert_rowid(),
            agent_id: agent_id.to_string(),
            ts,
            body,
        };
        publish(&event);
        Ok(QuietMark::Marked(Box::new(event)))
    }

    /// The newest event of an agent of this kind (`agent.quick_replies`), if there is one.
    pub fn last_event_of_kind(&self, agent_id: &str, kind: &str) -> Result<Option<Event>> {
        let row = self
            .conn()
            .query_row(
                "SELECT seq, ts, payload FROM events WHERE agent_id = ?1 AND kind = ?2 ORDER BY seq DESC LIMIT 1",
                params![agent_id, kind],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, String>(2)?)),
            )
            .optional()?;
        let Some((seq, ts, payload)) = row else {
            return Ok(None);
        };
        let payload: Value = serde_json::from_str(&payload)?;
        Ok(Some(Event {
            seq,
            agent_id: agent_id.to_string(),
            ts,
            body: EventBody::from_parts(kind, payload)?,
        }))
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

    /// The seq of the newest message the person wrote to the agent (queued ones too), if any.
    pub fn last_user_message_seq(&self, agent_id: &str) -> Result<Option<i64>> {
        Ok(self.conn().query_row(
            "SELECT MAX(seq) FROM events WHERE agent_id = ?1 AND kind = 'message.user'
               AND json_extract(payload, '$.source') = 'user'",
            [agent_id],
            |r| r.get(0),
        )?)
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
    fn the_file_database_runs_in_wal_with_the_connection_settings() {
        let dir = tempfile::tempdir().unwrap();
        let s = Store::open(&dir.path().join("bandito.db")).unwrap();
        let conn = s.conn();
        let mode: String = conn.query_row("PRAGMA journal_mode", [], |r| r.get(0)).unwrap();
        assert_eq!(mode, "wal");
        let sync: i64 = conn.query_row("PRAGMA synchronous", [], |r| r.get(0)).unwrap();
        assert_eq!(sync, 1, "synchronous=NORMAL");
        let timeout: i64 = conn.query_row("PRAGMA busy_timeout", [], |r| r.get(0)).unwrap();
        assert_eq!(timeout, 5000);
        let fk: i64 = conn.query_row("PRAGMA foreign_keys", [], |r| r.get(0)).unwrap();
        assert_eq!(fk, 1);
        let cache: i64 = conn.query_row("PRAGMA cache_size", [], |r| r.get(0)).unwrap();
        assert_eq!(cache, -16000, "16 MB of pages");
        let temp: i64 = conn.query_row("PRAGMA temp_store", [], |r| r.get(0)).unwrap();
        assert_eq!(temp, 2, "temp_store=MEMORY");
    }

    #[test]
    fn a_fresh_database_reaches_the_last_migration_with_all_the_tables_and_columns() {
        let s = Store::open_in_memory().unwrap();
        let version: i64 = s.conn().query_row("PRAGMA user_version", [], |r| r.get(0)).unwrap();
        assert_eq!(version as usize, MIGRATIONS.len());
        for table in ["integration_tools", "tool_calls"] {
            let found: i64 = s
                .conn()
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    [table],
                    |r| r.get(0),
                )
                .unwrap();
            assert_eq!(found, 1, "table {table}");
        }
        let columns: Vec<String> = s
            .conn()
            .prepare("SELECT name FROM pragma_table_info('integrations')")
            .unwrap()
            .query_map([], |r| r.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        for column in ["tool_mode", "tool_overrides"] {
            assert!(columns.iter().any(|c| c == column), "column integrations.{column}");
        }
        let indexed: i64 = s
            .conn()
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'tool_calls_at'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(indexed, 1, "index on tool_calls(at_ms)");
    }

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
    fn the_device_sign_in_migration_keeps_every_integration_and_accepts_the_new_value() {
        // A database as the previous release left it: every migration but the newest, with a browser sign-in row.
        let before = MIGRATIONS.len() - 1;
        let conn = Connection::open_in_memory().unwrap();
        for sql in &MIGRATIONS[..before] {
            conn.execute_batch(sql).unwrap();
        }
        conn.pragma_update(None, "user_version", before as i64).unwrap();
        conn.execute(
            "INSERT INTO integrations (id, name, kind, url, headers, enabled, created_at, auth, tool_mode, tool_overrides)
             VALUES ('i1', 'linear', 'http', 'https://mcp.linear.app/mcp', '{\"X\":\"y\"}', 0, 5, 'oauth', 'confirm_writes', '{\"a\":\"deny\"}')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO integration_tools (integration_id, name, seen_at) VALUES ('i1', 'search', 9)",
            [],
        )
        .unwrap();

        let s = Store::init(conn).unwrap();
        let row = s.integration_get("i1").unwrap().unwrap();
        assert_eq!(
            (row.name.as_str(), row.auth, row.enabled, row.created_at),
            ("linear", IntegrationAuth::Oauth, false, 5)
        );
        assert_eq!(row.tool_mode, ToolMode::ConfirmWrites);
        assert_eq!(row.headers.get("X").map(String::as_str), Some("y"));
        assert_eq!(s.integration_tools("i1").unwrap().len(), 1);
        assert!(s.integration_set_auth("i1", IntegrationAuth::Device).unwrap());
        assert_eq!(s.integration_get("i1").unwrap().unwrap().auth, IntegrationAuth::Device);
        // The name stays unique, as it was.
        let dup = NewIntegration {
            name: "linear".into(),
            kind: IntegrationKind::Http,
            command: None,
            args: vec![],
            url: Some("https://x.example/mcp".into()),
            env: Default::default(),
            headers: Default::default(),
            enabled: true,
            auth: IntegrationAuth::None,
        };
        assert!(s.integration_create(dup).is_err());
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

#[cfg(test)]
mod quiet_mark_tests {
    use super::*;
    use crate::event::Source;

    fn started(store: &Store, source: Source) {
        store
            .append_event(
                "a",
                EventBody::TurnStarted {
                    turn_id: "t".into(),
                    source,
                    reactions_until: None,
                    message_seq: None,
                },
            )
            .unwrap();
    }

    fn quiet_marks(store: &Store) -> usize {
        store
            .events_since(0, 1000, Some("a"))
            .unwrap()
            .iter()
            .filter(|e| matches!(e.body, EventBody::TurnQuiet { .. }))
            .count()
    }

    #[test]
    fn only_a_scheduled_turn_takes_the_mark_and_publishes_it() {
        let store = Store::open_in_memory().unwrap();
        assert_eq!(store.mark_quiet_turn("a", None, |_| {}).unwrap(), QuietMark::NoTurn);

        started(&store, Source::User);
        assert_eq!(
            store.mark_quiet_turn("a", None, |_| {}).unwrap(),
            QuietMark::NotScheduled
        );
        assert_eq!(quiet_marks(&store), 0);

        // A scheduled turn: the mark is stored with its reason, and the publish sees the stored event.
        let store = Store::open_in_memory().unwrap();
        started(&store, Source::Schedule);
        let mut published = None;
        let mark = store
            .mark_quiet_turn("a", Some("no mail".into()), |ev| published = Some(ev.clone()))
            .unwrap();
        let QuietMark::Marked(ev) = mark else {
            panic!("expected a mark");
        };
        let ev = *ev;
        assert_eq!(published, Some(ev.clone()));
        assert!(ev.seq > 0);
        assert_eq!(
            ev.body,
            EventBody::TurnQuiet {
                turn_id: "t".into(),
                reason: Some("no mail".into()),
            }
        );
        assert_eq!(quiet_marks(&store), 1);
    }

    #[test]
    fn a_second_call_in_the_same_turn_adds_nothing() {
        let store = Store::open_in_memory().unwrap();
        started(&store, Source::Schedule);
        assert!(matches!(
            store.mark_quiet_turn("a", None, |_| {}).unwrap(),
            QuietMark::Marked(_)
        ));
        assert_eq!(store.mark_quiet_turn("a", None, |_| {}).unwrap(), QuietMark::Already);
        assert_eq!(quiet_marks(&store), 1);
    }

    #[test]
    fn a_turn_that_has_ended_takes_no_mark() {
        // The boundary with `turn.completed`: once the turn is completed, a late call finds no turn.
        let store = Store::open_in_memory().unwrap();
        started(&store, Source::Schedule);
        store
            .append_event(
                "a",
                EventBody::TurnCompleted {
                    turn_id: "t".into(),
                    status: crate::event::TurnStatus::Ok,
                    usage: None,
                    cost_usd: None,
                },
            )
            .unwrap();
        assert_eq!(store.mark_quiet_turn("a", None, |_| {}).unwrap(), QuietMark::NoTurn);
        assert_eq!(quiet_marks(&store), 0);
    }

    #[test]
    fn parallel_calls_store_one_mark() {
        let store = std::sync::Arc::new(Store::open_in_memory().unwrap());
        started(&store, Source::Schedule);
        let handles: Vec<_> = (0..8)
            .map(|_| {
                let store = store.clone();
                std::thread::spawn(move || store.mark_quiet_turn("a", None, |_| {}).unwrap())
            })
            .collect();
        let marks: Vec<QuietMark> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        assert_eq!(marks.iter().filter(|m| matches!(m, QuietMark::Marked(_))).count(), 1);
        assert_eq!(marks.iter().filter(|m| **m == QuietMark::Already).count(), 7);
        assert_eq!(quiet_marks(&store), 1);
    }
}
