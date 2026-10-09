//! Codex adapter: drives `codex app-server --stdio` (JSON-RPC 2.0, one message per
//! line). Protocol notes and a recorded transcript: `tests/fixtures/codex/`.

use super::process::{self, JsonProcess, LineSink, Router, locked};
use super::{
    ApprovalRequest, Plan, Runtime, RuntimeKind, RuntimeOutput, RuntimeStatus, Session, SpawnConfig, Spawned,
    capitalized, clip_input,
};
use crate::event::{Decision, EventBody, LimitWindow, TOOL_OUTPUT_LIMIT, TurnStatus, Usage, truncate_output};
use crate::store::Effort;
use anyhow::{anyhow, bail};
use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::process::Command;
use tokio::sync::oneshot;
use tokio::time::timeout;

/// Name of the CLI in logs and error messages.
const LABEL: &str = "codex";
/// JSON-RPC error code for a method we do not implement.
const METHOD_NOT_FOUND: i64 = -32601;
/// Ids of the two requests of a usage read (`initialize`, then `account/rateLimits/read`).
const USAGE_INIT_ID: i64 = 1;
const USAGE_READ_ID: i64 = 2;
/// Upper bound for a whole usage read: start, handshake, answer.
const USAGE_TIMEOUT: Duration = Duration::from_secs(15);
/// Ids of the two requests of a plan read (`initialize`, then `account/read`). Its own process, so its own ids.
const PLAN_INIT_ID: i64 = 1;
const PLAN_READ_ID: i64 = 2;
/// Tool input strings longer than this are clipped in events and approvals.
const INPUT_CLIP_BYTES: usize = 4096;
/// Max bytes of diff text shown in an approval.
const APPROVAL_DIFF_LIMIT: usize = 8192;
/// Max chars of a command used as a tool title.
const TITLE_LIMIT: usize = 200;
/// Shown when `thread/resume` fails and a new thread is started instead.
const RESUME_FALLBACK: &str = "codex could not resume the previous thread; started a new one";

/// Stands in for a missing field, so lookups can borrow a `&Value`.
static NULL: Value = Value::Null;

pub struct CodexRuntime {
    program: String,
    /// Extra environment for the usage read (`refresh_usage`). Turns get theirs from the spawn config.
    env: Vec<(String, String)>,
}

impl CodexRuntime {
    pub fn new() -> Self {
        Self::with_program("codex")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
            env: Vec::new(),
        }
    }

    /// Environment for the usage read. Tests point it at a fake CLI.
    pub fn with_env(mut self, env: Vec<(String, String)>) -> Self {
        self.env = env;
        self
    }
}

impl Default for CodexRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Runtime for CodexRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Codex
    }

    async fn status(&self) -> RuntimeStatus {
        let version = super::probe_version(&self.program).await;
        RuntimeStatus {
            kind: RuntimeKind::Codex,
            installed: version.is_some(),
            version,
            logged_in: None,
            detail: None,
        }
    }

    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned> {
        let program = cfg.program.clone().unwrap_or_else(|| PathBuf::from(&self.program));
        let mut cmd = Command::new(&program);
        cmd.arg("app-server").arg("--stdio");
        if let Some((prog, args)) = &cfg.mcp {
            // `-c key=value` values are parsed as TOML; JSON strings and arrays are valid TOML.
            cmd.arg("-c").arg(format!(
                "mcp_servers.bandito.command={}",
                json!(prog.display().to_string())
            ));
            cmd.arg("-c").arg(format!("mcp_servers.bandito.args={}", json!(args)));
        }
        if !cfg.extra_dirs.is_empty() {
            // The workspace-write sandbox also writes to these roots. One override carries the whole list.
            let roots: Vec<String> = cfg.extra_dirs.iter().map(|dir| dir.display().to_string()).collect();
            cmd.arg("-c")
                .arg(format!("sandbox_workspace_write.writable_roots={}", json!(roots)));
        }
        cmd.current_dir(&cfg.cwd).envs(cfg.env.iter().map(|(k, v)| (k, v)));
        // Marks the CLI and its children for `host.processes` (see docs/ARCHITECTURE.md#host).
        cmd.env("BANDITO_AGENT_ID", &cfg.agent_id);
        if let Some(token) = &cfg.agent_token {
            cmd.env("BANDITO_AGENT_TOKEN", token);
        }

        let state = Arc::new(Mutex::new(State::new(cfg.effort.map(turn_effort))));
        let launch = Launch::from_config(&cfg);
        let router_state = Arc::clone(&state);
        let router_launch = launch.clone();
        let router: Router =
            Box::new(move |msg: &Value, sink: &LineSink| route(msg, &router_state, &router_launch, sink));
        let cmd = crate::workspace::confine(cmd, cfg.workspace.as_ref());
        let (proc, output) = JsonProcess::spawn(cmd, LABEL, router)?;
        let sink = proc.sink();
        // A CLI that already died has closed its stdin. Its exit reaches the caller as `Exited`.
        if let Err(e) = locked(&state).request(&sink, "initialize", client_info(), Pending::Init) {
            tracing::debug!("could not send initialize: {e}");
        }

        Ok(Spawned {
            session: Box::new(CodexSession { proc, sink, state }),
            output,
        })
    }

    /// Starts `codex app-server` only for this read, with no thread and no turn, and stops it again.
    async fn refresh_usage(&self) -> anyhow::Result<Option<Vec<LimitWindow>>> {
        let mut cmd = Command::new(&self.program);
        cmd.arg("app-server")
            .arg("--stdio")
            .envs(self.env.iter().map(|(k, v)| (k, v)));
        let (answer_tx, answer_rx) = oneshot::channel();
        let mut answer_tx = Some(answer_tx);
        let router: Router = Box::new(move |msg: &Value, sink: &LineSink| {
            if let Some(answer) = usage_step(msg, sink)
                && let Some(tx) = answer_tx.take()
            {
                // The caller may have given up already; then nobody needs the answer.
                let _ = tx.send(answer);
            }
            Vec::new()
        });
        let (proc, _output) = JsonProcess::spawn(cmd, LABEL, router)?;
        let outcome = timeout(USAGE_TIMEOUT, usage_exchange(&proc, answer_rx)).await;
        proc.shutdown().await;
        match outcome {
            // An empty answer must not wipe the windows a turn reported earlier.
            Ok(answer) => answer.map(|w| (!w.is_empty()).then_some(w)),
            Err(_) => bail!("codex: rate limits request timed out"),
        }
    }

    /// Starts `codex app-server` only for this read (`account/read`), with no thread and no turn, and stops it again.
    async fn account_plan(&self) -> anyhow::Result<Option<Plan>> {
        let mut cmd = Command::new(&self.program);
        cmd.arg("app-server")
            .arg("--stdio")
            .envs(self.env.iter().map(|(k, v)| (k, v)));
        let (answer_tx, answer_rx) = oneshot::channel();
        let mut answer_tx = Some(answer_tx);
        let router: Router = Box::new(move |msg: &Value, sink: &LineSink| {
            if let Some(answer) = plan_step(msg, sink)
                && let Some(tx) = answer_tx.take()
            {
                // The caller may have given up already; then nobody needs the answer.
                let _ = tx.send(answer);
            }
            Vec::new()
        });
        let (proc, _output) = JsonProcess::spawn(cmd, LABEL, router)?;
        let outcome = timeout(USAGE_TIMEOUT, plan_exchange(&proc, answer_rx)).await;
        proc.shutdown().await;
        match outcome {
            Ok(answer) => answer,
            Err(_) => bail!("codex: account read timed out"),
        }
    }
}

