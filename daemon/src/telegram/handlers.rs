//! What the bot does with what Telegram sends: messages (a link attempt, a command, plain text), presses of buttons,
//! and changes of its own membership. Only a private chat linked to the sender is obeyed; anyone else gets, at most,
//! one notice an hour, and groups are left.

use super::format::{escape_html, truncate_chars};
use super::strings::tr;
use super::{
    BAD_CODE_GAP, CODE_LEN, Held, LinkCode, MAX_CHAT_CODE_FAILURES, MAX_CODE_FAILURES, Sent, Telegram, map_language,
};
use crate::commands::prepare as prepare_message;
use crate::event::{DecidedBy, Decision, Source};
use crate::store::{Agent, ApprovalStatus, TgChat, TgLink, now_ms};
use crate::supervisor::Inbound;
use serde_json::{Value, json};
use std::time::Instant;

/// Agents shown as buttons or lines in one message.
const MAX_LISTED_AGENTS: usize = 30;
/// Approvals `/approvals` sends as cards.
const MAX_LISTED_APPROVALS: usize = 10;
/// Longest message an agent takes, bytes (as `agents.send`).
const MAX_MESSAGE_BYTES: usize = 100 * 1024;

/// A message that starts with `/`.
enum Parsed {
    Cmd {
        name: String,
        args: String,
    },
    /// `/cmd@other_bot`: for a different bot.
    Foreign,
}

fn parse_command(text: &str, bot: Option<&str>) -> Option<Parsed> {
    let text = text.trim_start();
    let rest = text.strip_prefix('/')?;
    let (head, args) = match rest.find(char::is_whitespace) {
        Some(i) => (&rest[..i], rest[i..].trim()),
        None => (rest, ""),
    };
    let (name, target) = match head.split_once('@') {
        Some((name, target)) => (name, Some(target)),
        None => (head, None),
    };
    if let Some(target) = target
        && !bot.is_some_and(|b| b.eq_ignore_ascii_case(target))
    {
        return Some(Parsed::Foreign);
    }
    Some(Parsed::Cmd {
        name: name.to_ascii_lowercase(),
        args: args.to_string(),
    })
}

/// Equal strings, in time that does not depend on where they differ.
fn same_code(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let mut diff = (a.len() ^ b.len()) as u8;
    for i in 0..a.len().max(b.len()) {
        diff |= a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(1);
    }
    diff == 0
}

/// Inline keyboard JSON from rows of `(label, callback_data)`.
fn keyboard(rows: Vec<Vec<(String, String)>>) -> Value {
    let rows: Vec<Vec<Value>> = rows
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|(text, data)| json!({ "text": text, "callback_data": data }))
                .collect()
        })
        .collect();
    json!({ "inline_keyboard": rows })
}

/// The name of a private chat for the list in the app.
fn chat_title(chat: &Value, from: &Value, chat_id: i64) -> String {
    let join = |a: &Value, b: &Value| {
        [a.as_str().unwrap_or_default(), b.as_str().unwrap_or_default()]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" ")
    };
    let mut title = join(&chat["first_name"], &chat["last_name"]);
    if title.is_empty() {
        title = join(&from["first_name"], &from["last_name"]);
    }
    if title.is_empty()
        && let Some(user) = chat["username"].as_str().or_else(|| from["username"].as_str())
    {
        title = format!("@{user}");
    }
    if title.is_empty() {
        title = format!("Chat {chat_id}");
    }
    truncate_chars(&title, 64).to_string()
}

