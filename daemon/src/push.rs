//! Push notifications for phones whose app is closed (docs/ARCHITECTURE.md#push).
//!
//! A phone registers a target (`push.register`, see `rpc/push.rs`): its address at bandito.dev, a 32-byte key, the
//! name it gives this server and the kinds it wants. A background task listens to the [`Hub`]; for each event that the
//! phone's own app would have made a local notification for ([`push_kind`]), it encrypts a small JSON payload with the
//! phone's key (ChaCha20-Poly1305) and posts it to the cloud, which hands it to APNs. The cloud never sees the text.
//!
//! Sending never blocks the hub or an RPC for long: events wait in two queues (approvals and questions first, 256 each;
//! `done` and `error` after them, dropped when full) and are sent by `curl` subprocesses, a few at a time. Logs carry the kind and the status code, never the handle, the key, the text
//! or a token.

use crate::event::{AgentChange, AgentStatus, Event, EventBody, TurnStatus};
use crate::hub::Hub;
use crate::store::{PushTarget, Store};
use anyhow::{Result, anyhow, bail};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Semaphore, broadcast, mpsc};

/// The cloud API, without a trailing slash. `BANDITO_PUSH_URL` replaces it (tests, a staging cloud).
pub const DEFAULT_BASE_URL: &str = "https://bandito.dev/api/v1";
/// The most events waiting in each of the two queues.
const QUEUE: usize = 256;
/// How long a full high queue is waited for before the event is dropped.
const HIGH_WAIT: Duration = Duration::from_secs(1);
/// A phone gets an `error` push for one agent at most this often (more are dropped).
const ERROR_EVERY: Duration = Duration::from_secs(30);
/// A phone gets a `done` push for one agent at most this often (more are dropped).
const DONE_EVERY: Duration = Duration::from_secs(10);
/// After a 429 nothing is sent to that phone for this long.
const RATE_PAUSE: Duration = Duration::from_secs(60);
/// The most approvals and questions kept for a phone during a pause (the oldest go first).
const DEFERRED_MAX: usize = 20;
/// Sends running at the same time.
const PARALLEL: usize = 4;
/// The most bytes of plaintext. The cloud takes 2700 bytes of ciphertext; the tag adds 16.
pub const MAX_PLAINTEXT: usize = 2600;
/// The longest text a done shows, in characters; the envelope tries it cut to each step, then without it.
const TEXT_CHARS: usize = 400;
const TEXT_STEPS: [usize; 3] = [TEXT_CHARS, 200, 80];
/// Heavy strings in a payload are cut to this many characters when it does not fit.
const CUT_CHARS: usize = 300;
/// The longest server name (`serverRef`) the daemon accepts.
const SERVER_REF_CHARS: usize = 64;
/// The longest agent name that goes into a payload.
const NAME_CHARS: usize = 100;
/// The most bytes of the cloud's answer that are read.
const MAX_ANSWER: u64 = 64 * 1024;
/// One request, start to end (curl `--max-time`).
const REQUEST_SECONDS: u64 = 10;
/// The associated data of every payload is this plus the handle: a payload for one handle fails on another.
const AAD_PREFIX: &str = "bandito-push:v1:";

/// What a push is about. The names are the cloud's `kind` values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PushKind {
    Approval,
    Question,
    Done,
    Error,
    /// Reserved: nothing sends it yet, but a phone may ask for it.
    Connect,
}

impl PushKind {
    pub const ALL: [PushKind; 5] = [
        PushKind::Approval,
        PushKind::Question,
        PushKind::Done,
        PushKind::Error,
        PushKind::Connect,
    ];

    /// Approvals and questions wait for the person: they go first and are kept through a pause.
    fn urgent(self) -> bool {
        matches!(self, PushKind::Approval | PushKind::Question)
    }

    /// The least time between two pushes of this kind for one phone and one agent.
    fn min_gap(self) -> Option<Duration> {
        match self {
            PushKind::Error => Some(ERROR_EVERY),
            PushKind::Done => Some(DONE_EVERY),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            PushKind::Approval => "approval",
            PushKind::Question => "question",
            PushKind::Done => "done",
            PushKind::Error => "error",
            PushKind::Connect => "connect",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|k| k.as_str() == s)
    }

    /// The kinds of a stored comma-separated list. A name that is not known is skipped.
    pub fn parse_csv(csv: &str) -> Vec<Self> {
        csv.split(',').filter_map(|s| Self::parse(s.trim())).collect()
    }

    /// The stored list: each kind once, in the order of [`PushKind::ALL`].
    pub fn to_csv(kinds: &[PushKind]) -> String {
        Self::ALL
            .into_iter()
            .filter(|k| kinds.contains(k))
            .map(PushKind::as_str)
            .collect::<Vec<_>>()
            .join(",")
    }
}

/// What the task knows about the agent and the turn, beyond the event itself.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Ctx {
    /// The turn that ended with this event was a quiet one (`turn.quiet` came before): nobody is told.
    pub quiet_turn: bool,
    /// The agent has an approval, a form or a connect request waiting, which has its own push.
    pub other_pending: bool,
    /// The plain text of the turn's last message (cut to 400 characters). Set on `turn.completed` only: a done needs
    /// it, and it is the text the notification shows.
    pub answer: Option<String>,
}

/// The push an event makes, if any: the same rules as the phone's local notifications
/// (`IOSNotifications.notice(for:)` and `AgentNotice.notice(for:in:)`), so a closed app and an open one tell the same.
/// - an approval waiting -> `approval`;
/// - a form -> `question` (a connect request has no local notification either, so no push);
/// - the agent needs the person with nothing else waiting (its own question) -> `question`;
/// - a turn that ended well, unless it was quiet or wrote no text -> `done` (with the text);
/// - an error -> `error`.
pub fn push_kind(ev: &Event, ctx: &Ctx) -> Option<PushKind> {
    match &ev.body {
        EventBody::ApprovalRequested { .. } => Some(PushKind::Approval),
        EventBody::FormRequested { .. } => Some(PushKind::Question),
        EventBody::AgentStatus {
            status: AgentStatus::NeedsYou,
            ..
        } if !ctx.other_pending => Some(PushKind::Question),
        EventBody::TurnCompleted {
            status: TurnStatus::Ok, ..
        } if !ctx.quiet_turn && ctx.answer.as_deref().is_some_and(|t| !t.is_empty()) => Some(PushKind::Done),
        EventBody::Error { .. } => Some(PushKind::Error),
        _ => None,
    }
}

// ---- the open text: what the phone reads after decrypting ----

/// `s` cut to `max` characters, the last one being `…` when something was cut.
fn cut(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max - 1).collect();
    out.push('…');
    out
}

/// Every string inside `v`, however deep, cut to [`CUT_CHARS`].
fn cut_strings(v: &mut Value) {
    match v {
        Value::String(s) => {
            if s.chars().count() > CUT_CHARS {
                *s = cut(s, CUT_CHARS);
            }
        }
        Value::Array(items) => items.iter_mut().for_each(cut_strings),
        Value::Object(map) => map.values_mut().for_each(cut_strings),
        _ => {}
    }
}

/// The text a notification shows: the markdown taken off (fence lines go, the code they wrap stays as text; heading
/// marks, `**`, `*` and `_` emphasis and backticks go; `[text](url)` becomes `text`), then every run of whitespace is
/// one space. A `*` or `_` between two letters or digits stays (`my_var`, `2*3`).
pub fn plain(raw: &str) -> String {
    let lines: Vec<&str> = raw
        .lines()
        .filter(|l| !l.trim_start().starts_with("```"))
        .map(heading_text)
        .collect();
    strip_inline(&lines.join("\n"))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// A line without its heading mark (`## Итог` is `Итог`); a `#` with no space after it is text.
fn heading_text(line: &str) -> &str {
    let t = line.trim_start();
    let body = t.trim_start_matches('#');
    if body.len() < t.len() && body.starts_with(' ') {
        body.trim_start()
    } else {
        t
    }
}

fn strip_inline(s: &str) -> String {
    let c: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len());
    let mut i = 0;
    while i < c.len() {
        match c[i] {
            '`' => {}
            '[' => {
                if let Some((close, end)) = link_end(&c, i) {
                    out.extend(&c[i + 1..close]);
                    i = end + 1;
                    continue;
                }
                out.push('[');
            }
            '*' | '_'
                if !(i > 0 && c[i - 1].is_alphanumeric() && c.get(i + 1).is_some_and(|n| n.is_alphanumeric())) => {}
            other => out.push(other),
        }
        i += 1;
    }
    out
}

/// For a `[` at `open`: the index of the `]` that ends its text and of the `)` that ends its url, when `](...)` follows.
fn link_end(c: &[char], open: usize) -> Option<(usize, usize)> {
    let close = open + 1 + c[open + 1..].iter().position(|&x| x == ']')?;
    if c.get(close + 1) != Some(&'(') {
        return None;
    }
    let end = close + 2 + c[close + 2..].iter().position(|&x| x == ')')?;
    Some((close, end))
}

/// The envelope; `text` (a done's reply, already plain) is added as the top-level `text` field when given.
fn envelope(server_ref: &str, ev: &Event, name: &str, text: Option<&str>, event: &Value) -> String {
    let mut env = json!({
        "v": 1,
        "srv": server_ref,
        "seq": ev.seq,
        "agent": ev.agent_id,
        "name": cut(name, NAME_CHARS),
        "ts": ev.ts,
        "event": event,
    });
    if let Some(text) = text {
        env["text"] = json!(text);
    }
    env.to_string()
}

