use super::{Store, now_ms};
use crate::event::ReactionBy;
use anyhow::Result;
use rusqlite::{Row, params};

/// A reaction on a message: who, which message (seq), which emoji, when.
#[derive(Debug, Clone, PartialEq)]
pub struct Reaction {
    pub agent_id: String,
    pub seq: i64,
    pub by: ReactionBy,
    pub emoji: String,
    pub at: i64,
}

fn by_str(by: ReactionBy) -> &'static str {
    match by {
        ReactionBy::User => "user",
        ReactionBy::Agent => "agent",
    }
}

fn from_row(r: &Row) -> rusqlite::Result<Reaction> {
    let by: String = r.get(2)?;
    Ok(Reaction {
        agent_id: r.get(0)?,
        seq: r.get(1)?,
        by: if by == "agent" {
            ReactionBy::Agent
        } else {
            ReactionBy::User
        },
        emoji: r.get(3)?,
        at: r.get(4)?,
    })
}

impl Store {
    /// Puts `by`'s reaction on a message, replacing its earlier one. `None` takes it off.
    pub fn reaction_set(&self, agent_id: &str, seq: i64, by: ReactionBy, emoji: Option<&str>) -> Result<()> {
        let conn = self.conn();
        match emoji {
            Some(e) => {
                conn.execute(
                    "INSERT INTO reactions (agent_id, seq, by, emoji, at) VALUES (?1, ?2, ?3, ?4, ?5)
                     ON CONFLICT (agent_id, seq, by) DO UPDATE SET emoji = excluded.emoji, at = excluded.at",
                    params![agent_id, seq, by_str(by), e, now_ms()],
                )?;
            }
            None => {
                conn.execute(
                    "DELETE FROM reactions WHERE agent_id = ?1 AND seq = ?2 AND by = ?3",
                    params![agent_id, seq, by_str(by)],
                )?;
            }
        }
        Ok(())
    }

    /// The reactions on one message, the user's and the agent's.
    pub fn reactions_on(&self, agent_id: &str, seq: i64) -> Result<Vec<Reaction>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT agent_id, seq, by, emoji, at FROM reactions WHERE agent_id = ?1 AND seq = ?2 ORDER BY by",
        )?;
        let rows = stmt.query_map(params![agent_id, seq], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// The human's reactions made after `after_ms` and up to `through_ms` (Unix ms), oldest first.
    pub fn user_reactions_between(&self, agent_id: &str, after_ms: i64, through_ms: i64) -> Result<Vec<Reaction>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT agent_id, seq, by, emoji, at FROM reactions
             WHERE agent_id = ?1 AND by = 'user' AND at > ?2 AND at <= ?3 ORDER BY at, seq",
        )?;
        let rows = stmt.query_map(params![agent_id, after_ms, through_ms], from_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{Store, new_id};

    #[test]
    fn one_reaction_per_person_replaces_and_clears() {
        let s = Store::open_in_memory().unwrap();
        let a = new_id();
        s.reaction_set(&a, 5, ReactionBy::User, Some("👍")).unwrap();
        s.reaction_set(&a, 5, ReactionBy::User, Some("👀")).unwrap();
        s.reaction_set(&a, 5, ReactionBy::Agent, Some("✅")).unwrap();
        let on = s.reactions_on(&a, 5).unwrap();
        assert_eq!(on.len(), 2);
        assert_eq!(on.iter().find(|r| r.by == ReactionBy::User).unwrap().emoji, "👀");
        s.reaction_set(&a, 5, ReactionBy::User, None).unwrap();
        let on = s.reactions_on(&a, 5).unwrap();
        assert_eq!(on.len(), 1);
        assert_eq!(on[0].by, ReactionBy::Agent);
        // Clearing what is not there is no error.
        s.reaction_set(&a, 9, ReactionBy::User, None).unwrap();
    }

    #[test]
    fn user_reactions_between_count_only_the_humans_inside_the_window() {
        let s = Store::open_in_memory().unwrap();
        let a = new_id();
        s.reaction_set(&a, 1, ReactionBy::User, Some("👍")).unwrap();
        s.reaction_set(&a, 2, ReactionBy::Agent, Some("👀")).unwrap();
        let all = s.user_reactions_between(&a, -1, now_ms() + 60_000).unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!((all[0].seq, all[0].emoji.as_str()), (1, "👍"));
        // Made after the window's end: not in this window, it waits for the next one.
        assert!(s.user_reactions_between(&a, -1, all[0].at - 1).unwrap().is_empty());
        // Not after the window's start: already in an earlier one.
        assert!(
            s.user_reactions_between(&a, all[0].at, now_ms() + 60_000)
                .unwrap()
                .is_empty()
        );
        assert!(
            s.user_reactions_between(&new_id(), -1, now_ms() + 60_000)
                .unwrap()
                .is_empty()
        );
    }
}