impl Telegram {
    /// Handles one update of `getUpdates`.
    pub(crate) async fn handle_update(&self, update: Value) {
        if !self.configured.load(std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        if let Some(message) = update.get("message") {
            self.on_message(message).await;
        } else if let Some(press) = update.get("callback_query") {
            self.on_callback(press).await;
        } else if let Some(change) = update.get("my_chat_member") {
            self.on_membership(change).await;
        }
    }

    // ---- messages ----

    async fn on_message(&self, m: &Value) {
        let (Some(chat_id), Some(from_id)) = (m["chat"]["id"].as_i64(), m["from"]["id"].as_i64()) else {
            return;
        };
        let from = &m["from"];
        if from["is_bot"].as_bool() == Some(true) {
            return;
        }
        if m["chat"]["type"].as_str() != Some("private") {
            // Groups and channels are not for this bot.
            if self.allow_notice(chat_id, "leave", self.timing.notice_gap) && self.allow_stranger_reply() {
                self.leave_chat(chat_id).await;
            }
            return;
        }
        // In a private chat the chat is the person: anything else is not a real one.
        if chat_id != from_id {
            return;
        }
        let bot = self.bot_username();
        let parsed = m["text"].as_str().and_then(|t| parse_command(t, bot.as_deref()));
        if matches!(parsed, Some(Parsed::Foreign)) {
            return;
        }
        let guess = map_language(from["language_code"].as_str());
        let chat = self
            .store()
            .tg_chat_get(chat_id)
            .ok()
            .flatten()
            .filter(|c| c.user_id == from_id);
        match chat {
            None => self.on_stranger(m, chat_id, guess, parsed).await,
            Some(mut chat) => {
                if chat.language != guess {
                    if let Err(e) = self.store().tg_chat_set_language(chat_id, guess) {
                        tracing::warn!("telegram: keep a chat's language: {e:#}");
                    }
                    chat.language = guess.to_string();
                }
                self.on_linked(m, chat, parsed).await;
            }
        }
    }

    /// A chat that is not linked: a link attempt, or one notice an hour.
    async fn on_stranger(&self, m: &Value, chat_id: i64, lang: &str, parsed: Option<Parsed>) {
        if let Some(Parsed::Cmd { name, args }) = &parsed
            && name == "start"
            && !args.is_empty()
        {
            let word = args.split_whitespace().next().unwrap_or_default();
            self.try_link(m, chat_id, lang, word).await;
            return;
        }
        if self.allow_notice(chat_id, "not_linked", self.timing.notice_gap) && self.allow_stranger_reply() {
            self.send_html(chat_id, &tr(lang, "not_linked", &[]), None, true).await;
        }
    }

    /// `/start <code>` from a private chat that is not linked.
    async fn try_link(&self, m: &Value, chat_id: i64, lang: &str, input: &str) {
        let now = now_ms();
        let input = input.to_ascii_uppercase();
        let taken: Option<LinkCode> = {
            let mut st = self.lock();
            match st.link.take() {
                None => None,
                Some(mut link) => {
                    let tried = link.chat_failures.get(&chat_id).copied().unwrap_or(0);
                    if now >= link.expires_at {
                        None
                    } else if tried >= MAX_CHAT_CODE_FAILURES {
                        // This chat has used up its tries on this code, the right one included.
                        st.link = Some(link);
                        None
                    } else if input.len() == CODE_LEN && same_code(&link.code, &input) {
                        Some(link)
                    } else {
                        link.failures += 1;
                        link.chat_failures.insert(chat_id, tried + 1);
                        if link.failures < MAX_CODE_FAILURES {
                            st.link = Some(link);
                        }
                        None
                    }
                }
            }
        };
        let Some(link) = taken else {
            if self.allow_notice(chat_id, "bad_code", BAD_CODE_GAP) && self.allow_stranger_reply() {
                self.send_html(chat_id, &tr(lang, "bad_code", &[]), None, true).await;
            }
            return;
        };
        let title = chat_title(&m["chat"], &m["from"], chat_id);
        match self.store().tg_chat_link(chat_id, chat_id, &title, lang, now) {
            Ok(TgLink::Linked) => {
                self.changed();
                let greeting = format!("{}\n\n{}", tr(lang, "welcome", &[]), tr(lang, "help", &[]));
                self.send_html(chat_id, &greeting, None, true).await;
            }
            Ok(TgLink::Full) => {
                self.restore_code(link);
                self.send_html(chat_id, &tr(lang, "too_many_chats", &[]), None, true)
                    .await;
            }
            Err(e) => {
                tracing::warn!("telegram: could not link a chat: {e:#}");
                self.restore_code(link);
                self.send_html(chat_id, &tr(lang, "generic_error", &[]), None, true)
                    .await;
            }
        }
    }

    /// Puts a code back after a link that did not happen, unless a newer code was made meanwhile.
    fn restore_code(&self, link: LinkCode) {
        let mut st = self.lock();
        if st.link.is_none() {
            st.link = Some(link);
        }
    }

    async fn on_linked(&self, m: &Value, mut chat: TgChat, parsed: Option<Parsed>) {
        match parsed {
            Some(Parsed::Cmd { name, args }) => self.run_command(&chat, &name, &args).await,
            Some(Parsed::Foreign) => {}
            None => match m["text"].as_str() {
                None => {
                    self.say(&chat, "text_only", &[]).await;
                }
                Some(text) => {
                    let reply_to = m["reply_to_message"]["message_id"].as_i64();
                    self.route_text(&mut chat, text, reply_to).await;
                }
            },
        }
    }

    async fn run_command(&self, chat: &TgChat, name: &str, args: &str) {
        match name {
            "start" | "help" => {
                self.say(chat, "help", &[]).await;
            }
            "agents" => self.list_agents(chat).await,
            "ask" => self.ask(chat, args).await,
            "approvals" => self.list_approvals(chat).await,
            "status" => self.report_status(chat).await,
            "unlink" => {
                self.say(chat, "unlinked_bye", &[]).await;
                if let Err(e) = self.forget_chat(chat.chat_id) {
                    tracing::warn!("telegram: could not unlink a chat: {e}");
                }
            }
            _ => {
                self.say(chat, "unknown_command", &[]).await;
            }
        }
    }

    // ---- agents ----

    fn agent_status_key(agent: &Agent) -> &'static str {
        use crate::event::AgentStatus;
        if agent.paused {
            return "status_paused";
        }
        match agent.status {
            Some(AgentStatus::Working) => "status_working",
            Some(AgentStatus::NeedsYou) => "status_needs_you",
            Some(AgentStatus::Error) => "status_error",
            Some(AgentStatus::Offline) => "status_offline",
            Some(AgentStatus::Idle) | None => "status_idle",
        }
    }