/// The JSON a phone decrypts: `{"v":1,"srv":serverRef,"seq":N,"agent":id,"name":agentName,"ts":ms,"event":{kind,payload}}`,
/// with a top-level `"text"` for a done.
/// `event` is the event's body as `events.since` sends it (`kind` and `payload`). When the envelope is longer than
/// [`MAX_PLAINTEXT`] bytes the `text` goes first (cut to 200, then 80 characters, then dropped); then the heavy fields (`diff`, `input`, `command`, `message`) are cut to 300 characters; then
/// every long string; then `input` and `diff` go; and at the very end only the ids that let the phone fetch the
/// event remain (`approval_id`, `form_id`, `request_id`).
pub fn build_payload(server_ref: &str, ev: &Event, agent_name: &str, text: Option<&str>) -> String {
    let (kind, payload) = ev.body.to_parts();
    let mut event = json!({ "kind": kind, "payload": payload });
    // The text goes first: cut to 400, then 200 and 80 characters, then dropped; only then is anything else cut.
    let mut shown: Vec<Option<String>> = text
        .map(|t| TEXT_STEPS.iter().map(|&n| Some(cut(t, n))).collect())
        .unwrap_or_default();
    shown.push(None);
    for candidate in &shown {
        let full = envelope(server_ref, ev, agent_name, candidate.as_deref(), &event);
        if full.len() <= MAX_PLAINTEXT {
            return full;
        }
    }
    // 1. The heavy fields.
    if let Some(map) = event.get_mut("payload").and_then(Value::as_object_mut) {
        for key in ["diff", "input", "command", "message"] {
            if let Some(v) = map.get_mut(key) {
                cut_strings(v);
            }
        }
    }
    let text = envelope(server_ref, ev, agent_name, None, &event);
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 2. Every long string.
    if let Some(p) = event.get_mut("payload") {
        cut_strings(p);
    }
    let text = envelope(server_ref, ev, agent_name, None, &event);
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 3. Without the biggest optional fields.
    if let Some(map) = event.get_mut("payload").and_then(Value::as_object_mut) {
        map.remove("input");
        map.remove("diff");
    }
    let text = envelope(server_ref, ev, agent_name, None, &event);
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 4. Only what names the thing.
    let (kind, parts) = ev.body.to_parts();
    let mut ids = serde_json::Map::new();
    if let Some(map) = parts.as_object() {
        for key in ["approval_id", "form_id", "request_id"] {
            if let Some(v) = map.get(key) {
                let mut v = v.clone();
                cut_strings(&mut v);
                ids.insert(key.to_string(), v);
            }
        }
    }
    let text = envelope(
        server_ref,
        ev,
        agent_name,
        None,
        &json!({ "kind": kind, "payload": ids }),
    );
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 5. The last word: the kind alone, with the server name and the agent name cut to what they may be.
    let event = json!({ "kind": kind });
    for (srv, name) in [(SERVER_REF_CHARS, NAME_CHARS), (16, 0), (0, 0)] {
        let text = json!({
            "v": 1,
            "srv": cut(server_ref, srv),
            "seq": ev.seq,
            "agent": ev.agent_id,
            "name": cut(agent_name, name),
            "ts": ev.ts,
            "event": event,
        })
        .to_string();
        if text.len() <= MAX_PLAINTEXT {
            return text;
        }
    }
    // An agent id this long cannot exist (ids are UUIDs); the phone still gets the kind and the sequence number.
    json!({ "v": 1, "seq": ev.seq, "ts": ev.ts, "event": event }).to_string()
}

// ---- encryption ----

/// ChaCha20-Poly1305 (IETF, 12-byte nonce) of `plaintext` under the phone's `key`, with `bandito-push:v1:<handle>` as
/// the associated data. The result is the ciphertext followed by the 16-byte tag (what `ChaChaPoly.SealedBox` splits).
pub fn seal(key: &[u8], handle: &str, nonce: &[u8; 12], plaintext: &[u8]) -> Result<Vec<u8>> {
    let cipher = ChaCha20Poly1305::new_from_slice(key).map_err(|_| anyhow!("the push key is not 32 bytes"))?;
    let aad = format!("{AAD_PREFIX}{handle}");
    cipher
        .encrypt(
            Nonce::from_slice(nonce),
            Payload {
                msg: plaintext,
                aad: aad.as_bytes(),
            },
        )
        .map_err(|_| anyhow!("could not encrypt the push"))
}

/// Seals with a fresh random nonce; `(ct, nonce)` as standard base64 with padding, as the cloud takes them.
fn seal_b64(key: &[u8], handle: &str, plaintext: &[u8]) -> Result<(String, String)> {
    let nonce: [u8; 12] = rand::random();
    let ct = seal(key, handle, &nonce, plaintext)?;
    Ok((STANDARD.encode(ct), STANDARD.encode(nonce)))
}

// ---- who is waiting for what ----

/// What the task has seen of each agent: its open approvals, forms and connect requests (a question of the agent's
/// own is a `needs_you` with none of them), and the turns that were quiet.
#[derive(Default)]
struct Tracker {
    open: HashMap<String, HashSet<String>>,
    quiet: HashSet<String>,
    /// The plain text of each agent's last message in its running turn (cut to [`TEXT_CHARS`]).
    answers: HashMap<String, String>,
}

impl Tracker {
    fn add(&mut self, agent: &str, id: String) {
        self.open.entry(agent.to_string()).or_default().insert(id);
    }

    fn remove(&mut self, agent: &str, id: &str) {
        if let Some(set) = self.open.get_mut(agent) {
            set.remove(id);
            if set.is_empty() {
                self.open.remove(agent);
            }
        }
    }

    /// Forgets what was known and reads what waits now from the store: at start, and after the task fell behind (an
    /// answer that came in the missed events must not keep an agent's question from being told).
    fn reseed(&mut self, store: &Store) {
        self.open.clear();
        self.seed(store);
    }

    fn seed(&mut self, store: &Store) {
        match store.approval_list_pending(None) {
            Ok(list) => list
                .into_iter()
                .for_each(|a| self.add(&a.agent_id, format!("a:{}", a.id))),
            Err(e) => tracing::warn!("push: read pending approvals: {e:#}"),
        }
        match store.form_list(None, Some(crate::store::FormStatus::Pending)) {
            Ok(list) => list
                .into_iter()
                .for_each(|f| self.add(&f.agent_id, format!("f:{}", f.id))),
            Err(e) => tracing::warn!("push: read pending forms: {e:#}"),
        }
        match store.connect_requests_unresolved() {
            Ok(list) => list
                .into_iter()
                .for_each(|(agent, id)| self.add(&agent, format!("c:{id}"))),
            Err(e) => tracing::warn!("push: read pending connect requests: {e:#}"),
        }
    }

    /// Takes the event in and says what is known about its agent.
    fn observe(&mut self, ev: &Event) -> Ctx {
        let agent = ev.agent_id.as_str();
        let mut quiet_turn = false;
        let mut answer: Option<String> = None;
        match &ev.body {
            EventBody::TurnStarted { .. } => {
                self.answers.remove(agent);
            }
            EventBody::MessageAssistant { text } => {
                self.answers.insert(agent.to_string(), cut(&plain(text), TEXT_CHARS));
            }
            EventBody::ApprovalRequested { approval_id, .. } => self.add(agent, format!("a:{approval_id}")),
            EventBody::ApprovalResolved { approval_id, .. } | EventBody::ApprovalWithdrawn { approval_id } => {
                self.remove(agent, &format!("a:{approval_id}"));
            }
            EventBody::FormRequested { form_id, .. } => self.add(agent, format!("f:{form_id}")),
            EventBody::FormAnswered { form_id, .. } => self.remove(agent, &format!("f:{form_id}")),
            EventBody::IntegrationRequested { request_id, .. } => self.add(agent, format!("c:{request_id}")),
            EventBody::IntegrationRequestEnded { request_id, .. } => self.remove(agent, &format!("c:{request_id}")),
            EventBody::TurnQuiet { turn_id, .. } => {
                if self.quiet.len() >= 256 {
                    self.quiet.clear();
                }
                self.quiet.insert(turn_id.clone());
            }
            EventBody::TurnCompleted { turn_id, .. } => {
                quiet_turn = self.quiet.remove(turn_id);
                answer = self.answers.remove(agent);
            }
            EventBody::AgentChanged {
                action: AgentChange::Deleted,
            } => {
                self.open.remove(agent);
                self.answers.remove(agent);
            }
            _ => {}
        }
        Ctx {
            quiet_turn,
            other_pending: self.open.contains_key(agent),
            answer,
        }
    }
}

// ---- the task ----

/// The task's clock, in milliseconds since it was made. Tests move it by hand ([`Clock::advance`]).
#[derive(Debug, Clone)]
pub struct Clock {
    start: Instant,
    skew_ms: Arc<AtomicU64>,
}

impl Default for Clock {
    fn default() -> Self {
        Self {
            start: Instant::now(),
            skew_ms: Arc::new(AtomicU64::new(0)),
        }
    }
}

impl Clock {
    fn now_ms(&self) -> u64 {
        self.start.elapsed().as_millis() as u64 + self.skew_ms.load(Ordering::Relaxed)
    }

    /// Moves the clock forward (tests).
    pub fn advance(&self, by: Duration) {
        self.skew_ms.fetch_add(by.as_millis() as u64, Ordering::Relaxed);
    }
}

/// Where and how the task sends.
#[derive(Debug, Clone)]
pub struct Config {
    pub base_url: String,
    /// The wait before the one retry.
    pub retry_delay: Duration,
    /// Time for the pauses and the gaps between pushes.
    pub clock: Clock,
    /// How often the sender looks at the clock when nothing arrives (a pause ends, deferred pushes go).
    pub tick: Duration,
}

/// Whether `url` is plain http to this machine: the only http the task accepts.
fn is_loopback_http(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("http://") else {
        return false;
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    // `http://127.0.0.1@evil.example` has a user part: not loopback.
    if authority.contains('@') {
        return false;
    }
    let host = match authority.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or_default(),
        None => authority.split(':').next().unwrap_or_default(),
    };
    matches!(host, "localhost" | "127.0.0.1" | "::1")
}

impl Config {
    /// `BANDITO_PUSH_URL` when it is an https address, or http to this machine; else the cloud.
    pub fn from_env() -> Self {
        let base_url = match std::env::var("BANDITO_PUSH_URL") {
            Ok(v) if v.starts_with("https://") || is_loopback_http(&v) => v.trim_end_matches('/').to_string(),
            Ok(v) if v.trim().is_empty() => DEFAULT_BASE_URL.to_string(),
            Ok(_) => {
                tracing::warn!("BANDITO_PUSH_URL is not https or http to this machine: ignored");
                DEFAULT_BASE_URL.to_string()
            }
            Err(_) => DEFAULT_BASE_URL.to_string(),
        };
        Self {
            base_url,
            retry_delay: Duration::from_secs(2),
            clock: Clock::default(),
            tick: Duration::from_secs(1),
        }
    }
}

/// A request ready to send. It holds the encrypted body only, never the key.
struct Job {
    device_id: String,
    handle: String,
    agent_id: String,
    kind: PushKind,
    body: String,
}

