//! SQLite store. One connection behind a mutex; calls are short, so callers
//! on the async side wrap heavy ones in `spawn_blocking` if needed.

use crate::event::{Event, EventBody};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

mod agents;
mod approvals;
pub mod auth;
mod checkpoints;
mod history;
mod rules;
mod schedules;
mod secrets;
mod usage;
mod workspaces;

pub use agents::{Agent, AgentPatch, NewAgent};
pub use approvals::{Approval, ApprovalStatus};
pub use auth::Device;
pub use checkpoints::{Checkpoint, CheckpointKind};
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
