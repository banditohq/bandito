//! Grok adapter: drives `grok agent --no-leader stdio` over ACP (Agent Client
//! Protocol): JSON-RPC 2.0, one message per line. Protocol shapes and replay
//! scripts live in `tests/fixtures/grok/`; the contract is `tests/grok_runtime.rs`.

use super::process::{self, JsonProcess, LineSink, Router, locked};
use super::{
    ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, RuntimeStatus, Session, SpawnConfig, Spawned, clip_input,
};
use crate::event::{Decision, EventBody, TOOL_OUTPUT_LIMIT, TurnStatus, truncate_output};
use crate::store::Effort;
use anyhow::{anyhow, bail};
use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::process::Command;

const LABEL: &str = "grok";
/// ACP protocol version we speak.
const PROTOCOL_VERSION: u64 = 1;
/// Our request ids: `initialize` = 1, `session/new` or `session/load` = 2, then one per prompt from 3 on.
const INIT_ID: u64 = 1;
const SESSION_ID: u64 = 2;
const FIRST_PROMPT_ID: u64 = 3;
/// Tool input strings longer than this are clipped in events and approvals.
const INPUT_CLIP_BYTES: usize = 4096;
/// Max bytes of diff text shown in an approval.
const APPROVAL_DIFF_LIMIT: usize = 8192;
/// Reported when an Allow has no one-time option, so the action was denied instead.
const ALLOW_REFUSED: &str = "Grok offered no one-time approval for this action, so it was denied";

pub struct GrokRuntime {
    program: String,
}

impl GrokRuntime {
    pub fn new() -> Self {
        Self::with_program("grok")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
        }
    }
}

impl Default for GrokRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Runtime for GrokRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Grok
    }

    async fn status(&self) -> RuntimeStatus {
        let version = super::probe_version(&self.program).await;
        RuntimeStatus {
            kind: RuntimeKind::Grok,
            installed: version.is_some(),
            version,
            logged_in: None,
            detail: None,
        }
    }

    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned> {
        let program = cfg.program.clone().unwrap_or_else(|| PathBuf::from(&self.program));
        let mut cmd = Command::new(&program);
        cmd.arg("agent").arg("--no-leader");
        if let Some(model) = &cfg.model {
            cmd.arg("--model").arg(model);
        }
        if let Some(effort) = cfg.effort {
            cmd.arg("--reasoning-effort").arg(reasoning_effort(effort));
        }
        // `cfg.extra_dirs` is not passed on: Grok has no option for extra directories, so they are ignored here.
        cmd.arg("stdio");
        cmd.current_dir(&cfg.cwd).envs(cfg.env.iter().map(|(k, v)| (k, v)));
        // Marks the CLI and its children for `host.processes` (see docs/ARCHITECTURE.md#host).
        cmd.env("BANDITO_AGENT_ID", &cfg.agent_id);

        let state = Arc::new(Mutex::new(State::new(cfg.system_prompt.clone())));
        let handshake = Handshake {
            cwd: cfg.cwd.clone(),
            resume: cfg.resume.clone(),
            mcp: cfg.mcp.clone(),
        };
        let router_state = Arc::clone(&state);
        let router: Router = Box::new(move |msg: &Value, sink: &LineSink| route(msg, &router_state, &handshake, sink));
        let cmd = crate::workspace::confine(cmd, cfg.workspace.as_ref());
        let (proc, output) = JsonProcess::spawn(cmd, LABEL, router)?;
        let init = json!({
            "jsonrpc": "2.0",
            "id": INIT_ID,
            "method": "initialize",
            "params": {
                "protocolVersion": PROTOCOL_VERSION,
                "clientCapabilities": {
                    "fs": {"readTextFile": false, "writeTextFile": false},
                    "terminal": false
                }
            }
        });
        // A CLI that already died (e.g. not logged in) has closed its stdin. Its exit
        // reaches the caller as `Exited`, so a failed write here is not an error.
        let _ = proc.send(&init);

        Ok(Spawned {
            session: Box::new(GrokSession { proc, state }),
            output,
        })
    }
}

/// `--reasoning-effort` value. Grok has no level above `high`, so `xhigh` and `max` are sent as `high`.
fn reasoning_effort(effort: Effort) -> &'static str {
    match effort {
        Effort::Low => "low",
        Effort::Medium => "medium",
        Effort::High | Effort::Xhigh | Effort::Max => "high",
    }
}