/// The two queues in front of the sender.
struct Queues {
    /// Approvals and questions.
    high: mpsc::Sender<Job>,
    /// `done` and `error`.
    low: mpsc::Sender<Job>,
    /// How long a full high queue is waited for.
    high_wait: Duration,
}

/// Starts the task: it listens to the hub from now on (an event from before a registration is never sent later) and
/// lives as long as the hub does. The hub is subscribed and the waiting items are read before this returns, so an
/// event emitted right after cannot be missed.
pub fn spawn(hub: &Hub) -> tokio::task::JoinHandle<()> {
    spawn_with(hub, Config::from_env())
}

pub fn spawn_with(hub: &Hub, config: Config) -> tokio::task::JoinHandle<()> {
    let mut rx = hub.subscribe();
    let store = hub.store.clone();
    let mut tracker = Tracker::default();
    tracker.reseed(&store);
    let (high, high_rx) = mpsc::channel::<Job>(QUEUE);
    let (low, low_rx) = mpsc::channel::<Job>(QUEUE);
    let queues = Queues {
        high,
        low,
        high_wait: HIGH_WAIT,
    };
    tokio::spawn(send_loop(high_rx, low_rx, store.clone(), config));
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let ctx = tracker.observe(&ev);
                    if let Some(kind) = push_kind(&ev, &ctx) {
                        enqueue(&store, &queues, &ev, kind, ctx.answer.as_deref()).await;
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(missed = n, "push: the task fell behind, some events were not looked at");
                    tracker.reseed(&store);
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    })
}

/// Encrypts the event for each phone that wants `kind` and queues the requests. A full low queue drops the event at
/// once; a full high queue is waited for up to `high_wait`.
async fn enqueue(store: &Store, queues: &Queues, ev: &Event, kind: PushKind, answer: Option<&str>) {
    let targets = match store.push_list() {
        Ok(t) => t,
        Err(e) => {
            tracing::warn!("push: read the targets: {e:#}");
            return;
        }
    };
    let targets: Vec<PushTarget> = targets
        .into_iter()
        .filter(|t| PushKind::parse_csv(&t.kinds).contains(&kind))
        .collect();
    if targets.is_empty() {
        return;
    }
    let name = match store.agent_view(&ev.agent_id) {
        Ok(Some(a)) => a.name,
        _ => String::new(),
    };
    for target in targets {
        let body = match request_body(&target, kind, ev, &name, answer) {
            Ok(body) => body,
            Err(e) => {
                tracing::warn!(kind = kind.as_str(), "push: {e:#}");
                continue;
            }
        };
        let job = Job {
            device_id: target.device_id.clone(),
            handle: target.handle.clone(),
            agent_id: ev.agent_id.clone(),
            kind,
            body,
        };
        let queued = if kind.urgent() {
            queues.high.send_timeout(job, queues.high_wait).await.is_ok()
        } else {
            queues.low.try_send(job).is_ok()
        };
        if !queued {
            tracing::warn!(kind = kind.as_str(), "push: the queue is full, event dropped");
        }
    }
}

/// The JSON body of `POST /push/send` for one phone.
fn request_body(
    target: &PushTarget,
    kind: PushKind,
    ev: &Event,
    agent_name: &str,
    answer: Option<&str>,
) -> Result<String> {
    let text = build_payload(&target.server_ref, ev, agent_name, answer);
    let (ct, nonce) = seal_b64(&target.key, &target.handle, text.as_bytes())?;
    let mut body = json!({ "handle": target.handle, "kind": kind.as_str(), "ct": ct, "nonce": nonce });
    // One notification per event on the phone, and the agent's pushes group in one thread.
    body["collapseId"] = json!(format!("b{}", ev.seq));
    if ev.agent_id.len() <= 64 && ev.agent_id.chars().all(|c| c.is_ascii_graphic()) {
        body["threadId"] = json!(ev.agent_id);
    }
    Ok(body.to_string())
}

/// What the sender keeps for one phone.
#[derive(Default)]
struct Gate {
    /// No sending to this phone until then (after a 429), in clock milliseconds.
    paused_until: Option<u64>,
    /// Approvals and questions that came during the pause, oldest first.
    deferred: VecDeque<Job>,
}

/// The sender: takes jobs (the high queue first), keeps the gaps between pushes and the pause after a 429, and runs
/// the requests a few at a time.
struct Sender {
    config: Arc<Config>,
    gates: HashMap<String, Gate>,
    /// When the last `done` or `error` of a (phone, agent, kind) was let through.
    last: HashMap<(String, String, PushKind), u64>,
    /// Jobs whose pause has ended, to be sent before anything new.
    ready: VecDeque<Job>,
}

impl Sender {
    fn new(config: Arc<Config>) -> Self {
        Self {
            config,
            gates: HashMap::new(),
            last: HashMap::new(),
            ready: VecDeque::new(),
        }
    }

    /// A phone's pause begins now.
    fn pause(&mut self, device_id: &str) {
        let until = self.config.clock.now_ms() + RATE_PAUSE.as_millis() as u64;
        self.gates.entry(device_id.to_string()).or_default().paused_until = Some(until);
    }

    /// Ends the pauses that are over; their deferred jobs become ready. Forgets old gaps.
    fn release(&mut self) {
        let now = self.config.clock.now_ms();
        for gate in self.gates.values_mut() {
            if gate.paused_until.is_some_and(|t| t <= now) {
                gate.paused_until = None;
                self.ready.extend(gate.deferred.drain(..));
            }
        }
        self.gates
            .retain(|_, g| g.paused_until.is_some() || !g.deferred.is_empty());
        let longest = ERROR_EVERY.max(DONE_EVERY).as_millis() as u64;
        self.last.retain(|_, t| now.saturating_sub(*t) < longest);
    }

    /// The job, if it may go out now. In a pause an urgent one is kept and a `done` or `error` is dropped; a `done` or
    /// `error` closer than its gap to the last one is dropped.
    fn admit(&mut self, job: Job) -> Option<Job> {
        let now = self.config.clock.now_ms();
        let gate = self.gates.entry(job.device_id.clone()).or_default();
        if gate.paused_until.is_some_and(|t| t > now) {
            if job.kind.urgent() {
                if gate.deferred.len() >= DEFERRED_MAX {
                    gate.deferred.pop_front();
                }
                gate.deferred.push_back(job);
            }
            return None;
        }
        if let Some(gap) = job.kind.min_gap() {
            let key = (job.device_id.clone(), job.agent_id.clone(), job.kind);
            if self
                .last
                .get(&key)
                .is_some_and(|t| now.saturating_sub(*t) < gap.as_millis() as u64)
            {
                tracing::debug!(kind = job.kind.as_str(), "push: too soon after the last one, dropped");
                return None;
            }
            self.last.insert(key, now);
        }
        Some(job)
    }
}

async fn send_loop(mut high: mpsc::Receiver<Job>, mut low: mpsc::Receiver<Job>, store: Arc<Store>, config: Config) {
    let slots = Arc::new(Semaphore::new(PARALLEL));
    let config = Arc::new(config);
    let (report, mut limited) = mpsc::unbounded_channel::<String>();
    let mut sender = Sender::new(config.clone());
    let mut tick = tokio::time::interval(config.tick);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        // A free slot first, so that what is sent next is chosen as late as possible: the high queue wins.
        let Ok(permit) = slots.clone().acquire_owned().await else {
            break;
        };
        sender.release();
        let job = if let Some(job) = sender.ready.pop_front() {
            Some(job)
        } else {
            tokio::select! {
                biased;
                Some(device_id) = limited.recv() => {
                    sender.pause(&device_id);
                    None
                }
                job = high.recv() => match job {
                    Some(job) => sender.admit(job),
                    None => break,
                },
                job = low.recv() => match job {
                    Some(job) => sender.admit(job),
                    None => break,
                },
                _ = tick.tick() => None,
            }
        };
        let Some(job) = job else {
            continue;
        };
        let store = store.clone();
        let config = config.clone();
        let report = report.clone();
        tokio::spawn(async move {
            deliver(&store, &config, job, &report).await;
            drop(permit);
        });
    }
}

/// What the cloud's answer means for the sender.
#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    Sent,
    /// The handle is gone for good: forget the target.
    Gone,
    /// Try once more (a server error).
    Retry,
    /// Do not try again (rate limit, a bad request, the cloud without push, anything unexpected).
    Drop,
}

fn verdict(status: u16, body: &str) -> Verdict {
    match status {
        200..=299 => Verdict::Sent,
        410 => Verdict::Gone,
        // A 404 on a wrong address must not forget phones: only the cloud's own answer counts.
        404 if body.contains("unknown_handle") => Verdict::Gone,
        503 => Verdict::Drop,
        500..=599 => Verdict::Retry,
        _ => Verdict::Drop,
    }
}

fn still_registered(store: &Store, job: &Job) -> bool {
    matches!(store.push_get(&job.device_id), Ok(Some(t)) if t.handle == job.handle)
}

/// Sends one request; one more try after `retry_delay` on a network error or a 5xx (not 503).
async fn deliver(store: &Store, config: &Config, job: Job, report: &mpsc::UnboundedSender<String>) {
    let kind = job.kind.as_str();
    for attempt in 0..2 {
        // A device revoked or re-registered while the request waited gets nothing.
        if !still_registered(store, &job) {
            return;
        }
        let retry = match post(&config.base_url, &job.body).await {
            Ok((status, body)) => match verdict(status, &body) {
                Verdict::Sent => {
                    tracing::debug!(kind, status, "push sent");
                    return;
                }
                Verdict::Gone => {
                    tracing::info!(kind, status, "push target is gone: removed");
                    if let Err(e) = store.push_delete_handle(&job.device_id, &job.handle) {
                        tracing::warn!("push: remove the target: {e:#}");
                    }
                    return;
                }
                Verdict::Drop => {
                    tracing::warn!(kind, status, "push not sent");
                    if status == 429 {
                        // The sender pauses this phone for a minute.
                        let _ = report.send(job.device_id.clone());
                    }
                    return;
                }
                Verdict::Retry => {
                    tracing::warn!(kind, status, "push failed");
                    true
                }
            },
            Err(e) => {
                tracing::warn!(kind, "push failed: {e:#}");
                true
            }
        };
        if retry && attempt == 0 {
            tokio::time::sleep(config.retry_delay).await;
        }
    }
}

