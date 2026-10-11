//! The "typing…" of a turn that a Telegram message started: while the agent works on it, the chat shows "typing…" (Telegram
//! keeps it about five seconds), so one `sendChatAction` goes out every few seconds until the turn completes, however it
//! ends, and never longer than the cap. An action is not a message: it skips the line of a chat. A failed action is
//! logged and forgotten, except that a refused token or a conflict ends the task. Which turns a chat started is decided
//! in `events.rs`; this file only keeps their tasks.

use super::Telegram;
use super::api::{Api, ApiError};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::oneshot;

/// What the tasks of the turns share: which turns have a task, and when a chat last got an action.
#[derive(Default)]
pub(super) struct Typing {
    /// Turn id to the stop switch of its task. Dropping the sender ends the task.
    turns: HashMap<String, oneshot::Sender<()>>,
    /// Chat to when its last action went out. One action per chat per gap, whichever turn asks.
    last: HashMap<i64, Instant>,
}

pub(super) type Shared = Arc<Mutex<Typing>>;

impl Typing {
    /// Whether a chat may get an action now (and notes that it does).
    pub(super) fn allow(&mut self, chat: i64, now: Instant, gap: Duration) -> bool {
        if self
            .last
            .get(&chat)
            .is_some_and(|at| now.saturating_duration_since(*at) < gap)
        {
            return false;
        }
        self.last.insert(chat, now);
        true
    }

    /// Forgets the tasks that have ended.
    fn prune(&mut self) {
        self.turns.retain(|_, stop| !stop.is_closed());
    }
}

impl Telegram {
    fn typing_state(&self) -> std::sync::MutexGuard<'_, Typing> {
        self.typing.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Starts the "typing…" of a turn that a message of `chat` started. A turn that has a task already keeps it.
    pub(super) fn start_typing(&self, turn_id: &str, chat: i64) {
        let Some(token) = self.token() else {
            return;
        };
        let (stop, stopped) = oneshot::channel();
        {
            let mut typing = self.typing_state();
            typing.prune();
            if typing.turns.contains_key(turn_id) {
                return;
            }
            typing.turns.insert(turn_id.to_string(), stop);
        }
        let job = Job {
            api: self.api.clone(),
            token,
            chat,
            every: self.timing.typing_every,
            max: self.timing.typing_max,
            shared: self.typing.clone(),
        };
        tokio::spawn(job.run(stopped));
    }

    /// Ends the "typing…" of a turn, whichever way the turn ended.
    pub(super) fn stop_typing(&self, turn_id: &str) {
        self.typing_state().turns.remove(turn_id);
    }

    /// Ends every "typing…" (the token is removed, or the poll stops).
    pub(super) fn stop_all_typing(&self) {
        let mut typing = self.typing_state();
        typing.turns.clear();
        typing.last.clear();
    }
}

/// What a turn's task needs, without the bot itself.
struct Job {
    api: Api,
    token: String,
    chat: i64,
    every: Duration,
    max: Duration,
    shared: Shared,
}

impl Job {
    async fn run(self, mut stop: oneshot::Receiver<()>) {
        let until = tokio::time::Instant::now() + self.max;
        let mut tick = tokio::time::interval(self.every);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                _ = &mut stop => break,
                _ = tokio::time::sleep_until(until) => break,
                _ = tick.tick() => {}
            }
            if !self
                .shared
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .allow(self.chat, Instant::now(), self.every)
            {
                continue;
            }
            let sent = tokio::select! {
                _ = &mut stop => break,
                _ = tokio::time::sleep_until(until) => break,
                sent = self.api.call(&self.token, "sendChatAction", json!({ "chat_id": self.chat, "action": "typing" }), 15) => sent,
            };
            match sent {
                Ok(_) => {}
                Err(ApiError::Unauthorized | ApiError::Conflict) => break,
                Err(e) => tracing::debug!("telegram: could not send a typing action: {e}"),
            }
        }
        self.shared.lock().unwrap_or_else(|e| e.into_inner()).prune();
    }
}