/// What the handshake sends once `initialize` is answered.
struct Handshake {
    cwd: PathBuf,
    /// ACP session id to load; `None` creates a new session.
    resume: Option<String>,
    mcp: Option<(PathBuf, Vec<String>)>,
}

/// State shared by the router (pump task) and the session (caller task).
#[derive(Default)]
struct State {
    system_prompt: Option<String>,
    /// The handshake failed. Sends are refused from then on.
    failed: bool,
    /// Set once `session/new` or `session/load` is answered.
    session_id: Option<String>,
    /// `session/load` in flight. Replayed history is dropped until it is answered.
    loading: bool,
    /// Id of the next `session/prompt`.
    next_id: u64,
    /// Prompts waiting for their answer.
    prompt_ids: HashSet<u64>,
    /// Texts sent before the session was ready. Sent in order once it is.
    queued: Vec<String>,
    /// The system prompt is already in the session history (loaded), or was sent.
    first_prompt_sent: bool,
    /// Approvals waiting for an answer, by key.
    pending: HashMap<String, PendingApproval>,
    /// Approvals withdrawn by interrupt. Reported on the next message from the CLI.
    cancelled_keys: Vec<String>,
    /// Texts dropped by interrupt before the session was ready. Each is reported as an
    /// interrupted turn on the next message from the CLI.
    interrupted_queued: usize,
    /// Errors from answers and the handshake. Reported on the next message from the CLI.
    notices: Vec<String>,
    /// Agent text not yet emitted as a message.
    text_buf: String,
    /// Tool calls that already produced their `ToolResult`.
    finished_tools: HashSet<String>,
}

impl State {
    fn new(system_prompt: Option<String>) -> Self {
        Self {
            system_prompt,
            next_id: FIRST_PROMPT_ID,
            ..Self::default()
        }
    }
}

/// A permission request from the CLI, kept until it is answered.
struct PendingApproval {
    /// The CLI's request id, echoed back in the answer.
    request_id: Value,
    options: Vec<ApprovalOption>,
}

struct ApprovalOption {
    option_id: String,
    /// `allow_once`, `allow_always`, `reject_once`, `reject_always`, ...
    kind: String,
}

/// A live Grok session. Frames go out through [`JsonProcess::send`]; the
/// router keeps [`State`] current and the process wrapper reports the exit.
struct GrokSession {
    proc: JsonProcess,
    state: Arc<Mutex<State>>,
}

#[async_trait]
impl Session for GrokSession {
    async fn send(&mut self, text: &str) -> anyhow::Result<()> {
        let frame = {
            let mut guard = locked(&self.state);
            let st = &mut *guard;
            if st.failed {
                bail!("grok session failed to start");
            }
            match st.session_id.clone() {
                Some(session) => prompt_frame(st, &session, text),
                None => {
                    st.queued.push(text.to_string());
                    return Ok(());
                }
            }
        };
        self.proc.send(&frame)
    }

    async fn interrupt(&mut self) -> anyhow::Result<()> {
        let mut guard = locked(&self.state);
        let st = &mut *guard;
        let Some(session) = st.session_id.clone() else {
            // Not ready yet: nothing was sent for these texts, so they are dropped here.
            st.interrupted_queued += std::mem::take(&mut st.queued).len();
            return Ok(());
        };
        if st.prompt_ids.is_empty() {
            return Ok(());
        }
        // Every frame goes out even if one send fails: open approvals must still be
        // answered. The first error is returned after all of them.
        let mut result = self.proc.send(&json!({
            "jsonrpc": "2.0",
            "method": "session/cancel",
            "params": {"sessionId": session}
        }));
        // ACP: open permission requests must be answered with `cancelled`.
        // The CLI reports them as ApprovalCancelled on its next message.
        for (key, approval) in st.pending.drain() {
            let sent = self.proc.send(&cancelled_frame(&approval.request_id));
            if result.is_ok() {
                result = sent;
            }
            st.cancelled_keys.push(key);
        }
        result
    }

    async fn resolve(&mut self, key: &str, decision: Decision) -> anyhow::Result<()> {
        let mut guard = locked(&self.state);
        answer_pending(&mut guard, key, decision, |frame| self.proc.send(frame))
    }

    async fn shutdown(self: Box<Self>) {
        let this = *self;
        this.proc.shutdown().await;
    }
}