    async fn list_agents(&self, chat: &TgChat) {
        let agents = match self.store().agent_list_view() {
            Ok(a) => a,
            Err(e) => {
                tracing::warn!("telegram: list agents: {e:#}");
                self.say(chat, "generic_error", &[]).await;
                return;
            }
        };
        if agents.is_empty() {
            self.say(chat, "no_agents", &[]).await;
            return;
        }
        let lang = &chat.language;
        let mut text = tr(lang, "agents_header", &[]);
        text.push('\n');
        let mut rows = Vec::new();
        for agent in agents.iter().take(MAX_LISTED_AGENTS) {
            let status = tr(lang, Self::agent_status_key(agent), &[]);
            let role = if agent.role.trim().is_empty() {
                String::new()
            } else {
                format!(" — {}", escape_html(agent.role.trim()))
            };
            text.push_str(&format!("\n• {}{role} — {status}", escape_html(&agent.name)));
            let current = chat.current_agent.as_deref() == Some(agent.id.as_str());
            let label = format!("{}{}", if current { "✓ " } else { "" }, truncate_chars(&agent.name, 40));
            rows.push(vec![(label, format!("c:{}", agent.id))]);
        }
        if agents.len() > MAX_LISTED_AGENTS {
            let more = (agents.len() - MAX_LISTED_AGENTS).to_string();
            text.push_str(&format!("\n{}", tr(lang, "more_agents", &[("count", &more)])));
        }
        self.send_html(chat.chat_id, &text, Some(keyboard(rows)), true).await;
    }

    async fn report_status(&self, chat: &TgChat) {
        let store = self.store();
        let (agents, pending) = match (store.agent_list_view(), store.approval_list_pending(None)) {
            (Ok(a), Ok(p)) => (a, p),
            _ => {
                self.say(chat, "generic_error", &[]).await;
                return;
            }
        };
        let working = agents
            .iter()
            .filter(|a| !a.paused && a.status == Some(crate::event::AgentStatus::Working))
            .count();
        self.say(
            chat,
            "status_text",
            &[
                ("version", crate::rpc::VERSION),
                ("working", &working.to_string()),
                ("total", &agents.len().to_string()),
                ("pending", &pending.len().to_string()),
            ],
        )
        .await;
    }