/// `clientInfo` of the `initialize` request.
fn client_info() -> Value {
    json!({"clientInfo": {"name": "bandito", "title": "Bandito", "version": env!("CARGO_PKG_VERSION")}})
}

/// Sends `initialize` and waits for the windows the router passes on through `answer`.
/// The router drops `answer`'s sender when the process ends, which ends the wait with an error.
async fn usage_exchange(
    proc: &JsonProcess,
    answer: oneshot::Receiver<anyhow::Result<Vec<LimitWindow>>>,
) -> anyhow::Result<Vec<LimitWindow>> {
    proc.send(&json!({"jsonrpc": "2.0", "id": USAGE_INIT_ID, "method": "initialize", "params": client_info()}))?;
    answer
        .await
        .map_err(|_| anyhow!("codex: app-server exited before answering"))?
}

/// The usage read's reaction to one server message. `Some` when the read is over: its windows, or its error.
/// Notifications and server requests are ignored, so the read is never answered by mistake.
fn usage_step(msg: &Value, sink: &LineSink) -> Option<anyhow::Result<Vec<LimitWindow>>> {
    if msg.get("method").is_some() {
        return None;
    }
    match msg.get("id").and_then(Value::as_i64)? {
        USAGE_INIT_ID => {
            if let Some(error) = msg.get("error") {
                return Some(Err(anyhow!("codex: {}", error_text(error, "initialize failed"))));
            }
            let initialized = json!({"jsonrpc": "2.0", "method": "initialized"});
            let read =
                json!({"jsonrpc": "2.0", "id": USAGE_READ_ID, "method": "account/rateLimits/read", "params": {}});
            let sent =
                process::push_line(sink, LABEL, &initialized).and_then(|()| process::push_line(sink, LABEL, &read));
            match sent {
                Ok(()) => None,
                Err(e) => Some(Err(e)),
            }
        }
        USAGE_READ_ID => Some(match msg.get("error") {
            Some(error) => Err(anyhow!("codex: {}", error_text(error, "rate limits read failed"))),
            None => Ok(rate_limit_windows(msg.pointer("/result/rateLimits").unwrap_or(&NULL))),
        }),
        _ => None,
    }
}

/// Sends `initialize` and waits for the plan the router passes on through `answer`.
/// The router drops `answer`'s sender when the process ends, which ends the wait with an error.
async fn plan_exchange(
    proc: &JsonProcess,
    answer: oneshot::Receiver<anyhow::Result<Option<Plan>>>,
) -> anyhow::Result<Option<Plan>> {
    proc.send(&json!({"jsonrpc": "2.0", "id": PLAN_INIT_ID, "method": "initialize", "params": client_info()}))?;
    answer
        .await
        .map_err(|_| anyhow!("codex: app-server exited before answering"))?
}

/// The plan read's reaction to one server message. `Some` when the read is over.
/// A refused read is logged and means "no plan": it must not fail the usage refresh.
fn plan_step(msg: &Value, sink: &LineSink) -> Option<anyhow::Result<Option<Plan>>> {
    if msg.get("method").is_some() {
        return None;
    }
    match msg.get("id").and_then(Value::as_i64)? {
        PLAN_INIT_ID => {
            if let Some(error) = msg.get("error") {
                tracing::debug!(
                    "codex: plan read refused at initialize: {}",
                    error_text(error, "initialize failed")
                );
                return Some(Ok(None));
            }
            let initialized = json!({"jsonrpc": "2.0", "method": "initialized"});
            let read = json!({"jsonrpc": "2.0", "id": PLAN_READ_ID, "method": "account/read", "params": {}});
            let sent =
                process::push_line(sink, LABEL, &initialized).and_then(|()| process::push_line(sink, LABEL, &read));
            match sent {
                Ok(()) => None,
                Err(e) => Some(Err(e)),
            }
        }
        PLAN_READ_ID => Some(match msg.get("error") {
            Some(error) => {
                tracing::debug!(
                    "codex: account read refused: {}",
                    error_text(error, "account read failed")
                );
                Ok(None)
            }
            None => Ok(plan_of_account(msg.get("result").unwrap_or(&NULL))),
        }),
        _ => None,
    }
}

