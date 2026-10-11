//! A fake Telegram Bot API for the tests of the bot: it listens on `127.0.0.1`, records every call, serves queued
//! updates through `getUpdates` (a long poll, like the real one) and can be told to fail a method once.

use axum::Router;
use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// One call the bot made.
#[derive(Debug, Clone)]
pub struct Call {
    pub method: String,
    pub body: Value,
    /// The `bot<TOKEN>` part of the path.
    pub bot: String,
    pub at: Instant,
}

/// How a method fails when it is told to.
#[derive(Debug, Clone)]
pub struct Failure {
    pub status: u16,
    pub description: String,
    pub retry_after: Option<u64>,
}

struct Inner {
    tokens: Vec<String>,
    calls: Vec<Call>,
    updates: VecDeque<Value>,
    failures: HashMap<String, VecDeque<Failure>>,
    next_message_id: i64,
    next_update_id: i64,
}

pub struct FakeTelegram {
    /// `http://127.0.0.1:<port>`
    pub base: String,
    inner: Mutex<Inner>,
    wake: tokio::sync::Notify,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for FakeTelegram {
    fn drop(&mut self) {
        if let Some(t) = self.task.lock().unwrap_or_else(|e| e.into_inner()).take() {
            t.abort();
        }
    }
}

impl FakeTelegram {
    /// A fake that knows `token` and answers `getMe` with the bot `bandito_test_bot`.
    pub async fn start(token: &str) -> Arc<FakeTelegram> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let fake = Arc::new(FakeTelegram {
            base: format!("http://127.0.0.1:{port}"),
            inner: Mutex::new(Inner {
                tokens: vec![token.to_string()],
                calls: Vec::new(),
                updates: VecDeque::new(),
                failures: HashMap::new(),
                next_message_id: 1000,
                next_update_id: 1,
            }),
            wake: tokio::sync::Notify::new(),
            task: Mutex::new(None),
        });
        let app = Router::new().route("/{bot}/{method}", post(handle)).with_state(fake.clone());
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        *fake.task.lock().unwrap() = Some(task);
        fake
    }

    /// Makes the fake know one more token.
    pub fn add_token(&self, token: &str) {
        self.inner.lock().unwrap().tokens.push(token.to_string());
    }

    /// Queues an update for `getUpdates`; it gets the next `update_id`.
    pub fn push_update(&self, mut update: Value) -> i64 {
        let mut inner = self.inner.lock().unwrap();
        let id = inner.next_update_id;
        inner.next_update_id += 1;
        update["update_id"] = json!(id);
        inner.updates.push_back(update);
        drop(inner);
        self.wake.notify_waiters();
        id
    }

    /// The next call of `method` fails with this Bot API error.
    pub fn fail_next(&self, method: &str, status: u16, description: &str, retry_after: Option<u64>) {
        self.inner
            .lock()
            .unwrap()
            .failures
            .entry(method.to_string())
            .or_default()
            .push_back(Failure {
                status,
                description: description.to_string(),
                retry_after,
            });
    }

    /// Every call so far.
    pub fn all_calls(&self) -> Vec<Call> {
        self.inner.lock().unwrap().calls.clone()
    }

    /// The bodies of the calls of `method`, oldest first.
    pub fn calls(&self, method: &str) -> Vec<Value> {
        self.calls_full(method).into_iter().map(|c| c.body).collect()
    }

    pub fn calls_full(&self, method: &str) -> Vec<Call> {
        self.inner
            .lock()
            .unwrap()
            .calls
            .iter()
            .filter(|c| c.method == method)
            .cloned()
            .collect()
    }

    /// The `sendMessage` bodies sent to `chat`.
    pub fn sent_to(&self, chat: i64) -> Vec<Value> {
        self.calls("sendMessage")
            .into_iter()
            .filter(|b| b["chat_id"].as_i64() == Some(chat))
            .collect()
    }

