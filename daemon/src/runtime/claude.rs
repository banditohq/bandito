//! Claude Code adapter: drives the official `claude` CLI in print mode with
//! stream-json on both sides and answers permission prompts as the host.
//! Protocol notes and a real transcript: `tests/fixtures/claude/`.

use super::{
    ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, RuntimeStatus, Session, SpawnConfig, Spawned, clip_input,
};
use crate::event::{Decision, EventBody, LimitWindow, TOOL_OUTPUT_LIMIT, TurnStatus, Usage, truncate_output};
use anyhow::{Context, bail};
use async_trait::async_trait;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::timeout;

/// Message sent back to Claude when the human (or policy) says no.
pub const DENY_MESSAGE: &str = "Denied by the user in Bandito";

/// Flags every session starts with.
const BASE_ARGS: [&str; 11] = [
    "-p",
    "--input-format",
    "stream-json",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--permission-prompt-tool",
    "stdio",
    "--permission-mode",
    "default",
];

const INIT_REQUEST_ID: &str = "init";
/// Capacity of the output channel. The pump waits when it is full.
const OUTPUT_CAPACITY: usize = 256;
/// Max bytes of stderr kept for `Exited { stderr_tail }`.
const STDERR_TAIL_LIMIT: usize = 4096;
/// Longest stdout/stderr line kept in memory. Longer lines are dropped whole.
const MAX_LINE_BYTES: usize = 8 * 1024 * 1024;
/// Tool input strings longer than this are clipped in events and approvals.
const INPUT_CLIP_BYTES: usize = 4096;
/// How long the CLI may take to exit after stdin is closed, before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(5);
/// How long to wait for the child to exit after the kill signal, before the task is aborted.
const KILL_GRACE: Duration = Duration::from_secs(2);
/// How long to wait for stderr to close after the child exited.
const STDERR_GRACE: Duration = Duration::from_secs(2);
/// Max bytes of diff text shown in an approval.
const APPROVAL_DIFF_LIMIT: usize = 8192;
/// Max chars of a Bash command used as a tool title.
const TITLE_LIMIT: usize = 200;

/// Approval key → the original tool input (echoed back as `updatedInput`, unclipped).
type PendingMap = Arc<Mutex<HashMap<String, Value>>>;
/// Frames waiting for the writer task. `None` once the session is shut down.
type LineSink = Arc<Mutex<Option<mpsc::UnboundedSender<String>>>>;

pub struct ClaudeRuntime {
    program: String,
}

impl ClaudeRuntime {
    pub fn new() -> Self {
        Self::with_program("claude")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
        }
    }
}

impl Default for ClaudeRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Runtime for ClaudeRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Claude
    }

    async fn status(&self) -> RuntimeStatus {
        let version = super::probe_version(&self.program).await;
        RuntimeStatus {
            kind: RuntimeKind::Claude,
            installed: version.is_some(),
            version,
            logged_in: None,
            detail: None,
        }
    }

    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned> {
        let program = cfg.program.clone().unwrap_or_else(|| PathBuf::from(&self.program));
        let mut cmd = Command::new(&program);
        cmd.args(BASE_ARGS);
        if let Some(model) = &cfg.model {
            cmd.arg("--model").arg(model);
        }
        if let Some(prompt) = &cfg.system_prompt {
            cmd.arg("--append-system-prompt").arg(prompt);
        }
        if let Some(id) = &cfg.resume {
            cmd.arg("--resume").arg(id);
        }
        if let Some((prog, args)) = &cfg.mcp {
            let config = json!({
                "mcpServers": {"bandito": {"command": prog.display().to_string(), "args": args}}
            })
            .to_string();
            cmd.arg("--mcp-config").arg(config);
        }
        cmd.current_dir(&cfg.cwd)
            .envs(cfg.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        configure_group(&mut cmd);

        let mut child = cmd
            .spawn()
            .with_context(|| format!("failed to start {}", program.display()))?;
        // Unix: the child leads its own process group, so the whole tree can be killed.
        let pgid = if cfg!(unix) { child.id() } else { None };
        let stdin = piped(child.stdin.take(), "stdin")?;
        let stdout = piped(child.stdout.take(), "stdout")?;
        let stderr = piped(child.stderr.take(), "stderr")?;

        let (line_tx, line_rx) = mpsc::unbounded_channel();
        let sink: LineSink = Arc::new(Mutex::new(Some(line_tx)));
        tokio::spawn(writer_task(stdin, line_rx));
        let init = json!({
            "type": "control_request",
            "request_id": INIT_REQUEST_ID,
            "request": {"subtype": "initialize"}
        });
        // A CLI that already died (e.g. not logged in) has closed its stdin. Its exit
        // reaches the caller as `Exited`, so a failed write here is not an error.
        let _ = push_line(&sink, &init);

        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let stderr_tail = Arc::new(Mutex::new(String::new()));
        let stderr_task = spawn_stderr(stderr, Arc::clone(&stderr_tail));
        let (tx, rx) = mpsc::channel(OUTPUT_CAPACITY);
        let (kill_tx, kill_rx) = oneshot::channel();
        let pump = Pump {
            child,
            pgid,
            pending: Arc::clone(&pending),
            sink: Arc::clone(&sink),
            tx,
            kill: kill_rx,
            killed: false,
            stderr: stderr_tail,
            stderr_task,
        };
        let exited = tokio::spawn(pump.run(stdout));

        Ok(Spawned {
            session: Box::new(ClaudeSession {
                sink,
                pending,
                kill: Some(kill_tx),
                exited,
                pgid,
                next_request: 0,
            }),
            output: rx,
        })
    }
}

