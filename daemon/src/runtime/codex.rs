//! Codex adapter: drives `codex app-server --stdio` (JSON-RPC 2.0, one message per
//! line). Protocol notes and a recorded transcript: `tests/fixtures/codex/`.

use super::process::{self, JsonProcess, LineSink, Router, locked};
use super::{
    ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, RuntimeStatus, Session, SpawnConfig, Spawned, clip_input,
};
use crate::event::{Decision, EventBody, LimitWindow, TOOL_OUTPUT_LIMIT, TurnStatus, Usage, truncate_output};
use anyhow::bail;
use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::process::Command;

/// Name of the CLI in logs and error messages.
const LABEL: &str = "codex";
/// JSON-RPC error code for a method we do not implement.
const METHOD_NOT_FOUND: i64 = -32601;
/// Tool input strings longer than this are clipped in events and approvals.
const INPUT_CLIP_BYTES: usize = 4096;
/// Max bytes of diff text shown in an approval.
const APPROVAL_DIFF_LIMIT: usize = 8192;
/// Max chars of a command used as a tool title.
const TITLE_LIMIT: usize = 200;

/// Stands in for a missing field, so lookups can borrow a `&Value`.
static NULL: Value = Value::Null;

pub struct CodexRuntime {
    program: String,
}

impl CodexRuntime {
    pub fn new() -> Self {
        Self::with_program("codex")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
        }
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
        cmd.current_dir(&cfg.cwd).envs(cfg.env.iter().map(|(k, v)| (k, v)));

        let state = Arc::new(Mutex::new(State::new()));
        let launch = Launch::from_config(&cfg);
        let router_state = Arc::clone(&state);
        let router_launch = launch.clone();
        let router: Router =
            Box::new(move |msg: &Value, sink: &LineSink| route(msg, &router_state, &router_launch, sink));
        let (proc, output) = JsonProcess::spawn(cmd, LABEL, router)?;
        let sink = proc.sink();
        let client =
            json!({"clientInfo": {"name": "bandito", "title": "Bandito", "version": env!("CARGO_PKG_VERSION")}});
        // A CLI that already died has closed its stdin. Its exit reaches the caller as `Exited`.
        if let Err(e) = locked(&state).request(&sink, "initialize", client, Pending::Init) {
            tracing::debug!("could not send initialize: {e}");
        }

        Ok(Spawned {
            session: Box::new(CodexSession { proc, sink, state }),
            output,
        })
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
    TurnStart,
    Other,
}

/// Session state shared by the router (server messages) and the session (our calls).
struct State {
    /// Id of our next request. JSON-RPC ids start at 1; `initialize` takes 1.
    next_id: i64,
    thread_id: Option<String>,
    turn_id: Option<String>,
    /// Messages sent before the thread exists, in order.
    queued: Vec<String>,
    /// Approval key → the server's JSON-RPC id, echoed back in the answer unchanged.
    approvals: HashMap<String, Value>,
    /// Our requests still waiting for an answer.
    requests: HashMap<i64, Pending>,
    /// Changes of each `fileChange` item, from `item/started`: (path, diff).
    file_changes: HashMap<String, Vec<(String, String)>>,
    last_usage: Option<Usage>,
}

