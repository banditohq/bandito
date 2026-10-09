//! SQLite store. One connection behind a mutex; calls are short, so callers
//! on the async side wrap heavy ones in `spawn_blocking` if needed.

use crate::event::{Event, EventBody};
use anyhow::{Context, Result, bail};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Mutex;

mod agents;
mod approvals;
pub mod auth;
mod rules;
mod schedules;

pub use agents::{Agent, AgentPatch, NewAgent};
pub use approvals::{Approval, ApprovalStatus};
pub use auth::Device;
pub use rules::{Rule, RuleAction};
pub use schedules::{NewSchedule, NextRun, Schedule, SchedulePatch};

const MIGRATIONS: &[&str] = &[
    include_str!("../../migrations/0001_init.sql"),
    include_str!("../../migrations/0002_memory.sql"),
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

    // ---- secrets ----

    pub fn secret_get(&self, name: &str) -> Result<Option<String>> {
        Ok(self
            .conn()
            .query_row("SELECT value FROM secrets WHERE name = ?1", [name], |r| r.get(0))
            .optional()?)
    }

    pub fn secret_set(&self, name: &str, value: &str) -> Result<()> {
        self.conn().execute(
            "INSERT INTO secrets (name, value) VALUES (?1, ?2)
             ON CONFLICT(name) DO UPDATE SET value = excluded.value",
            params![name, value],
        )?;
        Ok(())
    }
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

    #[test]
    fn secrets_upsert() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.secret_get("k").unwrap(), None);
        s.secret_set("k", "1").unwrap();
        s.secret_set("k", "2").unwrap();
        assert_eq!(s.secret_get("k").unwrap().as_deref(), Some("2"));
    }
}
