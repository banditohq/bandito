//! Push notifications for phones whose app is closed (docs/ARCHITECTURE.md#push).
//!
//! A phone registers a target (`push.register`, see `rpc/push.rs`): its address at bandito.dev, a 32-byte key, the
//! name it gives this server and the kinds it wants. A background task listens to the [`Hub`]; for each event that the
//! phone's own app would have made a local notification for ([`push_kind`]), it encrypts a small JSON payload with the
//! phone's key (ChaCha20-Poly1305) and posts it to the cloud, which hands it to APNs. The cloud never sees the text.
//!
//! Sending never blocks the hub or an RPC: events are queued (256 at most; a full queue drops the event) and sent by
//! `curl` subprocesses, a few at a time. Logs carry the kind and the status code, never the handle, the key, the text
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
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::{Semaphore, broadcast, mpsc};

/// The cloud API, without a trailing slash. `BANDITO_PUSH_URL` replaces it (tests, a staging cloud).
pub const DEFAULT_BASE_URL: &str = "https://bandito.dev/api/v1";
/// The most events waiting to be sent; more are dropped.
const QUEUE: usize = 256;
/// Sends running at the same time.
const PARALLEL: usize = 4;
/// The most bytes of plaintext. The cloud takes 2700 bytes of ciphertext; the tag adds 16.
pub const MAX_PLAINTEXT: usize = 2600;
/// Heavy strings in a payload are cut to this many characters when it does not fit.
const CUT_CHARS: usize = 300;
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
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Ctx {
    /// The turn that ended with this event was a quiet one (`turn.quiet` came before): nobody is told.
    pub quiet_turn: bool,
    /// The agent has an approval, a form or a connect request waiting, which has its own push.
    pub other_pending: bool,
}

/// The push an event makes, if any: the same rules as the phone's local notifications
/// (`IOSNotifications.notice(for:)` and `AgentNotice.notice(for:in:)`), so a closed app and an open one tell the same.
/// - an approval waiting -> `approval`;
/// - a form, or a connect request -> `question`;
/// - the agent needs the person with nothing else waiting (its own question) -> `question`;
/// - a turn that ended well, unless it was quiet -> `done`;
/// - an error -> `error`.
pub fn push_kind(ev: &Event, ctx: &Ctx) -> Option<PushKind> {
    match &ev.body {
        EventBody::ApprovalRequested { .. } => Some(PushKind::Approval),
        EventBody::FormRequested { .. } | EventBody::IntegrationRequested { .. } => Some(PushKind::Question),
        EventBody::AgentStatus {
            status: AgentStatus::NeedsYou,
            ..
        } if !ctx.other_pending => Some(PushKind::Question),
        EventBody::TurnCompleted {
            status: TurnStatus::Ok, ..
        } if !ctx.quiet_turn => Some(PushKind::Done),
        EventBody::Error { .. } => Some(PushKind::Error),
        _ => None,
    }
}

// ---- the open text: what the phone reads after decrypting ----