/// The plan in an `account/read` answer: `account.planType`, else `rateLimits.planType`.
pub fn plan_of_account(result: &Value) -> Option<Plan> {
    let plan_type = id_at(result, "/account/planType").or_else(|| id_at(result, "/rateLimits/planType"))?;
    plan_from_codex(&plan_type)
}

/// Plan from Codex's `planType`. Known names get their label; any other name is shown as it comes.
pub fn plan_from_codex(plan_type: &str) -> Option<Plan> {
    let raw = plan_type.trim();
    if raw.is_empty() {
        return None;
    }
    let key = raw.to_lowercase();
    let known = match key.as_str() {
        "plus" => Some("Plus"),
        "pro" => Some("Pro"),
        "team" => Some("Team"),
        "business" => Some("Business"),
        "enterprise" => Some("Enterprise"),
        "edu" => Some("Edu"),
        "free" => Some("Free"),
        _ => None,
    };
    Some(match known {
        Some(label) => Plan {
            id: key,
            label: label.to_string(),
        },
        None => Plan {
            id: raw.to_string(),
            label: capitalized(raw),
        },
    })
}

/// Codex's `effort` for a turn. `max` is not a Codex level and the RPC refuses it, so it maps to the highest one.
fn turn_effort(effort: Effort) -> &'static str {
    match effort {
        Effort::Low => "low",
        Effort::Medium => "medium",
        Effort::High => "high",
        Effort::Xhigh | Effort::Max => "xhigh",
    }
}

/// What the spawn options turn into when the thread is started or resumed.
#[derive(Clone)]
struct Launch {
    cwd: String,
    model: Option<String>,
    system_prompt: Option<String>,
    resume: Option<String>,
}

impl Launch {
    fn from_config(cfg: &SpawnConfig) -> Self {
        Self {
            cwd: cfg.cwd.to_string_lossy().into_owned(),
            model: cfg.model.clone(),
            system_prompt: cfg.system_prompt.clone(),
            resume: cfg.resume.clone(),
        }
    }
}

/// What the answer to one of our requests means.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pending {
    Init,
    ThreadStart,
    /// `thread/resume`. A failed answer falls back to `thread/start`.
    ThreadResume,
    TurnStart,
    Other,
}

/// Session state shared by the router (server messages) and the session (our calls).
struct State {
    /// Id of our next request. JSON-RPC ids start at 1; `initialize` takes 1.
    next_id: i64,
    thread_id: Option<String>,
    turn_id: Option<String>,
    /// A `turn/start` was sent and its turn has not ended yet.
    turn_active: bool,
    /// `interrupt()` came while the turn id was not known yet. Sent once it is.
    interrupt_pending: bool,
    /// Messages sent before the thread exists, in order.
    queued: Vec<String>,
    /// Texts that `interrupt()` dropped from `queued`. Their turn ends go out with the CLI's next message.
    withdrawn_texts: usize,
    /// Approval key → the server's JSON-RPC id, echoed back in the answer unchanged.
    approvals: HashMap<String, Value>,
    /// Our requests still waiting for an answer.
    requests: HashMap<i64, Pending>,
    /// Changes of each `fileChange` item, from `item/started`: (path, diff).
    file_changes: HashMap<String, Vec<(String, String)>>,
    last_usage: Option<Usage>,
    /// `effort` sent with every `turn/start`. `None` leaves it out.
    effort: Option<&'static str>,
}

impl State {
    fn new(effort: Option<&'static str>) -> Self {
        Self {
            effort,
            next_id: 1,
            thread_id: None,
            turn_id: None,
            turn_active: false,
            interrupt_pending: false,
            queued: Vec::new(),
            withdrawn_texts: 0,
            approvals: HashMap::new(),
            requests: HashMap::new(),
            file_changes: HashMap::new(),
            last_usage: None,
        }
    }

    /// Send a request and remember what its answer means.
    fn request(&mut self, sink: &LineSink, method: &str, params: Value, kind: Pending) -> anyhow::Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        self.requests.insert(id, kind);
        let frame = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        if let Err(e) = process::push_line(sink, LABEL, &frame) {
            self.requests.remove(&id);
            return Err(e);
        }
        Ok(())
    }

    /// Resume the stored thread, or start one, as the spawn options say.
    fn thread_request(&mut self, sink: &LineSink, launch: &Launch) -> anyhow::Result<()> {
        match &launch.resume {
            Some(thread_id) => {
                let params = thread_params(launch, json!({"threadId": thread_id}));
                self.request(sink, "thread/resume", params, Pending::ThreadResume)
            }
            None => self.start_thread(sink, launch),
        }
    }

    /// `thread/start` with the spawn options.
    fn start_thread(&mut self, sink: &LineSink, launch: &Launch) -> anyhow::Result<()> {
        let params = thread_params(launch, json!({"cwd": launch.cwd}));
        self.request(sink, "thread/start", params, Pending::ThreadStart)
    }

    /// `turn/start` for `text` on the current thread.
    fn start_turn(&mut self, sink: &LineSink, text: &str) -> anyhow::Result<()> {
        let Some(thread_id) = self.thread_id.clone() else {
            bail!("codex thread is not started");
        };
        // No `text_elements`: the recorded transcript matches the input item exactly.
        let input = json!([{"type": "text", "text": text}]);
        let mut params = json!({"threadId": thread_id, "input": input});
        if let Some(effort) = self.effort {
            params["effort"] = json!(effort);
        }
        self.request(sink, "turn/start", params, Pending::TurnStart)?;
        self.turn_active = true;
        Ok(())
    }

    /// `turn/interrupt` for the current turn. Needs both the thread and the turn id.
    fn send_interrupt(&mut self, sink: &LineSink) -> anyhow::Result<()> {
        let (Some(thread_id), Some(turn_id)) = (self.thread_id.clone(), self.turn_id.clone()) else {
            bail!("codex turn id is not known");
        };
        self.request(
            sink,
            "turn/interrupt",
            json!({"threadId": thread_id, "turnId": turn_id}),
            Pending::Other,
        )
    }

    /// The turn id is known (from the `turn/start` answer or `turn/started`).
    /// An interrupt that was waiting for it goes out now.
    fn turn_known(&mut self, sink: &LineSink, turn_id: String) -> Vec<RuntimeOutput> {
        self.turn_id = Some(turn_id);
        if !std::mem::take(&mut self.interrupt_pending) {
            return Vec::new();
        }
        match self.send_interrupt(sink) {
            Ok(()) => Vec::new(),
            Err(e) => vec![error_event(format!("codex: could not interrupt the turn: {e}"))],
        }
    }

    /// The turn is over: it completed, failed, or never started.
    fn forget_turn(&mut self) {
        self.turn_id = None;
        self.turn_active = false;
        self.interrupt_pending = false;
    }
}

