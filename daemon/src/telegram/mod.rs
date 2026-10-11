//! The Telegram bot: the daemon polls a bot (the person's own, made with @BotFather) over `curl`, links private chats
//! with a one-time code, shows approvals as cards with buttons, sends agents' answers, and passes the person's messages
//! to agents. See docs/ARCHITECTURE.md#telegram.
//!
//! Layout: `api` (the Bot API over `curl`, the token never in an argument), `format` (markdown to Telegram HTML),
//! `strings` (the texts in nine languages), `handlers` (what a message, a press or a membership change does),
//! `events` (what the daemon's own events do), and this file (state, the poll loop, sending, the calls of the app).
//! No lock is held across an `.await`.

mod api;
mod events;
mod format;
mod handlers;
mod strings;

#[cfg(test)]
mod fake;
#[cfg(test)]
mod tests;

use crate::event::{Event, EventBody};
use crate::store::{Store, TgChat, now_ms};
use crate::supervisor::Supervisor;
use api::{Api, ApiError, updates_body};
use format::{MESSAGE_LIMIT, plain_from_html, truncate_chars, utf16_len};
use futures_util::FutureExt;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::panic::AssertUnwindSafe;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use strings::tr;
use tokio::task::JoinHandle;

/// The secret that holds the bot's token. Hidden from the secrets calls and given to no agent
/// (`integrations::TELEGRAM_SECRET_PREFIX`).
pub const TOKEN_SECRET: &str = "DAEMON_TELEGRAM_BOT_TOKEN";

const KEY_OFFSET: &str = "offset";
const KEY_USERNAME: &str = "bot_username";
const KEY_NAME: &str = "bot_name";

/// A code is eight characters of base32.
const CODE_LEN: usize = 8;
const CODE_ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
/// Wrong codes a code survives.
const MAX_CODE_FAILURES: u32 = 10;
/// The answer to a wrong code goes to one chat this often.
const BAD_CODE_GAP: Duration = Duration::from_secs(3);
/// A message that would wait longer than this to go out (an answer, not a card or a reply) is dropped.
const MAX_SEND_BACKLOG: Duration = Duration::from_secs(30);
/// Rows of sent messages are kept this long.
const MESSAGE_KEEP_MS: i64 = 7 * 24 * 3600 * 1000;
/// Entries a bookkeeping map may hold before it is emptied (a runaway sender must not grow memory).
const MAP_LIMIT: usize = 2000;

/// Delays of the bot. The defaults are the real ones; the tests shorten them.
#[derive(Debug, Clone)]
pub struct Timing {
    /// The long-poll timeout of `getUpdates`, seconds.
    pub poll_secs: u64,
    /// Rest after a poll that brought nothing (the long poll itself waits, so none in production).
    pub idle_pause: Duration,
    /// Wait after a 409 before polling again.
    pub conflict_wait: Duration,
    /// First wait after a network failure; it doubles up to `backoff_max`.
    pub backoff_start: Duration,
    pub backoff_max: Duration,
    /// Least time between two messages to one chat.
    pub send_gap: Duration,
    /// Least time between two "not connected" notices to one chat.
    pub notice_gap: Duration,
    /// How long a link code lives.
    pub link_ttl: Duration,
    /// Longest wait honoured after a 429.
    pub retry_cap: Duration,
    /// How long a text waits for the person to choose an agent.
    pub pending_ttl: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            poll_secs: 50,
            idle_pause: Duration::ZERO,
            conflict_wait: Duration::from_secs(60),
            backoff_start: Duration::from_secs(1),
            backoff_max: Duration::from_secs(60),
            send_gap: Duration::from_secs(1),
            notice_gap: Duration::from_secs(3600),
            link_ttl: Duration::from_secs(600),
            retry_cap: Duration::from_secs(30),
            pending_ttl: Duration::from_secs(600),
        }
    }
}