/// `s` cut to `max` characters, the last one being `…` when something was cut.
fn cut(s: &str, max: usize) -> String {
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

fn envelope(server_ref: &str, ev: &Event, name: &str, event: &Value) -> String {
    json!({
        "v": 1,
        "srv": server_ref,
        "seq": ev.seq,
        "agent": ev.agent_id,
        "name": cut(name, NAME_CHARS),
        "ts": ev.ts,
        "event": event,
    })
    .to_string()
}

/// The JSON a phone decrypts: `{"v":1,"srv":serverRef,"seq":N,"agent":id,"name":agentName,"ts":ms,"event":{kind,payload}}`.
/// `event` is the event's body as `events.since` sends it (`kind` and `payload`). When the text is longer than
/// [`MAX_PLAINTEXT`] bytes the heavy fields (`diff`, `input`, `command`, `message`) are cut to 300 characters; then
/// every long string; then `input` and `diff` go; and at the very end only the ids that let the phone fetch the
/// event remain (`approval_id`, `form_id`, `request_id`).
pub fn build_payload(server_ref: &str, ev: &Event, agent_name: &str) -> String {
    let (kind, payload) = ev.body.to_parts();
    let mut event = json!({ "kind": kind, "payload": payload });
    let full = envelope(server_ref, ev, agent_name, &event);
    if full.len() <= MAX_PLAINTEXT {
        return full;
    }
    // 1. The heavy fields.
    if let Some(map) = event.get_mut("payload").and_then(Value::as_object_mut) {
        for key in ["diff", "input", "command", "message"] {
            if let Some(v) = map.get_mut(key) {
                cut_strings(v);
            }
        }
    }
    let text = envelope(server_ref, ev, agent_name, &event);
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 2. Every long string.
    if let Some(p) = event.get_mut("payload") {
        cut_strings(p);
    }
    let text = envelope(server_ref, ev, agent_name, &event);
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 3. Without the biggest optional fields.
    if let Some(map) = event.get_mut("payload").and_then(Value::as_object_mut) {
        map.remove("input");
        map.remove("diff");
    }
    let text = envelope(server_ref, ev, agent_name, &event);
    if text.len() <= MAX_PLAINTEXT {
        return text;
    }
    // 4. Only what names the thing.
    let mut ids = serde_json::Map::new();
    if let Some(map) = ev.body.to_parts().1.as_object() {
        for key in ["approval_id", "form_id", "request_id"] {
            if let Some(v) = map.get(key) {
                ids.insert(key.to_string(), v.clone());
            }
        }
    }
    let event = json!({ "kind": ev.body.to_parts().0, "payload": ids });
    envelope(server_ref, ev, agent_name, &event)
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

    /// Reads what waits now from the store: at start, and after the task fell behind.
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
        match &ev.body {
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
            EventBody::TurnCompleted { turn_id, .. } => quiet_turn = self.quiet.remove(turn_id),
            EventBody::AgentChanged {
                action: AgentChange::Deleted,
            } => {
                self.open.remove(agent);
            }
            _ => {}
        }
        Ctx {
            quiet_turn,
            other_pending: self.open.contains_key(agent),
        }
    }
}

// ---- the task ----

/// Where and how the task sends.
#[derive(Debug, Clone)]
pub struct Config {
    pub base_url: String,
    /// The wait before the one retry.
    pub retry_delay: Duration,
}

impl Config {
    /// `BANDITO_PUSH_URL` when it is an http(s) address, else the cloud.
    pub fn from_env() -> Self {
        let base_url = match std::env::var("BANDITO_PUSH_URL") {
            Ok(v) if v.starts_with("https://") || v.starts_with("http://") => v.trim_end_matches('/').to_string(),
            Ok(v) if !v.trim().is_empty() => {
                tracing::warn!("BANDITO_PUSH_URL is not an http(s) address: ignored");
                DEFAULT_BASE_URL.to_string()
            }
            _ => DEFAULT_BASE_URL.to_string(),
        };
        Self {
            base_url,
            retry_delay: Duration::from_secs(2),
        }
    }
}

/// A request ready to send. It holds the encrypted body only, never the key.
struct Job {
    device_id: String,
    handle: String,
    kind: PushKind,
    body: String,
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
    tracker.seed(&store);
    let (tx, jobs) = mpsc::channel::<Job>(QUEUE);
    tokio::spawn(send_loop(jobs, store.clone(), config));
    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    let ctx = tracker.observe(&ev);
                    if let Some(kind) = push_kind(&ev, &ctx) {
                        enqueue(&store, &tx, &ev, kind);
                    }
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    tracing::warn!(missed = n, "push: the task fell behind, some events were not looked at");
                    tracker.seed(&store);
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    })
}

/// Encrypts the event for each phone that wants `kind` and queues the requests.
fn enqueue(store: &Store, tx: &mpsc::Sender<Job>, ev: &Event, kind: PushKind) {
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
        match request_body(&target, kind, ev, &name) {
            Ok(body) => {
                let job = Job {
                    device_id: target.device_id,
                    handle: target.handle,
                    kind,
                    body,
                };
                if tx.try_send(job).is_err() {
                    tracing::warn!(kind = kind.as_str(), "push: the queue is full or closed, event dropped");
                }
            }
            Err(e) => tracing::warn!(kind = kind.as_str(), "push: {e:#}"),
        }
    }
}

