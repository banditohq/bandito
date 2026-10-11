//! Store side of the agent migration (see docs/ARCHITECTURE.md#agent-migration): reading an agent's events as stored,
//! writing a moved agent's events in one transaction with new `seq`s, and marking an agent as moved.

use super::{Store, now_ms};
use anyhow::{Result, bail};
use rusqlite::params;
use serde_json::Value;
use std::collections::HashMap;

/// One stored event as it leaves the server: the payload stays the JSON text that was stored.
#[derive(Debug, Clone, PartialEq)]
pub struct ExportedEvent {
    pub seq: i64,
    pub ts: i64,
    pub kind: String,
    pub payload: String,
}

/// One event to write for a moved agent: its time and kind from the source, its payload already checked.
#[derive(Debug, Clone, PartialEq)]
pub struct NewEvent {
    /// The seq the event had on the source server. Only the old-to-new map uses it.
    pub old_seq: i64,
    pub ts: i64,
    pub kind: String,
    pub payload: Value,
}

impl Store {
    /// The agent's events with `after < seq <= upto`, oldest first, at most `limit`. Payloads are not decoded.
    pub fn events_for_export(&self, agent_id: &str, after: i64, upto: i64, limit: u32) -> Result<Vec<ExportedEvent>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT seq, ts, kind, payload FROM events
             WHERE agent_id = ?1 AND seq > ?2 AND seq <= ?3 ORDER BY seq LIMIT ?4",
        )?;
        let rows = stmt.query_map(params![agent_id, after, upto, limit], |r| {
            Ok(ExportedEvent {
                seq: r.get(0)?,
                ts: r.get(1)?,
                kind: r.get(2)?,
                payload: r.get(3)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Writes a moved agent's events in one transaction: either all of them are stored or none. `source` yields them
    /// oldest first. `prepare` gets each event's kind and payload and the map from source seqs to the new ones (of the
    /// events already written), may change the payload, and returns `false` to leave the event out. Returns how many
    /// were written. Each event gets a new `seq` and keeps its source time.
    pub fn events_import<I, F>(&self, agent_id: &str, source: I, mut prepare: F) -> Result<usize>
    where
        I: Iterator<Item = Result<NewEvent>>,
        F: FnMut(&str, &mut Value, &HashMap<i64, i64>) -> bool,
    {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let mut map: HashMap<i64, i64> = HashMap::new();
        let mut written = 0;
        {
            let mut insert = tx.prepare("INSERT INTO events (agent_id, ts, kind, payload) VALUES (?1, ?2, ?3, ?4)")?;
            for event in source {
                let mut event = event?;
                if !prepare(&event.kind, &mut event.payload, &map) {
                    continue;
                }
                insert.execute(params![agent_id, event.ts, event.kind, event.payload.to_string()])?;
                map.insert(event.old_seq, tx.last_insert_rowid());
                written += 1;
            }
        }
        tx.commit()?;
        Ok(written)
    }

    /// Marks the agent as moved to the server `moved_to` at `at`. Moving it again replaces the mark. The pause is not set
    /// here: `Supervisor::set_paused` does it, since it also stops the agent's session. Errors when the agent does not exist.
    pub fn agent_set_migrated(&self, id: &str, moved_to: &str, at: i64) -> Result<()> {
        let n = self.conn().execute(
            "UPDATE agents SET migrated_to = ?2, migrated_at = ?3, updated_at = ?4 WHERE id = ?1",
            params![id, moved_to, at, now_ms()],
        )?;
        if n == 0 {
            bail!("no agent {id}");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{EventBody, Source};
    use crate::runtime::RuntimeKind;
    use crate::store::NewAgent;

    fn agent(s: &Store, name: &str) -> String {
        let n: NewAgent =
            serde_json::from_value(serde_json::json!({ "name": name, "runtime": RuntimeKind::Claude })).unwrap();
        s.agent_create(n).unwrap().id
    }

    fn user(text: &str) -> EventBody {
        EventBody::MessageUser {
            text: text.into(),
            source: Source::User,
            from_agent: None,
            command: None,
            reply_to: None,
            attachments: vec![],
            mentions: vec![],
            queued: false,
        }
    }

    #[test]
    fn export_reads_one_agents_events_up_to_a_seq() {
        let s = Store::open_in_memory().unwrap();
        let a = agent(&s, "A");
        let b = agent(&s, "B");
        let e1 = s.append_event(&a, user("one")).unwrap();
        s.append_event(&b, user("other")).unwrap();
        let e3 = s.append_event(&a, user("two")).unwrap();
        s.append_event(&a, user("later")).unwrap();
        let got = s.events_for_export(&a, 0, e3.seq, 100).unwrap();
        assert_eq!(got.iter().map(|e| e.seq).collect::<Vec<_>>(), vec![e1.seq, e3.seq]);
        let page = s.events_for_export(&a, e1.seq, e3.seq, 100).unwrap();
        assert_eq!(page.len(), 1);
        assert_eq!(s.events_for_export(&a, 0, e3.seq, 1).unwrap().len(), 1);
    }

    #[test]
    fn import_is_one_transaction_with_new_seqs_and_the_old_to_new_map() {
        let s = Store::open_in_memory().unwrap();
        let other = agent(&s, "Other");
        s.append_event(&other, user("x")).unwrap();
        let a = agent(&s, "A");
        let rows = (1..=3).map(|i| {
            Ok(NewEvent {
                old_seq: 100 + i,
                ts: 5_000 + i,
                kind: "message.assistant".into(),
                payload: serde_json::json!({ "text": format!("m{i}") }),
            })
        });
        let mut seen: Vec<HashMap<i64, i64>> = Vec::new();
        let n = s
            .events_import(&a, rows, |_, _, map| {
                seen.push(map.clone());
                true
            })
            .unwrap();
        assert_eq!(n, 3);
        assert_eq!(seen[0].len(), 0);
        assert_eq!(seen[2].len(), 2, "the third sees the first two");
        let got = s.events_for_export(&a, 0, i64::MAX, 100).unwrap();
        assert_eq!(got.len(), 3);
        assert!(got[0].seq > 1, "new seqs follow the other agent's");
        assert_eq!(got.iter().map(|e| e.ts).collect::<Vec<_>>(), vec![5_001, 5_002, 5_003]);
        assert_eq!(seen[2][&101], got[0].seq);
    }

    #[test]
    fn a_failing_source_writes_nothing() {
        let s = Store::open_in_memory().unwrap();
        let a = agent(&s, "A");
        let rows = vec![
            Ok(NewEvent {
                old_seq: 1,
                ts: 1,
                kind: "message.assistant".into(),
                payload: serde_json::json!({ "text": "ok" }),
            }),
            Err(anyhow::anyhow!("broken line")),
        ];
        assert!(s.events_import(&a, rows.into_iter(), |_, _, _| true).is_err());
        assert!(s.events_for_export(&a, 0, i64::MAX, 10).unwrap().is_empty());
    }

    #[test]
    fn prepare_may_drop_an_event() {
        let s = Store::open_in_memory().unwrap();
        let a = agent(&s, "A");
        let rows = (1..=2).map(|i| {
            Ok(NewEvent {
                old_seq: i,
                ts: i,
                kind: if i == 1 { "reaction" } else { "message.assistant" }.into(),
                payload: serde_json::json!({ "text": "t" }),
            })
        });
        let n = s.events_import(&a, rows, |kind, _, _| kind != "reaction").unwrap();
        assert_eq!(n, 1);
    }

    #[test]
    fn marking_sets_both_fields() {
        let s = Store::open_in_memory().unwrap();
        let a = agent(&s, "A");
        s.agent_set_migrated(&a, "vps", 1234).unwrap();
        let got = s.agent_view(&a).unwrap().unwrap();
        assert_eq!(
            (got.migrated_to.as_deref(), got.migrated_at, got.paused),
            (Some("vps"), Some(1234), false)
        );
        assert!(s.agent_set_migrated("nobody", "vps", 1).is_err());
        let plain = agent(&s, "B");
        let got = s.agent_view(&plain).unwrap().unwrap();
        assert_eq!((got.migrated_to, got.migrated_at), (None, None));
    }
}