    async fn list_approvals(&self, chat: &TgChat) {
        let pending = match self.store().approval_list_pending(None) {
            Ok(p) => p,
            Err(e) => {
                tracing::warn!("telegram: list approvals: {e:#}");
                self.say(chat, "generic_error", &[]).await;
                return;
            }
        };
        if pending.is_empty() {
            self.say(chat, "approvals_none", &[]).await;
            return;
        }
        for approval in pending.iter().take(MAX_LISTED_APPROVALS) {
            self.send_card(chat, approval).await;
        }
    }

    /// `/ask <name> <text>`.
    async fn ask(&self, chat: &TgChat, args: &str) {
        let (word, text) = match args.find(char::is_whitespace) {
            Some(i) => (&args[..i], args[i..].trim()),
            None => (args, ""),
        };
        if word.is_empty() || text.is_empty() {
            self.say(chat, "ask_usage", &[]).await;
            return;
        }
        let agents = match self.store().agent_list() {
            Ok(a) => a,
            Err(e) => {
                tracing::warn!("telegram: list agents: {e:#}");
                self.say(chat, "generic_error", &[]).await;
                return;
            }
        };
        let word = word.to_lowercase();
        let exact: Vec<&Agent> = agents.iter().filter(|a| a.name.to_lowercase() == word).collect();
        let found: Vec<&Agent> = if exact.is_empty() {
            agents
                .iter()
                .filter(|a| a.name.to_lowercase().starts_with(&word))
                .collect()
        } else {
            exact
        };
        match found.as_slice() {
            [one] => {
                self.deliver(chat, one, text).await;
            }
            [] => {
                self.pick_agent(chat, &agents.iter().collect::<Vec<_>>(), Some(text))
                    .await
            }
            many => self.pick_agent(chat, many, Some(text)).await,
        }
    }

    /// Asks which agent should get `held` (kept for a while), with one button per agent.
    async fn pick_agent(&self, chat: &TgChat, agents: &[&Agent], held: Option<&str>) {
        if agents.is_empty() {
            self.say(chat, "no_agents", &[]).await;
            return;
        }
        if let Some(text) = held {
            let mut st = self.lock();
            st.held.insert(
                chat.chat_id,
                Held {
                    text: text.to_string(),
                    at: Instant::now(),
                },
            );
            st.bound();
        }
        let rows = agents
            .iter()
            .take(MAX_LISTED_AGENTS)
            .map(|a| vec![(truncate_chars(&a.name, 40).to_string(), format!("s:{}", a.id))])
            .collect();
        self.send_html(
            chat.chat_id,
            &tr(&chat.language, "pick_agent", &[]),
            Some(keyboard(rows)),
            true,
        )
        .await;
    }

