//! Recall over an agent's own past conversation: the user and assistant
//! messages in the event log. Older messages are not in the agent's context;
//! the crew MCP server reads them through `history.search` / `history.day`.

use super::Store;
use crate::event::{Event, EventBody};
use anyhow::{Context, Result};
use rusqlite::params;

/// Most matches `history_search` returns.
const SEARCH_LIMIT_MAX: u32 = 50;
/// Most messages `history_range` returns.
const RANGE_LIMIT_MAX: u32 = 500;

impl Store {
    /// Messages of one agent whose payload contains `query`, newest first.
    /// A blank query matches nothing.
    pub fn history_search(&self, agent_id: &str, query: &str, limit: u32) -> Result<Vec<Event>> {
        let query = query.trim();
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let pattern = format!("%{}%", escape_like(query));
        let conn = self.conn();
        let mut stmt = conn.prepare(
            r"SELECT seq, agent_id, ts, kind, payload FROM events
              WHERE agent_id = ?1
                AND kind IN ('message.user','message.assistant')
                AND json_extract(payload, '$.text') LIKE ?2 ESCAPE '\'
              ORDER BY seq DESC LIMIT ?3",
        )?;
        let rows = stmt.query_map(params![agent_id, pattern, limit.clamp(1, SEARCH_LIMIT_MAX)], map_row)?;
        let events: Result<Vec<Event>> = rows.map(|r| decode(r?)).collect();
        events
    }

    /// Messages of one agent with `from_ms <= ts < to_ms`, oldest first.
    pub fn history_range(&self, agent_id: &str, from_ms: i64, to_ms: i64, limit: u32) -> Result<Vec<Event>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT seq, agent_id, ts, kind, payload FROM events
             WHERE agent_id = ?1
               AND kind IN ('message.user','message.assistant')
               AND ts >= ?2 AND ts < ?3
             ORDER BY ts, seq LIMIT ?4",
        )?;
        let rows = stmt.query_map(
            params![agent_id, from_ms, to_ms, limit.clamp(1, RANGE_LIMIT_MAX)],
            map_row,
        )?;
        let events: Result<Vec<Event>> = rows.map(|r| decode(r?)).collect();
        events
    }
}

/// Raw columns of one event row: seq, agent_id, ts, kind, payload.
type Row = (i64, String, i64, String, String);

fn map_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Row> {
    Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
}

fn decode(row: Row) -> Result<Event> {
    let (seq, agent_id, ts, kind, payload) = row;
    let body = EventBody::from_parts(&kind, serde_json::from_str(&payload)?)
        .with_context(|| format!("decode event {seq} ({kind})"))?;
    Ok(Event {
        seq,
        agent_id,
        ts,
        body,
    })
}

/// Escape `LIKE` wildcards and the escape character itself. Used with `ESCAPE '\'`.
fn escape_like(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '\\' | '%' | '_') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::Source;

    fn user(text: &str) -> EventBody {
        EventBody::MessageUser {
            text: text.into(),
            source: Source::User,
            from_agent: None,
        }
    }

    fn assistant(text: &str) -> EventBody {
        EventBody::MessageAssistant { text: text.into() }
    }

    fn seqs(events: &[Event]) -> Vec<i64> {
        events.iter().map(|e| e.seq).collect()
    }

    /// Insert with a chosen timestamp (`append_event` stamps the current time).
    fn insert_at(s: &Store, agent_id: &str, ts: i64, body: EventBody) -> i64 {
        let (kind, payload) = body.to_parts();
        let conn = s.conn();
        conn.execute(
            "INSERT INTO events (agent_id, ts, kind, payload) VALUES (?1, ?2, ?3, ?4)",
            params![agent_id, ts, kind, payload.to_string()],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    #[test]
    fn search_finds_substrings_newest_first() {
        let s = Store::open_in_memory().unwrap();
        let a = s.append_event("a", user("deploy the staging build")).unwrap();
        let b = s.append_event("a", assistant("Deployed to Staging.")).unwrap();
        s.append_event("a", user("unrelated")).unwrap();
        assert_eq!(seqs(&s.history_search("a", "staging", 20).unwrap()), [b.seq, a.seq]);
        assert_eq!(seqs(&s.history_search("a", "DEPLOY", 20).unwrap()), [b.seq, a.seq]);
    }

    #[test]
    fn search_skips_other_kinds_and_other_agents() {
        let s = Store::open_in_memory().unwrap();
        s.append_event(
            "a",
            EventBody::Error {
                message: "staging broke".into(),
            },
        )
        .unwrap();
        let mine = s.append_event("a", user("staging ok")).unwrap();
        s.append_event("b", user("staging secret")).unwrap();
        assert_eq!(seqs(&s.history_search("a", "staging", 20).unwrap()), [mine.seq]);
        assert!(s.history_search("c", "staging", 20).unwrap().is_empty());
    }

    #[test]
    fn search_escapes_wildcards_and_backslash() {
        let s = Store::open_in_memory().unwrap();
        let pct = s.append_event("a", user("100% sure")).unwrap();
        s.append_event("a", user("100 sure")).unwrap();
        let under = s.append_event("a", user("snake_case name")).unwrap();
        s.append_event("a", user("snakeXcase name")).unwrap();
        let back = s.append_event("a", user(r"C:\tmp")).unwrap();
        s.append_event("a", user("C:tmp")).unwrap();

        assert_eq!(seqs(&s.history_search("a", "%", 20).unwrap()), [pct.seq]);
        assert_eq!(seqs(&s.history_search("a", "_", 20).unwrap()), [under.seq]);
        assert_eq!(seqs(&s.history_search("a", r"\", 20).unwrap()), [back.seq]);
    }

    #[test]
    fn search_limit_and_blank_query() {
        let s = Store::open_in_memory().unwrap();
        for i in 0..55 {
            s.append_event("a", user(&format!("note {i}"))).unwrap();
        }
        assert_eq!(s.history_search("a", "note", 2).unwrap().len(), 2);
        assert_eq!(s.history_search("a", "note", 1000).unwrap().len(), 50);
        assert!(s.history_search("a", "   ", 20).unwrap().is_empty());
        assert!(s.history_search("a", "", 20).unwrap().is_empty());
    }

    #[test]
    fn range_is_half_open_and_oldest_first() {
        let s = Store::open_in_memory().unwrap();
        let t1 = insert_at(&s, "a", 1_000, user("first"));
        let t2 = insert_at(&s, "a", 2_000, assistant("second"));
        let t3 = insert_at(&s, "a", 2_500, user("third"));
        insert_at(&s, "a", 3_000, user("at the end, excluded"));
        insert_at(
            &s,
            "a",
            1_500,
            EventBody::Error {
                message: "not a message".into(),
            },
        );
        insert_at(&s, "b", 1_800, user("other agent"));

        let all = s.history_range("a", 1_000, 3_000, 100).unwrap();
        assert_eq!(seqs(&all), [t1, t2, t3]);
        assert_eq!(seqs(&s.history_range("a", 1_000, 3_000, 2).unwrap()), [t1, t2]);
        assert_eq!(s.history_range("a", 3_000, 4_000, 100).unwrap().len(), 1);
        assert!(s.history_range("a", 4_000, 5_000, 100).unwrap().is_empty());
    }
}