/// Thread options shared by `thread/start` and `thread/resume`.
fn thread_params(launch: &Launch, mut params: Value) -> Value {
    params["approvalPolicy"] = json!("untrusted");
    params["sandbox"] = json!("workspace-write");
    if let Some(model) = &launch.model {
        params["model"] = json!(model);
    }
    if let Some(prompt) = &launch.system_prompt {
        params["developerInstructions"] = json!(prompt);
    }
    params
}

/// A live Codex app-server process. Our calls go out through the shared state;
/// the process wrapper owns the child and reports its exit.
struct CodexSession {
    proc: JsonProcess,
    sink: LineSink,
    state: Arc<Mutex<State>>,
}

#[async_trait]
impl Session for CodexSession {
    async fn send(&mut self, text: &str) -> anyhow::Result<()> {
        let mut st = locked(&self.state);
        if st.thread_id.is_some() {
            st.start_turn(&self.sink, text)
        } else {
            st.queued.push(text.to_string());
            Ok(())
        }
    }

    async fn interrupt(&mut self) -> anyhow::Result<()> {
        let mut st = locked(&self.state);
        if st.thread_id.is_none() {
            // The thread does not exist yet, so the queued texts will never run.
            // Their turn ends are reported with the CLI's next message.
            let dropped = std::mem::take(&mut st.queued);
            st.withdrawn_texts += dropped.len();
            return Ok(());
        }
        if st.turn_id.is_some() {
            return st.send_interrupt(&self.sink);
        }
        // `turn/start` is on its way (or nothing runs). Interrupt only a turn that exists.
        if st.turn_active {
            st.interrupt_pending = true;
        }
        Ok(())
    }

    async fn resolve(&mut self, key: &str, decision: Decision) -> anyhow::Result<()> {
        let removed = locked(&self.state).approvals.remove(key);
        let Some(id) = removed else {
            bail!("unknown approval {key}");
        };
        let answer = match decision {
            Decision::Allow => "accept",
            Decision::Deny => "decline",
        };
        self.proc
            .send(&json!({"jsonrpc": "2.0", "id": id, "result": {"decision": answer}}))
    }

    async fn shutdown(self: Box<Self>) {
        let this = *self;
        this.proc.shutdown().await;
    }
}

/// Route one parsed stdout message. Messages with `method` + `id` are server
/// requests, `method` alone are notifications, `id` alone are answers to ours.
fn route(msg: &Value, state: &Mutex<State>, launch: &Launch, sink: &LineSink) -> Vec<RuntimeOutput> {
    let mut st = locked(state);
    // Texts dropped by an interrupt before the thread existed end first, before anything else the CLI says.
    let mut out: Vec<RuntimeOutput> = (0..std::mem::take(&mut st.withdrawn_texts))
        .map(|_| turn_end(TurnStatus::Interrupted))
        .collect();
    let params = msg.get("params").unwrap_or(&NULL);
    match (msg.get("method").and_then(Value::as_str), msg.get("id")) {
        (Some(method), Some(id)) => out.extend(server_request(&mut st, method, id, params, sink)),
        (Some(method), None) => out.extend(notification(&mut st, method, params, sink)),
        (None, Some(id)) => {
            let Some(request_id) = id.as_i64() else {
                return out;
            };
            if let Some(kind) = st.requests.remove(&request_id) {
                out.extend(answer(&mut st, msg, kind, launch, sink));
            }
        }
        (None, None) => {}
    }
    out
}

/// A request from the server: approvals are kept for the host's answer; anything else gets an error reply.
fn server_request(st: &mut State, method: &str, id: &Value, params: &Value, sink: &LineSink) -> Vec<RuntimeOutput> {
    match method {
        "item/commandExecution/requestApproval" => {
            let key = request_key(id);
            st.approvals.insert(key.clone(), id.clone());
            vec![RuntimeOutput::Approval(command_approval(&key, params))]
        }
        "item/fileChange/requestApproval" => {
            let key = request_key(id);
            st.approvals.insert(key.clone(), id.clone());
            vec![RuntimeOutput::Approval(file_change_approval(st, &key, params))]
        }
        _ => {
            let reply = json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": {"code": METHOD_NOT_FOUND, "message": format!("Unsupported request: {method}")},
            });
            if let Err(e) = process::push_line(sink, LABEL, &reply) {
                tracing::debug!("could not answer {method}: {e}");
            }
            Vec::new()
        }
    }
}