    /// Plain text: to the agent whose answer it replies to, else the current agent, else ask which.
    async fn route_text(&self, chat: &mut TgChat, text: &str, reply_to: Option<i64>) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let store = self.store();
        if let Some(message_id) = reply_to
            && let Ok(Some(row)) = store.tg_msg_get(chat.chat_id, message_id)
            && row.kind == "answer"
        {
            match store.agent_get(&row.agent_id) {
                Ok(Some(agent)) => {
                    self.deliver(chat, &agent, text).await;
                }
                _ => {
                    self.say(chat, "agent_gone", &[]).await;
                }
            }
            return;
        }
        if let Some(current) = chat.current_agent.clone() {
            match store.agent_get(&current) {
                Ok(Some(agent)) => {
                    self.deliver(chat, &agent, text).await;
                    return;
                }
                _ => {
                    // The agent was deleted: choose again.
                    if let Err(e) = store.tg_chat_set_current(chat.chat_id, None) {
                        tracing::warn!("telegram: forget the current agent: {e:#}");
                    }
                    chat.current_agent = None;
                }
            }
        }
        match store.agent_list() {
            Ok(agents) => {
                let all: Vec<&Agent> = agents.iter().collect();
                self.pick_agent(chat, &all, Some(text)).await;
            }
            Err(e) => {
                tracing::warn!("telegram: list agents: {e:#}");
                self.say(chat, "generic_error", &[]).await;
            }
        }
    }

    /// Sends `text` to an agent as the person, the way `agents.send` does, and notes that it came from Telegram, so
    /// that the turn it starts is answered here. Returns whether it went.
    async fn deliver(&self, chat: &TgChat, agent: &Agent, text: &str) -> bool {
        let lang = &chat.language;
        if text.len() > MAX_MESSAGE_BYTES {
            self.say(chat, "message_too_long", &[]).await;
            return false;
        }
        let msg = match prepare_message(Some(agent), text) {
            Ok(prepared) => prepared.into_inbound(Source::User),
            Err(e) => {
                tracing::warn!("telegram: could not prepare a message: {e:#}");
                self.say(chat, "generic_error", &[]).await;
                return false;
            }
        };
        let inbound: Inbound = msg;
        {
            let mut st = self.lock();
            let queue = st.sent.entry(agent.id.clone()).or_default();
            queue.push_back(Sent {
                chat_id: chat.chat_id,
                text: text.to_string(),
                at: Instant::now(),
            });
            while queue.len() > 20 {
                queue.pop_front();
            }
            st.bound();
        }
        match self.sup.send_held(&agent.id, inbound).await {
            Ok(false) => true,
            Ok(true) => {
                self.send_html(
                    chat.chat_id,
                    &tr(lang, "agent_paused", &[("agent", &escape_html(&agent.name))]),
                    None,
                    true,
                )
                .await;
                true
            }
            Err(e) => {
                tracing::warn!("telegram: could not send a message to an agent: {e:#}");
                {
                    let mut st = self.lock();
                    if let Some(queue) = st.sent.get_mut(&agent.id)
                        && let Some(at) = queue.iter().rposition(|s| s.chat_id == chat.chat_id && s.text == text)
                    {
                        queue.remove(at);
                    }
                }
                self.say(chat, "generic_error", &[]).await;
                false
            }
        }
    }

    // ---- presses ----

    async fn on_callback(&self, press: &Value) {
        let id = press["id"].as_str().unwrap_or_default();
        let from_id = press["from"]["id"].as_i64();
        let message = &press["message"];
        let chat_id = message["chat"]["id"].as_i64();
        let private = message["chat"]["type"].as_str() == Some("private");
        let chat = match (chat_id, from_id) {
            (Some(c), Some(f)) if private && c == f => {
                self.store().tg_chat_get(c).ok().flatten().filter(|c| c.user_id == f)
            }
            _ => None,
        };
        let Some(chat) = chat else {
            // Not ours to obey: the button just stops spinning.
            self.answer_callback(id, None).await;
            return;
        };
        let message_id = message["message_id"].as_i64().unwrap_or(0);
        let data = press["data"].as_str().unwrap_or_default();
        let mut parts = data.splitn(3, ':');
        match (parts.next(), parts.next(), parts.next()) {
            (Some("a"), Some(approval), Some(answer @ ("y" | "n"))) if !approval.is_empty() => {
                self.press_approval(&chat, id, message_id, approval, answer == "y")
                    .await;
            }
            (Some("s"), Some(agent), None) if !agent.is_empty() => {
                self.press_select(&chat, id, message_id, agent).await;
            }
            (Some("c"), Some(agent), None) if !agent.is_empty() => {
                self.press_current(&chat, id, agent).await;
            }
            _ => self.answer_callback(id, None).await,
        }
    }

    async fn press_approval(&self, chat: &TgChat, callback_id: &str, message_id: i64, approval_id: &str, allow: bool) {
        let lang = &chat.language;
        let found = self.store().approval_get(approval_id).ok().flatten();
        let Some(approval) = found else {
            self.answer_callback(callback_id, Some(&tr(lang, "approval_already", &[])))
                .await;
            return;
        };
        if approval.status != ApprovalStatus::Pending {
            self.answer_callback(callback_id, Some(&tr(lang, "approval_already", &[])))
                .await;
            self.close_cards(approval_id, super::events::closed_from(&approval))
                .await;
            return;
        }
        // Only a button the bot itself put in this chat decides: a card of this approval, here.
        let own_card = self
            .store()
            .tg_msg_get(chat.chat_id, message_id)
            .ok()
            .flatten()
            .is_some_and(|row| row.ref_id == approval_id && (row.kind == "approval" || row.kind == "approval_done"));
        if !own_card {
            self.answer_callback(callback_id, None).await;
            return;
        }
        let decision = if allow { Decision::Allow } else { Decision::Deny };
        self.lock().decided_here.insert(approval_id.to_string(), chat.chat_id);
        match self.sup.resolve(approval_id, decision, false).await {
            Ok(()) => {
                self.answer_callback(callback_id, None).await;
                self.close_cards(approval_id, super::events::Closed::Decided(decision, DecidedBy::User))
                    .await;
            }
            Err(e) => {
                tracing::warn!("telegram: could not resolve an approval: {e:#}");
                self.lock().decided_here.remove(approval_id);
                // Decided meanwhile (in the app, or by a timeout), or the agent is gone.
                let still = self
                    .store()
                    .approval_get(approval_id)
                    .ok()
                    .flatten()
                    .is_some_and(|a| a.status == ApprovalStatus::Pending);
                let key = if still { "generic_error" } else { "approval_already" };
                self.answer_callback(callback_id, Some(&tr(lang, key, &[]))).await;
            }
        }
    }

    /// The person chose an agent from a list: it becomes the current one, and a held text goes to it.
    async fn press_select(&self, chat: &TgChat, callback_id: &str, message_id: i64, agent_id: &str) {
        let lang = &chat.language;
        let store = self.store();
        let Some(agent) = store.agent_get(agent_id).ok().flatten() else {
            self.answer_callback(callback_id, Some(&tr(lang, "agent_gone", &[])))
                .await;
            return;
        };
        if let Err(e) = store.tg_chat_set_current(chat.chat_id, Some(agent_id)) {
            tracing::warn!("telegram: keep the current agent: {e:#}");
        }
        let held = self.lock().held.remove(&chat.chat_id);
        let name = escape_html(&agent.name);
        match held {
            Some(held) if held.at.elapsed() <= self.timing.pending_ttl => {
                if self.deliver(chat, &agent, &held.text).await {
                    self.answer_callback(callback_id, None).await;
                    self.edit_html(chat.chat_id, message_id, &tr(lang, "sent_to", &[("agent", &name)]))
                        .await;
                } else {
                    self.answer_callback(callback_id, Some(&tr(lang, "generic_error", &[])))
                        .await;
                }
            }
            Some(_) => {
                self.answer_callback(callback_id, Some(&tr(lang, "pending_expired", &[])))
                    .await;
                self.edit_html(chat.chat_id, message_id, &tr(lang, "current_set", &[("agent", &name)]))
                    .await;
            }
            None => {
                self.answer_callback(callback_id, Some(&tr(lang, "current_set", &[("agent", &name)])))
                    .await;
                self.edit_html(chat.chat_id, message_id, &tr(lang, "current_set", &[("agent", &name)]))
                    .await;
            }
        }
    }

    /// The person chose the current agent from `/agents`.
    async fn press_current(&self, chat: &TgChat, callback_id: &str, agent_id: &str) {
        let lang = &chat.language;
        let Some(agent) = self.store().agent_get(agent_id).ok().flatten() else {
            self.answer_callback(callback_id, Some(&tr(lang, "agent_gone", &[])))
                .await;
            return;
        };
        if let Err(e) = self.store().tg_chat_set_current(chat.chat_id, Some(agent_id)) {
            tracing::warn!("telegram: keep the current agent: {e:#}");
        }
        let name = escape_html(&agent.name);
        self.answer_callback(callback_id, Some(&tr(lang, "current_set", &[("agent", &name)])))
            .await;
    }

    // ---- membership ----

    /// The bot was added to a group or a channel: it leaves.
    async fn on_membership(&self, change: &Value) {
        let Some(chat_id) = change["chat"]["id"].as_i64() else {
            return;
        };
        if change["chat"]["type"].as_str() == Some("private") {
            return;
        }
        let joined = matches!(
            change["new_chat_member"]["status"].as_str(),
            Some("member" | "administrator")
        );
        if joined {
            self.leave_chat(chat_id).await;
        }
    }
}