impl State {
    fn new() -> Self {
        Self {
            next_id: 1,
            thread_id: None,
            turn_id: None,
            queued: Vec::new(),
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

    /// Start or resume the thread, as the spawn options say.
    fn thread_request(&mut self, sink: &LineSink, launch: &Launch) -> anyhow::Result<()> {
        let (method, mut params) = match &launch.resume {
            Some(thread_id) => ("thread/resume", json!({"threadId": thread_id})),
            None => ("thread/start", json!({"cwd": launch.cwd})),
        };
        params["approvalPolicy"] = json!("untrusted");
        params["sandbox"] = json!("workspace-write");
        if let Some(model) = &launch.model {
            params["model"] = json!(model);
        }
        if let Some(prompt) = &launch.system_prompt {
            params["developerInstructions"] = json!(prompt);
        }
        self.request(sink, method, params, Pending::ThreadStart)
    }

    /// `turn/start` for `text` on the current thread.
    fn start_turn(&mut self, sink: &LineSink, text: &str) -> anyhow::Result<()> {
        let Some(thread_id) = self.thread_id.clone() else {
            bail!("codex thread is not started");
        };
        // No `text_elements`: the recorded transcript matches the input item exactly.
        let input = json!([{"type": "text", "text": text}]);
        self.request(
            sink,
            "turn/start",
            json!({"threadId": thread_id, "input": input}),
            Pending::TurnStart,
        )
    }
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
        let (Some(thread_id), Some(turn_id)) = (st.thread_id.clone(), st.turn_id.clone()) else {
            return Ok(());
        };
        st.request(
            &self.sink,
            "turn/interrupt",
            json!({"threadId": thread_id, "turnId": turn_id}),
            Pending::Other,
        )
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
    let params = msg.get("params").unwrap_or(&NULL);
    match (msg.get("method").and_then(Value::as_str), msg.get("id")) {
        (Some(method), Some(id)) => server_request(&mut st, method, id, params, sink),
        (Some(method), None) => notification(&mut st, method, params),
        (None, Some(id)) => {
            let Some(request_id) = id.as_i64() else {
                return Vec::new();
            };
            match st.requests.remove(&request_id) {
                Some(kind) => answer(&mut st, msg, request_id, kind, launch, sink),
                None => Vec::new(),
            }
        }
        (None, None) => Vec::new(),
    }
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
fn answer(st: &mut State, msg: &Value, id: i64, kind: Pending, launch: &Launch, sink: &LineSink) -> Vec<RuntimeOutput> {
    if let Some(error) = msg.get("error") {
        let message = error_text(error, "request failed");
        return match kind {
            Pending::Init | Pending::ThreadStart => vec![error_event(format!("codex: {message}"))],
            Pending::TurnStart => turn_failed(format!("codex: {message}")),
            Pending::Other => {
                tracing::debug!("codex request {id} failed: {message}");
                Vec::new()
            }
        };
    }
    let result = msg.get("result").unwrap_or(&NULL);
    match kind {
        Pending::Init => {
            let initialized = json!({"jsonrpc": "2.0", "method": "initialized"});
            let started = process::push_line(sink, LABEL, &initialized).and_then(|()| st.thread_request(sink, launch));
            match started {
                Ok(()) => Vec::new(),
                Err(e) => vec![error_event(format!("codex: could not start the thread: {e}"))],
            }
        }
        Pending::ThreadStart => thread_started(st, result, sink),
        Pending::TurnStart => {
            st.turn_id = result.pointer("/turn/id").and_then(Value::as_str).map(str::to_string);
            Vec::new()
        }
        Pending::Other => Vec::new(),
    }
}

/// The thread exists: announce it, then send the messages queued before it.
fn thread_started(st: &mut State, result: &Value, sink: &LineSink) -> Vec<RuntimeOutput> {
    let Some(thread_id) = result
        .pointer("/thread/id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
    else {
        return vec![error_event("codex: thread response has no thread id".to_string())];
    };
    let thread_id = thread_id.to_string();
    st.thread_id = Some(thread_id.clone());
    let mut out = vec![RuntimeOutput::SessionId(thread_id)];
    for text in std::mem::take(&mut st.queued) {
        if let Err(e) = st.start_turn(sink, &text) {
            out.extend(turn_failed(format!("codex: {e}")));
        }
    }
    out
}

/// Notifications (no `id`): stream deltas, items, usage and turn ends.
fn notification(st: &mut State, method: &str, params: &Value) -> Vec<RuntimeOutput> {
    let mut out = Vec::new();
    match method {
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
    st.turn_id = None;
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
    vec![
        error_event(message),
        RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: String::new(),
            status: TurnStatus::Error,
            usage: None,
            cost_usd: None,
        }),
    ]
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
        (true, text)
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
}