/// Answer a pending approval through `send`. The record is removed only once the
/// answer went out, so a failed send leaves the approval answerable.
fn answer_pending(
    st: &mut State,
    key: &str,
    decision: Decision,
    send: impl FnOnce(&Value) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let approval = st.pending.get(key).ok_or_else(|| anyhow!("unknown approval {key}"))?;
    let outcome = match choose_option(&approval.options, decision) {
        Some(option_id) => json!({"outcome": "selected", "optionId": option_id}),
        None => json!({"outcome": "cancelled"}),
    };
    let notice = (decision == Decision::Allow && !approval.options.iter().any(|o| o.kind == "allow_once"))
        .then(|| ALLOW_REFUSED.to_string());
    send(&json!({
        "jsonrpc": "2.0",
        "id": approval.request_id,
        "result": {"outcome": outcome}
    }))?;
    st.pending.remove(key);
    st.notices.extend(notice);
    Ok(())
}

/// The option an answer selects. Allow takes a one-time allow, else a one-time reject.
/// Deny takes a one-time reject, else a permanent one. `allow_always` is never chosen.
/// `None` means cancel.
fn choose_option(options: &[ApprovalOption], decision: Decision) -> Option<&str> {
    let (preferred, fallback) = match decision {
        Decision::Allow => ("allow_once", "reject_once"),
        Decision::Deny => ("reject_once", "reject_always"),
    };
    options
        .iter()
        .find(|o| o.kind == preferred)
        .or_else(|| options.iter().find(|o| o.kind == fallback))
        .map(|o| o.option_id.as_str())
}

/// Route one parsed stdout message. Runs on the pump task.
fn route(msg: &Value, state: &Mutex<State>, handshake: &Handshake, sink: &LineSink) -> Vec<RuntimeOutput> {
    let mut guard = locked(state);
    let st = &mut *guard;
    // Owed before anything else the CLI says: withdrawn approvals, interrupted queued
    // turns, and errors from answers that could not be reported at the time.
    let mut out: Vec<RuntimeOutput> = st
        .cancelled_keys
        .drain(..)
        .map(|key| RuntimeOutput::ApprovalCancelled { key })
        .collect();
    out.extend((0..std::mem::take(&mut st.interrupted_queued)).map(|_| turn_completed(TurnStatus::Interrupted)));
    out.extend(st.notices.drain(..).map(error_event));
    match (msg.get("method").and_then(Value::as_str), msg.get("id")) {
        (Some(method), Some(id)) => incoming_request(id, method, msg, st, sink, &mut out),
        (Some(method), None) => notification(method, msg, st, &mut out),
        (None, Some(id)) => response(id, msg, st, handshake, sink, &mut out),
        (None, None) => {}
    }
    out
}

/// A request from the CLI: a permission prompt, or something we do not support.
fn incoming_request(
    id: &Value,
    method: &str,
    msg: &Value,
    st: &mut State,
    sink: &LineSink,
    out: &mut Vec<RuntimeOutput>,
) {
    if method == "session/request_permission" {
        let params = msg.get("params").unwrap_or(&Value::Null);
        permission_request(id, params, st, out);
    } else {
        let frame = json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": {"code": -32601, "message": format!("Unsupported request: {method}")}
        });
        reply(sink, &frame, out);
    }
}

fn notification(method: &str, msg: &Value, st: &mut State, out: &mut Vec<RuntimeOutput>) {
    // Replayed history during session/load is not shown again.
    if method == "session/update"
        && !st.loading
        && let Some(update) = msg.pointer("/params/update")
    {
        session_update(update, st, out);
    }
}

/// An answer to one of our requests. Answers with other ids are ignored.
fn response(
    id: &Value,
    msg: &Value,
    st: &mut State,
    handshake: &Handshake,
    sink: &LineSink,
    out: &mut Vec<RuntimeOutput>,
) {
    let Some(id) = id.as_u64() else {
        return;
    };
    if id == INIT_ID {
        initialized(msg, handshake, st, sink, out);
    } else if id == SESSION_ID {
        session_ready(msg, handshake, st, sink, out);
    } else if st.prompt_ids.remove(&id) {
        turn_done(msg, st, sink, out);
    }
}