    /// Waits until `count` calls of `method` were made, up to 5 s.
    pub async fn wait_calls(&self, method: &str, count: usize) -> Vec<Value> {
        for _ in 0..500 {
            let found = self.calls(method);
            if found.len() >= count {
                return found;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("expected {count} calls of {method}, saw {:?}", self.calls(method));
    }

    pub fn clear_calls(&self) {
        self.inner.lock().unwrap().calls.clear();
    }

    /// The id of the message the fake sent last.
    pub fn last_message_id(&self) -> i64 {
        self.inner.lock().unwrap().next_message_id
    }

    pub fn pending_updates(&self) -> usize {
        self.inner.lock().unwrap().updates.len()
    }
}

fn answer(status: u16, body: Value) -> Response {
    (
        StatusCode::from_u16(status).unwrap(),
        [(header::CONTENT_TYPE, "application/json")],
        body.to_string(),
    )
        .into_response()
}

fn error_body(status: u16, description: &str, retry_after: Option<u64>) -> Value {
    let mut body = json!({ "ok": false, "error_code": status, "description": description });
    if let Some(n) = retry_after {
        body["parameters"] = json!({ "retry_after": n });
    }
    body
}

async fn handle(
    State(f): State<Arc<FakeTelegram>>,
    Path((bot, method)): Path<(String, String)>,
    body: Bytes,
) -> Response {
    let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let (known, failure) = {
        let mut inner = f.inner.lock().unwrap();
        inner.calls.push(Call {
            method: method.clone(),
            body: body.clone(),
            bot: bot.clone(),
            at: Instant::now(),
        });
        let known = inner.tokens.iter().any(|t| bot == format!("bot{t}"));
        let failure = inner.failures.get_mut(&method).and_then(VecDeque::pop_front);
        (known, failure)
    };
    if !known {
        return answer(401, error_body(401, "Unauthorized", None));
    }
    if let Some(fail) = failure {
        return answer(fail.status, error_body(fail.status, &fail.description, fail.retry_after));
    }
    match method.as_str() {
        "getMe" => answer(
            200,
            json!({ "ok": true, "result": {
                "id": 424242, "is_bot": true, "first_name": "Bandito Test", "username": "bandito_test_bot" } }),
        ),
        "getUpdates" => {
            let offset = body["offset"].as_i64().unwrap_or(0);
            let wait = Duration::from_secs(body["timeout"].as_u64().unwrap_or(0));
            let deadline = Instant::now() + wait;
            loop {
                let notified = f.wake.notified();
                tokio::pin!(notified);
                // Enable before looking, so a push between the look and the wait is not lost.
                notified.as_mut().enable();
                let batch: Vec<Value> = {
                    let mut inner = f.inner.lock().unwrap();
                    inner.updates.retain(|u| u["update_id"].as_i64().unwrap_or(0) >= offset);
                    inner.updates.iter().cloned().collect()
                };
                if !batch.is_empty() {
                    return answer(200, json!({ "ok": true, "result": batch }));
                }
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return answer(200, json!({ "ok": true, "result": [] }));
                }
                let _ = tokio::time::timeout(left, notified).await;
            }
        }
        "sendMessage" => {
            let mut inner = f.inner.lock().unwrap();
            inner.next_message_id += 1;
            let id = inner.next_message_id;
            answer(
                200,
                json!({ "ok": true, "result": { "message_id": id, "chat": { "id": body["chat_id"] } } }),
            )
        }
        "editMessageText" => answer(
            200,
            json!({ "ok": true, "result": { "message_id": body["message_id"], "chat": { "id": body["chat_id"] } } }),
        ),
        "answerCallbackQuery" | "leaveChat" | "deleteWebhook" | "setMyCommands" => {
            answer(200, json!({ "ok": true, "result": true }))
        }
        other => answer(404, error_body(404, &format!("Not Found: {other}"), None)),
    }
}