/// One-line human title for a tool call.
pub fn tool_title(tool: &str, input: &Value) -> String {
    let labeled = |label: &str, key: &str| match str_field(input, key) {
        Some(value) => format!("{label} {value}"),
        None => tool.to_string(),
    };
    match tool {
        "Bash" => str_field(input, "command")
            .and_then(|command| command.lines().next())
            .filter(|line| !line.trim().is_empty())
            .map(|line| line.chars().take(TITLE_LIMIT).collect::<String>())
            .unwrap_or_else(|| tool.to_string()),
        "Edit" | "MultiEdit" => labeled("Edit", "file_path"),
        "Write" => labeled("Write", "file_path"),
        "Read" => labeled("Read", "file_path"),
        "NotebookEdit" => labeled("Edit", "notebook_path"),
        "WebFetch" => labeled("Fetch", "url"),
        "WebSearch" => labeled("Search", "query"),
        "Glob" | "Grep" => labeled(tool, "pattern"),
        _ => tool.to_string(),
    }
}

/// Map one stdout line (already parsed) to outputs. Pure, so it is unit-testable.
/// `control_request{can_use_tool}` is NOT handled here (it needs session state).
pub fn map_message(msg: &Value) -> Vec<RuntimeOutput> {
    let mut out = Vec::new();
    match raw_str(msg, "type") {
        "system" => {
            if let (Some("init"), Some(id)) = (msg.get("subtype").and_then(Value::as_str), str_field(msg, "session_id"))
            {
                out.push(RuntimeOutput::SessionId(id.to_string()));
            }
        }
        "assistant" => map_assistant(msg, &mut out),
        "user" => map_user(msg, &mut out),
        "stream_event" => map_stream_event(msg, &mut out),
        "rate_limit_event" => map_rate_limit(msg, &mut out),
        "result" => map_result(msg, &mut out),
        _ => {}
    }
    out
}

/// Build the approval request for a `can_use_tool` control request.
/// `input` in the result is clipped; the original input stays with the caller.
pub fn approval_from_control(msg: &Value) -> Option<ApprovalRequest> {
    let request = msg.get("request")?;
    if raw_str(msg, "type") != "control_request" || raw_str(request, "subtype") != "can_use_tool" {
        return None;
    }
    let key = str_field(msg, "request_id")?.to_string();
    let tool = raw_str(request, "tool_name").to_string();
    let input = request.get("input").cloned().unwrap_or(Value::Null);
    let call_id = str_field(request, "tool_use_id").unwrap_or(key.as_str()).to_string();
    let title = tool_title(&tool, &input);
    let command = if tool == "Bash" {
        str_field(&input, "command").map(str::to_string)
    } else {
        None
    };
    let diff = match tool.as_str() {
        "Edit" | "MultiEdit" => Some(edit_diff(&tool, &input)),
        "Write" => Some(prefixed_lines(raw_str(&input, "content"), "+ ")),
        _ => None,
    }
    .filter(|d| !d.is_empty())
    .map(|d| truncate_output(&d, APPROVAL_DIFF_LIMIT));
    let paths = if let Some(blocked) = str_field(request, "blocked_path") {
        vec![blocked.to_string()]
    } else if let Some(path) = str_field(&input, "file_path").or_else(|| str_field(&input, "notebook_path")) {
        vec![path.to_string()]
    } else {
        Vec::new()
    };
    Some(ApprovalRequest {
        key,
        call_id,
        tool,
        title,
        command,
        diff,
        paths,
        input: clip_input(&input, INPUT_CLIP_BYTES),
    })
}

/// A live Claude Code process. Writes go through the writer task; the pump task
/// owns the child and reports its exit.
struct ClaudeSession {
    /// `None` after shutdown: the writer task then drops stdin (EOF for the CLI).
    sink: LineSink,
    pending: PendingMap,
    /// Asks the pump to kill the child. Dropping it (session dropped) kills too.
    kill: Option<oneshot::Sender<()>>,
    /// The pump task.
    exited: JoinHandle<()>,
    /// Process group id, for killing the whole tree.
    pgid: Option<u32>,
    next_request: u64,
}

impl ClaudeSession {
    fn take_pending(&self, key: &str) -> Option<Value> {
        locked(&self.pending).remove(key)
    }
}

#[async_trait]
impl Session for ClaudeSession {
    async fn send(&mut self, text: &str) -> anyhow::Result<()> {
        push_line(
            &self.sink,
            &json!({
                "type": "user",
                "message": {"role": "user", "content": text},
                "parent_tool_use_id": null,
                "session_id": "",
            }),
        )
    }

    async fn interrupt(&mut self) -> anyhow::Result<()> {
        let id = self.next_request;
        self.next_request += 1;
        push_line(
            &self.sink,
            &json!({
                "type": "control_request",
                "request_id": format!("int-{id}"),
                "request": {"subtype": "interrupt"}
            }),
        )
    }

    async fn resolve(&mut self, key: &str, decision: Decision) -> anyhow::Result<()> {
        let Some(input) = self.take_pending(key) else {
            bail!("unknown approval {key}");
        };
        let response = match decision {
            Decision::Allow => json!({"behavior": "allow", "updatedInput": input}),
            Decision::Deny => json!({"behavior": "deny", "message": DENY_MESSAGE}),
        };
        push_line(
            &self.sink,
            &json!({
                "type": "control_response",
                "response": {"subtype": "success", "request_id": key, "response": response}
            }),
        )
    }

    async fn shutdown(self: Box<Self>) {
        let mut this = *self;
        // Closing the channel ends the writer task, which drops stdin: EOF for the CLI.
        let _ = locked(&this.sink).take();
        if timeout(EXIT_GRACE, &mut this.exited).await.is_ok() {
            return;
        }
        if let Some(kill) = this.kill.take() {
            let _ = kill.send(());
        }
        if timeout(KILL_GRACE, &mut this.exited).await.is_err() {
            if let Some(pgid) = this.pgid {
                kill_group(pgid);
            }
            // Last resort: dropping the task drops the child (kill_on_drop).
            this.exited.abort();
        }
    }
}

