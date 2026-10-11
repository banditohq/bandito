//! The Telegram bot's tables: linked chats, the messages it sent that later events refer to, and its small state
//! (the poll offset, the bot's name). The bot's token is a secret (`telegram::TOKEN_SECRET`), not here.
//! See docs/ARCHITECTURE.md#telegram.

use super::Store;
use anyhow::{Result, bail};
use rusqlite::{OptionalExtension, Row, params};
use serde::Serialize;

/// Most chats that can be linked at once.
pub const MAX_CHATS: i64 = 5;

/// The ways a chat can answer for agents' answers (`telegram_chats.answers`).
pub const ANSWER_MODES: [&str; 3] = ["all", "telegram", "none"];

/// A private chat linked to the bot.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct TgChat {
    pub chat_id: i64,
    /// The Telegram user the chat belongs to: only this user's messages and presses count.
    pub user_id: i64,
    pub title: String,
    pub language: String,
    pub linked_at: i64,
    pub approvals: bool,
    pub answers: String,
    /// The agent plain messages go to, when one was chosen.
    pub current_agent: Option<String>,
}

/// What linking a chat came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TgLink {
    Linked,
    /// [`MAX_CHATS`] other chats are linked already.
    Full,
}

/// A message the bot sent, kept so a reply or a later event can find it.
#[derive(Debug, Clone, PartialEq)]
pub struct TgMessage {
    pub chat_id: i64,
    pub message_id: i64,
    pub agent_id: String,
    pub kind: String,
    pub ref_id: String,
    pub created_at: i64,
}

const CHAT_COLS: &str = "chat_id, user_id, title, language, linked_at, approvals, answers, current_agent";

fn chat_row(r: &Row) -> rusqlite::Result<TgChat> {
    Ok(TgChat {
        chat_id: r.get(0)?,
        user_id: r.get(1)?,
        title: r.get(2)?,
        language: r.get(3)?,
        linked_at: r.get(4)?,
        approvals: r.get::<_, i64>(5)? != 0,
        answers: r.get(6)?,
        current_agent: r.get(7)?,
    })
}

fn message_row(r: &Row) -> rusqlite::Result<TgMessage> {
    Ok(TgMessage {
        chat_id: r.get(0)?,
        message_id: r.get(1)?,
        agent_id: r.get(2)?,
        kind: r.get(3)?,
        ref_id: r.get(4)?,
        created_at: r.get(5)?,
    })
}

impl Store {
    // ---- chats ----