/// `POST {base}/push/send` with `curl`; the body goes in on stdin. Returns the status and the answer's text.
async fn post(base_url: &str, body: &str) -> Result<(u16, String)> {
    // Plain http only for an address that was asked for (tests, a local cloud); the default is https only.
    let proto = if base_url.starts_with("http://") {
        "=https,http"
    } else {
        "=https"
    };
    let user_agent = format!("user-agent: bandito-daemon/{}", env!("CARGO_PKG_VERSION"));
    let mut cmd = tokio::process::Command::new("curl");
    cmd.args(["-q", "-sS", "--proto", proto, "--max-time"])
        .arg(REQUEST_SECONDS.to_string())
        .args(["--connect-timeout", "5", "-X", "POST"])
        .args(["-H", "content-type: application/json", "-H", &user_agent])
        .args(["--data-binary", "@-", "-o", "-", "-w", "\n%{http_code}"])
        .arg(format!("{}/push/send", base_url.trim_end_matches('/')))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = cmd.spawn().map_err(|e| anyhow!("cannot run curl: {e}"))?;
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
    let mut stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
    let mut stderr = child.stderr.take().ok_or_else(|| anyhow!("no stderr"))?;
    let run = async {
        // A curl that stops reading early must not hang us: the write error is the answer's problem, not ours.
        let _ = stdin.write_all(body.as_bytes()).await;
        drop(stdin);
        let mut out = Vec::new();
        (&mut stdout).take(MAX_ANSWER).read_to_end(&mut out).await?;
        let mut err = Vec::new();
        (&mut stderr).take(2048).read_to_end(&mut err).await?;
        let status = child.wait().await?;
        anyhow::Ok((out, err, status))
    };
    let (out, err, status) = tokio::time::timeout(Duration::from_secs(REQUEST_SECONDS + 5), run)
        .await
        .map_err(|_| anyhow!("the cloud did not answer in time"))??;
    if !status.success() {
        // curl's own message names the host and the reason, nothing of the request.
        let line: String = String::from_utf8_lossy(&err)
            .lines()
            .next()
            .unwrap_or_default()
            .chars()
            .filter(|c| !c.is_control())
            .take(160)
            .collect();
        bail!("could not reach the cloud ({line})");
    }
    let text = String::from_utf8_lossy(&out);
    let (answer, code) = text
        .rsplit_once('\n')
        .ok_or_else(|| anyhow!("the cloud's answer has no status"))?;
    let code = code
        .trim()
        .parse::<u16>()
        .map_err(|_| anyhow!("the cloud's answer has no status"))?;
    Ok((code, answer.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{ConnectEnd, DecidedBy, Decision, Source};
    use crate::forms::{FieldType, FormField, FormKind};
    use crate::runtime::RuntimeKind;
    use crate::store::NewAgent;
    use std::sync::Mutex;
    use tokio::io::AsyncBufReadExt;
    use tokio::net::TcpListener;

    fn ev(body: EventBody) -> Event {
        Event {
            seq: 42,
            agent_id: "agent-1".into(),
            ts: 1_700_000_000_000,
            body,
        }
    }

    fn approval(command: Option<String>, diff: Option<String>, input: Option<Value>) -> EventBody {
        EventBody::ApprovalRequested {
            approval_id: "ap1".into(),
            call_id: "c1".into(),
            tool: "Bash".into(),
            title: "Run a command".into(),
            command,
            diff,
            reason: "risky".into(),
            input,
        }
    }

    fn form() -> EventBody {
        EventBody::FormRequested {
            form_id: "f1".into(),
            title: "Pick".into(),
            intro: None,
            kind: FormKind::Question,
            fields: vec![],
            submit_label: None,
            reject_label: None,
        }
    }

    fn completed(status: TurnStatus) -> EventBody {
        EventBody::TurnCompleted {
            turn_id: "t1".into(),
            status,
            usage: None,
            cost_usd: None,
        }
    }

    fn needs_you() -> EventBody {
        EventBody::AgentStatus {
            status: AgentStatus::NeedsYou,
            detail: None,
        }
    }

    // ---- push_kind ----

    #[test]
    fn an_approval_is_an_approval() {
        let c = Ctx::default();
        assert_eq!(push_kind(&ev(approval(None, None, None)), &c), Some(PushKind::Approval));
    }

    #[test]
    fn a_form_is_a_question_and_a_connect_request_makes_no_push() {
        let c = Ctx::default();
        assert_eq!(push_kind(&ev(form()), &c), Some(PushKind::Question));
        let connect = EventBody::IntegrationRequested {
            request_id: "r".into(),
            service: "github".into(),
            reason: None,
        };
        assert_eq!(
            push_kind(&ev(connect), &c),
            None,
            "the phone makes no local notification for it"
        );
    }

    #[test]
    fn needs_you_is_a_question_only_when_nothing_else_waits() {
        let alone = Ctx::default();
        let busy = Ctx {
            other_pending: true,
            ..Ctx::default()
        };
        assert_eq!(push_kind(&ev(needs_you()), &alone), Some(PushKind::Question));
        assert_eq!(push_kind(&ev(needs_you()), &busy), None);
        for status in [
            AgentStatus::Idle,
            AgentStatus::Working,
            AgentStatus::Error,
            AgentStatus::Offline,
        ] {
            let body = EventBody::AgentStatus { status, detail: None };
            assert_eq!(push_kind(&ev(body), &alone), None, "{status:?}");
        }
    }

    #[test]
    fn only_a_turn_that_ended_well_with_text_and_was_not_quiet_is_done() {
        let said = Ctx {
            answer: Some("Готово".into()),
            ..Ctx::default()
        };
        assert_eq!(push_kind(&ev(completed(TurnStatus::Ok)), &said), Some(PushKind::Done));
        assert_eq!(push_kind(&ev(completed(TurnStatus::Error)), &said), None);
        assert_eq!(push_kind(&ev(completed(TurnStatus::Interrupted)), &said), None);
        let quiet = Ctx {
            quiet_turn: true,
            answer: Some("Готово".into()),
            ..Ctx::default()
        };
        assert_eq!(push_kind(&ev(completed(TurnStatus::Ok)), &quiet), None);
    }

    #[test]
    fn a_turn_that_wrote_no_text_makes_no_done() {
        assert_eq!(push_kind(&ev(completed(TurnStatus::Ok)), &Ctx::default()), None);
        let blank = Ctx {
            answer: Some(String::new()),
            ..Ctx::default()
        };
        assert_eq!(push_kind(&ev(completed(TurnStatus::Ok)), &blank), None);
    }

    #[test]
    fn the_done_text_is_the_last_message_of_its_turn() {
        let mut t = Tracker::default();
        t.observe(&ev(turn_started()));
        t.observe(&ev(EventBody::MessageAssistant {
            text: "первое".into()
        }));
        t.observe(&ev(EventBody::MessageAssistant {
            text: "**второе**".into(),
        }));
        assert_eq!(
            t.observe(&ev(completed(TurnStatus::Ok))).answer.as_deref(),
            Some("второе")
        );
        // The next turn wrote nothing: it has no text, whatever the turn before wrote.
        t.observe(&ev(turn_started()));
        assert_eq!(t.observe(&ev(completed(TurnStatus::Ok))).answer, None);
    }

    #[test]
    fn the_markdown_comes_off_the_done_text() {
        let raw = "## Итог\n\n**Сделано:** `fmt` и [отчёт](https://e.x/r)\n```rust\nlet a = 1;\n```\nвсё_готово *ok*";
        assert_eq!(plain(raw), "Итог Сделано: fmt и отчёт let a = 1; всё_готово ok");
        assert_eq!(plain("```\n```\n** **"), "");
        assert_eq!(plain("[без ссылки"), "[без ссылки");
        assert_eq!(plain("2*3 = 6, my_var"), "2*3 = 6, my_var");
    }

    #[test]
    fn a_done_text_is_cut_to_400_characters_and_a_big_one_fits() {
        let long = "а".repeat(1000);
        let raw = build_payload("my-server", &ev(completed(TurnStatus::Ok)), "Forge", Some(&long));
        assert!(raw.len() <= MAX_PLAINTEXT);
        let v = parse(&raw);
        let text = v["text"].as_str().unwrap();
        assert_eq!(text.chars().count(), 400);
        assert!(text.ends_with('…'));
        let short = parse(&build_payload(
            "my-server",
            &ev(completed(TurnStatus::Ok)),
            "Forge",
            Some("Готово"),
        ));
        assert_eq!(short["text"], "Готово");
        // Only a done carries a text.
        let other = parse(&build_payload(
            "my-server",
            &ev(approval(None, None, None)),
            "Forge",
            None,
        ));
        assert!(other.get("text").is_none());
    }

    #[test]
    fn the_text_shrinks_before_anything_else_when_the_envelope_is_too_big() {
        let server = "s".repeat(2100);
        let long = "a".repeat(1000);
        let v = parse(&build_payload(
            &server,
            &ev(completed(TurnStatus::Ok)),
            "Forge",
            Some(&long),
        ));
        assert_eq!(v["srv"].as_str().unwrap().chars().count(), 2100);
        assert_eq!(v["text"].as_str().unwrap().chars().count(), 200);
    }

    fn turn_started() -> EventBody {
        EventBody::TurnStarted {
            turn_id: "t1".into(),
            source: Source::User,
            reactions_until: None,
            message_seq: None,
        }
    }

    #[test]
    fn an_error_is_an_error() {
        let body = EventBody::Error { message: "boom".into() };
        assert_eq!(push_kind(&ev(body), &Ctx::default()), Some(PushKind::Error));
    }

    #[test]
    fn everything_else_makes_no_push() {
        let c = Ctx::default();
        let others = [
            EventBody::MessageAssistant { text: "hi".into() },
            EventBody::MessageDelta { text: "h".into() },
            EventBody::ApprovalWithdrawn {
                approval_id: "a".into(),
            },
            EventBody::ApprovalResolved {
                approval_id: "a".into(),
                decision: Decision::Allow,
                by: DecidedBy::User,
                remember: false,
            },
            EventBody::TurnQuiet {
                turn_id: "t".into(),
                reason: None,
            },
            EventBody::IntegrationRequestEnded {
                request_id: "r".into(),
                status: ConnectEnd::Connected,
                integration: None,
            },
            EventBody::AgentChanged {
                action: AgentChange::Updated,
            },
            EventBody::RelayChanged,
        ];
        for body in others {
            assert_eq!(push_kind(&ev(body.clone()), &c), None, "{body:?}");
        }
    }

    #[test]
    fn connect_is_never_made_but_it_can_be_asked_for() {
        assert_eq!(PushKind::parse("connect"), Some(PushKind::Connect));
        assert_eq!(PushKind::parse("nonsense"), None);
        assert_eq!(
            PushKind::parse_csv("done, approval,bogus"),
            vec![PushKind::Done, PushKind::Approval]
        );
        assert_eq!(
            PushKind::to_csv(&[PushKind::Done, PushKind::Approval, PushKind::Done]),
            "approval,done"
        );
    }

    // ---- the tracker ----

    #[test]
    fn the_tracker_knows_what_waits_and_which_turns_were_quiet() {
        let mut t = Tracker::default();
        assert!(!t.observe(&ev(needs_you())).other_pending);
        assert!(t.observe(&ev(approval(None, None, None))).other_pending);
        assert!(t.observe(&ev(needs_you())).other_pending, "the approval is still open");
        let resolved = EventBody::ApprovalResolved {
            approval_id: "ap1".into(),
            decision: Decision::Deny,
            by: DecidedBy::User,
            remember: false,
        };
        assert!(!t.observe(&ev(resolved)).other_pending);
        assert!(t.observe(&ev(form())).other_pending);
        let answered = EventBody::FormAnswered {
            form_id: "f1".into(),
            action: crate::forms::FormAction::Submit,
            values: None,
            comment: None,
            message: None,
        };
        assert!(!t.observe(&ev(answered)).other_pending);
        // A quiet mark belongs to its turn only, and is used once.
        t.observe(&ev(EventBody::TurnQuiet {
            turn_id: "t1".into(),
            reason: None,
        }));
        assert!(t.observe(&ev(completed(TurnStatus::Ok))).quiet_turn);
        assert!(!t.observe(&ev(completed(TurnStatus::Ok))).quiet_turn);
    }

    // ---- the open text ----

    fn parse(text: &str) -> Value {
        serde_json::from_str(text).unwrap()
    }

    #[test]
    fn the_payload_has_the_agreed_shape() {
        let e = ev(approval(Some("ls".into()), None, Some(json!({ "path": "/tmp" }))));
        let v = parse(&build_payload("my-server", &e, "Forge", None));
        assert_eq!(v["v"], 1);
        assert_eq!(v["srv"], "my-server");
        assert_eq!(v["seq"], 42);
        assert_eq!(v["agent"], "agent-1");
        assert_eq!(v["name"], "Forge");
        assert_eq!(v["ts"], 1_700_000_000_000_i64);
        assert_eq!(v["event"]["kind"], "approval.requested");
        assert_eq!(v["event"]["payload"]["approval_id"], "ap1");
        assert_eq!(v["event"]["payload"]["command"], "ls");
        assert_eq!(v["event"]["payload"]["input"]["path"], "/tmp");
        // The same body `events.since` sends decodes from it.
        let body = EventBody::from_parts("approval.requested", v["event"]["payload"].clone()).unwrap();
        assert_eq!(body, e.body);
    }

    #[test]
    fn a_big_diff_and_command_are_cut_to_300_characters() {
        let big = "ж".repeat(5000);
        let e = ev(approval(
            Some(big.clone()),
            Some(big.clone()),
            Some(json!({ "text": big })),
        ));
        let text = build_payload("s", &e, "Forge", None);
        assert!(text.len() <= MAX_PLAINTEXT, "{}", text.len());
        let v = parse(&text);
        let p = &v["event"]["payload"];
        for s in [
            p["command"].as_str().unwrap(),
            p["diff"].as_str().unwrap(),
            p["input"]["text"].as_str().unwrap(),
        ] {
            assert_eq!(s.chars().count(), 300);
            assert!(s.ends_with('…'));
        }
        assert_eq!(p["approval_id"], "ap1");
        assert_eq!(p["title"], "Run a command");
    }

    #[test]
    fn a_long_error_message_is_cut() {
        let e = ev(EventBody::Error {
            message: "x".repeat(6000),
        });
        let text = build_payload("s", &e, "Forge", None);
        assert!(text.len() <= MAX_PLAINTEXT);
        let v = parse(&text);
        assert_eq!(v["event"]["kind"], "error");
        assert_eq!(v["event"]["payload"]["message"].as_str().unwrap().chars().count(), 300);
    }

    #[test]
    fn when_cutting_strings_is_not_enough_the_input_goes() {
        // Many medium strings: each is under 300 characters, together far over the limit.
        let fields: Vec<Value> = (0..60)
            .map(|i| json!({ "id": format!("f{i}"), "label": "y".repeat(250) }))
            .collect();
        let e = ev(approval(None, None, Some(json!({ "fields": fields }))));
        let text = build_payload("s", &e, "Forge", None);
        assert!(text.len() <= MAX_PLAINTEXT, "{}", text.len());
        let v = parse(&text);
        let p = &v["event"]["payload"];
        assert!(p.get("input").is_none());
        assert_eq!(
            (p["approval_id"].as_str(), p["tool"].as_str()),
            (Some("ap1"), Some("Bash"))
        );
    }

    #[test]
    fn when_even_that_is_not_enough_only_the_ids_stay() {
        let fields: Vec<FormField> = (0..40)
            .map(|i| FormField {
                id: format!("f{i}"),
                label: "y".repeat(250),
                field_type: FieldType::Text,
                options: None,
                required: false,
                default: None,
                placeholder: None,
                help: None,
            })
            .collect();
        let e = ev(EventBody::FormRequested {
            form_id: "f9".into(),
            title: "Pick".into(),
            intro: None,
            kind: FormKind::Question,
            fields,
            submit_label: None,
            reject_label: None,
        });
        let text = build_payload("s", &e, "n", None);
        assert!(text.len() <= MAX_PLAINTEXT, "{}", text.len());
        let v = parse(&text);
        assert_eq!(v["event"]["kind"], "form_requested");
        assert_eq!(v["event"]["payload"], json!({ "form_id": "f9" }));
        assert_eq!(v["seq"], 42);
        assert_eq!(v["agent"], "agent-1");
    }

    #[test]
    fn a_long_title_is_cut_but_the_form_stays_whole() {
        let e = ev(EventBody::FormRequested {
            form_id: "f9".into(),
            title: "t".repeat(2000),
            intro: Some("i".repeat(2000)),
            kind: FormKind::Question,
            fields: vec![],
            submit_label: None,
            reject_label: None,
        });
        let v = parse(&build_payload("s", &e, "n", None));
        assert_eq!(v["event"]["payload"]["form_id"], "f9");
        assert_eq!(v["event"]["payload"]["title"].as_str().unwrap().chars().count(), 300);
    }

    #[test]
    fn a_long_name_is_cut() {
        let v = parse(&build_payload("s", &ev(form()), &"n".repeat(500), None));
        assert_eq!(v["name"].as_str().unwrap().chars().count(), 100);
    }

    // ---- encryption ----

    fn unhex(s: &str) -> Vec<u8> {
        hex::decode(s.split_whitespace().collect::<String>()).unwrap()
    }

    /// RFC 8439 section 2.8.2: the AEAD test vector (our `seal` takes its AAD from the handle, so this one goes
    /// through the cipher directly).
    #[test]
    fn the_cipher_matches_rfc_8439() {
        let key: Vec<u8> = (0x80..=0x9f).collect();
        let nonce = unhex("07 00 00 00 40 41 42 43 44 45 46 47");
        let aad = unhex("50 51 52 53 c0 c1 c2 c3 c4 c5 c6 c7");
        let plain = b"Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
        let expected = unhex(
            "d3 1a 8d 34 64 8e 60 db 7b 86 af bc 53 ef 7e c2
             a4 ad ed 51 29 6e 08 fe a9 e2 b5 a7 36 ee 62 d6
             3d be a4 5e 8c a9 67 12 82 fa fb 69 da 92 72 8b
             1a 71 de 0a 9e 06 0b 29 05 d6 a5 b6 7e cd 3b 36
             92 dd bd 7f 2d 77 8b 8c 98 03 ae e3 28 09 1b 58
             fa b3 24 e4 fa d6 75 94 55 85 80 8b 48 31 d7 bc
             3f f4 de f0 8e 4b 7a 9d e5 76 d2 65 86 ce c6 4b
             61 16
             1a e1 0b 59 4f 09 e2 6a 7e 90 2e cb d0 60 06 91",
        );
        let cipher = ChaCha20Poly1305::new_from_slice(&key).unwrap();
        let sealed = cipher
            .encrypt(Nonce::from_slice(&nonce), Payload { msg: plain, aad: &aad })
            .unwrap();
        assert_eq!(sealed, expected);
    }

    fn open(key: &[u8], handle: &str, nonce: &[u8], ct: &[u8]) -> Option<Vec<u8>> {
        let cipher = ChaCha20Poly1305::new_from_slice(key).unwrap();
        let aad = format!("{AAD_PREFIX}{handle}");
        cipher
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: ct,
                    aad: aad.as_bytes(),
                },
            )
            .ok()
    }

    #[test]
    fn a_known_key_nonce_and_aad_decrypt_back() {
        let key = [9u8; 32];
        let nonce = [3u8; 12];
        let ct = seal(&key, "h-1", &nonce, b"hello phone").unwrap();
        assert_eq!(ct.len(), "hello phone".len() + 16, "ciphertext, then the 16-byte tag");
        assert_eq!(open(&key, "h-1", &nonce, &ct).unwrap(), b"hello phone");
        // The handle is bound in: another handle, key or nonce opens nothing.
        assert!(open(&key, "h-2", &nonce, &ct).is_none());
        assert!(open(&[8u8; 32], "h-1", &nonce, &ct).is_none());
        assert!(open(&key, "h-1", &[4u8; 12], &ct).is_none());
        // A flipped bit fails the tag.
        let mut bad = ct.clone();
        bad[0] ^= 1;
        assert!(open(&key, "h-1", &nonce, &bad).is_none());
        assert!(seal(&[1; 31], "h", &nonce, b"x").is_err());
    }

    #[test]
    fn each_message_gets_its_own_nonce() {
        let a = seal_b64(&[1; 32], "h", b"same").unwrap();
        let b = seal_b64(&[1; 32], "h", b"same").unwrap();
        assert_ne!(a.1, b.1);
        assert_ne!(a.0, b.0);
        assert_eq!(STANDARD.decode(&a.1).unwrap().len(), 12);
    }

    #[test]
    fn the_biggest_payload_fits_the_cloud_limit_after_encrypting() {
        let key = [5u8; 32];
        let ct = seal(&key, "h", &[0; 12], &vec![b'a'; MAX_PLAINTEXT]).unwrap();
        assert!(ct.len() <= 2700);
    }

    // ---- verdicts ----

    #[test]
    fn the_cloud_answers_are_read_as_agreed() {
        assert_eq!(verdict(200, "{\"ok\":true}"), Verdict::Sent);
        assert_eq!(verdict(410, "{\"error\":\"gone\"}"), Verdict::Gone);
        assert_eq!(verdict(404, "{\"error\":\"unknown_handle\"}"), Verdict::Gone);
        assert_eq!(verdict(404, "<html>Not found</html>"), Verdict::Drop);
        assert_eq!(verdict(429, "rate_limited"), Verdict::Drop);
        assert_eq!(verdict(400, ""), Verdict::Drop);
        assert_eq!(verdict(503, "push_not_configured"), Verdict::Drop);
        assert_eq!(verdict(502, "apns"), Verdict::Retry);
        assert_eq!(verdict(500, ""), Verdict::Retry);
        assert_eq!(verdict(302, ""), Verdict::Drop);
    }

    // ---- the whole way, against a local server ----

    struct Cloud {
        base_url: String,
        seen: Arc<Mutex<Vec<Value>>>,
    }

    /// A minimal HTTP/1.1 server. `answer` gets each request's JSON body and returns the status and text to reply.
    async fn cloud(answer: impl Fn(&Value) -> (u16, String) + Send + Sync + 'static) -> Cloud {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base_url = format!("http://{}/api/v1", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        let answer = Arc::new(answer);
        tokio::spawn(async move {
            loop {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let log = log.clone();
                let answer = answer.clone();
                tokio::spawn(async move {
                    let (read, mut write) = sock.split();
                    let mut reader = tokio::io::BufReader::new(read);
                    let mut request_line = String::new();
                    reader.read_line(&mut request_line).await.unwrap();
                    let mut length = 0usize;
                    loop {
                        let mut line = String::new();
                        reader.read_line(&mut line).await.unwrap();
                        if line.trim().is_empty() {
                            break;
                        }
                        if let Some((name, value)) = line.split_once(':')
                            && name.eq_ignore_ascii_case("content-length")
                        {
                            length = value.trim().parse().unwrap();
                        }
                    }
                    let mut body = vec![0u8; length];
                    reader.read_exact(&mut body).await.unwrap();
                    assert!(request_line.starts_with("POST /api/v1/push/send "), "{request_line}");
                    let json: Value = serde_json::from_slice(&body).unwrap();
                    let (status, text) = answer(&json);
                    log.lock().unwrap().push(json);
                    let reply = format!(
                        "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
                        text.len()
                    );
                    write.write_all(reply.as_bytes()).await.unwrap();
                });
            }
        });
        Cloud { base_url, seen }
    }

    impl Cloud {
        fn count(&self) -> usize {
            self.seen.lock().unwrap().len()
        }

        async fn wait_for(&self, n: usize) {
            for _ in 0..200 {
                if self.count() >= n {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
            panic!("waited for {n} requests, got {}", self.count());
        }

        /// The requests for `handle`, opened with `key`: `(kind, collapseId, threadId, plaintext JSON)`.
        fn for_handle(&self, handle: &str, key: &[u8]) -> Vec<(String, Value, Value, Value)> {
            self.seen
                .lock()
                .unwrap()
                .iter()
                .filter(|r| r["handle"] == handle)
                .map(|r| {
                    let ct = STANDARD.decode(r["ct"].as_str().unwrap()).unwrap();
                    let nonce = STANDARD.decode(r["nonce"].as_str().unwrap()).unwrap();
                    assert_eq!(nonce.len(), 12);
                    assert!(ct.len() <= 2700);
                    let plain = open(key, handle, &nonce, &ct).expect("the phone's key opens it");
                    (
                        r["kind"].as_str().unwrap().to_string(),
                        r["collapseId"].clone(),
                        r["threadId"].clone(),
                        serde_json::from_slice(&plain).unwrap(),
                    )
                })
                .collect()
        }
    }

    fn config(base_url: &str, clock: &Clock) -> Config {
        Config {
            base_url: base_url.to_string(),
            retry_delay: Duration::from_millis(50),
            clock: clock.clone(),
            tick: Duration::from_millis(20),
        }
    }

    fn setup(cloud: &Cloud) -> (Hub, String) {
        let (hub, agent, _) = setup_clock(cloud);
        (hub, agent)
    }

    /// Like `setup`, with the clock of the sender (moved by hand to pass the gaps and the pauses).
    fn setup_clock(cloud: &Cloud) -> (Hub, String, Clock) {
        let clock = Clock::default();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let hub = Hub::new(store.clone());
        let new_agent: NewAgent =
            serde_json::from_value(json!({ "name": "Forge", "runtime": RuntimeKind::Claude })).unwrap();
        let agent = store.agent_create(new_agent).unwrap().id;
        spawn_with(&hub, config(&cloud.base_url, &clock));
        (hub, agent, clock)
    }

    fn ok_reply(_: &Value) -> (u16, String) {
        (200, "{\"ok\":true}".into())
    }

    fn assistant() -> EventBody {
        EventBody::MessageAssistant { text: "hello".into() }
    }

    async fn settle() {
        tokio::time::sleep(Duration::from_millis(300)).await;
    }

    #[tokio::test]
    async fn an_approval_reaches_the_phone_encrypted() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("iPhone", "tok").unwrap();
        hub.store
            .push_upsert(&d.id, "handle-1", &[7; 32], "my-server", "approval,done", None)
            .unwrap();
        let sent = hub.emit(&agent, approval(Some("rm -rf build".into()), None, None));
        cloud.wait_for(1).await;
        let got = cloud.for_handle("handle-1", &[7; 32]);
        assert_eq!(got.len(), 1);
        let (kind, collapse, thread, plain) = &got[0];
        assert_eq!(kind, "approval");
        assert_eq!(collapse, &json!(format!("b{}", sent.seq)));
        assert_eq!(thread, &json!(agent));
        assert_eq!(plain["v"], 1);
        assert_eq!(plain["srv"], "my-server");
        assert_eq!(plain["seq"], sent.seq);
        assert_eq!(plain["agent"], json!(agent));
        assert_eq!(plain["name"], "Forge");
        assert_eq!(plain["ts"], sent.ts);
        assert_eq!(plain["event"]["kind"], "approval.requested");
        assert_eq!(plain["event"]["payload"]["command"], "rm -rf build");
    }

    #[tokio::test]
    async fn kinds_filter_and_events_without_a_push_send_nothing() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("iPhone", "tok").unwrap();
        hub.store.push_upsert(&d.id, "h", &[1; 32], "s", "done", None).unwrap();
        // Not wanted by this phone, or not a push at all.
        hub.emit(&agent, approval(None, None, None));
        hub.emit(&agent, form());
        hub.emit(&agent, EventBody::Error { message: "x".into() });
        hub.emit(&agent, assistant());
        hub.emit(&agent, EventBody::MessageDelta { text: "d".into() });
        hub.emit(
            &agent,
            EventBody::AgentStatus {
                status: AgentStatus::Working,
                detail: None,
            },
        );
        settle().await;
        assert_eq!(cloud.count(), 0);
        // The one it wants.
        hub.emit(&agent, completed(TurnStatus::Ok));
        cloud.wait_for(1).await;
        settle().await;
        let got = cloud.for_handle("h", &[1; 32]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, "done");
    }

    #[tokio::test]
    async fn a_done_push_carries_the_text_of_its_turn() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("iPhone", "tok").unwrap();
        hub.store
            .push_upsert(&d.id, "handle-1", &[9; 32], "my-server", "done", None)
            .unwrap();
        hub.emit(
            &agent,
            EventBody::MessageAssistant {
                text: "**Готово**: см. [отчёт](https://e.x)".into(),
            },
        );
        hub.emit(&agent, completed(TurnStatus::Ok));
        cloud.wait_for(1).await;
        let got = cloud.for_handle("handle-1", &[9; 32]);
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, "done");
        assert_eq!(got[0].3["text"], "Готово: см. отчёт");
    }

    #[tokio::test]
    async fn a_quiet_turn_and_a_failed_turn_are_not_done() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("iPhone", "tok").unwrap();
        hub.store.push_upsert(&d.id, "h", &[1; 32], "s", "done", None).unwrap();
        hub.emit(
            &agent,
            EventBody::TurnQuiet {
                turn_id: "t1".into(),
                reason: None,
            },
        );
        hub.emit(&agent, completed(TurnStatus::Ok));
        hub.emit(&agent, completed(TurnStatus::Error));
        settle().await;
        assert_eq!(cloud.count(), 0);
        // The next turn is not quiet.
        let next = EventBody::TurnCompleted {
            turn_id: "t2".into(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: None,
        };
        hub.emit(&agent, EventBody::MessageAssistant { text: "ok".into() });
        hub.emit(&agent, next);
        cloud.wait_for(1).await;
    }

    #[tokio::test]
    async fn an_agents_own_question_pushes_once_and_a_form_does_not_push_twice() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("iPhone", "tok").unwrap();
        hub.store
            .push_upsert(&d.id, "h", &[1; 32], "s", "question", None)
            .unwrap();
        // A form, then the status the supervisor sets with it: one push.
        hub.emit(&agent, form());
        hub.emit(&agent, needs_you());
        cloud.wait_for(1).await;
        settle().await;
        assert_eq!(cloud.count(), 1);
        // The agent's own question: a needs_you with nothing waiting.
        hub.emit(
            &agent,
            EventBody::FormAnswered {
                form_id: "f1".into(),
                action: crate::forms::FormAction::Submit,
                values: None,
                comment: None,
                message: None,
            },
        );
        hub.emit(&agent, needs_you());
        cloud.wait_for(2).await;
    }

    #[tokio::test]
    async fn two_phones_get_two_pushes_with_their_own_keys() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let a = hub.store.device_add("A", "ta").unwrap();
        let b = hub.store.device_add("B", "tb").unwrap();
        hub.store
            .push_upsert(&a.id, "ha", &[1; 32], "sa", "error", None)
            .unwrap();
        hub.store
            .push_upsert(&b.id, "hb", &[2; 32], "sb", "error", None)
            .unwrap();
        hub.emit(&agent, EventBody::Error { message: "boom".into() });
        cloud.wait_for(2).await;
        let for_a = cloud.for_handle("ha", &[1; 32]);
        let for_b = cloud.for_handle("hb", &[2; 32]);
        assert_eq!((for_a.len(), for_b.len()), (1, 1));
        assert_eq!(for_a[0].3["srv"], "sa");
        assert_eq!(for_b[0].3["srv"], "sb");
    }

    #[tokio::test]
    async fn a_phone_registered_twice_gets_one_push_to_the_latest_handle() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("A", "ta").unwrap();
        hub.store
            .push_upsert(&d.id, "old", &[1; 32], "s", "error", None)
            .unwrap();
        hub.store
            .push_upsert(&d.id, "new", &[2; 32], "s", "error", None)
            .unwrap();
        hub.emit(&agent, EventBody::Error { message: "boom".into() });
        cloud.wait_for(1).await;
        settle().await;
        assert_eq!(cloud.count(), 1);
        assert_eq!(cloud.for_handle("new", &[2; 32]).len(), 1);
    }

    #[tokio::test]
    async fn an_event_from_before_the_registration_is_not_sent_later() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        hub.emit(
            &agent,
            EventBody::Error {
                message: "early".into(),
            },
        );
        settle().await;
        let d = hub.store.device_add("A", "ta").unwrap();
        hub.store.push_upsert(&d.id, "h", &[1; 32], "s", "error", None).unwrap();
        settle().await;
        assert_eq!(cloud.count(), 0);
    }

    #[tokio::test]
    async fn a_revoked_device_gets_nothing() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent) = setup(&cloud);
        let d = hub.store.device_add("A", "ta").unwrap();
        hub.store.push_upsert(&d.id, "h", &[1; 32], "s", "error", None).unwrap();
        hub.store.device_revoke(&d.id).unwrap();
        hub.emit(&agent, EventBody::Error { message: "boom".into() });
        settle().await;
        assert_eq!(cloud.count(), 0);
    }

    #[tokio::test]
    async fn a_410_removes_only_that_target() {
        let cloud = cloud(|req| {
            if req["handle"] == "gone" {
                (410, "{\"ok\":false,\"error\":\"gone\"}".into())
            } else {
                (200, "{\"ok\":true}".into())
            }
        })
        .await;
        let (hub, agent, clock) = setup_clock(&cloud);
        let a = hub.store.device_add("A", "ta").unwrap();
        let b = hub.store.device_add("B", "tb").unwrap();
        hub.store
            .push_upsert(&a.id, "gone", &[1; 32], "s", "error", None)
            .unwrap();
        hub.store
            .push_upsert(&b.id, "fine", &[2; 32], "s", "error", None)
            .unwrap();
        hub.emit(&agent, EventBody::Error { message: "boom".into() });
        cloud.wait_for(2).await;
        settle().await;
        assert!(
            hub.store.push_get(&a.id).unwrap().is_none(),
            "the gone handle was forgotten"
        );
        assert!(hub.store.push_get(&b.id).unwrap().is_some());
        // Nothing more goes to the forgotten one.
        clock.advance(ERROR_EVERY + Duration::from_secs(1));
        hub.emit(
            &agent,
            EventBody::Error {
                message: "again".into(),
            },
        );
        settle().await;
        assert_eq!(cloud.for_handle("gone", &[1; 32]).len(), 1);
        assert_eq!(cloud.for_handle("fine", &[2; 32]).len(), 2);
    }

    #[tokio::test]
    async fn a_404_unknown_handle_removes_the_target_but_a_bare_404_does_not() {
        let cloud = cloud(|req| {
            if req["handle"] == "unknown" {
                (404, "{\"ok\":false,\"error\":\"unknown_handle\"}".into())
            } else {
                (404, "Not found".into())
            }
        })
        .await;
        let (hub, agent) = setup(&cloud);
        let a = hub.store.device_add("A", "ta").unwrap();
        let b = hub.store.device_add("B", "tb").unwrap();
        hub.store
            .push_upsert(&a.id, "unknown", &[1; 32], "s", "error", None)
            .unwrap();
        hub.store
            .push_upsert(&b.id, "other", &[2; 32], "s", "error", None)
            .unwrap();
        hub.emit(&agent, EventBody::Error { message: "boom".into() });
        cloud.wait_for(2).await;
        settle().await;
        assert!(hub.store.push_get(&a.id).unwrap().is_none());
        assert!(hub.store.push_get(&b.id).unwrap().is_some());
    }

    #[tokio::test]
    async fn a_server_error_is_tried_once_more_and_a_rate_limit_is_not() {
        let tries = Arc::new(Mutex::new(0u32));
        let counter = tries.clone();
        let cloud = cloud(move |req| {
            if req["handle"] == "limited" {
                return (429, "{\"error\":\"rate_limited\"}".into());
            }
            let mut n = counter.lock().unwrap();
            *n += 1;
            if *n == 1 {
                (502, "{\"error\":\"apns\"}".into())
            } else {
                (200, "{\"ok\":true}".into())
            }
        })
        .await;
        let (hub, agent) = setup(&cloud);
        let a = hub.store.device_add("A", "ta").unwrap();
        let b = hub.store.device_add("B", "tb").unwrap();
        hub.store
            .push_upsert(&a.id, "flaky", &[1; 32], "s", "error", None)
            .unwrap();
        hub.store
            .push_upsert(&b.id, "limited", &[2; 32], "s", "error", None)
            .unwrap();
        hub.emit(&agent, EventBody::Error { message: "boom".into() });
        cloud.wait_for(3).await;
        settle().await;
        assert_eq!(cloud.for_handle("flaky", &[1; 32]).len(), 2, "one retry");
        assert_eq!(cloud.for_handle("limited", &[2; 32]).len(), 1, "no retry on 429");
        assert!(hub.store.push_get(&a.id).unwrap().is_some());
        assert!(hub.store.push_get(&b.id).unwrap().is_some());
    }

    #[tokio::test]
    async fn an_unreachable_cloud_changes_nothing() {
        // Nothing listens here: curl fails, the task goes on, and the target stays.
        let dead = {
            let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
            format!("http://{}/api/v1", l.local_addr().unwrap())
        };
        let store = Arc::new(Store::open_in_memory().unwrap());
        let hub = Hub::new(store.clone());
        spawn_with(&hub, config(&dead, &Clock::default()));
        let d = store.device_add("A", "ta").unwrap();
        store.push_upsert(&d.id, "h", &[1; 32], "s", "error", None).unwrap();
        hub.emit("a", EventBody::Error { message: "boom".into() });
        hub.emit("a", EventBody::Error { message: "boom".into() });
        settle().await;
        assert!(store.push_get(&d.id).unwrap().is_some());
    }

    // ---- after a lag, the gaps, the pause, the queues ----

    #[test]
    fn after_a_lag_what_was_answered_meanwhile_is_forgotten() {
        let store = Store::open_in_memory().unwrap();
        let new_agent: NewAgent =
            serde_json::from_value(json!({ "name": "Forge", "runtime": RuntimeKind::Claude })).unwrap();
        let agent = store.agent_create(new_agent).unwrap().id;
        let waiting = store.approval_create(&agent, "c1", "Bash", "Run", json!({})).unwrap();
        let mut t = Tracker::default();
        t.reseed(&store);
        let status = Event {
            seq: 5,
            agent_id: agent.clone(),
            ts: 1,
            body: needs_you(),
        };
        assert!(t.observe(&status).other_pending, "the approval waits");
        // The answer comes in the events the task missed: the store has it, the task does not.
        store
            .approval_resolve(&waiting.id, crate::event::Decision::Allow)
            .unwrap();
        assert!(t.observe(&status).other_pending, "still believed to wait");
        t.reseed(&store);
        let ctx = t.observe(&status);
        assert!(!ctx.other_pending);
        assert_eq!(push_kind(&status, &ctx), Some(PushKind::Question));
    }

    #[test]
    fn a_waiting_connect_request_keeps_needs_you_from_being_a_question() {
        let mut t = Tracker::default();
        let connect = EventBody::IntegrationRequested {
            request_id: "r".into(),
            service: "github".into(),
            reason: None,
        };
        t.observe(&ev(connect));
        let ctx = t.observe(&ev(needs_you()));
        assert_eq!(push_kind(&ev(needs_you()), &ctx), None);
    }

    #[test]
    fn plain_http_is_for_this_machine_only() {
        for ok in [
            "http://127.0.0.1:8080/api/v1",
            "http://localhost/api/v1",
            "http://localhost:9",
            "http://[::1]:8080/x",
        ] {
            assert!(is_loopback_http(ok), "{ok}");
        }
        for bad in [
            "http://example.com/api",
            "http://127.0.0.1.example.com/api",
            "http://127.0.0.1@evil.example/api",
            "http://localhost.evil.example",
            "https://localhost/api",
            "ftp://127.0.0.1",
            "",
        ] {
            assert!(!is_loopback_http(bad), "{bad}");
        }
    }

    fn job(device: &str, agent: &str, kind: PushKind, body: &str) -> Job {
        Job {
            device_id: device.into(),
            handle: "h".into(),
            agent_id: agent.into(),
            kind,
            body: body.into(),
        }
    }

    fn sender(clock: &Clock) -> Sender {
        Sender::new(Arc::new(config("http://127.0.0.1:1", clock)))
    }

    #[test]
    fn gaps_between_pushes_are_kept_per_phone_agent_and_kind() {
        let clock = Clock::default();
        let mut s = sender(&clock);
        let go = |s: &mut Sender, d: &str, a: &str, k: PushKind| s.admit(job(d, a, k, "")).is_some();
        assert!(go(&mut s, "d1", "a1", PushKind::Error));
        for _ in 0..4 {
            assert!(!go(&mut s, "d1", "a1", PushKind::Error), "too soon");
        }
        // Another agent, another phone, another kind: each has its own gap.
        assert!(go(&mut s, "d1", "a2", PushKind::Error));
        assert!(go(&mut s, "d2", "a1", PushKind::Error));
        assert!(go(&mut s, "d1", "a1", PushKind::Done));
        assert!(!go(&mut s, "d1", "a1", PushKind::Done));
        // Approvals and questions have no gap.
        assert!(go(&mut s, "d1", "a1", PushKind::Approval));
        assert!(go(&mut s, "d1", "a1", PushKind::Approval));
        // `done` is free again after 10 s, `error` only after 30 s.
        clock.advance(Duration::from_secs(11));
        assert!(go(&mut s, "d1", "a1", PushKind::Done));
        assert!(!go(&mut s, "d1", "a1", PushKind::Error));
        clock.advance(Duration::from_secs(20));
        assert!(go(&mut s, "d1", "a1", PushKind::Error));
    }

    #[test]
    fn a_pause_keeps_the_last_twenty_urgent_pushes_and_drops_the_rest() {
        let clock = Clock::default();
        let mut s = sender(&clock);
        s.pause("d1");
        for i in 0..25 {
            assert!(s.admit(job("d1", "a", PushKind::Approval, &format!("m{i}"))).is_none());
        }
        assert!(s.admit(job("d1", "a", PushKind::Question, "q")).is_none());
        assert!(s.admit(job("d1", "a", PushKind::Done, "done")).is_none());
        assert!(s.admit(job("d1", "a", PushKind::Error, "error")).is_none());
        // Another phone is not paused.
        assert!(s.admit(job("d2", "a", PushKind::Approval, "other")).is_some());
        clock.advance(Duration::from_secs(59));
        s.release();
        assert!(s.ready.is_empty(), "the pause is a minute");
        clock.advance(Duration::from_secs(2));
        s.release();
        let bodies: Vec<&str> = s.ready.iter().map(|j| j.body.as_str()).collect();
        assert_eq!(bodies.len(), DEFERRED_MAX);
        assert_eq!(bodies[0], "m6", "the oldest were pushed out");
        assert_eq!(bodies[DEFERRED_MAX - 2], "m24");
        assert_eq!(bodies[DEFERRED_MAX - 1], "q");
        // After the pause new pushes go straight out again.
        assert!(s.admit(job("d1", "a", PushKind::Done, "done")).is_some());
    }

    #[tokio::test]
    async fn five_errors_in_a_row_make_one_push() {
        let cloud = cloud(ok_reply).await;
        let (hub, agent, _clock) = setup_clock(&cloud);
        let d = hub.store.device_add("A", "ta").unwrap();
        hub.store.push_upsert(&d.id, "h", &[1; 32], "s", "error", None).unwrap();
        for i in 0..5 {
            hub.emit(
                &agent,
                EventBody::Error {
                    message: format!("boom {i}"),
                },
            );
        }
        cloud.wait_for(1).await;
        settle().await;
        assert_eq!(cloud.count(), 1);
    }

    #[tokio::test]
    async fn after_a_429_approvals_wait_for_the_pause_and_done_is_dropped() {
        let calls = Arc::new(Mutex::new(0u32));
        let counter = calls.clone();
        let cloud = cloud(move |_| {
            let mut n = counter.lock().unwrap();
            *n += 1;
            if *n == 1 {
                (429, "{\"error\":\"rate_limited\"}".into())
            } else {
                (200, "{\"ok\":true}".into())
            }
        })
        .await;
        let (hub, agent, clock) = setup_clock(&cloud);
        let d = hub.store.device_add("A", "ta").unwrap();
        hub.store
            .push_upsert(&d.id, "h", &[1; 32], "s", "approval,done", None)
            .unwrap();
        hub.emit(&agent, approval(Some("first".into()), None, None));
        cloud.wait_for(1).await;
        settle().await;
        // The pause has begun: an approval is kept, a done is dropped.
        hub.emit(&agent, approval(Some("second".into()), None, None));
        hub.emit(&agent, completed(TurnStatus::Ok));
        settle().await;
        assert_eq!(cloud.count(), 1, "nothing goes during the pause");
        clock.advance(RATE_PAUSE + Duration::from_secs(1));
        cloud.wait_for(2).await;
        settle().await;
        let got = cloud.for_handle("h", &[1; 32]);
        assert_eq!(got.len(), 2, "the done was not kept");
        assert_eq!(got[1].0, "approval");
        assert_eq!(got[1].3["event"]["payload"]["command"], "second");
        // And the phone is not paused any more.
        hub.emit(&agent, EventBody::MessageAssistant { text: "ok".into() });
        hub.emit(&agent, completed(TurnStatus::Ok));
        cloud.wait_for(3).await;
    }

    fn queues(cap: usize, wait: Duration) -> (Queues, mpsc::Receiver<Job>, mpsc::Receiver<Job>) {
        let (high, high_rx) = mpsc::channel(cap);
        let (low, low_rx) = mpsc::channel(cap);
        (
            Queues {
                high,
                low,
                high_wait: wait,
            },
            high_rx,
            low_rx,
        )
    }

    #[tokio::test]
    async fn a_full_low_queue_does_not_touch_the_high_one() {
        let store = Store::open_in_memory().unwrap();
        let d = store.device_add("A", "ta").unwrap();
        store
            .push_upsert(&d.id, "h", &[1; 32], "s", "approval,done,error", None)
            .unwrap();
        let (q, mut high_rx, mut low_rx) = queues(3, Duration::from_millis(20));
        for i in 0..10 {
            let e = Event {
                seq: i,
                agent_id: "a".into(),
                ts: 1,
                body: EventBody::Error { message: "x".into() },
            };
            enqueue(&store, &q, &e, PushKind::Error, None).await;
        }
        let ap = Event {
            seq: 100,
            agent_id: "a".into(),
            ts: 1,
            body: approval(None, None, None),
        };
        let started = Instant::now();
        enqueue(&store, &q, &ap, PushKind::Approval, None).await;
        assert!(
            started.elapsed() < Duration::from_millis(15),
            "the high queue did not wait"
        );
        assert_eq!(high_rx.try_recv().unwrap().kind, PushKind::Approval);
        let mut low = 0;
        while low_rx.try_recv().is_ok() {
            low += 1;
        }
        assert_eq!(low, 3, "the rest of the low ones were dropped");
    }

    #[tokio::test]
    async fn a_full_high_queue_waits_a_little_and_then_drops() {
        let store = Store::open_in_memory().unwrap();
        let d = store.device_add("A", "ta").unwrap();
        store.push_upsert(&d.id, "h", &[1; 32], "s", "approval", None).unwrap();
        let (q, mut high_rx, _low_rx) = queues(1, Duration::from_millis(60));
        let ap = |seq| Event {
            seq,
            agent_id: "a".into(),
            ts: 1,
            body: approval(None, None, None),
        };
        enqueue(&store, &q, &ap(1), PushKind::Approval, None).await;
        let started = Instant::now();
        enqueue(&store, &q, &ap(2), PushKind::Approval, None).await;
        assert!(started.elapsed() >= Duration::from_millis(50), "it waited");
        assert_eq!(high_rx.try_recv().unwrap().kind, PushKind::Approval);
        assert!(high_rx.try_recv().is_err(), "the second was dropped");
        // A slot that frees while it waits is used.
        enqueue(&store, &q, &ap(3), PushKind::Approval, None).await;
        let waiting = tokio::spawn({
            let (store, q) = (Arc::new(store), q);
            async move {
                let e = Event {
                    seq: 4,
                    agent_id: "a".into(),
                    ts: 1,
                    body: approval(None, None, None),
                };
                enqueue(&store, &q, &e, PushKind::Approval, None).await;
            }
        });
        tokio::time::sleep(Duration::from_millis(10)).await;
        assert!(high_rx.try_recv().is_ok());
        waiting.await.unwrap();
        assert!(high_rx.try_recv().is_ok(), "the waiting one got in");
    }

    // ---- the worst payload ----

    #[test]
    fn the_worst_input_still_fits_the_cloud_after_encrypting() {
        let name = "😀\"".repeat(50);
        assert_eq!(name.chars().count(), 100);
        let server_ref = "🛰\"".repeat(32);
        let fields: Vec<FormField> = (0..50)
            .map(|i| FormField {
                id: format!("поле-{i}"),
                label: "ключ\"значение\\ ".repeat(70),
                field_type: FieldType::Text,
                options: Some(vec!["日本語".repeat(300)]),
                required: true,
                default: Some(json!("😀".repeat(1000))),
                placeholder: Some("é".repeat(1000)),
                help: Some("\"".repeat(1000)),
            })
            .collect();
        let form = EventBody::FormRequested {
            form_id: "f".repeat(300),
            title: "Заголовок \"формы\"".repeat(100),
            intro: Some("😀".repeat(1000)),
            kind: FormKind::Question,
            fields,
            submit_label: Some("ok".repeat(500)),
            reject_label: None,
        };
        let diff = "строка 日本語 \"quote\" 😀\n".repeat(400);
        let approval = approval(
            Some(diff.clone()),
            Some(diff.clone()),
            Some(json!({ "a": diff, "b": [diff.clone(), diff] })),
        );
        let error = EventBody::Error {
            message: "😀\"\\".repeat(2000),
        };
        for body in [form, approval, error] {
            let e = ev(body);
            let text = build_payload(&server_ref, &e, &name, None);
            assert!(text.len() <= MAX_PLAINTEXT, "{} bytes", text.len());
            let v = parse(&text);
            assert_eq!(v["seq"], 42);
            assert!(v["event"]["kind"].is_string());
            let ct = seal(&[3; 32], "handle", &[0; 12], text.as_bytes()).unwrap();
            assert!(ct.len() <= 2700, "{} bytes", ct.len());
        }
    }

    #[test]
    fn the_last_word_is_the_kind_alone() {
        // An absurd agent id and server name that no step before can shorten enough.
        let e = Event {
            seq: 7,
            agent_id: "a".repeat(2000),
            ts: 1,
            body: approval(None, None, None),
        };
        let text = build_payload(&"s".repeat(64), &e, &"n".repeat(100), None);
        assert!(text.len() <= MAX_PLAINTEXT);
        let v = parse(&text);
        assert_eq!(v["event"]["kind"], "approval.requested");
        let e = Event {
            seq: 7,
            agent_id: "a".repeat(3000),
            ts: 1,
            body: approval(None, None, None),
        };
        let text = build_payload("s", &e, "n", None);
        assert!(text.len() <= MAX_PLAINTEXT);
        assert_eq!(parse(&text)["event"]["kind"], "approval.requested");
    }
}