#[cfg(test)]
impl Timing {
    /// Short waits, for the tests.
    pub fn fast() -> Self {
        Self {
            poll_secs: 1,
            idle_pause: Duration::from_millis(10),
            conflict_wait: Duration::from_millis(100),
            backoff_start: Duration::from_millis(10),
            backoff_max: Duration::from_millis(100),
            send_gap: Duration::from_millis(5),
            retry_cap: Duration::from_millis(50),
            ..Self::default()
        }
    }
}

/// A call of the app that failed. `reason` is the stable code the app reads (`invalid_token`, `network`,
/// `not_configured`, `no_such_chat`, `invalid_params`, `telegram`, `internal`).
#[derive(Debug, Clone, PartialEq)]
pub struct TgError {
    pub reason: &'static str,
    pub message: String,
}

impl TgError {
    fn new(reason: &'static str, message: impl Into<String>) -> Self {
        Self {
            reason,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for TgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.reason, self.message)
    }
}

impl From<anyhow::Error> for TgError {
    fn from(e: anyhow::Error) -> Self {
        Self::new("internal", format!("{e:#}"))
    }
}

/// The code of the language of a Telegram `language_code`: one of the nine, English when unknown.
pub fn map_language(code: Option<&str>) -> &'static str {
    let code = code.unwrap_or_default().to_ascii_lowercase();
    match code.split(['-', '_']).next().unwrap_or_default() {
        "ru" => "ru",
        "de" => "de",
        "es" => "es",
        "fr" => "fr",
        "ja" => "ja",
        "ko" => "ko",
        "pt" => "pt-BR",
        "zh" => "zh-Hans",
        _ => "en",
    }
}