/// Our answer to a request we sent. `kind` says what the request was.
fn answer(st: &mut State, msg: &Value, kind: Pending, launch: &Launch, sink: &LineSink) -> Vec<RuntimeOutput> {
    if let Some(error) = msg.get("error") {
        let message = error_text(error, "request failed");
        return match kind {
            Pending::Init | Pending::ThreadStart => startup_failed(st, format!("codex: {message}")),
            Pending::ThreadResume => resume_failed(st, launch, sink),
            Pending::TurnStart => {
                st.forget_turn();
                turn_failed(format!("codex: {message}"))
            }
            Pending::Other => vec![error_event(format!("codex: {message}"))],
        };
    }
    let result = msg.get("result").unwrap_or(&NULL);
    match kind {
        Pending::Init => {
            let initialized = json!({"jsonrpc": "2.0", "method": "initialized"});
            let started = process::push_line(sink, LABEL, &initialized).and_then(|()| st.thread_request(sink, launch));
            match started {
                Ok(()) => Vec::new(),
                Err(e) => startup_failed(st, format!("codex: could not start the thread: {e}")),
            }
        }
        Pending::ThreadStart => match id_at(result, "/thread/id") {
            Some(thread_id) => thread_started(st, thread_id, sink),
            None => startup_failed(st, "codex: thread response has no thread id".to_string()),
        },
        // A resume answer without a thread id is as unusable as an error: start a new thread.
        Pending::ThreadResume => match id_at(result, "/thread/id") {
            Some(thread_id) => thread_started(st, thread_id, sink),
            None => resume_failed(st, launch, sink),
        },
        Pending::TurnStart => match id_at(result, "/turn/id") {
            Some(turn_id) => st.turn_known(sink, turn_id),
            None => Vec::new(),
        },
        Pending::Other => Vec::new(),
    }
}

/// The thread exists: announce it, then send the messages queued before it.
fn thread_started(st: &mut State, thread_id: String, sink: &LineSink) -> Vec<RuntimeOutput> {
    st.thread_id = Some(thread_id.clone());
    let mut out = vec![RuntimeOutput::SessionId(thread_id)];
    for text in std::mem::take(&mut st.queued) {
        if let Err(e) = st.start_turn(sink, &text) {
            out.extend(turn_failed(format!("codex: {e}")));
        }
    }
    out
}

/// The thread cannot be started. The queued texts never run: one error, then an error turn end for each.
fn startup_failed(st: &mut State, message: String) -> Vec<RuntimeOutput> {
    let queued = std::mem::take(&mut st.queued);
    let mut out = vec![error_event(message)];
    out.extend(queued.iter().map(|_| turn_end(TurnStatus::Error)));
    out
}

/// `thread/resume` failed: start a new thread with the same options. The queued texts wait for it.
fn resume_failed(st: &mut State, launch: &Launch, sink: &LineSink) -> Vec<RuntimeOutput> {
    match st.start_thread(sink, launch) {
        Ok(()) => vec![error_event(RESUME_FALLBACK.to_string())],
        Err(e) => startup_failed(st, format!("codex: could not start the thread: {e}")),
    }
}

/// Notifications (no `id`): stream deltas, items, usage and turn ends.
fn notification(st: &mut State, method: &str, params: &Value, sink: &LineSink) -> Vec<RuntimeOutput> {
    let mut out = Vec::new();
    match method {
        "turn/started" => {
            if let Some(turn_id) = id_at(params, "/turn/id") {
                out.extend(st.turn_known(sink, turn_id));
            }
        }
        "serverRequest/resolved" => {
            let key = request_key(params.get("requestId").unwrap_or(&NULL));
            // Only a request we still hold is a cancellation; our own answer also triggers this.
            if st.approvals.remove(&key).is_some() {
                out.push(RuntimeOutput::ApprovalCancelled { key });
            }
        }
        "item/agentMessage/delta" => {
            if let Some(delta) = str_field(params, "delta") {
                out.push(RuntimeOutput::Event(EventBody::MessageDelta {
                    text: delta.to_string(),
                }));
            }
        }
        "item/started" => item_started(st, params.get("item").unwrap_or(&NULL), &mut out),
        "item/completed" => item_completed(st, params.get("item").unwrap_or(&NULL), &mut out),
        "thread/tokenUsage/updated" => {
            if let Some(last) = params.pointer("/tokenUsage/last") {
                st.last_usage = Some(Usage {
                    input_tokens: u64_field(last, "inputTokens"),
                    output_tokens: u64_field(last, "outputTokens"),
                });
            }
        }
        "turn/completed" => turn_completed(st, params.get("turn").unwrap_or(&NULL), &mut out),
        "account/rateLimits/updated" => {
            let windows = rate_limit_windows(params.get("rateLimits").unwrap_or(&NULL));
            if !windows.is_empty() {
                out.push(RuntimeOutput::Event(EventBody::UsageLimits {
                    runtime: "codex".to_string(),
                    windows,
                }));
            }
        }
        // `error` notifications are retries; the turn's final status carries the real failure.
        _ => {}
    }
    out
}

fn item_started(st: &mut State, item: &Value, out: &mut Vec<RuntimeOutput>) {
    let call_id = raw_str(item, "id").to_string();
    match raw_str(item, "type") {
        "commandExecution" => {
            let command = raw_str(item, "command");
            out.push(tool_call(
                call_id,
                "shell",
                command_title(command),
                json!({"command": command}),
            ));
        }
        "fileChange" => {
            let changes = file_changes_of(item);
            let paths: Vec<String> = changes.iter().map(|(path, _)| path.clone()).collect();
            out.push(tool_call(
                call_id.clone(),
                "apply_patch",
                file_change_title(&paths),
                json!({"paths": paths}),
            ));
            st.file_changes.insert(call_id, changes);
        }
        "mcpToolCall" => {
            let tool = mcp_tool_name(item);
            let input = clip_input(item.get("arguments").unwrap_or(&NULL), INPUT_CLIP_BYTES);
            out.push(tool_call(call_id, &tool, tool.clone(), input));
        }
        "webSearch" => {
            let query = raw_str(item, "query");
            out.push(tool_call(
                call_id,
                "web_search",
                web_search_title(query),
                json!({"query": query}),
            ));
        }
        _ => {}
    }
}