fn initialized(msg: &Value, handshake: &Handshake, st: &mut State, sink: &LineSink, out: &mut Vec<RuntimeOutput>) {
    if let Some(err) = msg.get("error") {
        fail(st, out, format!("initialize failed: {}", error_message(err)));
        return;
    }
    // Checked, not fatal: the handshake goes on.
    let version = msg.pointer("/result/protocolVersion");
    if version.and_then(Value::as_u64) != Some(PROTOCOL_VERSION) {
        let shown = version.map_or_else(|| "missing".to_string(), Value::to_string);
        out.push(error_event(format!("Unsupported ACP version {shown} from grok")));
    }
    let servers = match &handshake.mcp {
        Some((program, args)) => json!([{
            "name": "bandito",
            "command": program.display().to_string(),
            "args": args,
            "env": []
        }]),
        None => json!([]),
    };
    let cwd = handshake.cwd.display().to_string();
    let can_load = msg
        .pointer("/result/agentCapabilities/loadSession")
        .and_then(Value::as_bool)
        == Some(true);
    let request = match &handshake.resume {
        Some(session) if can_load => {
            st.loading = true;
            // The loaded history already holds the system prompt from the first prompt.
            st.first_prompt_sent = true;
            json!({
                "jsonrpc": "2.0",
                "id": SESSION_ID,
                "method": "session/load",
                "params": {"sessionId": session, "cwd": cwd, "mcpServers": servers}
            })
        }
        Some(_) => {
            out.push(error_event("grok can't resume sessions; starting a new one".into()));
            new_session_request(&cwd, &servers)
        }
        None => new_session_request(&cwd, &servers),
    };
    reply(sink, &request, out);
}

fn new_session_request(cwd: &str, servers: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": SESSION_ID,
        "method": "session/new",
        "params": {"cwd": cwd, "mcpServers": servers}
    })
}

fn session_ready(msg: &Value, handshake: &Handshake, st: &mut State, sink: &LineSink, out: &mut Vec<RuntimeOutput>) {
    // Whether this answers a session/load we sent (not a fallback to session/new).
    let loading = std::mem::take(&mut st.loading);
    if let Some(err) = msg.get("error") {
        fail(st, out, error_message(err));
        return;
    }
    // session/load may answer with a null result: the id is the one we asked for.
    let session = match (loading, &handshake.resume) {
        (true, Some(id)) => id.clone(),
        _ => match msg.pointer("/result/sessionId").and_then(Value::as_str) {
            Some(id) => id.to_string(),
            None => {
                fail(st, out, "session/new returned no sessionId".into());
                return;
            }
        },
    };
    st.session_id = Some(session.clone());
    out.push(RuntimeOutput::SessionId(session.clone()));
    for text in std::mem::take(&mut st.queued) {
        let frame = prompt_frame(st, &session, &text);
        reply(sink, &frame, out);
    }
}

/// The handshake failed: report it, end every queued turn, and refuse further sends.
fn fail(st: &mut State, out: &mut Vec<RuntimeOutput>, message: String) {
    st.failed = true;
    st.loading = false;
    out.push(error_event(format!("grok: {message}")));
    for _ in st.queued.drain(..) {
        out.push(turn_completed(TurnStatus::Error));
    }
}

/// A `session/prompt` answer: the turn is over. Approvals still open are withdrawn first.
fn turn_done(msg: &Value, st: &mut State, sink: &LineSink, out: &mut Vec<RuntimeOutput>) {
    out.extend(flush_text(st));
    let mut open: Vec<String> = st.pending.keys().cloned().collect();
    open.sort_unstable();
    for key in open {
        if let Some(approval) = st.pending.remove(&key) {
            reply(sink, &cancelled_frame(&approval.request_id), out);
            out.push(RuntimeOutput::ApprovalCancelled { key });
        }
    }
    let status = match msg.get("error") {
        Some(err) => {
            let message = str_at(err, "message").unwrap_or("unknown error");
            out.push(error_event(match str_at(err, "data") {
                Some(data) => format!("{message}: {data}"),
                None => message.to_string(),
            }));
            TurnStatus::Error
        }
        None => match msg.pointer("/result/stopReason").and_then(Value::as_str) {
            Some("cancelled") => TurnStatus::Interrupted,
            Some("refusal") => {
                out.push(error_event("grok refused the request".into()));
                TurnStatus::Error
            }
            // end_turn, max_tokens, max_turn_requests, and anything unknown.
            _ => TurnStatus::Ok,
        },
    };
    out.push(turn_completed(status));
}

fn session_update(update: &Value, st: &mut State, out: &mut Vec<RuntimeOutput>) {
    match str_at(update, "sessionUpdate") {
        Some("agent_message_chunk") => {
            if let Some(text) = text_chunk(update) {
                st.text_buf.push_str(text);
                out.push(RuntimeOutput::Event(EventBody::MessageDelta { text: text.to_string() }));
            }
        }
        Some("tool_call") => tool_call(update, st, out),
        Some("tool_call_update") => tool_result(update, st, out),
        // Thoughts, plans, command lists, modes, session info and other vendor updates are not shown.
        _ => {}
    }
}