/// `^\d{5,12}:[A-Za-z0-9_-]{30,64}$`
fn valid_token_format(token: &str) -> bool {
    let Some((id, secret)) = token.split_once(':') else {
        return false;
    };
    (5..=12).contains(&id.len())
        && id.chars().all(|c| c.is_ascii_digit())
        && (30..=64).contains(&secret.len())
        && secret
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// The number before the colon: a bot's id, the same for every token it ever had.
fn bot_id(token: &str) -> &str {
    token.split(':').next().unwrap_or_default()
}

/// A link code that waits for `/start <code>`.
#[derive(Debug, Clone)]
struct LinkCode {
    code: String,
    expires_at: i64,
    failures: u32,
}

/// A text that waits for the person to choose an agent.
#[derive(Debug, Clone)]
struct Held {
    text: String,
    at: Instant,
}

/// A message the bot passed to an agent, until the agent's thread shows it.
#[derive(Debug, Clone)]
struct Sent {
    chat_id: i64,
    text: String,
    at: Instant,
}

#[derive(Default)]
struct State {
    /// Bumped at every poller start, so an old poller's end does not clear the new one's `running`.
    generation: u64,
    running: bool,
    last_error: Option<&'static str>,
    link: Option<LinkCode>,
    /// `(chat, kind)` to when it was last answered, for notices that come at most so often.
    notices: HashMap<(i64, &'static str), Instant>,
    held: HashMap<i64, Held>,
    /// Chat to the earliest time its next message may go out.
    send_slots: HashMap<i64, Instant>,
    /// Agent to the messages sent to it from Telegram that its thread has not shown yet.
    sent: HashMap<String, VecDeque<Sent>>,
    /// `(agent, seq)` of a message that waits in an agent's queue, to the chat it came from.
    queued: HashMap<(String, i64), i64>,
    /// Agent to its newest turn started by a person, whose message has not been seen yet.
    last_turn: HashMap<String, String>,
    /// Turn id to the chat whose message started it.
    turn_chats: HashMap<String, i64>,
    /// Agent to its newest message of the turn that runs.
    last_answer: HashMap<String, String>,
    /// Approval id to the chat whose press decided it.
    decided_here: HashMap<String, i64>,
}

impl State {
    /// Empties a map that grew past [`MAP_LIMIT`].
    fn bound(&mut self) {
        fn cap<K, V>(m: &mut HashMap<K, V>) {
            if m.len() > MAP_LIMIT {
                m.clear();
            }
        }
        cap(&mut self.notices);
        cap(&mut self.held);
        cap(&mut self.send_slots);
        cap(&mut self.sent);
        cap(&mut self.queued);
        cap(&mut self.last_turn);
        cap(&mut self.turn_chats);
        cap(&mut self.last_answer);
        cap(&mut self.decided_here);
    }

    /// Forgets what belongs to the linked chats and the turns (not the poller's own bookkeeping).
    fn forget_chats(&mut self) {
        self.link = None;
        self.notices.clear();
        self.held.clear();
        self.send_slots.clear();
        self.sent.clear();
        self.queued.clear();
        self.last_turn.clear();
        self.turn_chats.clear();
        self.last_answer.clear();
        self.decided_here.clear();
    }
}

#[derive(Default)]
struct Tasks {
    poller: Option<JoinHandle<()>>,
    listener: Option<JoinHandle<()>>,
}

/// Ends the `running` of its poller when the poller's task ends, however it ends.
struct RunGuard {
    tg: Arc<Telegram>,
    generation: u64,
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        let mut st = self.tg.lock();
        if st.generation == self.generation {
            st.running = false;
        }
    }
}

pub struct Telegram {
    sup: Arc<Supervisor>,
    api: Api,
    timing: Timing,
    /// Whether a token is set: events and updates are ignored without one.
    configured: AtomicBool,
    state: Mutex<State>,
    tasks: Mutex<Tasks>,
}

impl Telegram {
    /// The bot of this daemon, on the real Bot API.
    pub fn new(sup: Arc<Supervisor>) -> Arc<Self> {
        Self::build(sup, Api::new(), Timing::default())
    }

    /// A bot on another address, with other delays: the fake of the tests.
    #[cfg(test)]
    pub fn with_base(sup: Arc<Supervisor>, base: &str, timing: Timing) -> Arc<Self> {
        Self::build(sup, Api::with_base(base), timing)
    }

    fn build(sup: Arc<Supervisor>, api: Api, timing: Timing) -> Arc<Self> {
        let configured = sup.hub().store.secret_get(TOKEN_SECRET).ok().flatten().is_some();
        Arc::new(Self {
            sup,
            api,
            timing,
            configured: AtomicBool::new(configured),
            state: Mutex::new(State::default()),
            tasks: Mutex::new(Tasks::default()),
        })
    }

    fn store(&self) -> &Store {
        &self.sup.hub().store
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn token(&self) -> Option<String> {
        self.store().secret_get(TOKEN_SECRET).ok().flatten()
    }

    fn bot_username(&self) -> Option<String> {
        self.store().tg_state_get(KEY_USERNAME).ok().flatten()
    }

    /// Tells the apps the bot's status or chats changed.
    fn changed(&self) {
        self.sup.hub().emit("", EventBody::TelegramChanged);
    }

    /// Records a token and the bot behind it, without starting anything.
    fn keep_token(&self, token: &str, username: &str, name: &str) -> Result<(), TgError> {
        let store = self.store();
        store.secret_set(TOKEN_SECRET, token, &[])?;
        store.tg_state_set(KEY_USERNAME, username)?;
        store.tg_state_set(KEY_NAME, name)?;
        self.configured.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// A token and a bot name in place, for the tests that need neither a `getMe` nor a poller.
    #[cfg(test)]
    pub fn seed_for_test(&self, token: &str, username: &str, name: &str) {
        self.keep_token(token, username, name).expect("seed the token");
    }

    /// Stops the tasks, for the tests.
    #[cfg(test)]
    pub async fn stop_for_test(&self) {
        let mut tasks = self.tasks.lock().unwrap_or_else(|e| e.into_inner());
        for handle in [tasks.poller.take(), tasks.listener.take()].into_iter().flatten() {
            handle.abort();
        }
    }

    // ---- the calls of the app ----

    /// `{configured, bot, running, last_error, chats}`.
    pub fn status(&self) -> Result<Value, TgError> {
        let store = self.store();
        let configured = store.secret_get(TOKEN_SECRET)?.is_some();
        let bot = match (configured, store.tg_state_get(KEY_USERNAME)?) {
            (true, Some(username)) => {
                let name = store.tg_state_get(KEY_NAME)?.unwrap_or_default();
                json!({ "username": username, "name": name })
            }
            _ => Value::Null,
        };
        let (running, last_error) = {
            let st = self.lock();
            (st.running, st.last_error)
        };
        let chats: Vec<Value> = store
            .tg_chat_list()?
            .into_iter()
            .map(|c| {
                json!({
                    "chat_id": c.chat_id,
                    "title": c.title,
                    "language": c.language,
                    "linked_at": c.linked_at,
                    "approvals": c.approvals,
                    "answers": c.answers,
                })
            })
            .collect();
        Ok(json!({
            "configured": configured,
            "bot": bot,
            "running": configured && running,
            "last_error": if configured { json!(last_error) } else { Value::Null },
            "chats": chats,
        }))
    }

    /// Checks a token with `getMe`, keeps it and starts polling. The same token again changes nothing; another bot's
    /// token starts clean (its chats, messages and offset are dropped).
    pub async fn set_token(self: &Arc<Self>, token: &str) -> Result<Value, TgError> {
        let token = token.trim();
        if !valid_token_format(token) {
            return Err(TgError::new(
                "invalid_token",
                "that does not look like a bot token: copy it from @BotFather",
            ));
        }
        let me = match self.api.call(token, "getMe", json!({}), 15).await {
            Ok(me) => me,
            Err(ApiError::Unauthorized | ApiError::Rejected { code: 404, .. }) => {
                return Err(TgError::new("invalid_token", "Telegram does not accept that token"));
            }
            Err(ApiError::Network(_)) => {
                return Err(TgError::new(
                    "network",
                    "could not reach Telegram: check the server's connection",
                ));
            }
            Err(e) => return Err(TgError::new("telegram", e.to_string())),
        };
        let username = me["username"].as_str().unwrap_or_default();
        let name = me["first_name"].as_str().unwrap_or(username);
        let old = self.token();
        if old.as_deref().is_some_and(|old| bot_id(old) != bot_id(token)) {
            self.stop_poller();
            self.store().tg_clear()?;
            self.lock().forget_chats();
        }
        let unchanged = old.as_deref() == Some(token);
        self.keep_token(token, username, name)?;
        let working = {
            let st = self.lock();
            st.running && st.last_error.is_none()
        };
        if !(unchanged && working) {
            self.start();
        }
        self.changed();
        self.status()
    }

    /// Stops the bot and forgets the token, the chats and everything kept for them.
    pub async fn remove_token(&self) -> Result<Value, TgError> {
        self.stop_poller();
        self.configured.store(false, Ordering::SeqCst);
        self.store().secret_delete(TOKEN_SECRET)?;
        self.store().tg_clear()?;
        {
            let mut st = self.lock();
            st.forget_chats();
            st.last_error = None;
        }
        self.changed();
        self.status()
    }

    /// A new link code (replacing any earlier) and the address that opens the bot with it.
    pub fn link_start(&self) -> Result<Value, TgError> {
        let username = match (self.token(), self.bot_username()) {
            (Some(_), Some(username)) => username,
            _ => return Err(TgError::new("not_configured", "set the bot token first")),
        };
        let bytes: [u8; CODE_LEN] = rand::random();
        let code: String = bytes.iter().map(|b| CODE_ALPHABET[(b & 31) as usize] as char).collect();
        let expires_at = now_ms() + self.timing.link_ttl.as_millis() as i64;
        self.lock().link = Some(LinkCode {
            code: code.clone(),
            expires_at,
            failures: 0,
        });
        Ok(json!({
            "code": code,
            "url": format!("https://t.me/{username}?start={code}"),
            "expires_at": expires_at,
        }))
    }

    /// Says goodbye in the chat, then forgets it.
    pub async fn unlink(&self, chat_id: i64) -> Result<Value, TgError> {
        let Some(chat) = self.store().tg_chat_get(chat_id)? else {
            return Err(TgError::new("no_such_chat", "that chat is not linked"));
        };
        self.say(&chat, "unlinked_bye", &[]).await;
        self.forget_chat(chat_id)?;
        self.status()
    }

    /// Changes whether a chat gets approval cards, and which answers it gets.
    pub fn update_chat(&self, chat_id: i64, approvals: Option<bool>, answers: Option<&str>) -> Result<Value, TgError> {
        if let Some(mode) = answers
            && !crate::store::ANSWER_MODES.contains(&mode)
        {
            return Err(TgError::new("invalid_params", "answers must be all, telegram or none"));
        }
        if !self.store().tg_chat_update(chat_id, approvals, answers)? {
            return Err(TgError::new("no_such_chat", "that chat is not linked"));
        }
        self.changed();
        self.status()
    }

    /// Removes a chat and what is kept for it, and tells the apps.
    fn forget_chat(&self, chat_id: i64) -> Result<(), TgError> {
        self.store().tg_chat_delete(chat_id)?;
        {
            let mut st = self.lock();
            st.held.remove(&chat_id);
            st.notices.retain(|(chat, _), _| *chat != chat_id);
        }
        self.changed();
        Ok(())
    }

    // ---- tasks ----

    /// Starts the listener of the daemon's events and the poller (a running one is replaced). Does nothing without a
    /// token. Called when the daemon starts (never in safe mode) and when a token is set.
    pub fn start(self: &Arc<Self>) {
        if self.token().is_none() {
            return;
        }
        self.configured.store(true, Ordering::SeqCst);
        self.ensure_listener();
        self.restart_poller();
    }

    fn restart_poller(self: &Arc<Self>) {
        let mut tasks = self.tasks.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = tasks.poller.take() {
            old.abort();
        }
        let generation = {
            let mut st = self.lock();
            st.generation += 1;
            st.running = true;
            st.last_error = None;
            st.generation
        };
        let me = self.clone();
        tasks.poller = Some(tokio::spawn(async move { me.poll(generation).await }));
    }

    fn stop_poller(&self) {
        let mut tasks = self.tasks.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(old) = tasks.poller.take() {
            old.abort();
        }
        let mut st = self.lock();
        st.generation += 1;
        st.running = false;
    }

    fn ensure_listener(self: &Arc<Self>) {
        let mut tasks = self.tasks.lock().unwrap_or_else(|e| e.into_inner());
        if tasks.listener.as_ref().is_some_and(|h| !h.is_finished()) {
            return;
        }
        // Subscribed here, not in the task, so nothing between this call and the task's start is missed.
        let mut events = self.sup.hub().subscribe();
        let me = self.clone();
        tasks.listener = Some(tokio::spawn(async move {
            let mut housekeeping = tokio::time::interval(Duration::from_secs(3600));
            loop {
                tokio::select! {
                    got = events.recv() => match got {
                        Ok(ev) => me.handle_event_guarded(ev).await,
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            tracing::warn!(missed = n, "telegram: the event stream lagged");
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    },
                    _ = housekeeping.tick() => {
                        if let Err(e) = me.store().tg_msgs_prune(now_ms() - MESSAGE_KEEP_MS) {
                            tracing::warn!("telegram: prune old messages: {e:#}");
                        }
                    }
                }
            }
        }));
    }

    async fn handle_event_guarded(&self, ev: Event) {
        if AssertUnwindSafe(self.handle_event(ev)).catch_unwind().await.is_err() {
            tracing::error!("telegram: handling an event panicked");
        }
    }

    async fn handle_update_guarded(&self, update: Value) {
        if AssertUnwindSafe(self.handle_update(update))
            .catch_unwind()
            .await
            .is_err()
        {
            tracing::error!("telegram: handling an update panicked");
        }
    }

    /// Records the poller's state and tells the apps when it changed. `stopped`: the poller ends.
    fn set_error(&self, error: Option<&'static str>, stopped: bool) {
        let changed = {
            let mut st = self.lock();
            let changed = st.last_error != error || (stopped && st.running);
            st.last_error = error;
            if stopped {
                st.running = false;
            }
            changed
        };
        if changed {
            self.changed();
        }
    }

    /// What the poller does about a failed call. `false`: it stops.
    async fn poll_error(&self, error: &ApiError, backoff: &mut Duration) -> bool {
        match error {
            ApiError::Unauthorized => {
                self.set_error(Some("unauthorized"), true);
                return false;
            }
            ApiError::Conflict => {
                self.set_error(Some("conflict"), false);
                tokio::time::sleep(self.timing.conflict_wait).await;
            }
            ApiError::RateLimited(secs) => {
                tokio::time::sleep(Duration::from_secs(*secs).min(self.timing.retry_cap)).await;
            }
            ApiError::Network(_) | ApiError::Rejected { .. } => {
                tracing::warn!("telegram: poll failed: {error}");
                self.set_error(Some("network"), false);
                tokio::time::sleep(*backoff).await;
                *backoff = (*backoff * 2).min(self.timing.backoff_max);
            }
        }
        true
    }

    async fn poll(self: Arc<Self>, generation: u64) {
        let _guard = RunGuard {
            tg: self.clone(),
            generation,
        };
        let Some(token) = self.token() else {
            return;
        };
        let mut backoff = self.timing.backoff_start;
        // A webhook and a poll cannot both be set.
        loop {
            match self.api.call(&token, "deleteWebhook", json!({}), 15).await {
                Ok(_) => break,
                Err(e) => {
                    if !self.poll_error(&e, &mut backoff).await {
                        return;
                    }
                }
            }
        }
        loop {
            let offset = self
                .store()
                .tg_state_get(KEY_OFFSET)
                .ok()
                .flatten()
                .and_then(|v| v.parse::<i64>().ok());
            let body = updates_body(self.timing.poll_secs, offset);
            match self
                .api
                .call(&token, "getUpdates", body, self.timing.poll_secs + 15)
                .await
            {
                Ok(result) => {
                    backoff = self.timing.backoff_start;
                    self.set_error(None, false);
                    let updates = result.as_array().cloned().unwrap_or_default();
                    if updates.is_empty() {
                        tokio::time::sleep(self.timing.idle_pause).await;
                        continue;
                    }
                    for update in updates {
                        let id = update["update_id"].as_i64();
                        self.handle_update_guarded(update).await;
                        // After handling, so a crash in the middle repeats the update rather than losing it.
                        if let Some(id) = id
                            && let Err(e) = self.store().tg_state_set(KEY_OFFSET, &(id + 1).to_string())
                        {
                            tracing::warn!("telegram: keep the offset: {e:#}");
                        }
                    }
                }
                Err(e) => {
                    if !self.poll_error(&e, &mut backoff).await {
                        return;
                    }
                }
            }
        }
    }

    // ---- sending ----

    /// Whether a notice of `kind` may go to `chat` now (and notes that it did).
    fn allow_notice(&self, chat: i64, kind: &'static str, gap: Duration) -> bool {
        let mut st = self.lock();
        let now = Instant::now();
        if st
            .notices
            .get(&(chat, kind))
            .is_some_and(|at| now.duration_since(*at) < gap)
        {
            return false;
        }
        st.notices.insert((chat, kind), now);
        st.bound();
        true
    }

    /// Takes the next place in the chat's line (one message a second) and waits for it. `false`: the line is so long
    /// that an unimportant message is dropped.
    async fn reserve(&self, chat: i64, important: bool) -> bool {
        let slot = {
            let mut st = self.lock();
            let now = Instant::now();
            let slot = st.send_slots.get(&chat).copied().unwrap_or(now).max(now);
            if !important && slot.duration_since(now) > MAX_SEND_BACKLOG {
                return false;
            }
            st.send_slots.insert(chat, slot + self.timing.send_gap);
            st.bound();
            slot
        };
        let wait = slot.saturating_duration_since(Instant::now());
        if !wait.is_zero() {
            tokio::time::sleep(wait).await;
        }
        true
    }

    /// One call, repeated after a 429 (once the wait is over) and after a network failure (twice).
    async fn call_retrying(&self, token: &str, method: &str, body: Value) -> Result<Value, ApiError> {
        let mut attempt = 0u32;
        loop {
            attempt += 1;
            match self.api.call(token, method, body.clone(), 30).await {
                Err(ApiError::RateLimited(secs)) if attempt < 3 => {
                    tokio::time::sleep(Duration::from_secs(secs).min(self.timing.retry_cap)).await;
                }
                Err(ApiError::Network(_)) if attempt < 3 => {
                    tokio::time::sleep(self.timing.backoff_start * attempt).await;
                }
                other => return other,
            }
        }
    }

    /// Sends an HTML message and returns its id. A message Telegram cannot parse goes again as plain text; a chat that
    /// cannot be written to (the bot was blocked) is logged and skipped.
    async fn send_html(&self, chat: i64, html: &str, markup: Option<Value>, important: bool) -> Option<i64> {
        let token = self.token()?;
        if !self.reserve(chat, important).await {
            tracing::debug!("telegram: a message to a busy chat was dropped");
            return None;
        }
        let too_long = utf16_len(html) > MESSAGE_LIMIT;
        let mut plain = too_long;
        let mut text = if too_long {
            fit(&plain_from_html(html))
        } else {
            html.to_string()
        };
        loop {
            let mut body = json!({
                "chat_id": chat,
                "text": text,
                "link_preview_options": { "is_disabled": true },
            });
            if !plain {
                body["parse_mode"] = json!("HTML");
            }
            if let Some(markup) = &markup {
                body["reply_markup"] = markup.clone();
            }
            match self.call_retrying(&token, "sendMessage", body).await {
                Ok(sent) => return sent["message_id"].as_i64(),
                Err(ApiError::Rejected { code: 400, description })
                    if !plain && description.to_lowercase().contains("parse") =>
                {
                    plain = true;
                    text = fit(&plain_from_html(html));
                }
                Err(e) => {
                    tracing::warn!("telegram: could not send a message: {e}");
                    return None;
                }
            }
        }
    }

    /// Replaces a message's text and takes its buttons off.
    async fn edit_html(&self, chat: i64, message_id: i64, html: &str) {
        let Some(token) = self.token() else {
            return;
        };
        self.reserve(chat, true).await;
        let body = json!({
            "chat_id": chat,
            "message_id": message_id,
            "text": if utf16_len(html) > MESSAGE_LIMIT { fit(&plain_from_html(html)) } else { html.to_string() },
            "parse_mode": "HTML",
            "link_preview_options": { "is_disabled": true },
            "reply_markup": { "inline_keyboard": [] },
        });
        match self.call_retrying(&token, "editMessageText", body).await {
            Ok(_) => {}
            // The same text twice is no failure.
            Err(ApiError::Rejected { description, .. }) if description.contains("not modified") => {}
            Err(e) => tracing::warn!("telegram: could not edit a message: {e}"),
        }
    }

    /// Answers a press, so the button stops spinning; `text` shows as a short note.
    async fn answer_callback(&self, callback_id: &str, text: Option<&str>) {
        let Some(token) = self.token() else {
            return;
        };
        let mut body = json!({ "callback_query_id": callback_id });
        if let Some(text) = text {
            body["text"] = json!(truncate_chars(text, 200));
        }
        if let Err(e) = self.api.call(&token, "answerCallbackQuery", body, 15).await {
            tracing::debug!("telegram: could not answer a press: {e}");
        }
    }

    async fn leave_chat(&self, chat: i64) {
        let Some(token) = self.token() else {
            return;
        };
        if let Err(e) = self.api.call(&token, "leaveChat", json!({ "chat_id": chat }), 15).await {
            tracing::debug!("telegram: could not leave a chat: {e}");
        }
    }

    /// A text of the table in the chat's language, as an important message.
    async fn say(&self, chat: &TgChat, key: &str, args: &[(&str, &str)]) -> Option<i64> {
        self.send_html(chat.chat_id, &tr(&chat.language, key, args), None, true)
            .await
    }
}

/// `text` cut to what one message holds.
fn fit(text: &str) -> String {
    let mut out = truncate_chars(text, MESSAGE_LIMIT).to_string();
    while utf16_len(&out) > MESSAGE_LIMIT {
        out.pop();
    }
    out
}
