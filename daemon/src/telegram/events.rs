//! What the bot does with the daemon's own events: an approval asked becomes a card, an approval decided closes the
//! cards, and the last message of a finished turn goes to the chats that follow it. Telling which turns a chat's own
//! messages started rests on the order of an agent's events: a turn that starts by itself is followed by the echo of
//! its message (`turn.started`, then `message.user`), and a message that waited is echoed first and named by the
//! `message_seq` of the turn that takes it.

use super::format::{escape_html, format_answer, truncate_chars};
use super::strings::tr;
use super::{Edited, Sent, Telegram};
use crate::event::{DecidedBy, Decision, Event, EventBody, Source, TurnStatus};
use crate::redact::Redactor;
use crate::store::{Approval, ApprovalStatus, TgChat};
use futures_util::future::join_all;
use serde_json::json;
use std::sync::atomic::Ordering;
use std::time::Duration;

/// Most characters of what an approval wants that a card shows.
const CARD_DETAIL_CHARS: usize = 600;
/// A message passed to an agent is looked for in its thread this long.
const SENT_KEEP: Duration = Duration::from_secs(600);

/// How an approval ended, for the line on its cards.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) enum Closed {
    Decided(Decision, DecidedBy),
    /// Nobody answered in time.
    Expired,
    /// The agent's CLI took the request back.
    Withdrawn,
}

/// The ending of an approval that is not pending any more.
pub(super) fn closed_from(approval: &Approval) -> Closed {
    match approval.status {
        ApprovalStatus::Resolved | ApprovalStatus::Pending => {
            Closed::Decided(approval.decision.unwrap_or(Decision::Deny), DecidedBy::User)
        }
        ApprovalStatus::Expired => Closed::Expired,
        ApprovalStatus::Withdrawn => Closed::Withdrawn,
    }
}

impl Telegram {
    /// Handles one event of the hub.
    pub(crate) async fn handle_event(&self, ev: Event) {
        if !self.configured.load(Ordering::SeqCst) {
            return;
        }
        let agent = ev.agent_id;
        match ev.body {
            EventBody::ApprovalRequested { approval_id, .. } => self.on_approval_requested(&approval_id).await,
            EventBody::ApprovalResolved {
                approval_id,
                decision,
                by,
                ..
            } => self.close_cards(&approval_id, Closed::Decided(decision, by)).await,
            EventBody::ApprovalWithdrawn { approval_id } => self.close_cards(&approval_id, Closed::Withdrawn).await,
            EventBody::TurnStarted {
                turn_id,
                source,
                message_seq,
                ..
            } => self.on_turn_started(&agent, turn_id, source, message_seq),
            EventBody::MessageUser {
                text, source, queued, ..
            } => self.on_message_user(&agent, &text, source, queued, ev.seq),
            EventBody::MessageAssistant { text } => {
                let mut st = self.lock();
                st.last_answer.insert(agent, text);
                st.bound();
            }
            EventBody::TurnCompleted { turn_id, status, .. } => self.on_turn_completed(&agent, &turn_id, status).await,
            _ => {}
        }
    }

    // ---- turns ----

    fn on_turn_started(&self, agent: &str, turn_id: String, source: Source, message_seq: Option<i64>) {
        let mut st = self.lock();
        st.last_answer.remove(agent);
        st.last_turn.remove(agent);
        if source != Source::User {
            return;
        }
        match message_seq {
            // It takes a message that waited: if that was ours, the turn is ours.
            Some(seq) => {
                if let Some(chat) = st.queued.remove(&(agent.to_string(), seq)) {
                    st.turn_chats.insert(turn_id, chat);
                }
            }
            // Its message is echoed right after this event.
            None => {
                st.last_turn.insert(agent.to_string(), turn_id);
            }
        }
        st.bound();
    }

    fn on_message_user(&self, agent: &str, text: &str, source: Source, queued: bool, seq: i64) {
        if source != Source::User {
            return;
        }
        let mut st = self.lock();
        let Some(list) = st.sent.get_mut(agent) else {
            return;
        };
        list.retain(|s: &Sent| s.at.elapsed() < SENT_KEEP);
        let Some(at) = list.iter().position(|s| s.text.trim() == text.trim()) else {
            return;
        };
        let Some(sent) = list.remove(at) else {
            return;
        };
        if list.is_empty() {
            st.sent.remove(agent);
        }
        if queued {
            if seq > 0 {
                st.queued.insert((agent.to_string(), seq), sent.chat_id);
            }
        } else if let Some(turn) = st.last_turn.remove(agent) {
            st.turn_chats.insert(turn, sent.chat_id);
        }
        st.bound();
    }