    /// Links a chat, or refreshes the title, the language and the owner of one that is linked already (its settings
    /// stay). [`TgLink::Full`] when it is a sixth chat. One transaction, so two links cannot both take the last place.
    pub fn tg_chat_link(&self, chat_id: i64, user_id: i64, title: &str, language: &str, now: i64) -> Result<TgLink> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM telegram_chats WHERE chat_id = ?1)",
            [chat_id],
            |r| r.get(0),
        )?;
        if exists {
            tx.execute(
                "UPDATE telegram_chats SET user_id = ?2, title = ?3, language = ?4 WHERE chat_id = ?1",
                params![chat_id, user_id, title, language],
            )?;
        } else {
            let count: i64 = tx.query_row("SELECT COUNT(*) FROM telegram_chats", [], |r| r.get(0))?;
            if count >= MAX_CHATS {
                return Ok(TgLink::Full);
            }
            tx.execute(
                "INSERT INTO telegram_chats (chat_id, user_id, title, language, linked_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![chat_id, user_id, title, language, now],
            )?;
        }
        tx.commit()?;
        Ok(TgLink::Linked)
    }

    pub fn tg_chat_get(&self, chat_id: i64) -> Result<Option<TgChat>> {
        Ok(self
            .conn()
            .query_row(
                &format!("SELECT {CHAT_COLS} FROM telegram_chats WHERE chat_id = ?1"),
                [chat_id],
                chat_row,
            )
            .optional()?)
    }

    /// Every linked chat, oldest link first.
    pub fn tg_chat_list(&self) -> Result<Vec<TgChat>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(&format!(
            "SELECT {CHAT_COLS} FROM telegram_chats ORDER BY linked_at, chat_id"
        ))?;
        let rows = stmt.query_map([], chat_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Changes the settings of a chat. `false` when there is no such chat; an unknown `answers` mode is an error.
    pub fn tg_chat_update(&self, chat_id: i64, approvals: Option<bool>, answers: Option<&str>) -> Result<bool> {
        if let Some(mode) = answers
            && !ANSWER_MODES.contains(&mode)
        {
            bail!("answers must be all, telegram or none");
        }
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM telegram_chats WHERE chat_id = ?1)",
            [chat_id],
            |r| r.get(0),
        )?;
        if !exists {
            return Ok(false);
        }
        if let Some(on) = approvals {
            tx.execute(
                "UPDATE telegram_chats SET approvals = ?2 WHERE chat_id = ?1",
                params![chat_id, on as i64],
            )?;
        }
        if let Some(mode) = answers {
            tx.execute(
                "UPDATE telegram_chats SET answers = ?2 WHERE chat_id = ?1",
                params![chat_id, mode],
            )?;
        }
        tx.commit()?;
        Ok(true)
    }

    pub fn tg_chat_set_language(&self, chat_id: i64, language: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE telegram_chats SET language = ?2 WHERE chat_id = ?1",
            params![chat_id, language],
        )?;
        Ok(())
    }

    pub fn tg_chat_set_current(&self, chat_id: i64, agent_id: Option<&str>) -> Result<()> {
        self.conn().execute(
            "UPDATE telegram_chats SET current_agent = ?2 WHERE chat_id = ?1",
            params![chat_id, agent_id],
        )?;
        Ok(())
    }

    /// Removes a chat and the messages kept for it. `false` when there was none.
    pub fn tg_chat_delete(&self, chat_id: i64) -> Result<bool> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        tx.execute("DELETE FROM telegram_messages WHERE chat_id = ?1", [chat_id])?;
        let n = tx.execute("DELETE FROM telegram_chats WHERE chat_id = ?1", [chat_id])?;
        tx.commit()?;
        Ok(n > 0)
    }

    /// Forgets everything the bot kept: chats, messages and state. For a removed token or another bot.
    pub fn tg_clear(&self) -> Result<()> {
        let conn = self.conn();
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch("DELETE FROM telegram_chats; DELETE FROM telegram_messages; DELETE FROM telegram_state;")?;
        tx.commit()?;
        Ok(())
    }

    // ---- messages ----

    /// Remembers a message the bot sent (replacing a row with the same ids).
    pub fn tg_msg_add(&self, chat_id: i64, message_id: i64, agent_id: &str, kind: &str, ref_id: &str) -> Result<()> {
        self.conn().execute(
            "INSERT OR REPLACE INTO telegram_messages (chat_id, message_id, agent_id, kind, ref_id, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![chat_id, message_id, agent_id, kind, ref_id, super::now_ms()],
        )?;
        Ok(())
    }

    pub fn tg_msg_get(&self, chat_id: i64, message_id: i64) -> Result<Option<TgMessage>> {
        Ok(self
            .conn()
            .query_row(
                "SELECT chat_id, message_id, agent_id, kind, ref_id, created_at FROM telegram_messages
                 WHERE chat_id = ?1 AND message_id = ?2",
                params![chat_id, message_id],
                message_row,
            )
            .optional()?)
    }

    /// The messages of `kind` that refer to `ref_id` (the cards of one approval), in every chat.
    pub fn tg_msgs_for_ref(&self, kind: &str, ref_id: &str) -> Result<Vec<TgMessage>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT chat_id, message_id, agent_id, kind, ref_id, created_at FROM telegram_messages
             WHERE kind = ?1 AND ref_id = ?2 ORDER BY created_at",
        )?;
        let rows = stmt.query_map(params![kind, ref_id], message_row)?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    /// Changes the kind of one message from `from` to `to`. `true` for the one caller that made the change, so a card
    /// is edited once whichever of two events gets there first.
    pub fn tg_msg_claim(&self, chat_id: i64, message_id: i64, from: &str, to: &str) -> Result<bool> {
        let n = self.conn().execute(
            "UPDATE telegram_messages SET kind = ?4 WHERE chat_id = ?1 AND message_id = ?2 AND kind = ?3",
            params![chat_id, message_id, from, to],
        )?;
        Ok(n > 0)
    }

    /// Removes the messages made before `before` (Unix ms). Returns how many.
    pub fn tg_msgs_prune(&self, before: i64) -> Result<usize> {
        Ok(self
            .conn()
            .execute("DELETE FROM telegram_messages WHERE created_at < ?1", [before])?)
    }

    // ---- state ----

    pub fn tg_state_get(&self, key: &str) -> Result<Option<String>> {
        Ok(self
            .conn()
            .query_row("SELECT value FROM telegram_state WHERE key = ?1", [key], |r| r.get(0))
            .optional()?)
    }

    pub fn tg_state_set(&self, key: &str, value: &str) -> Result<()> {
        self.conn().execute(
            "INSERT INTO telegram_state (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn five_chats_at_most_and_a_linked_one_can_be_refreshed() {
        let s = Store::open_in_memory().unwrap();
        for id in 1..=5 {
            assert_eq!(s.tg_chat_link(id, id, "A", "en", 10 + id).unwrap(), TgLink::Linked);
        }
        assert_eq!(s.tg_chat_link(6, 6, "F", "en", 20).unwrap(), TgLink::Full);
        assert_eq!(s.tg_chat_list().unwrap().len(), 5);
        // A linked chat links again: the settings stay, the name and language follow.
        s.tg_chat_update(3, Some(false), Some("all")).unwrap();
        assert_eq!(s.tg_chat_link(3, 3, "New", "ru", 99).unwrap(), TgLink::Linked);
        let chat = s.tg_chat_get(3).unwrap().unwrap();
        assert_eq!((chat.title.as_str(), chat.language.as_str()), ("New", "ru"));
        assert!(!chat.approvals);
        assert_eq!(chat.answers, "all");
        assert_eq!(chat.linked_at, 13);
    }

    #[test]
    fn defaults_and_the_checks_on_settings() {
        let s = Store::open_in_memory().unwrap();
        s.tg_chat_link(1, 1, "A", "en", 1).unwrap();
        let chat = s.tg_chat_get(1).unwrap().unwrap();
        assert!(chat.approvals);
        assert_eq!(chat.answers, "telegram");
        assert_eq!(chat.current_agent, None);
        assert!(s.tg_chat_update(1, None, Some("sometimes")).is_err());
        assert!(!s.tg_chat_update(2, Some(true), None).unwrap());
        s.tg_chat_set_current(1, Some("agent")).unwrap();
        assert_eq!(
            s.tg_chat_get(1).unwrap().unwrap().current_agent.as_deref(),
            Some("agent")
        );
        s.tg_chat_set_current(1, None).unwrap();
        assert_eq!(s.tg_chat_get(1).unwrap().unwrap().current_agent, None);
    }

    #[test]
    fn deleting_a_chat_takes_its_messages() {
        let s = Store::open_in_memory().unwrap();
        s.tg_chat_link(1, 1, "A", "en", 1).unwrap();
        s.tg_msg_add(1, 5, "a", "answer", "t").unwrap();
        s.tg_msg_add(2, 6, "a", "answer", "t").unwrap();
        assert!(s.tg_chat_delete(1).unwrap());
        assert!(!s.tg_chat_delete(1).unwrap());
        assert!(s.tg_msg_get(1, 5).unwrap().is_none());
        assert!(s.tg_msg_get(2, 6).unwrap().is_some());
    }

    #[test]
    fn a_card_is_claimed_once() {
        let s = Store::open_in_memory().unwrap();
        s.tg_msg_add(1, 5, "a", "approval", "ap1").unwrap();
        s.tg_msg_add(2, 9, "a", "approval", "ap1").unwrap();
        assert_eq!(s.tg_msgs_for_ref("approval", "ap1").unwrap().len(), 2);
        assert!(s.tg_msg_claim(1, 5, "approval", "approval_done").unwrap());
        assert!(!s.tg_msg_claim(1, 5, "approval", "approval_done").unwrap());
        assert_eq!(s.tg_msgs_for_ref("approval", "ap1").unwrap().len(), 1);
        assert_eq!(s.tg_msgs_for_ref("approval_done", "ap1").unwrap().len(), 1);
    }

    #[test]
    fn state_is_kept_and_cleared() {
        let s = Store::open_in_memory().unwrap();
        assert_eq!(s.tg_state_get("offset").unwrap(), None);
        s.tg_state_set("offset", "5").unwrap();
        s.tg_state_set("offset", "6").unwrap();
        assert_eq!(s.tg_state_get("offset").unwrap().as_deref(), Some("6"));
        s.tg_chat_link(1, 1, "A", "en", 1).unwrap();
        s.tg_clear().unwrap();
        assert_eq!(s.tg_state_get("offset").unwrap(), None);
        assert!(s.tg_chat_list().unwrap().is_empty());
    }
}