fn item_completed(st: &mut State, item: &Value, out: &mut Vec<RuntimeOutput>) {
    let call_id = raw_str(item, "id").to_string();
    match raw_str(item, "type") {
        "agentMessage" => {
            if let Some(text) = str_field(item, "text") {
                out.push(RuntimeOutput::Event(EventBody::MessageAssistant {
                    text: text.to_string(),
                }));
            }
        }
        "commandExecution" => {
            let ok = command_ok(raw_str(item, "status"), item.get("exitCode").and_then(Value::as_i64));
            out.push(tool_result(
                call_id,
                ok,
                truncate_output(raw_str(item, "aggregatedOutput"), TOOL_OUTPUT_LIMIT),
            ));
        }
        "fileChange" => {
            let status = raw_str(item, "status");
            let stored = st.file_changes.remove(&call_id);
            let reported = item.get("changes").and_then(Value::as_array).filter(|c| !c.is_empty());
            let count = reported.map_or_else(|| stored.as_ref().map_or(0, Vec::len), Vec::len);
            out.push(tool_result(
                call_id,
                status == "completed",
                file_change_result(status, count),
            ));
        }
        "mcpToolCall" => {
            let (ok, output) = mcp_result(item);
            out.push(tool_result(call_id, ok, truncate_output(&output, TOOL_OUTPUT_LIMIT)));
        }
        "webSearch" => out.push(tool_result(call_id, true, String::new())),
        _ => {}
    }
}

fn turn_completed(st: &mut State, turn: &Value, out: &mut Vec<RuntimeOutput>) {
    // The server closes the requests still open with the turn itself. Nothing is answered for them.
    let mut open: Vec<String> = st.approvals.drain().map(|(key, _)| key).collect();
    open.sort();
    out.extend(open.into_iter().map(|key| RuntimeOutput::ApprovalCancelled { key }));
    st.file_changes.clear();

    let status = match raw_str(turn, "status") {
        "completed" => TurnStatus::Ok,
        "interrupted" => TurnStatus::Interrupted,
        _ => TurnStatus::Error,
    };
    if status == TurnStatus::Error {
        let message = error_text(turn.get("error").unwrap_or(&NULL), "Codex turn failed");
        out.push(error_event(message));
    }
    out.push(RuntimeOutput::Event(EventBody::TurnCompleted {
        // The supervisor fills in the turn id.
        turn_id: String::new(),
        status,
        usage: st.last_usage.take(),
        cost_usd: None,
    }));
    st.forget_turn();
}

/// Approval for a shell command.
fn command_approval(key: &str, params: &Value) -> ApprovalRequest {
    let command = raw_str(params, "command");
    ApprovalRequest {
        key: key.to_string(),
        call_id: str_field(params, "itemId").unwrap_or(key).to_string(),
        tool: "shell".to_string(),
        title: command_title(command),
        command: Some(command.to_string()),
        diff: None,
        paths: Vec::new(),
        input: clip_input(params, INPUT_CLIP_BYTES),
    }
}

/// Approval for a patch. Paths and diffs come from the `fileChange` item seen at `item/started`.
fn file_change_approval(st: &State, key: &str, params: &Value) -> ApprovalRequest {
    let item_id = raw_str(params, "itemId");
    let changes: &[(String, String)] = st.file_changes.get(item_id).map(Vec::as_slice).unwrap_or_default();
    let paths: Vec<String> = changes.iter().map(|(path, _)| path.clone()).collect();
    let diff = (!changes.is_empty()).then(|| truncate_output(&file_change_diff(changes), APPROVAL_DIFF_LIMIT));
    ApprovalRequest {
        key: key.to_string(),
        call_id: str_field(params, "itemId").unwrap_or(key).to_string(),
        tool: "apply_patch".to_string(),
        title: file_change_title(&paths),
        command: None,
        diff,
        paths,
        input: clip_input(params, INPUT_CLIP_BYTES),
    }
}

fn tool_call(call_id: String, tool: &str, title: String, input: Value) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::ToolCall {
        call_id,
        tool: tool.to_string(),
        title,
        input,
    })
}

fn tool_result(call_id: String, ok: bool, output: String) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::ToolResult { call_id, ok, output })
}

fn error_event(message: String) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::Error { message })
}

/// An error and the end of its turn, for a turn that never started.
fn turn_failed(message: String) -> Vec<RuntimeOutput> {
    vec![error_event(message), turn_end(TurnStatus::Error)]
}

/// The end of a turn. The supervisor fills in the turn id.
fn turn_end(status: TurnStatus) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::TurnCompleted {
        turn_id: String::new(),
        status,
        usage: None,
        cost_usd: None,
    })
}