fn tool_call(update: &Value, st: &mut State, out: &mut Vec<RuntimeOutput>) {
    out.extend(flush_text(st));
    let kind = non_empty(update, "kind");
    let title = non_empty(update, "title").or(kind).unwrap_or("tool");
    let raw_input = update.get("rawInput").cloned().unwrap_or(Value::Null);
    out.push(RuntimeOutput::Event(EventBody::ToolCall {
        call_id: str_at(update, "toolCallId").unwrap_or_default().to_string(),
        tool: kind.unwrap_or("tool").to_string(),
        title: title.to_string(),
        input: clip_input(&raw_input, INPUT_CLIP_BYTES),
    }));
    // A call can arrive already finished: its result follows the same rules as an update.
    tool_result(update, st, out);
}

/// The `ToolResult` of a call whose status is final (`completed` or `failed`). Once per call.
fn tool_result(update: &Value, st: &mut State, out: &mut Vec<RuntimeOutput>) {
    let ok = match str_at(update, "status") {
        Some("completed") => true,
        Some("failed") => false,
        // pending and in_progress are not results.
        _ => return,
    };
    let Some(call_id) = str_at(update, "toolCallId") else {
        return;
    };
    if !st.finished_tools.insert(call_id.to_string()) {
        return;
    }
    out.push(RuntimeOutput::Event(EventBody::ToolResult {
        call_id: call_id.to_string(),
        ok,
        output: tool_output(update),
    }));
}

/// The text a finished tool call reports: its text content and edit notices, else its raw output.
fn tool_output(update: &Value) -> String {
    let parts: Vec<String> = array(update, "content")
        .iter()
        .filter_map(|item| match str_at(item, "type") {
            Some("content") => item
                .get("content")
                .filter(|c| str_at(c, "type") == Some("text"))
                .and_then(|c| str_at(c, "text"))
                .map(str::to_string),
            Some("diff") => str_at(item, "path").map(|path| format!("Edited {path}")),
            _ => None,
        })
        .collect();
    let mut output = parts.join("\n");
    if output.is_empty()
        && let Some(raw) = update.get("rawOutput").filter(|r| !r.is_null())
    {
        output = match raw.as_str() {
            Some(text) => text.to_string(),
            None => raw.to_string(),
        };
    }
    truncate_output(&output, TOOL_OUTPUT_LIMIT)
}

fn permission_request(id: &Value, params: &Value, st: &mut State, out: &mut Vec<RuntimeOutput>) {
    // Text the agent wrote before asking shows up before the approval, as it does before a tool call.
    out.extend(flush_text(st));
    let key = request_key(id);
    let call = params.get("toolCall").unwrap_or(&Value::Null);
    let content = array(call, "content");
    let kind = non_empty(call, "kind");
    let tool = kind.unwrap_or("tool").to_string();
    let title = non_empty(call, "title").or(kind).unwrap_or("tool").to_string();
    let raw_input = call.get("rawInput").cloned().unwrap_or(Value::Null);
    let command = str_at(&raw_input, "command").map(str::to_string);
    let mut paths: Vec<String> = array(call, "locations")
        .iter()
        .filter_map(|loc| str_at(loc, "path"))
        .map(str::to_string)
        .collect();
    if paths.is_empty() {
        paths = diff_items(content)
            .filter_map(|d| str_at(d, "path"))
            .map(str::to_string)
            .collect();
    }
    let call_id = str_at(call, "toolCallId").unwrap_or(key.as_str()).to_string();
    let options = array(params, "options").iter().filter_map(approval_option).collect();

    st.pending.insert(
        key.clone(),
        PendingApproval {
            request_id: id.clone(),
            options,
        },
    );
    out.push(RuntimeOutput::Approval(ApprovalRequest {
        key,
        call_id,
        tool,
        title,
        command,
        diff: approval_diff(content),
        paths,
        input: clip_input(&raw_input, INPUT_CLIP_BYTES),
    }));
}