/// The stdout side of a session. Owns the child, routes lines, and reports
/// `Exited` at the end.
struct Pump {
    child: Child,
    /// Process group id (unix). Kills go to the whole group.
    pgid: Option<u32>,
    pending: PendingMap,
    sink: LineSink,
    tx: mpsc::Sender<RuntimeOutput>,
    /// Fires on shutdown. A dropped session closes it too, which also kills.
    kill: oneshot::Receiver<()>,
    killed: bool,
    stderr: Arc<Mutex<String>>,
    stderr_task: JoinHandle<()>,
}

impl Pump {
    fn kill_now(&mut self) {
        self.killed = true;
        kill_tree(&mut self.child, self.pgid);
    }

    async fn run(mut self, stdout: ChildStdout) {
        let mut reader = BufReader::new(stdout);
        loop {
            let read = tokio::select! {
                read = read_capped_line(&mut reader, MAX_LINE_BYTES) => read,
                _ = &mut self.kill, if !self.killed => {
                    self.kill_now();
                    continue;
                }
            };
            let line = match read {
                Ok(Line::Text(text)) => text,
                Ok(Line::TooLong) => {
                    tracing::warn!("dropped a claude stdout line longer than {MAX_LINE_BYTES} bytes");
                    continue;
                }
                Ok(Line::Eof) => break,
                Err(e) => {
                    tracing::warn!("claude stdout read failed: {e}");
                    self.kill_now();
                    break;
                }
            };
            let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                tracing::debug!("skipping non-JSON line from claude stdout");
                continue;
            };
            for output in route(&msg, &self.pending, &self.sink) {
                if self.killed {
                    break;
                }
                // Shutdown must not wait behind a full channel.
                let sent = tokio::select! {
                    result = self.tx.send(output) => result.is_ok(),
                    _ = &mut self.kill, if !self.killed => false,
                };
                if !sent {
                    // A kill was requested, or nobody listens any more.
                    self.kill_now();
                    break;
                }
            }
        }

        let status = loop {
            tokio::select! {
                status = self.child.wait() => break status.ok(),
                _ = &mut self.kill, if !self.killed => self.kill_now(),
            }
        };
        if let Some(pgid) = self.pgid {
            // Whatever the CLI left in its group (e.g. background jobs) goes too.
            kill_group(pgid);
        }
        let code = status.and_then(|s| s.code());
        if timeout(STDERR_GRACE, &mut self.stderr_task).await.is_err() {
            self.stderr_task.abort();
        }
        let stderr_tail = locked(&self.stderr).clone();
        tokio::select! {
            _ = self.tx.send(RuntimeOutput::Exited { code, stderr_tail }) => {}
            _ = &mut self.kill, if !self.killed => {}
        }
    }
}

/// Route one parsed stdout message: approvals and their cancellation, answers
/// to unknown control requests, and everything else through `map_message`.
fn route(msg: &Value, pending: &PendingMap, sink: &LineSink) -> Vec<RuntimeOutput> {
    if let Some(req) = approval_from_control(msg) {
        // Keep the original input: the answer must echo it back unclipped.
        let original = msg.pointer("/request/input").cloned().unwrap_or(Value::Null);
        locked(pending).insert(req.key.clone(), original);
        return vec![RuntimeOutput::Approval(req)];
    }
    if let Some(key) = cancelled_key(msg) {
        let known = locked(pending).remove(key).is_some();
        return if known {
            vec![RuntimeOutput::ApprovalCancelled { key: key.to_string() }]
        } else {
            Vec::new()
        };
    }
    if let Some(reply) = unsupported_control_reply(msg) {
        tracing::debug!("answering unsupported control request: {reply}");
        if let Err(e) = push_line(sink, &reply) {
            tracing::debug!("could not answer control request: {e}");
        }
        return Vec::new();
    }
    map_message(msg)
}

/// `control_cancel_request`: the CLI withdraws a permission request.
fn cancelled_key(msg: &Value) -> Option<&str> {
    if raw_str(msg, "type") == "control_cancel_request" {
        str_field(msg, "request_id")
    } else {
        None
    }
}

/// Error reply for a `control_request` we do not implement (anything but `can_use_tool`).
fn unsupported_control_reply(msg: &Value) -> Option<Value> {
    if raw_str(msg, "type") != "control_request" {
        return None;
    }
    let subtype = msg.pointer("/request/subtype").and_then(Value::as_str).unwrap_or("");
    if subtype == "can_use_tool" {
        return None;
    }
    let request_id = str_field(msg, "request_id")?;
    Some(json!({
        "type": "control_response",
        "response": {
            "subtype": "error",
            "request_id": request_id,
            "error": format!("Unsupported control request: {subtype}"),
        }
    }))
}

/// Owns the child's stdin. Writes queued frames in order. When the channel
/// closes (shutdown), it drops stdin.
async fn writer_task(mut stdin: ChildStdin, mut lines: mpsc::UnboundedReceiver<String>) {
    while let Some(line) = lines.recv().await {
        let written = match stdin.write_all(line.as_bytes()).await {
            Ok(()) => stdin.flush().await,
            Err(e) => Err(e),
        };
        if let Err(e) = written {
            tracing::warn!("claude stdin write failed: {e}");
            break;
        }
    }
}

/// Queue one NDJSON frame for the writer task. Errors when the session is
/// closed or the writer task has stopped.
fn push_line(sink: &LineSink, v: &Value) -> anyhow::Result<()> {
    let guard = locked(sink);
    let Some(tx) = guard.as_ref() else {
        bail!("claude session is closed");
    };
    let mut line = v.to_string();
    line.push('\n');
    tx.send(line).map_err(|_| anyhow::anyhow!("claude session is closed"))
}