/// The JSON body of `POST /push/send` for one phone.
fn request_body(target: &PushTarget, kind: PushKind, ev: &Event, agent_name: &str) -> Result<String> {
    let text = build_payload(&target.server_ref, ev, agent_name);
    let (ct, nonce) = seal_b64(&target.key, &target.handle, text.as_bytes())?;
    let mut body = json!({ "handle": target.handle, "kind": kind.as_str(), "ct": ct, "nonce": nonce });
    // One notification per event on the phone, and the agent's pushes group in one thread.
    body["collapseId"] = json!(format!("b{}", ev.seq));
    if ev.agent_id.len() <= 64 && ev.agent_id.chars().all(|c| c.is_ascii_graphic()) {
        body["threadId"] = json!(ev.agent_id);
    }
    Ok(body.to_string())
}

async fn send_loop(mut jobs: mpsc::Receiver<Job>, store: Arc<Store>, config: Config) {
    let slots = Arc::new(Semaphore::new(PARALLEL));
    let config = Arc::new(config);
    while let Some(job) = jobs.recv().await {
        let Ok(permit) = slots.clone().acquire_owned().await else {
            break;
        };
        let store = store.clone();
        let config = config.clone();
        tokio::spawn(async move {
            deliver(&store, &config, job).await;
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
async fn deliver(store: &Store, config: &Config, job: Job) {
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
    use crate::event::{ConnectEnd, DecidedBy, Decision};
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
    fn a_form_and_a_connect_request_are_questions() {
        let c = Ctx::default();
        assert_eq!(push_kind(&ev(form()), &c), Some(PushKind::Question));
        let connect = EventBody::IntegrationRequested {
            request_id: "r".into(),
            service: "github".into(),
            reason: None,
        };
        assert_eq!(push_kind(&ev(connect), &c), Some(PushKind::Question));
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
    fn only_a_turn_that_ended_well_and_was_not_quiet_is_done() {
        let c = Ctx::default();
        assert_eq!(push_kind(&ev(completed(TurnStatus::Ok)), &c), Some(PushKind::Done));
        assert_eq!(push_kind(&ev(completed(TurnStatus::Error)), &c), None);
        assert_eq!(push_kind(&ev(completed(TurnStatus::Interrupted)), &c), None);
        let quiet = Ctx {
            quiet_turn: true,
            ..Ctx::default()
        };
        assert_eq!(push_kind(&ev(completed(TurnStatus::Ok)), &quiet), None);
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
        let v = parse(&build_payload("my-server", &e, "Forge"));
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
        let text = build_payload("s", &e, "Forge");
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
        let text = build_payload("s", &e, "Forge");
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
        let text = build_payload("s", &e, "Forge");
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
        let text = build_payload("s", &e, "n");
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
        let v = parse(&build_payload("s", &e, "n"));
        assert_eq!(v["event"]["payload"]["form_id"], "f9");
        assert_eq!(v["event"]["payload"]["title"].as_str().unwrap().chars().count(), 300);
    }

    #[test]
    fn a_long_name_is_cut() {
        let v = parse(&build_payload("s", &ev(form()), &"n".repeat(500)));
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

    fn setup(cloud: &Cloud) -> (Hub, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let hub = Hub::new(store.clone());
        let new_agent: NewAgent =
            serde_json::from_value(json!({ "name": "Forge", "runtime": RuntimeKind::Claude })).unwrap();
        let agent = store.agent_create(new_agent).unwrap().id;
        spawn_with(
            &hub,
            Config {
                base_url: cloud.base_url.clone(),
                retry_delay: Duration::from_millis(50),
            },
        );
        (hub, agent)
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
        let (hub, agent) = setup(&cloud);
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
        spawn_with(
            &hub,
            Config {
                base_url: dead,
                retry_delay: Duration::from_millis(20),
            },
        );
        let d = store.device_add("A", "ta").unwrap();
        store.push_upsert(&d.id, "h", &[1; 32], "s", "error", None).unwrap();
        hub.emit("a", EventBody::Error { message: "boom".into() });
        hub.emit("a", EventBody::Error { message: "boom".into() });
        settle().await;
        assert!(store.push_get(&d.id).unwrap().is_some());
    }
}