/// Key of a permission request, from its JSON-RPC id. A string id that could be read as
/// another id kind gets an `s:` prefix, so it never shares a key with a numeric id.
fn request_key(id: &Value) -> String {
    match id {
        Value::String(s) if looks_like_other_id(s) => format!("s:{s}"),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Whether a string id collides with a numeric or `null` id once keyed, or with
/// the `s:` form itself.
fn looks_like_other_id(s: &str) -> bool {
    s.parse::<f64>().is_ok() || s == "null" || s.starts_with("s:")
}

fn approval_option(o: &Value) -> Option<ApprovalOption> {
    Some(ApprovalOption {
        option_id: str_at(o, "optionId")?.to_string(),
        kind: str_at(o, "kind").unwrap_or_default().to_string(),
    })
}

/// Unified-style text of the `diff` items in a tool call's content, capped for an approval.
fn approval_diff(content: &[Value]) -> Option<String> {
    let mut lines = Vec::new();
    for d in diff_items(content) {
        lines.push(format!("--- {}", str_at(d, "path").unwrap_or_default()));
        lines.extend(prefixed_lines(str_at(d, "oldText").unwrap_or_default(), "- "));
        lines.extend(prefixed_lines(str_at(d, "newText").unwrap_or_default(), "+ "));
    }
    if lines.is_empty() {
        None
    } else {
        Some(truncate_output(&lines.join("\n"), APPROVAL_DIFF_LIMIT))
    }
}

fn diff_items(content: &[Value]) -> impl Iterator<Item = &Value> {
    content.iter().filter(|c| str_at(c, "type") == Some("diff"))
}

fn prefixed_lines(text: &str, prefix: &str) -> Vec<String> {
    text.lines().map(|line| format!("{prefix}{line}")).collect()
}

/// The `session/prompt` frame for `text`. Registers its id as awaiting an answer.
fn prompt_frame(st: &mut State, session: &str, text: &str) -> Value {
    let body = wrap_first_prompt(st, text);
    let id = st.next_id;
    st.next_id += 1;
    st.prompt_ids.insert(id);
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": "session/prompt",
        "params": {"sessionId": session, "prompt": [{"type": "text", "text": body}]}
    })
}

/// The first prompt of a session carries the agent's system prompt, since ACP has no field for it.
/// A loaded session already has it in its history, so it is not repeated there.
fn wrap_first_prompt(st: &mut State, text: &str) -> String {
    if st.first_prompt_sent {
        return text.to_string();
    }
    st.first_prompt_sent = true;
    match &st.system_prompt {
        Some(system) => format!("Instructions from Bandito:\n{system}\n\nUser message:\n{text}"),
        None => text.to_string(),
    }
}

/// Emit the buffered agent text as one message, if there is any.
fn flush_text(st: &mut State) -> Option<RuntimeOutput> {
    let text = std::mem::take(&mut st.text_buf);
    if text.trim().is_empty() {
        None
    } else {
        Some(RuntimeOutput::Event(EventBody::MessageAssistant { text }))
    }
}

fn turn_completed(status: TurnStatus) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::TurnCompleted {
        turn_id: String::new(),
        status,
        usage: None,
        cost_usd: None,
    })
}

fn error_event(message: String) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::Error { message })
}

/// The answer that withdraws a permission request.
fn cancelled_frame(request_id: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {"outcome": {"outcome": "cancelled"}}
    })
}

/// Queue a frame for the CLI. If the session is closed, the failure becomes an error event.
fn reply(sink: &LineSink, frame: &Value, out: &mut Vec<RuntimeOutput>) {
    if let Err(e) = process::push_line(sink, LABEL, frame) {
        out.push(error_event(e.to_string()));
    }
}

fn text_chunk(update: &Value) -> Option<&str> {
    let content = update.get("content").filter(|c| str_at(c, "type") == Some("text"))?;
    str_at(content, "text")
}

fn error_message(err: &Value) -> String {
    str_at(err, "message").unwrap_or("unknown error").to_string()
}

fn str_at<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key)?.as_str()
}

/// Non-empty string field of a JSON object.
fn non_empty<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    str_at(v, key).filter(|s| !s.is_empty())
}