/// Key of an approval: the JSON-RPC id as text (strings as they are, numbers via `to_string`).
fn request_key(id: &Value) -> String {
    match id {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// `method` of an `mcpToolCall` item, as `server.tool`.
fn mcp_tool_name(item: &Value) -> String {
    format!("{}.{}", raw_str(item, "server"), raw_str(item, "tool"))
}

/// Changes of a `fileChange` item as (path, diff) pairs.
fn file_changes_of(item: &Value) -> Vec<(String, String)> {
    item.get("changes")
        .and_then(Value::as_array)
        .map(|changes| {
            changes
                .iter()
                .filter_map(|change| {
                    Some((
                        str_field(change, "path")?.to_string(),
                        raw_str(change, "diff").to_string(),
                    ))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// One-line title of a shell command: its first line, clipped. `shell` when there is none.
pub fn command_title(command: &str) -> String {
    command
        .lines()
        .next()
        .filter(|line| !line.trim().is_empty())
        .map(|line| line.chars().take(TITLE_LIMIT).collect::<String>())
        .unwrap_or_else(|| "shell".to_string())
}

/// `Edit <first path>`, with ` (+N more)` when there are more paths.
pub fn file_change_title(paths: &[String]) -> String {
    match paths {
        [] => "Edit files".to_string(),
        [first] => format!("Edit {first}"),
        [first, rest @ ..] => format!("Edit {first} (+{} more)", rest.len()),
    }
}

/// Each change as `--- path` followed by its diff, joined by newlines.
fn file_change_diff(changes: &[(String, String)]) -> String {
    changes
        .iter()
        .map(|(path, diff)| format!("--- {path}\n{diff}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn web_search_title(query: &str) -> String {
    if query.is_empty() {
        "Search".to_string()
    } else {
        format!("Search {query}")
    }
}

/// Result text of a `fileChange` item by its status.
pub fn file_change_result(status: &str, count: usize) -> String {
    match status {
        "completed" => format!("applied {count} change(s)"),
        "declined" => "declined".to_string(),
        _ => "failed".to_string(),
    }
}

/// A shell command succeeded when it completed and exited with 0 (or reported no code).
pub fn command_ok(status: &str, exit_code: Option<i64>) -> bool {
    status == "completed" && matches!(exit_code, None | Some(0))
}

/// Success and text of an `mcpToolCall` item: the text parts of its result, or the error message.
pub fn mcp_result(item: &Value) -> (bool, String) {
    if raw_str(item, "status") == "completed" {
        let text = item
            .pointer("/result/content")
            .and_then(Value::as_array)
            .map(|parts| {
                parts
                    .iter()
                    .filter(|part| raw_str(part, "type") == "text")
                    .filter_map(|part| part.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n")
            })
            .unwrap_or_default();
        // A tool that reports `isError` failed, even though the call itself completed.
        let is_error = item.pointer("/result/isError").and_then(Value::as_bool) == Some(true);
        (!is_error, text)
    } else {
        (false, error_text(item.get("error").unwrap_or(&NULL), "failed"))
    }
}

/// Rate-limit windows from `account/rateLimits/updated`, named by their length.
pub fn rate_limit_windows(rate_limits: &Value) -> Vec<LimitWindow> {
    ["primary", "secondary"]
        .into_iter()
        .filter_map(|key| {
            let window = rate_limits.get(key).filter(|w| w.is_object())?;
            let used = window.get("usedPercent").and_then(Value::as_f64)?;
            let name = match window.get("windowDurationMins").and_then(Value::as_i64) {
                Some(300) => "five_hour".to_string(),
                Some(10080) => "seven_day".to_string(),
                Some(minutes) => format!("{minutes}m"),
                None => key.to_string(),
            };
            Some(LimitWindow {
                name,
                utilization: used / 100.0,
                resets_at: window.get("resetsAt").and_then(Value::as_i64),
            })
        })
        .collect()
}

/// Non-empty string field of a JSON object.
fn str_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// Non-empty string at a JSON pointer (e.g. `/thread/id`), as an owned id.
fn id_at(v: &Value, pointer: &str) -> Option<String> {
    v.pointer(pointer)
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_string)
}

/// String field of a JSON object, or "" if missing.
fn raw_str<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

fn u64_field(v: &Value, key: &str) -> u64 {
    v.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// `error.message`, or `fallback` when there is none.
fn error_text(error: &Value, fallback: &str) -> String {
    str_field(error, "message").unwrap_or(fallback).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_effort_names_codex_levels_and_maps_max_to_xhigh() {
        assert_eq!(turn_effort(Effort::Low), "low");
        assert_eq!(turn_effort(Effort::Medium), "medium");
        assert_eq!(turn_effort(Effort::High), "high");
        assert_eq!(turn_effort(Effort::Xhigh), "xhigh");
        assert_eq!(turn_effort(Effort::Max), "xhigh");
    }

    #[test]
    fn command_title_is_first_line_clipped_by_chars() {
        assert_eq!(command_title("git push origin main"), "git push origin main");
        assert_eq!(command_title("git status\nrm -rf x"), "git status");
        assert_eq!(command_title(""), "shell");
        assert_eq!(command_title("\nls"), "shell");
        assert_eq!(command_title("   \nls"), "shell");
        let title = command_title(&"я".repeat(300));
        assert_eq!(title.chars().count(), TITLE_LIMIT);
        assert!(title.chars().all(|c| c == 'я'));
    }

    #[test]
    fn file_change_title_names_first_path_and_count_of_rest() {
        assert_eq!(file_change_title(&[]), "Edit files");
        assert_eq!(file_change_title(&["/w/a.rs".to_string()]), "Edit /w/a.rs");
        let three = ["/w/a.rs", "/w/b.rs", "/w/c.rs"].map(str::to_string);
        assert_eq!(file_change_title(&three), "Edit /w/a.rs (+2 more)");
    }

    #[test]
    fn file_change_diff_prefixes_each_path() {
        let changes = vec![
            ("/w/a.rs".to_string(), "@@\n+x\n".to_string()),
            ("/w/b.rs".to_string(), "@@\n+y\n".to_string()),
        ];
        assert_eq!(
            file_change_diff(&changes),
            "--- /w/a.rs\n@@\n+x\n\n--- /w/b.rs\n@@\n+y\n"
        );
    }

    #[test]
    fn file_changes_of_reads_path_and_diff() {
        let item = json!({"type": "fileChange", "changes": [
            {"path": "/w/a.rs", "diff": "+1"},
            {"diff": "orphan"},
            {"path": "/w/b.rs"}
        ]});
        assert_eq!(
            file_changes_of(&item),
            vec![
                ("/w/a.rs".to_string(), "+1".to_string()),
                ("/w/b.rs".to_string(), String::new()),
            ]
        );
        assert!(file_changes_of(&json!({"type": "fileChange"})).is_empty());
    }

    #[test]
    fn rate_limit_windows_are_named_by_duration() {
        let limits = json!({
            "primary": {"usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1791543600},
            "secondary": {"usedPercent": 40, "windowDurationMins": 10080, "resetsAt": 1792026000}
        });
        assert_eq!(
            rate_limit_windows(&limits),
            vec![
                LimitWindow {
                    name: "five_hour".into(),
                    utilization: 0.12,
                    resets_at: Some(1791543600),
                },
                LimitWindow {
                    name: "seven_day".into(),
                    utilization: 0.40,
                    resets_at: Some(1792026000),
                },
            ]
        );
    }

    #[test]
    fn rate_limit_window_of_other_length_is_named_in_minutes() {
        let limits = json!({"primary": {"usedPercent": 5, "windowDurationMins": 1440}});
        assert_eq!(
            rate_limit_windows(&limits),
            vec![LimitWindow {
                name: "1440m".into(),
                utilization: 0.05,
                resets_at: None,
            }]
        );
    }

    #[test]
    fn rate_limit_window_without_duration_takes_its_slot_name() {
        let limits = json!({"secondary": {"usedPercent": 1}});
        assert_eq!(
            rate_limit_windows(&limits),
            vec![LimitWindow {
                name: "secondary".into(),
                utilization: 0.01,
                resets_at: None,
            }]
        );
    }

    #[test]
    fn rate_limit_windows_skip_missing_or_unusable_windows() {
        assert!(rate_limit_windows(&json!({})).is_empty());
        assert!(rate_limit_windows(&json!(null)).is_empty());
        assert!(rate_limit_windows(&json!({"primary": {"windowDurationMins": 300}})).is_empty());
        assert!(rate_limit_windows(&json!({"primary": 7})).is_empty());
    }

    #[test]
    fn command_ok_needs_completed_and_no_failing_exit_code() {
        assert!(command_ok("completed", Some(0)));
        assert!(!command_ok("completed", Some(1)));
        assert!(command_ok("completed", None));
        assert!(!command_ok("failed", None));
        assert!(!command_ok("declined", None));
        assert!(!command_ok("inProgress", None));
    }

    #[test]
    fn mcp_result_joins_text_parts_on_success() {
        let item = json!({"status": "completed", "result": {"content": [
            {"type": "text", "text": "sent"},
            {"type": "image", "data": "..."},
            {"type": "text", "text": "to Scout"}
        ]}});
        assert_eq!(mcp_result(&item), (true, "sent\nto Scout".to_string()));
        assert_eq!(mcp_result(&json!({"status": "completed"})), (true, String::new()));
    }

    #[test]
    fn mcp_result_uses_error_message_or_failed_otherwise() {
        let with_message = json!({"status": "failed", "error": {"message": "tool crashed"}});
        assert_eq!(mcp_result(&with_message), (false, "tool crashed".to_string()));
        assert_eq!(mcp_result(&json!({"status": "failed"})), (false, "failed".to_string()));
    }

    #[test]
    fn mcp_tool_name_joins_server_and_tool() {
        assert_eq!(
            mcp_tool_name(&json!({"server": "bandito", "tool": "crew_send"})),
            "bandito.crew_send"
        );
    }

    #[test]
    fn file_change_result_by_status() {
        assert_eq!(file_change_result("completed", 2), "applied 2 change(s)");
        assert_eq!(file_change_result("declined", 2), "declined");
        assert_eq!(file_change_result("failed", 0), "failed");
    }

    #[test]
    fn request_key_keeps_strings_and_prints_numbers() {
        assert_eq!(request_key(&json!("req-7")), "req-7");
        assert_eq!(request_key(&json!(0)), "0");
        assert_eq!(request_key(&json!(5)), "5");
    }

    #[test]
    fn error_text_falls_back_when_message_is_missing() {
        assert_eq!(error_text(&json!({"message": "boom"}), "x"), "boom");
        assert_eq!(error_text(&json!({"message": ""}), "x"), "x");
        assert_eq!(error_text(&NULL, "Codex turn failed"), "Codex turn failed");
    }

    #[test]
    fn plan_from_codex_names_known_plans() {
        let named = |id: &str, label: &str| {
            Some(Plan {
                id: id.into(),
                label: label.into(),
            })
        };
        assert_eq!(plan_from_codex("plus"), named("plus", "Plus"));
        assert_eq!(plan_from_codex("pro"), named("pro", "Pro"));
        assert_eq!(plan_from_codex("team"), named("team", "Team"));
        assert_eq!(plan_from_codex("business"), named("business", "Business"));
        assert_eq!(plan_from_codex("enterprise"), named("enterprise", "Enterprise"));
        assert_eq!(plan_from_codex("edu"), named("edu", "Edu"));
        assert_eq!(plan_from_codex("free"), named("free", "Free"));
        assert_eq!(plan_from_codex("PRO"), named("pro", "Pro"));
        assert_eq!(plan_from_codex(" pro "), named("pro", "Pro"));
    }

    #[test]
    fn plan_from_codex_names_other_plans_capitalized() {
        assert_eq!(
            plan_from_codex("prolite"),
            Some(Plan {
                id: "prolite".into(),
                label: "Prolite".into(),
            })
        );
    }

    #[test]
    fn plan_from_codex_needs_a_plan_type() {
        assert_eq!(plan_from_codex(""), None);
        assert_eq!(plan_from_codex("   "), None);
    }

    #[test]
    fn plan_of_account_prefers_account_then_rate_limits() {
        let plan = |id: &str, label: &str| {
            Some(Plan {
                id: id.into(),
                label: label.into(),
            })
        };
        let both = json!({"account": {"type": "chatgpt", "planType": "plus"}, "rateLimits": {"planType": "pro"}});
        assert_eq!(plan_of_account(&both), plan("plus", "Plus"));
        let only_limits = json!({"rateLimits": {"planType": "team"}});
        assert_eq!(plan_of_account(&only_limits), plan("team", "Team"));
        assert_eq!(plan_of_account(&json!({"account": {"type": "apiKey"}})), None);
        assert_eq!(plan_of_account(&NULL), None);
    }
}