    async fn on_turn_completed(&self, agent_id: &str, turn_id: &str, status: TurnStatus) {
        let (origin, text) = {
            let mut st = self.lock();
            (st.turn_chats.remove(turn_id), st.last_answer.remove(agent_id))
        };
        let Some(text) = text.filter(|t| !t.trim().is_empty()) else {
            return;
        };
        if status != TurnStatus::Ok {
            return;
        }
        let chats = match self.store().tg_chat_list() {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("telegram: list chats: {e:#}");
                return;
            }
        };
        let hears = |chat: &TgChat| match chat.answers.as_str() {
            "all" => true,
            "telegram" => origin == Some(chat.chat_id),
            _ => false,
        };
        let recipients: Vec<TgChat> = chats.into_iter().filter(hears).collect();
        if recipients.is_empty() {
            return;
        }
        let name = match self.store().agent_get(agent_id) {
            Ok(Some(agent)) => agent.name,
            _ => return,
        };
        let sends = recipients.iter().map(|chat| {
            let html = format_answer(&name, &text, &tr(&chat.language, "full_in_app", &[]));
            async move { (chat.chat_id, self.send_html(chat.chat_id, &html, None, false).await) }
        });
        for (chat_id, sent) in join_all(sends).await {
            if let Some(message_id) = sent
                && let Err(e) = self
                    .store()
                    .tg_msg_add(chat_id, message_id, agent_id, "answer", turn_id)
            {
                tracing::warn!("telegram: remember an answer: {e:#}");
            }
        }
    }

    // ---- approvals ----

    async fn on_approval_requested(&self, approval_id: &str) {
        let approval = match self.store().approval_get(approval_id) {
            Ok(Some(a)) if a.status == ApprovalStatus::Pending => a,
            _ => return,
        };
        let chats = match self.store().tg_chat_list() {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("telegram: list chats: {e:#}");
                return;
            }
        };
        let cards = chats
            .iter()
            .filter(|c| c.approvals)
            .map(|chat| self.send_card(chat, &approval));
        join_all(cards).await;
    }

    /// Sends an approval as a card with its two buttons to one chat, and remembers the message.
    pub(super) async fn send_card(&self, chat: &TgChat, approval: &Approval) {
        let lang = &chat.language;
        let html = self.card_html(lang, approval, None);
        let markup = json!({ "inline_keyboard": [[
            { "text": tr(lang, "btn_allow", &[]), "callback_data": format!("a:{}:y", approval.id) },
            { "text": tr(lang, "btn_deny", &[]), "callback_data": format!("a:{}:n", approval.id) },
        ]] });
        if let Some(message_id) = self.send_html(chat.chat_id, &html, Some(markup), true).await
            && let Err(e) =
                self.store()
                    .tg_msg_add(chat.chat_id, message_id, &approval.agent_id, "approval", &approval.id)
        {
            tracing::warn!("telegram: remember a card: {e:#}");
        }
    }

    /// The text of a card: who asks, what for (secrets hidden, cut to a few hundred characters), and a closing line
    /// once the approval is over.
    fn card_html(&self, lang: &str, approval: &Approval, closing: Option<&str>) -> String {
        let store = self.store();
        let name = store
            .agent_get(&approval.agent_id)
            .ok()
            .flatten()
            .map(|a| a.name)
            .unwrap_or_else(|| "Agent".to_string());
        let wanted = approval.payload["command"]
            .as_str()
            .filter(|c| !c.trim().is_empty())
            .unwrap_or(&approval.title);
        let redactor = Redactor::new(store.secrets_all().unwrap_or_default());
        let wanted = redactor.redact(wanted);
        let shown = if wanted.chars().count() > CARD_DETAIL_CHARS {
            format!("{}…", truncate_chars(&wanted, CARD_DETAIL_CHARS - 1))
        } else {
            wanted.to_string()
        };
        let ask = tr(
            lang,
            "approval_ask",
            &[("agent", &format!("<b>{}</b>", escape_html(&name)))],
        );
        let mut html = format!("🔐 {ask}");
        if !shown.trim().is_empty() {
            html.push_str(&format!("\n<pre>{}</pre>", escape_html(&shown)));
        }
        if let Some(line) = closing {
            html.push_str(&format!("\n\n{line}"));
        }
        html
    }

    /// Edits every card of an approval that still has buttons: the buttons go and a line says how it ended. A card is
    /// edited once, whichever of a press and the event of the decision comes first.
    pub(super) async fn close_cards(&self, approval_id: &str, how: Closed) {
        let store = self.store();
        let rows = match store.tg_msgs_for_ref("approval", approval_id) {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!("telegram: find cards: {e:#}");
                return;
            }
        };
        let decided_in = self.lock().decided_here.get(approval_id).copied();
        let approval = store.approval_get(approval_id).ok().flatten();
        for row in rows {
            match store.tg_msg_claim(row.chat_id, row.message_id, "approval", "approval_done") {
                Ok(true) => {}
                _ => continue,
            }
            let (Some(approval), Ok(Some(chat))) = (&approval, store.tg_chat_get(row.chat_id)) else {
                continue;
            };
            let from_telegram = decided_in == Some(row.chat_id);
            let key = match (how, from_telegram) {
                (Closed::Decided(Decision::Deny, DecidedBy::Policy), _) | (Closed::Expired, _) => "approval_expired",
                (Closed::Withdrawn, _) => "approval_withdrawn",
                (Closed::Decided(Decision::Allow, _), true) => "approval_allowed_tg",
                (Closed::Decided(Decision::Deny, _), true) => "approval_denied_tg",
                (Closed::Decided(Decision::Allow, _), false) => "approval_allowed_app",
                (Closed::Decided(Decision::Deny, _), false) => "approval_denied_app",
            };
            let line = tr(&chat.language, key, &[]);
            let html = self.card_html(&chat.language, approval, Some(&line));
            // A failed edit is tried again (3 times in all); if it still fails, the claim is given back, so the
            // next press on the card, or the next event, closes it.
            let mut edited = Edited::Failed;
            for attempt in 1..=3u32 {
                edited = self.edit_html(row.chat_id, row.message_id, &html).await;
                if edited != Edited::Failed {
                    break;
                }
                tokio::time::sleep(self.timing.backoff_start * attempt).await;
            }
            if edited == Edited::Failed
                && let Err(e) = store.tg_msg_claim(row.chat_id, row.message_id, "approval_done", "approval")
            {
                tracing::warn!("telegram: could not give a card back: {e:#}");
            }
        }
        self.lock().decided_here.remove(approval_id);
    }
}