/// Array field of a JSON object, or an empty slice.
fn array<'a>(v: &'a Value, key: &str) -> &'a [Value] {
    match v.get(key).and_then(Value::as_array) {
        Some(items) => items,
        None => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    #[test]
    fn reasoning_effort_names_grok_levels_and_caps_at_high() {
        assert_eq!(reasoning_effort(Effort::Low), "low");
        assert_eq!(reasoning_effort(Effort::Medium), "medium");
        assert_eq!(reasoning_effort(Effort::High), "high");
        assert_eq!(reasoning_effort(Effort::Xhigh), "high");
        assert_eq!(reasoning_effort(Effort::Max), "high");
    }

    fn option(option_id: &str, kind: &str) -> ApprovalOption {
        ApprovalOption {
            option_id: option_id.into(),
            kind: kind.into(),
        }
    }

    fn handshake() -> Handshake {
        Handshake {
            cwd: PathBuf::from("/work"),
            resume: None,
            mcp: None,
        }
    }

    fn test_sink() -> (LineSink, mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Arc::new(Mutex::new(Some(tx))), rx)
    }

    #[test]
    fn allow_takes_allow_once_and_never_allow_always() {
        let options = [option("always", "allow_always"), option("once", "allow_once")];
        assert_eq!(choose_option(&options, Decision::Allow), Some("once"));
        // Without a one-time allow, Allow falls back to a one-time reject, never to allow_always.
        let only_always = [option("always", "allow_always")];
        assert_eq!(choose_option(&only_always, Decision::Allow), None);
        let always_and_no = [option("always", "allow_always"), option("no", "reject_once")];
        assert_eq!(choose_option(&always_and_no, Decision::Allow), Some("no"));
    }

    #[test]
    fn deny_takes_reject_once_then_reject_always_then_cancels() {
        let options = [option("never", "reject_always"), option("no", "reject_once")];
        assert_eq!(choose_option(&options, Decision::Deny), Some("no"));
        let only_always = [option("never", "reject_always")];
        assert_eq!(choose_option(&only_always, Decision::Deny), Some("never"));
        let allow_only = [option("y", "allow_once")];
        assert_eq!(choose_option(&allow_only, Decision::Deny), None);
        assert_eq!(choose_option(&[], Decision::Allow), None);
    }

    #[test]
    fn allow_without_one_time_option_is_denied_with_a_notice() {
        let mut st = State::new(None);
        st.pending.insert(
            "7".into(),
            PendingApproval {
                request_id: json!(7),
                options: vec![option("always", "allow_always"), option("no", "reject_once")],
            },
        );
        let mut sent: Vec<Value> = Vec::new();
        answer_pending(&mut st, "7", Decision::Allow, |frame| {
            sent.push(frame.clone());
            Ok(())
        })
        .expect("answered");
        assert_eq!(
            sent[0]["result"]["outcome"],
            json!({"outcome": "selected", "optionId": "no"})
        );
        assert_eq!(st.notices, vec![ALLOW_REFUSED.to_string()]);
        assert!(st.pending.is_empty());
    }

    #[test]
    fn a_failed_answer_leaves_the_approval_open_and_an_answered_one_is_gone() {
        let mut st = State::new(None);
        st.pending.insert(
            "7".into(),
            PendingApproval {
                request_id: json!(7),
                options: vec![option("y", "allow_once")],
            },
        );
        assert!(answer_pending(&mut st, "7", Decision::Allow, |_| bail!("closed")).is_err());
        assert!(st.pending.contains_key("7"));
        assert!(st.notices.is_empty());

        assert!(answer_pending(&mut st, "7", Decision::Allow, |_| Ok(())).is_ok());
        assert!(!st.pending.contains_key("7"));
        assert!(answer_pending(&mut st, "7", Decision::Allow, |_| Ok(())).is_err());
    }

    #[test]
    fn numeric_and_string_ids_never_share_a_key() {
        assert_eq!(request_key(&json!(7)), "7");
        assert_eq!(request_key(&json!("p-1")), "p-1");
        assert_eq!(request_key(&json!("7")), "s:7");
        assert_eq!(request_key(&json!("s:7")), "s:s:7");
        assert_eq!(request_key(&json!("null")), "s:null");
        assert_eq!(request_key(&json!(null)), "null");
    }

    #[test]
    fn approval_diff_lists_removed_and_added_lines() {
        let content = json!([
            {"type": "content", "content": {"type": "text", "text": "ignored"}},
            {"type": "diff", "path": "/etc/hosts", "oldText": "a\nb\n", "newText": "c\n"}
        ]);
        let items = content.as_array().expect("array");
        assert_eq!(approval_diff(items).as_deref(), Some("--- /etc/hosts\n- a\n- b\n+ c"));
        assert_eq!(approval_diff(&[]), None);
    }

    #[test]
    fn tool_output_text_diff_raw_and_empty() {
        let text = json!({"content": [{"type": "content", "content": {"type": "text", "text": "0 vulnerabilities"}}]});
        assert_eq!(tool_output(&text), "0 vulnerabilities");

        let diff = json!({"content": [{"type": "diff", "path": "/a.rs", "oldText": "x", "newText": "y"}]});
        assert_eq!(tool_output(&diff), "Edited /a.rs");

        let raw_string = json!({"status": "completed", "rawOutput": "plain"});
        assert_eq!(tool_output(&raw_string), "plain");

        let raw_object = json!({"status": "completed", "rawOutput": {"exit": 0}});
        assert_eq!(tool_output(&raw_object), r#"{"exit":0}"#);

        let content_wins = json!({"content": [{"type": "content", "content": {"type": "text", "text": "shown"}}], "rawOutput": "hidden"});
        assert_eq!(tool_output(&content_wins), "shown");

        let empty = json!({"status": "completed"});
        assert_eq!(tool_output(&empty), "");
    }

    #[test]
    fn system_prompt_wraps_only_the_first_prompt() {
        let mut st = State::new(Some("Be brief.".into()));
        assert_eq!(
            wrap_first_prompt(&mut st, "hi"),
            "Instructions from Bandito:\nBe brief.\n\nUser message:\nhi"
        );
        assert_eq!(wrap_first_prompt(&mut st, "again"), "again");

        let mut plain = State::new(None);
        assert_eq!(wrap_first_prompt(&mut plain, "hi"), "hi");
    }

    #[test]
    fn sends_queued_before_ready_go_out_in_order() {
        let state = Mutex::new(State::new(Some("Be brief.".into())));
        locked(&state).queued = vec!["one".into(), "two".into()];
        let (sink, mut rx) = test_sink();
        let answer = json!({"jsonrpc": "2.0", "id": SESSION_ID, "result": {"sessionId": "s1"}});

        let out = route(&answer, &state, &handshake(), &sink);
        assert_eq!(out, vec![RuntimeOutput::SessionId("s1".into())]);

        let first: Value = serde_json::from_str(&rx.try_recv().expect("first frame")).expect("json");
        let second: Value = serde_json::from_str(&rx.try_recv().expect("second frame")).expect("json");
        assert_eq!(first["id"], 3);
        assert_eq!(first["params"]["sessionId"], "s1");
        assert_eq!(
            first["params"]["prompt"][0]["text"],
            "Instructions from Bandito:\nBe brief.\n\nUser message:\none"
        );
        assert_eq!(second["id"], 4);
        assert_eq!(second["params"]["prompt"][0]["text"], "two");
    }

    #[test]
    fn replayed_history_during_load_is_ignored() {
        let state = Mutex::new(State {
            loading: true,
            ..State::new(None)
        });
        let (sink, _rx) = test_sink();
        let replay = json!({
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {"sessionId": "s", "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "old"}
            }}
        });
        assert!(route(&replay, &state, &handshake(), &sink).is_empty());
        assert!(locked(&state).text_buf.is_empty());
    }

    #[test]
    fn a_completed_tool_call_yields_one_result() {
        let mut st = State::new(None);
        let mut out = Vec::new();
        let done = json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "c1",
            "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": "ok"}}]
        });
        session_update(&done, &mut st, &mut out);
        session_update(&done, &mut st, &mut out);
        assert_eq!(
            out,
            vec![RuntimeOutput::Event(EventBody::ToolResult {
                call_id: "c1".into(),
                ok: true,
                output: "ok".into(),
            })]
        );
    }

    #[test]
    fn a_call_that_arrives_completed_and_is_repeated_yields_one_result() {
        let mut st = State::new(None);
        let mut out = Vec::new();
        let call = json!({
            "sessionUpdate": "tool_call",
            "toolCallId": "c2",
            "title": "ls",
            "kind": "execute",
            "status": "failed",
            "content": [{"type": "content", "content": {"type": "text", "text": "boom"}}]
        });
        let repeat = json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "c2",
            "status": "failed"
        });
        session_update(&call, &mut st, &mut out);
        session_update(&repeat, &mut st, &mut out);
        let results: Vec<&RuntimeOutput> = out
            .iter()
            .filter(|o| matches!(o, RuntimeOutput::Event(EventBody::ToolResult { .. })))
            .collect();
        assert_eq!(
            results,
            vec![&RuntimeOutput::Event(EventBody::ToolResult {
                call_id: "c2".into(),
                ok: false,
                output: "boom".into(),
            })]
        );
    }
}