/// Collect stderr into a bounded tail shared with the pump.
fn spawn_stderr(stderr: ChildStderr, tail: Arc<Mutex<String>>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        loop {
            match read_capped_line(&mut reader, MAX_LINE_BYTES).await {
                Ok(Line::Text(line)) => {
                    let mut shared = locked(&tail);
                    shared.push_str(&line);
                    shared.push('\n');
                    trim_tail(&mut shared);
                }
                Ok(Line::TooLong) => {}
                Ok(Line::Eof) | Err(_) => break,
            }
        }
    })
}

/// Keep only the last `STDERR_TAIL_LIMIT` bytes, cut on a char boundary.
fn trim_tail(tail: &mut String) {
    if tail.len() <= STDERR_TAIL_LIMIT {
        return;
    }
    let mut start = tail.len() - STDERR_TAIL_LIMIT;
    while !tail.is_char_boundary(start) {
        start += 1;
    }
    tail.drain(..start);
}

/// One line read by [`read_capped_line`].
#[derive(Debug, PartialEq)]
enum Line {
    /// Stream ended with nothing left to read.
    Eof,
    /// Line without its `\n`. Invalid UTF-8 is replaced, not rejected.
    Text(String),
    /// Longer than the limit. The bytes were discarded up to the newline.
    TooLong,
}

/// Read one `\n`-terminated line. Memory stays bounded by `limit`: a longer
/// line is consumed to its end and reported as [`Line::TooLong`].
async fn read_capped_line<R>(reader: &mut R, limit: usize) -> std::io::Result<Line>
where
    R: AsyncBufRead + Unpin,
{
    let mut buf: Vec<u8> = Vec::new();
    let mut too_long = false;
    let mut read_any = false;
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            if !read_any {
                return Ok(Line::Eof);
            }
            break;
        }
        read_any = true;
        let newline = chunk.iter().position(|&b| b == b'\n');
        let content_len = newline.unwrap_or(chunk.len());
        if !too_long {
            if buf.len() + content_len > limit {
                too_long = true;
                buf = Vec::new();
            } else {
                buf.extend_from_slice(&chunk[..content_len]);
            }
        }
        let consumed = newline.map_or(chunk.len(), |i| i + 1);
        reader.consume(consumed);
        if newline.is_some() {
            break;
        }
    }
    Ok(if too_long {
        Line::TooLong
    } else {
        Line::Text(String::from_utf8_lossy(&buf).into_owned())
    })
}

/// Start the child in its own process group (unix), so a kill can reach its descendants.
#[cfg(unix)]
fn configure_group(cmd: &mut Command) {
    cmd.process_group(0);
}

#[cfg(not(unix))]
fn configure_group(_cmd: &mut Command) {}

/// SIGKILL to the whole process group.
#[cfg(unix)]
fn kill_group(pgid: u32) {
    // SAFETY: killpg only sends a signal. An unknown group yields ESRCH, which is ignored.
    let _ = unsafe { libc::killpg(pgid as i32, libc::SIGKILL) };
}

#[cfg(not(unix))]
fn kill_group(_pgid: u32) {}

/// Kill the child's whole group, or only the child when no group is known.
fn kill_tree(child: &mut Child, pgid: Option<u32>) {
    match pgid {
        Some(pgid) => kill_group(pgid),
        None => {
            let _ = child.start_kill();
        }
    }
}

/// The child's pipe, or an error if it was not set up as one.
fn piped<T>(pipe: Option<T>, name: &str) -> anyhow::Result<T> {
    pipe.ok_or_else(|| anyhow::anyhow!("claude {name} is not piped"))
}

/// Lock a mutex, ignoring poisoning (the data stays usable).
fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Non-empty string field of a JSON object.
fn str_field<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// String field of a JSON object, or "" if missing.
fn raw_str<'a>(v: &'a Value, key: &str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or("")
}

