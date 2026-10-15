//! Read marks: the seq each agent's chat was read to, kept on the server so that every device of the owner shows the
//! same unread state (docs/ARCHITECTURE.md#read-marks). One row per agent; the mark only moves forward.

use super::{Store, now_ms};
use anyhow::Result;
use rusqlite::{OptionalExtension, params};

impl Store {
    /// The seq the agent's chat was read to, or nil when no device has read it yet.
    pub fn read_mark(&self, agent_id: &str) -> Result<Option<i64>> {
        let conn = self.conn();
        Ok(conn
            .query_row("SELECT seq FROM read_marks WHERE agent_id = ?1", [agent_id], |r| {
                r.get(0)
            })
            .optional()?)
    }

    /// Moves the agent's mark up to `seq`, cut to the agent's newest event (a seq past it is not read yet). The mark
    /// never moves back: two devices that read at once keep the newer one. Returns the stored mark (0 when none) and
    /// whether this call moved it. One transaction, so a read and a mark cannot interleave.
    pub fn read_mark_raise(&self, agent_id: &str, seq: i64) -> Result<(i64, bool)> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let newest: Option<i64> = tx.query_row("SELECT MAX(seq) FROM events WHERE agent_id = ?1", [agent_id], |r| {
            r.get(0)
        })?;
        let old: i64 = tx
            .query_row("SELECT seq FROM read_marks WHERE agent_id = ?1", [agent_id], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or(0);
        // Events start at seq 1, so 0 means "nothing read"; an agent without events has nothing to move to.
        let target = seq.min(newest.unwrap_or(0));
        let new = old.max(target);
        let moved = new > old;
        if moved {
            tx.execute(
                "INSERT INTO read_marks (agent_id, seq, updated_ms) VALUES (?1, ?2, ?3)
                 ON CONFLICT (agent_id) DO UPDATE SET seq = excluded.seq, updated_ms = excluded.updated_ms",
                params![agent_id, new, now_ms()],
            )?;
        }
        tx.commit()?;
        Ok((new, moved))
    }
}

#[cfg(test)]
mod tests {
    use crate::event::EventBody;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, Store};

    fn store_with_agent(name: &str) -> (Store, String) {
        let store = Store::open_in_memory().unwrap();
        let id = add_agent(&store, name);
        (store, id)
    }

    fn add_agent(store: &Store, name: &str) -> String {
        store
            .agent_create(NewAgent {
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                integrations: None,
                name: name.into(),
                role: String::new(),
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
            })
            .unwrap()
            .id
    }

    fn say(store: &Store, agent: &str, text: &str) -> i64 {
        store
            .append_event(agent, EventBody::MessageAssistant { text: text.into() })
            .unwrap()
            .seq
    }

    #[test]
    fn the_mark_moves_forward_and_never_back() {
        let (store, a) = store_with_agent("A");
        let s1 = say(&store, &a, "one");
        let s2 = say(&store, &a, "two");
        let s3 = say(&store, &a, "three");
        assert_eq!(store.read_mark(&a).unwrap(), None);
        assert_eq!(store.read_mark_raise(&a, s1).unwrap(), (s1, true));
        assert_eq!(store.read_mark_raise(&a, s3).unwrap(), (s3, true));
        // An older seq (another device, a late message) does not move it back, and says so.
        assert_eq!(store.read_mark_raise(&a, s2).unwrap(), (s3, false));
        assert_eq!(store.read_mark_raise(&a, s3).unwrap(), (s3, false));
        assert_eq!(store.read_mark(&a).unwrap(), Some(s3));
    }

    #[test]
    fn the_mark_is_cut_to_the_newest_event_of_its_agent() {
        let (store, a) = store_with_agent("A");
        let b = add_agent(&store, "B");
        let mine = say(&store, &a, "mine");
        // Another agent's events come later in the global sequence: they must not raise A's mark.
        say(&store, &b, "theirs");
        let theirs = say(&store, &b, "theirs again");
        assert!(theirs > mine);
        assert_eq!(store.read_mark_raise(&a, theirs).unwrap(), (mine, true));
        assert_eq!(store.read_mark(&a).unwrap(), Some(mine));
        assert_eq!(store.read_mark(&b).unwrap(), None);
        // The cut also holds for a seq past everything the agent has.
        let later = say(&store, &a, "later");
        assert_eq!(store.read_mark_raise(&a, i64::MAX).unwrap(), (later, true));
    }

    #[test]
    fn an_agent_without_events_has_nothing_to_read() {
        let (store, a) = store_with_agent("A");
        assert_eq!(store.read_mark_raise(&a, 5).unwrap(), (0, false));
        assert_eq!(store.read_mark(&a).unwrap(), None);
    }

    #[test]
    fn a_negative_seq_never_stores_a_mark() {
        let (store, a) = store_with_agent("A");
        say(&store, &a, "one");
        assert_eq!(store.read_mark_raise(&a, -3).unwrap(), (0, false));
        assert_eq!(store.read_mark(&a).unwrap(), None);
    }

    #[test]
    fn a_transient_event_is_not_stored_and_its_seq_is_zero() {
        let (store, a) = store_with_agent("A");
        say(&store, &a, "one");
        let before = store.last_seq().unwrap();
        let ev = store.append_event(&a, EventBody::ReadMark { seq: 1 }).unwrap();
        assert_eq!(ev.seq, 0);
        assert_eq!(store.last_seq().unwrap(), before);
    }

    #[test]
    fn deleting_an_agent_deletes_its_mark() {
        let (store, a) = store_with_agent("A");
        let b = add_agent(&store, "B");
        let s = say(&store, &a, "one");
        say(&store, &b, "other");
        store.read_mark_raise(&a, s).unwrap();
        store.read_mark_raise(&b, 2).unwrap();
        assert!(store.agent_delete(&a).unwrap());
        assert_eq!(store.read_mark(&a).unwrap(), None);
        assert_eq!(store.read_mark(&b).unwrap(), Some(2));
    }
}