/// `message.content` as an array; empty for string content or no content.
fn content_blocks(msg: &Value) -> &[Value] {
    msg.pointer("/message/content")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

fn map_assistant(msg: &Value, out: &mut Vec<RuntimeOutput>) {
    for block in content_blocks(msg) {
        match raw_str(block, "type") {
            "text" => {
                if let Some(text) = str_field(block, "text") {
                    out.push(RuntimeOutput::Event(EventBody::MessageAssistant {
                        text: text.to_string(),
                    }));
                }
            }
            "tool_use" => {
                let tool = raw_str(block, "name");
                let input = block.get("input").cloned().unwrap_or(Value::Null);
                out.push(RuntimeOutput::Event(EventBody::ToolCall {
                    call_id: raw_str(block, "id").to_string(),
                    tool: tool.to_string(),
                    title: tool_title(tool, &input),
                    input: clip_input(&input, INPUT_CLIP_BYTES),
                }));
            }
            // thinking and other block kinds are not shown
            _ => {}
        }
    }
}

fn map_user(msg: &Value, out: &mut Vec<RuntimeOutput>) {
    // String content is the echo of the user's own message: nothing to show.
    for block in content_blocks(msg) {
        if raw_str(block, "type") != "tool_result" {
            continue;
        }
        let is_error = block.get("is_error").and_then(Value::as_bool).unwrap_or(false);
        out.push(RuntimeOutput::Event(EventBody::ToolResult {
            call_id: raw_str(block, "tool_use_id").to_string(),
            ok: !is_error,
            output: truncate_output(&tool_result_text(block), TOOL_OUTPUT_LIMIT),
        }));
    }
}

/// Text of a tool result: a string, or the `text` parts of an array joined by newlines.
fn tool_result_text(block: &Value) -> String {
    match block.get("content") {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .filter(|item| raw_str(item, "type") == "text")
            .filter_map(|item| item.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

fn is_type(v: &Value, t: &str) -> bool {
    raw_str(v, "type") == t
}

fn map_stream_event(msg: &Value, out: &mut Vec<RuntimeOutput>) {
    let Some(event) = msg.get("event").filter(|e| is_type(e, "content_block_delta")) else {
        return;
    };
    let Some(delta) = event.get("delta").filter(|d| is_type(d, "text_delta")) else {
        return;
    };
    if let Some(text) = delta.get("text").and_then(Value::as_str) {
        out.push(RuntimeOutput::Event(EventBody::MessageDelta { text: text.to_string() }));
    }
}

fn map_rate_limit(msg: &Value, out: &mut Vec<RuntimeOutput>) {
    let Some(windows) = msg
        .pointer("/rate_limit_info/unifiedWindows")
        .and_then(Value::as_object)
    else {
        return;
    };
    // A window without `utilization` carries no usable number: skip it.
    let mut windows: Vec<LimitWindow> = windows
        .iter()
        .filter_map(|(name, w)| {
            let utilization = w.get("utilization").and_then(Value::as_f64)?;
            Some(LimitWindow {
                name: name.clone(),
                utilization,
                resets_at: w.get("resetsAt").and_then(Value::as_i64),
            })
        })
        .collect();
    windows.sort_by(|a, b| a.name.cmp(&b.name));
    out.push(RuntimeOutput::Event(EventBody::UsageLimits {
        runtime: "claude".to_string(),
        windows,
    }));
}

fn map_result(msg: &Value, out: &mut Vec<RuntimeOutput>) {
    let result_text = str_field(msg, "result");
    let is_error = msg.get("is_error").and_then(Value::as_bool).unwrap_or(false);
    // "Interrupted" counts only when the turn really failed; a successful turn that happens to say it is Ok.
    let failed = is_error || raw_str(msg, "subtype") != "success";
    let status = if failed && result_text == Some("Interrupted") {
        TurnStatus::Interrupted
    } else if failed {
        TurnStatus::Error
    } else {
        TurnStatus::Ok
    };
    if status == TurnStatus::Error {
        out.push(RuntimeOutput::Event(EventBody::Error {
            message: result_text.unwrap_or("Claude Code reported an error").to_string(),
        }));
    }
    let usage = msg.get("usage").filter(|u| u.is_object()).map(|u| {
        let n = |key: &str| u.get(key).and_then(Value::as_u64).unwrap_or(0);
        Usage {
            input_tokens: n("input_tokens")
                .saturating_add(n("cache_creation_input_tokens"))
                .saturating_add(n("cache_read_input_tokens")),
            output_tokens: n("output_tokens"),
        }
    });
    out.push(RuntimeOutput::Event(EventBody::TurnCompleted {
        // The supervisor fills in the turn id.
        turn_id: String::new(),
        status,
        usage,
        cost_usd: msg.get("total_cost_usd").and_then(Value::as_f64),
    }));
}

/// Each line of `text` with `prefix`, joined by newlines.
fn prefixed_lines(text: &str, prefix: &str) -> String {
    text.lines()
        .map(|line| format!("{prefix}{line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// Diff of an `Edit` (one edit) or `MultiEdit` (each element of `edits`):
/// per edit, `- old` lines followed by `+ new` lines.
fn edit_diff(tool: &str, input: &Value) -> String {
    let edits: Vec<&Value> = if tool == "MultiEdit" {
        input
            .get("edits")
            .and_then(Value::as_array)
            .map(|items| items.iter().collect())
            .unwrap_or_default()
    } else {
        vec![input]
    };
    edits
        .into_iter()
        .map(single_edit_diff)
        .filter(|d| !d.is_empty())
        .collect::<Vec<_>>()
        .join("\n")
}

fn single_edit_diff(edit: &Value) -> String {
    [
        prefixed_lines(raw_str(edit, "old_string"), "- "),
        prefixed_lines(raw_str(edit, "new_string"), "+ "),
    ]
    .into_iter()
    .filter(|part| !part.is_empty())
    .collect::<Vec<_>>()
    .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approval(msg: &Value) -> ApprovalRequest {
        approval_from_control(msg).expect("an approval request")
    }

    #[test]
    fn tool_title_bash_uses_first_line_and_limits_length() {
        assert_eq!(
            tool_title("Bash", &json!({"command": "git status\nrm -rf x"})),
            "git status"
        );
        assert_eq!(tool_title("Bash", &json!({"command": "touch b.txt"})), "touch b.txt");
        assert_eq!(tool_title("Bash", &json!({})), "Bash");
        assert_eq!(tool_title("Bash", &json!({"command": ""})), "Bash");
        assert_eq!(tool_title("Bash", &json!({"command": "\nls"})), "Bash");

        let title = tool_title("Bash", &json!({"command": "я".repeat(300)}));
        assert_eq!(title.chars().count(), 200);
        assert!(title.chars().all(|c| c == 'я'));
    }

    #[test]
    fn tool_title_file_and_web_tools() {
        let input = json!({
            "file_path": "/w/a.rs",
            "notebook_path": "/w/n.ipynb",
            "url": "https://x.y",
            "query": "rust",
            "pattern": "fn main"
        });
        assert_eq!(tool_title("Edit", &input), "Edit /w/a.rs");
        assert_eq!(tool_title("MultiEdit", &input), "Edit /w/a.rs");
        assert_eq!(tool_title("Write", &input), "Write /w/a.rs");
        assert_eq!(tool_title("Read", &input), "Read /w/a.rs");
        assert_eq!(tool_title("NotebookEdit", &input), "Edit /w/n.ipynb");
        assert_eq!(tool_title("WebFetch", &input), "Fetch https://x.y");
        assert_eq!(tool_title("WebSearch", &input), "Search rust");
        assert_eq!(tool_title("Glob", &input), "Glob fn main");
        assert_eq!(tool_title("Grep", &input), "Grep fn main");
    }

    #[test]
    fn tool_title_falls_back_to_tool_name() {
        assert_eq!(tool_title("Edit", &json!({})), "Edit");
        assert_eq!(tool_title("Write", &json!({"file_path": ""})), "Write");
        assert_eq!(tool_title("NotebookEdit", &json!({"file_path": "/x"})), "NotebookEdit");
        assert_eq!(tool_title("WebFetch", &json!({})), "WebFetch");
        assert_eq!(tool_title("Grep", &json!({})), "Grep");
        assert_eq!(tool_title("TodoWrite", &json!({"todos": []})), "TodoWrite");
    }

    #[test]
    fn map_system_init_yields_session_id() {
        assert_eq!(
            map_message(&json!({"type": "system", "subtype": "init", "session_id": "s-1"})),
            vec![RuntimeOutput::SessionId("s-1".into())]
        );
        assert!(map_message(&json!({"type": "system", "subtype": "init"})).is_empty());
        assert!(map_message(&json!({"type": "system", "subtype": "hook_started", "session_id": "s"})).is_empty());
    }

    #[test]
    fn map_assistant_text_and_tool_use_skip_thinking() {
        let msg = json!({"type": "assistant", "message": {"content": [
            {"type": "thinking", "thinking": "hmm", "signature": "x"},
            {"type": "text", "text": "Let me look."},
            {"type": "text", "text": ""},
            {"type": "tool_use", "id": "toolu_7", "name": "Read", "input": {"file_path": "/w/a.rs"}}
        ]}});
        assert_eq!(
            map_message(&msg),
            vec![
                RuntimeOutput::Event(EventBody::MessageAssistant {
                    text: "Let me look.".into()
                }),
                RuntimeOutput::Event(EventBody::ToolCall {
                    call_id: "toolu_7".into(),
                    tool: "Read".into(),
                    title: "Read /w/a.rs".into(),
                    input: json!({"file_path": "/w/a.rs"}),
                }),
            ]
        );
    }

    #[test]
    fn map_user_tool_results_string_array_and_errors() {
        let msg = json!({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": "ok out"},
            {"type": "tool_result", "tool_use_id": "t2", "is_error": true, "content": [
                {"type": "text", "text": "boom"},
                {"type": "image", "source": {}},
                {"type": "text", "text": "second"}
            ]},
            {"type": "tool_result", "tool_use_id": "t3", "is_error": false}
        ]}});
        assert_eq!(
            map_message(&msg),
            vec![
                RuntimeOutput::Event(EventBody::ToolResult {
                    call_id: "t1".into(),
                    ok: true,
                    output: "ok out".into(),
                }),
                RuntimeOutput::Event(EventBody::ToolResult {
                    call_id: "t2".into(),
                    ok: false,
                    output: "boom\nsecond".into(),
                }),
                RuntimeOutput::Event(EventBody::ToolResult {
                    call_id: "t3".into(),
                    ok: true,
                    output: String::new(),
                }),
            ]
        );
    }

    #[test]
    fn map_user_tool_result_output_is_truncated() {
        let big = "x".repeat(TOOL_OUTPUT_LIMIT + 10);
        let msg = json!({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t1", "content": big.clone()}
        ]}});
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::ToolResult {
                call_id: "t1".into(),
                ok: true,
                output: truncate_output(&big, TOOL_OUTPUT_LIMIT),
            })]
        );
    }

    #[test]
    fn map_user_string_content_is_silent() {
        assert!(map_message(&json!({"type": "user", "message": {"role": "user", "content": "hi"}})).is_empty());
    }

    #[test]
    fn map_stream_event_only_text_deltas() {
        let text = json!({"type": "stream_event", "event": {
            "type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Hel"}
        }});
        assert_eq!(
            map_message(&text),
            vec![RuntimeOutput::Event(EventBody::MessageDelta { text: "Hel".into() })]
        );

        let thinking = json!({"type": "stream_event", "event": {
            "type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "hmm"}
        }});
        assert!(map_message(&thinking).is_empty());

        let start = json!({"type": "stream_event", "event": {"type": "message_start"}});
        assert!(map_message(&start).is_empty());
    }

    #[test]
    fn map_rate_limit_sorts_windows_and_skips_ones_without_utilization() {
        let msg = json!({"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows": {
            "seven_day": {"utilization": 0.21, "resetsAt": 1792026000},
            "five_hour": {"utilization": 0.04, "resetsAt": 1791543600},
            "opus": {"resetsAt": 1791543600}
        }}});
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::UsageLimits {
                runtime: "claude".into(),
                windows: vec![
                    LimitWindow {
                        name: "five_hour".into(),
                        utilization: 0.04,
                        resets_at: Some(1791543600),
                    },
                    LimitWindow {
                        name: "seven_day".into(),
                        utilization: 0.21,
                        resets_at: Some(1792026000),
                    },
                ],
            })]
        );
        assert!(map_message(&json!({"type": "rate_limit_event", "rate_limit_info": {"status": "allowed"}})).is_empty());
    }

    #[test]
    fn map_result_success_with_usage_and_cost() {
        let msg = json!({"type": "result", "subtype": "success", "is_error": false, "result": "done",
            "total_cost_usd": 0.5,
            "usage": {"input_tokens": 3, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 100, "output_tokens": 7}
        });
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::TurnCompleted {
                turn_id: String::new(),
                status: TurnStatus::Ok,
                usage: Some(Usage {
                    input_tokens: 113,
                    output_tokens: 7,
                }),
                cost_usd: Some(0.5),
            })]
        );
    }

    #[test]
    fn map_result_success_without_usage() {
        let msg = json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok"});
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::TurnCompleted {
                turn_id: String::new(),
                status: TurnStatus::Ok,
                usage: None,
                cost_usd: None,
            })]
        );
    }

    #[test]
    fn map_result_error_emits_error_then_turn_end() {
        let msg = json!({"type": "result", "subtype": "error_max_turns", "is_error": true, "result": "Hit the limit"});
        assert_eq!(
            map_message(&msg),
            vec![
                RuntimeOutput::Event(EventBody::Error {
                    message: "Hit the limit".into()
                }),
                RuntimeOutput::Event(EventBody::TurnCompleted {
                    turn_id: String::new(),
                    status: TurnStatus::Error,
                    usage: None,
                    cost_usd: None,
                }),
            ]
        );

        let bare = json!({"type": "result", "subtype": "error_during_execution", "is_error": true});
        assert_eq!(
            map_message(&bare)[0],
            RuntimeOutput::Event(EventBody::Error {
                message: "Claude Code reported an error".into()
            })
        );
    }

    #[test]
    fn map_result_interrupted_has_no_error_event() {
        let msg = json!({"type": "result", "subtype": "error_during_execution", "is_error": true,
            "result": "Interrupted", "usage": {"input_tokens": 1, "output_tokens": 2}});
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::TurnCompleted {
                turn_id: String::new(),
                status: TurnStatus::Interrupted,
                usage: Some(Usage {
                    input_tokens: 1,
                    output_tokens: 2,
                }),
                cost_usd: None,
            })]
        );
    }

    #[test]
    fn successful_result_with_interrupted_text_is_ok() {
        let msg = json!({"type": "result", "subtype": "success", "is_error": false, "result": "Interrupted"});
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::TurnCompleted {
                turn_id: String::new(),
                status: TurnStatus::Ok,
                usage: None,
                cost_usd: None,
            })]
        );
    }

    #[test]
    fn map_ignores_other_messages() {
        for msg in [
            json!({"type": "control_response", "response": {"subtype": "success", "request_id": "init"}}),
            json!({"type": "system", "subtype": "hook_response", "session_id": "s"}),
            json!({"type": "system", "subtype": "commands_changed"}),
            json!({"type": "system", "subtype": "thinking_tokens", "count": 4}),
            // Approvals are handled by the session, not by the mapper.
            json!({"type": "control_request", "request_id": "p", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {}}}),
        ] {
            assert!(map_message(&msg).is_empty(), "{msg}");
        }
    }

    #[test]
    fn approval_bash_with_blocked_path() {
        let msg = json!({"type": "control_request", "request_id": "perm-1", "request": {
            "subtype": "can_use_tool", "tool_name": "Bash",
            "input": {"command": "touch b.txt\necho"},
            "blocked_path": "/w/b.txt", "tool_use_id": "toolu_1"
        }});
        assert_eq!(
            approval(&msg),
            ApprovalRequest {
                key: "perm-1".into(),
                call_id: "toolu_1".into(),
                tool: "Bash".into(),
                title: "touch b.txt".into(),
                command: Some("touch b.txt\necho".into()),
                diff: None,
                paths: vec!["/w/b.txt".into()],
                input: json!({"command": "touch b.txt\necho"}),
            }
        );
    }

    #[test]
    fn approval_without_tool_use_id_uses_key_as_call_id() {
        let msg = json!({"type": "control_request", "request_id": "k9", "request": {
            "subtype": "can_use_tool", "tool_name": "WebFetch", "input": {"url": "https://x"}
        }});
        let req = approval(&msg);
        assert_eq!(req.call_id, "k9");
        assert_eq!(req.title, "Fetch https://x");
        assert!(req.command.is_none());
        assert!(req.diff.is_none());
        assert!(req.paths.is_empty());
    }

    #[test]
    fn approval_edit_has_diff_and_file_path() {
        let msg = json!({"type": "control_request", "request_id": "e1", "request": {
            "subtype": "can_use_tool", "tool_name": "Edit", "tool_use_id": "toolu_e",
            "input": {"file_path": "/w/a.rs", "old_string": "a\nb", "new_string": "c"}
        }});
        let req = approval(&msg);
        assert_eq!(req.call_id, "toolu_e");
        assert_eq!(req.title, "Edit /w/a.rs");
        assert_eq!(req.diff.as_deref(), Some("- a\n- b\n+ c"));
        assert_eq!(req.paths, vec!["/w/a.rs".to_string()]);
        assert!(req.command.is_none());
    }

    #[test]
    fn approval_multi_edit_diff_covers_each_edit() {
        let msg = json!({"type": "control_request", "request_id": "m1", "request": {
            "subtype": "can_use_tool", "tool_name": "MultiEdit",
            "input": {"file_path": "/w/m.rs", "edits": [
                {"old_string": "a", "new_string": "b"},
                {"old_string": "", "new_string": "c"}
            ]}
        }});
        let req = approval(&msg);
        assert_eq!(req.diff.as_deref(), Some("- a\n+ b\n+ c"));
        assert_eq!(req.paths, vec!["/w/m.rs".to_string()]);
    }

    #[test]
    fn approval_write_has_added_lines_and_file_path() {
        let msg = json!({"type": "control_request", "request_id": "w1", "request": {
            "subtype": "can_use_tool", "tool_name": "Write",
            "input": {"file_path": "/w/n.txt", "content": "l1\nl2"}
        }});
        let req = approval(&msg);
        assert_eq!(req.title, "Write /w/n.txt");
        assert_eq!(req.diff.as_deref(), Some("+ l1\n+ l2"));
        assert_eq!(req.paths, vec!["/w/n.txt".to_string()]);
    }

    #[test]
    fn approval_diff_is_truncated() {
        let msg = json!({"type": "control_request", "request_id": "w2", "request": {
            "subtype": "can_use_tool", "tool_name": "Write",
            "input": {"file_path": "/w/big.txt", "content": "x".repeat(APPROVAL_DIFF_LIMIT * 2)}
        }});
        let diff = approval(&msg).diff.expect("diff");
        assert!(diff.contains("[truncated"));
        assert!(diff.len() < APPROVAL_DIFF_LIMIT + 64);
    }

    #[test]
    fn approval_input_is_clipped_for_events() {
        let big = "z".repeat(100_000);
        let msg = json!({"type": "control_request", "request_id": "c1", "request": {
            "subtype": "can_use_tool", "tool_name": "Write",
            "input": {"file_path": "/w/big.txt", "content": big}
        }});
        let content = approval(&msg).input["content"].as_str().expect("content").len();
        assert!(content <= INPUT_CLIP_BYTES + 64, "clipped to {content} bytes");
    }

    #[test]
    fn approval_ignores_other_messages() {
        assert!(approval_from_control(&json!({"type": "assistant", "message": {"content": []}})).is_none());
        assert!(
            approval_from_control(&json!({
                "type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}
            }))
            .is_none()
        );
        assert!(
            approval_from_control(&json!({
                "type": "control_response", "response": {"request_id": "x"}
            }))
            .is_none()
        );
        assert!(
            approval_from_control(&json!({
                "type": "control_request", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {}}
            }))
            .is_none()
        );
    }

    #[test]
    fn cancel_request_yields_its_key() {
        let msg = json!({"type": "control_cancel_request", "request_id": "perm-3"});
        assert_eq!(cancelled_key(&msg), Some("perm-3"));
        assert_eq!(
            cancelled_key(&json!({"type": "control_request", "request_id": "x"})),
            None
        );
        assert_eq!(cancelled_key(&json!({"type": "control_cancel_request"})), None);
    }

    #[test]
    fn unsupported_control_request_gets_error_reply() {
        let msg = json!({"type": "control_request", "request_id": "hook-1", "request": {"subtype": "hook_callback"}});
        assert_eq!(
            unsupported_control_reply(&msg),
            Some(json!({"type": "control_response", "response": {
                "subtype": "error",
                "request_id": "hook-1",
                "error": "Unsupported control request: hook_callback",
            }}))
        );
        // can_use_tool is an approval, not an unsupported request; no id means no reply.
        let approval_msg =
            json!({"type": "control_request", "request_id": "p", "request": {"subtype": "can_use_tool"}});
        assert_eq!(unsupported_control_reply(&approval_msg), None);
        assert_eq!(
            unsupported_control_reply(&json!({"type": "control_request", "request": {"subtype": "x"}})),
            None
        );
        // Answers from the CLI to our own requests are ignored.
        assert_eq!(
            unsupported_control_reply(&json!({"type": "control_response", "response": {"request_id": "init"}})),
            None
        );
    }

    #[test]
    fn clip_input_cuts_long_strings_only() {
        let v = json!({"a": "x".repeat(10_000), "b": ["short", "y".repeat(5_000)], "n": 3, "t": true});
        let clipped = clip_input(&v, 4096);
        let a = clipped["a"].as_str().expect("a");
        assert!(a.starts_with("xxxx") && a.len() < 4096 + 64 && a.contains("[truncated"));
        assert_eq!(clipped["b"][0], "short");
        assert!(clipped["b"][1].as_str().expect("b1").len() < 4096 + 64);
        assert_eq!(clipped["n"], 3);
        assert_eq!(clipped["t"], true);
        // The original is untouched.
        assert_eq!(v["a"].as_str().expect("a").len(), 10_000);
    }

    #[tokio::test]
    async fn read_capped_line_replaces_invalid_utf8() {
        let mut r = BufReader::new(&b"ab\xff\n{}\n"[..]);
        assert_eq!(
            read_capped_line(&mut r, 1024).await.expect("io"),
            Line::Text("ab\u{FFFD}".into())
        );
        assert_eq!(
            read_capped_line(&mut r, 1024).await.expect("io"),
            Line::Text("{}".into())
        );
        assert_eq!(read_capped_line(&mut r, 1024).await.expect("io"), Line::Eof);
    }

    #[tokio::test]
    async fn read_capped_line_drops_overlong_line_and_keeps_going() {
        let mut r = BufReader::new(&b"abcdefgh\nxy\n"[..]);
        assert_eq!(read_capped_line(&mut r, 4).await.expect("io"), Line::TooLong);
        assert_eq!(read_capped_line(&mut r, 4).await.expect("io"), Line::Text("xy".into()));
        assert_eq!(read_capped_line(&mut r, 4).await.expect("io"), Line::Eof);
    }

    #[tokio::test]
    async fn read_capped_line_returns_unterminated_tail() {
        let mut r = BufReader::new(&b"tail"[..]);
        assert_eq!(
            read_capped_line(&mut r, 1024).await.expect("io"),
            Line::Text("tail".into())
        );
        assert_eq!(read_capped_line(&mut r, 1024).await.expect("io"), Line::Eof);
    }

    #[test]
    fn trim_tail_keeps_last_bytes_on_char_boundary() {
        // 'я' is 2 bytes and starts at even offsets; the naive cut at 1905 is mid-char.
        let mut s = format!("{}a", "я".repeat(3000));
        trim_tail(&mut s);
        assert_eq!(s.len(), 4095);
        assert!(s.ends_with('a'));
        assert!(s.starts_with('я'));
    }
}
