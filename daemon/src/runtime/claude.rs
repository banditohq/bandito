//! Claude Code adapter: drives the official `claude` CLI in print mode with
//! stream-json on both sides and answers permission prompts as the host.
//! Protocol notes and a real transcript: `tests/fixtures/claude/`.

use super::process::{self, JsonProcess, LineSink, Router, locked};
use super::{
    ApprovalRequest, LoginCache, LoginCheck, Plan, ProbeOutput, Runtime, RuntimeKind, RuntimeOutput, RuntimeStatus,
    Session, SpawnConfig, Spawned, capitalized, clip_input,
};
use crate::event::{Decision, EventBody, LimitWindow, TOOL_OUTPUT_LIMIT, TurnStatus, Usage, truncate_output};
use anyhow::bail;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::process::Command;

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

/// Permission rules that keep the agent's Read, Edit and Write tools out of `home`, Bandito's
/// own folder. Claude Code writes an absolute path with a `//` prefix: `Read(//home/u/.bandito/**)`.
fn bandito_home_rules(home: &std::path::Path) -> Vec<String> {
    let home = std::path::absolute(home).unwrap_or_else(|_| home.to_path_buf());
    let text = home.display().to_string();
    // The rule is a glob. A glob character in the folder's own name becomes a bracket class that matches
    // it (`(`, `)`, `[`, `]`, `*`, `?`, `{`, `}`); `!` and `\` are escaped with a backslash.
    let text: String = text
        .trim_end_matches('/')
        .chars()
        .map(|c| match c {
            '(' | ')' | '[' | ']' | '*' | '?' | '{' | '}' => format!("[{c}]"),
            '!' | '\\' => format!("\\{c}"),
            c => c.to_string(),
        })
        .collect();
    ["Read", "Edit", "Write"]
        .iter()
        .map(|tool| format!("{tool}(/{text}/**)"))
        .collect()
}

/// Tools whose calls go through `can_use_tool` and the policy. Listed as `permissions.ask` in the
/// `--settings` JSON. Grep (reads file contents) and Glob (reads names under a folder) are checked for
/// credential folders and Bandito's folder too. LS only lists names and stays out.
const POLICY_TOOLS: [&str; 9] = [
    "Bash",
    "Edit",
    "Write",
    "MultiEdit",
    "NotebookEdit",
    "WebFetch",
    "Read",
    "Grep",
    "Glob",
];

const INIT_REQUEST_ID: &str = "init";
/// Tool input strings longer than this are clipped in events and approvals.
const INPUT_CLIP_BYTES: usize = 4096;
/// Max bytes of diff text shown in an approval.
const APPROVAL_DIFF_LIMIT: usize = 8192;
/// Max chars of a Bash command used as a tool title.
const TITLE_LIMIT: usize = 200;

/// Approval key → the original tool input (echoed back as `updatedInput`, unclipped).
type PendingMap = Arc<Mutex<HashMap<String, Value>>>;

/// File in the Claude config folder that holds the login, the subscription and OAuth tokens.
const CREDENTIALS_FILE: &str = ".credentials.json";

pub struct ClaudeRuntime {
    program: String,
    /// Environment the account read sees, over the daemon's own. Spawned sessions keep their own env.
    env: Vec<(String, String)>,
    /// Folder with `.credentials.json`. `None` = from the environment. Tests point it at a temp dir.
    config_dir: Option<PathBuf>,
    /// The answer of `claude auth status`, asked at most once a minute.
    login: LoginCache,
}

impl ClaudeRuntime {
    pub fn new() -> Self {
        Self::with_program("claude")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
            env: Vec::new(),
            config_dir: None,
            login: LoginCache::default(),
        }
    }

    /// Environment for the account read (`CLAUDE_CONFIG_DIR`, `HOME`).
    pub fn with_env(mut self, env: Vec<(String, String)>) -> Self {
        self.env = env;
        self
    }

    /// Folder with `.credentials.json`, instead of the one the environment names.
    pub fn with_config_dir(mut self, dir: impl Into<PathBuf>) -> Self {
        self.config_dir = Some(dir.into());
        self
    }

    /// Folder with `.credentials.json`: the explicit one, else `CLAUDE_CONFIG_DIR`, else `$HOME/.claude`.
    fn credentials_dir(&self) -> Option<PathBuf> {
        if let Some(dir) = &self.config_dir {
            return Some(dir.clone());
        }
        let home = self.env_var("HOME").map(PathBuf::from).or_else(dirs::home_dir);
        config_dir_from(self.env_var("CLAUDE_CONFIG_DIR"), home)
    }

    /// `key` as the account read sees it: this runtime's own entries win, then the daemon's environment.
    fn env_var(&self, key: &str) -> Option<String> {
        self.env
            .iter()
            .rev()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.clone())
            .or_else(|| std::env::var(key).ok())
    }

    /// Whether the CLI is logged in and its plan, from `claude auth status` (cached, see [`LoginCache`]).
    async fn login(&self) -> LoginCheck {
        self.login
            .check(|| async {
                let probe = super::run_probe(
                    &self.program,
                    &["auth", "status"],
                    &self.env,
                    super::LOGIN_PROBE_TIMEOUT,
                )
                .await;
                login_from_auth_status(probe.as_ref())
            })
            .await
    }
}

/// The two fields of `claude auth status` that Bandito keeps. The account's email and organisation are not in this struct.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthStatus {
    logged_in: bool,
    subscription_type: Option<String>,
}

/// What `claude auth status` says. The CLI exits 1 when logged out and still prints its JSON, so the JSON decides
/// whatever the exit code; a run that was killed, or output that is not that JSON, is unknown: never "logged out".
pub fn login_from_auth_status(probe: Option<&ProbeOutput>) -> LoginCheck {
    let Some(probe) = probe.filter(|p| p.code.is_some()) else {
        return LoginCheck::unknown();
    };
    match serde_json::from_str::<AuthStatus>(&probe.stdout) {
        Ok(status) => LoginCheck {
            logged_in: Some(status.logged_in),
            plan: status
                .subscription_type
                .as_deref()
                .and_then(|subscription| plan_from_claude(subscription, None)),
        },
        Err(_) => {
            tracing::debug!("claude: auth status printed no readable answer");
            LoginCheck::unknown()
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
        let installed = version.is_some();
        let logged_in = if installed { self.login().await.logged_in } else { None };
        RuntimeStatus {
            kind: RuntimeKind::Claude,
            installed,
            version,
            logged_in,
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
        if let Some(effort) = cfg.effort {
            cmd.arg("--effort").arg(effort.as_str());
        }
        for dir in &cfg.extra_dirs {
            cmd.arg("--add-dir").arg(dir);
        }
        if let Some(prompt) = &cfg.system_prompt {
            cmd.arg("--append-system-prompt").arg(prompt);
        }
        if let Some(id) = &cfg.resume {
            cmd.arg("--resume").arg(id);
        }
        if let Some((prog, args)) = &cfg.mcp {
            let config = json!({
                "mcpServers": {"bandito": {"command": crate::runtime::path_text(prog)?, "args": args}}
            })
            .to_string();
            match &cfg.agent_mcp_file {
                // A file of its own, owner-only and removed with the session: the config stays out of argv.
                Some(file) => {
                    crate::agent_token::write_private(file, &config)?;
                    cmd.arg("--mcp-config").arg(file);
                }
                None => {
                    cmd.arg("--mcp-config").arg(config);
                }
            }
        }
        // The agent's file tools may not touch Bandito's own folder (see docs/ARCHITECTURE.md#approvals-policy).
        // The tools the policy decides are asked, so an `allow` in the user's or the project's settings
        // cannot run them without `can_use_tool`. Claude Code checks deny, then ask, then allow.
        // One argument of inline JSON, so no rule can be split at a space.
        let settings = json!({"permissions": {
            "deny": bandito_home_rules(&crate::workspace::data_dir()),
            "ask": POLICY_TOOLS,
        }});
        cmd.arg("--settings").arg(settings.to_string());
        cmd.current_dir(&cfg.cwd).envs(cfg.env.iter().map(|(k, v)| (k, v)));
        // Marks the CLI and its children for `host.processes` (see docs/ARCHITECTURE.md#host).
        cmd.env("BANDITO_AGENT_ID", &cfg.agent_id);
        if let Some(token) = &cfg.agent_token {
            cmd.env("BANDITO_AGENT_TOKEN", token);
        }

        let pending: PendingMap = Arc::new(Mutex::new(HashMap::new()));
        let router_pending = Arc::clone(&pending);
        let router: Router = Box::new(move |msg: &Value, sink: &LineSink| route(msg, &router_pending, sink));
        let cmd = crate::runtime::sandbox::wrap(cmd, cfg.sandbox.as_ref())?;
        let cmd = crate::workspace::confine(cmd, cfg.workspace.as_ref());
        let (proc, output) = JsonProcess::spawn(cmd, "claude", router)?;
        let init = json!({
            "type": "control_request",
            "request_id": INIT_REQUEST_ID,
            "request": {"subtype": "initialize"}
        });
        // A CLI that already died (e.g. not logged in) has closed its stdin. Its exit
        // reaches the caller as `Exited`, so a failed write here is not an error.
        let _ = proc.send(&init);

        Ok(Spawned {
            session: Box::new(ClaudeSession {
                proc,
                pending,
                next_request: 0,
            }),
            output,
        })
    }

    /// The subscription from `.credentials.json`. Without that file (macOS keeps the login in the Keychain)
    /// the plan is the one `claude auth status` names. An unreadable file gives `Ok(None)`.
    async fn account_plan(&self) -> anyhow::Result<Option<Plan>> {
        if let Some(dir) = self.credentials_dir() {
            let path = dir.join(CREDENTIALS_FILE);
            match tokio::fs::read(&path).await {
                Ok(bytes) => return Ok(plan_from_credentials(&bytes)),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    tracing::warn!(path = %path.display(), kind = ?e.kind(), "claude: could not read the account file");
                    return Ok(None);
                }
            }
        }
        Ok(self.login().await.plan)
    }
}

/// Where `.credentials.json` lives: `CLAUDE_CONFIG_DIR` when it is set and not blank, else `<home>/.claude`.
pub fn config_dir_from(claude_config_dir: Option<String>, home: Option<PathBuf>) -> Option<PathBuf> {
    match (claude_config_dir.filter(|dir| !dir.trim().is_empty()), home) {
        (Some(dir), _) => Some(PathBuf::from(dir)),
        (None, Some(home)) => Some(home.join(".claude")),
        (None, None) => None,
    }
}

/// Only the two fields the plan needs. Serde skips every other key, OAuth tokens included, so they never reach a struct.
#[derive(Deserialize)]
struct CredentialsFile {
    #[serde(rename = "claudeAiOauth")]
    oauth: Option<OauthAccount>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OauthAccount {
    subscription_type: Option<String>,
    rate_limit_tier: Option<String>,
}

/// The plan in a `.credentials.json` body. A broken file is logged without its content, since it holds tokens.
pub fn plan_from_credentials(bytes: &[u8]) -> Option<Plan> {
    let file: CredentialsFile = match serde_json::from_slice(bytes) {
        Ok(file) => file,
        Err(_) => {
            tracing::warn!("claude: .credentials.json is not readable; the plan stays unknown");
            return None;
        }
    };
    let oauth = file.oauth?;
    plan_from_claude(oauth.subscription_type.as_deref()?, oauth.rate_limit_tier.as_deref())
}

/// Plan from Claude's `subscriptionType` and `rateLimitTier`. The tier only tells the Max sizes apart.
pub fn plan_from_claude(subscription: &str, tier: Option<&str>) -> Option<Plan> {
    let raw = subscription.trim();
    let tier = tier.unwrap_or("").to_lowercase();
    let (id, label) = match raw.to_lowercase().as_str() {
        "" => return None,
        "max" if tier.contains("20x") => ("max_20x", "Max ×20"),
        "max" if tier.contains("5x") => ("max_5x", "Max ×5"),
        "max" => ("max", "Max"),
        "pro" => ("pro", "Pro"),
        "team" => ("team", "Team"),
        "enterprise" => ("enterprise", "Enterprise"),
        _ => {
            return Some(Plan {
                id: raw.to_string(),
                label: capitalized(raw),
            });
        }
    };
    Some(Plan {
        id: id.to_string(),
        label: label.to_string(),
    })
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

/// Tools tied to a known input shape. Any other tool has its path-like input strings checked too.
const KNOWN_TOOLS: &[&str] = &[
    "Bash",
    "Edit",
    "MultiEdit",
    "Write",
    "Read",
    "NotebookEdit",
    "WebFetch",
    "WebSearch",
    "Glob",
    "Grep",
    "LS",
    "Task",
    "TodoWrite",
];

/// The paths a tool call names, for the policy: the blocked path, the file it edits or reads,
/// the folder a search runs in, and for unknown tools every top-level string that looks like a path.
fn approval_paths(request: &Value, tool: &str, input: &Value) -> Vec<String> {
    if let Some(blocked) = str_field(request, "blocked_path") {
        return vec![blocked.to_string()];
    }
    let mut paths: Vec<String> = Vec::new();
    if let Some(path) = str_field(input, "file_path").or_else(|| str_field(input, "notebook_path")) {
        paths.push(path.to_string());
    }
    if matches!(tool, "Glob" | "Grep" | "LS") {
        paths.extend(str_field(input, "path").map(str::to_string));
    }
    if let (false, Some(fields)) = (KNOWN_TOOLS.contains(&tool), input.as_object()) {
        paths.extend(
            fields
                .values()
                .filter_map(Value::as_str)
                .filter(|s| looks_like_path(s))
                .map(str::to_string),
        );
    }
    paths
}

/// A string that names a file or folder: absolute, home-relative, or relative with a dot.
fn looks_like_path(text: &str) -> bool {
    text.starts_with('/') || text.starts_with('~') || text.starts_with("./") || text.starts_with("../")
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
    let paths = approval_paths(request, &tool, &input);
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

/// A live Claude Code process. Frames go out through [`JsonProcess::send`];
/// the process wrapper owns the child and reports its exit.
struct ClaudeSession {
    proc: JsonProcess,
    pending: PendingMap,
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
        self.proc.send(&json!({
            "type": "user",
            "message": {"role": "user", "content": text},
            "parent_tool_use_id": null,
            "session_id": "",
        }))
    }

    async fn interrupt(&mut self) -> anyhow::Result<()> {
        let id = self.next_request;
        self.next_request += 1;
        self.proc.send(&json!({
            "type": "control_request",
            "request_id": format!("int-{id}"),
            "request": {"subtype": "interrupt"}
        }))
    }

    async fn resolve(&mut self, key: &str, decision: Decision) -> anyhow::Result<()> {
        let Some(input) = self.take_pending(key) else {
            bail!("unknown approval {key}");
        };
        let response = match decision {
            Decision::Allow => json!({"behavior": "allow", "updatedInput": input}),
            Decision::Deny => json!({"behavior": "deny", "message": DENY_MESSAGE}),
        };
        self.proc.send(&json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": key, "response": response}
        }))
    }

    async fn shutdown(self: Box<Self>) {
        let this = *self;
        this.proc.shutdown().await;
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
        if let Err(e) = process::push_line(sink, "claude", &reply) {
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
    let usage = msg.get("usage").filter(|u| u.is_object());
    // The top level sums every API call of a multi-step turn. The context the
    // chapter holds now is the last call's, reported in `iterations`.
    let last_call = usage
        .and_then(|u| u.get("iterations"))
        .and_then(Value::as_array)
        .and_then(|calls| calls.last());
    if let Some(call) = last_call {
        let call = call_usage(call);
        out.push(RuntimeOutput::ContextSize(
            call.input_tokens.saturating_add(call.output_tokens),
        ));
    }
    out.push(RuntimeOutput::Event(EventBody::TurnCompleted {
        // The supervisor fills in the turn id.
        turn_id: String::new(),
        status,
        usage: usage.map(call_usage),
        cost_usd: msg.get("total_cost_usd").and_then(Value::as_f64),
    }));
}

/// Usage of one API call: input counts cache writes and reads too.
fn call_usage(u: &Value) -> Usage {
    let n = |key: &str| u.get(key).and_then(Value::as_u64).unwrap_or(0);
    Usage {
        input_tokens: n("input_tokens")
            .saturating_add(n("cache_creation_input_tokens"))
            .saturating_add(n("cache_read_input_tokens")),
        output_tokens: n("output_tokens"),
    }
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
    fn map_result_reports_the_last_call_as_context_and_the_total_as_usage() {
        // Two API calls in one turn: the first read a big context, the second is the context now held.
        let msg = json!({"type": "result", "subtype": "success", "is_error": false, "result": "done",
            "usage": {
                "input_tokens": 90, "cache_creation_input_tokens": 500, "cache_read_input_tokens": 150_000, "output_tokens": 900,
                "iterations": [
                    {"input_tokens": 80, "cache_creation_input_tokens": 400, "cache_read_input_tokens": 149_000, "output_tokens": 800},
                    {"input_tokens": 10, "cache_creation_input_tokens": 100, "cache_read_input_tokens": 20_000, "output_tokens": 100}
                ]
            }
        });
        assert_eq!(
            map_message(&msg),
            vec![
                RuntimeOutput::ContextSize(20_210),
                RuntimeOutput::Event(EventBody::TurnCompleted {
                    turn_id: String::new(),
                    status: TurnStatus::Ok,
                    usage: Some(Usage {
                        input_tokens: 150_590,
                        output_tokens: 900,
                    }),
                    cost_usd: None,
                }),
            ]
        );
    }

    #[test]
    fn map_result_with_empty_iterations_uses_the_top_level() {
        let msg = json!({"type": "result", "subtype": "success", "is_error": false, "result": "ok",
            "usage": {"input_tokens": 3, "output_tokens": 7, "iterations": []}
        });
        assert_eq!(
            map_message(&msg),
            vec![RuntimeOutput::Event(EventBody::TurnCompleted {
                turn_id: String::new(),
                status: TurnStatus::Ok,
                usage: Some(Usage {
                    input_tokens: 3,
                    output_tokens: 7,
                }),
                cost_usd: None,
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

    fn named(id: &str, label: &str) -> Plan {
        Plan {
            id: id.into(),
            label: label.into(),
        }
    }

    #[test]
    fn plan_from_claude_maps_max_tiers_and_plain_plans() {
        assert_eq!(
            plan_from_claude("max", Some("default_claude_max_20x")),
            Some(named("max_20x", "Max ×20"))
        );
        assert_eq!(
            plan_from_claude("max", Some("default_claude_max_5x")),
            Some(named("max_5x", "Max ×5"))
        );
        assert_eq!(plan_from_claude("max", None), Some(named("max", "Max")));
        assert_eq!(
            plan_from_claude("max", Some("default_claude_max")),
            Some(named("max", "Max"))
        );
        assert_eq!(
            plan_from_claude("pro", Some("default_claude_pro")),
            Some(named("pro", "Pro"))
        );
        assert_eq!(plan_from_claude("team", None), Some(named("team", "Team")));
        assert_eq!(
            plan_from_claude("enterprise", None),
            Some(named("enterprise", "Enterprise"))
        );
    }

    #[test]
    fn plan_from_claude_ignores_case_and_spaces() {
        assert_eq!(
            plan_from_claude("MAX", Some("  Default_Claude_Max_20X ")),
            Some(named("max_20x", "Max ×20"))
        );
        assert_eq!(plan_from_claude(" Max ", None), Some(named("max", "Max")));
        // The tier only refines `max`: a Pro account with a max-looking tier is Pro.
        assert_eq!(
            plan_from_claude("pro", Some("default_claude_max_20x")),
            Some(named("pro", "Pro"))
        );
    }

    #[test]
    fn plan_from_claude_names_other_plans_as_they_come() {
        assert_eq!(plan_from_claude("weird", None), Some(named("weird", "Weird")));
        assert_eq!(
            plan_from_claude("Custom Plan", None),
            Some(named("Custom Plan", "Custom Plan"))
        );
    }

    #[test]
    fn plan_from_claude_needs_a_subscription_type() {
        assert_eq!(plan_from_claude("", Some("default_claude_max_20x")), None);
        assert_eq!(plan_from_claude("   ", None), None);
    }

    #[test]
    fn config_dir_prefers_claude_config_dir_then_home() {
        assert_eq!(
            config_dir_from(Some("/opt/claude".into()), Some("/home/u".into())),
            Some(PathBuf::from("/opt/claude"))
        );
        assert_eq!(
            config_dir_from(Some("  ".into()), Some("/home/u".into())),
            Some(PathBuf::from("/home/u/.claude"))
        );
        assert_eq!(
            config_dir_from(None, Some("/home/u".into())),
            Some(PathBuf::from("/home/u/.claude"))
        );
        assert_eq!(config_dir_from(None, None), None);
    }

    const CREDENTIALS: &str = r#"{"claudeAiOauth": {"accessToken": "SECRET-ACCESS-123", "refreshToken": "SECRET-REFRESH-456", "expiresAt": 1791543600000, "scopes": ["user:inference"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}"#;

    fn dir_with_credentials(content: &str) -> tempfile::TempDir {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".credentials.json"), content).unwrap();
        dir
    }

    #[tokio::test]
    async fn account_plan_reads_the_subscription_and_never_the_tokens() {
        let dir = dir_with_credentials(CREDENTIALS);
        let plan = ClaudeRuntime::new()
            .with_config_dir(dir.path())
            .account_plan()
            .await
            .unwrap()
            .expect("a plan");
        assert_eq!(plan, named("max_20x", "Max ×20"));
        let debug = format!("{plan:?}");
        let json = serde_json::to_string(&plan).unwrap();
        for text in [debug, json] {
            assert!(!text.contains("SECRET"), "token leaked into {text}");
        }
    }

    #[tokio::test]
    async fn account_plan_uses_claude_config_dir_from_the_runtime_env() {
        let dir = dir_with_credentials(CREDENTIALS);
        let rt = ClaudeRuntime::new().with_env(vec![
            ("CLAUDE_CONFIG_DIR".into(), dir.path().display().to_string()),
            ("HOME".into(), "/nonexistent-home".into()),
        ]);
        assert_eq!(rt.account_plan().await.unwrap(), Some(named("max_20x", "Max ×20")));
    }

    #[tokio::test]
    async fn account_plan_is_none_without_the_file_or_a_cli() {
        // No real `claude` here: with no file, the plan comes from `claude auth status` (see login_tests).
        let dir = tempfile::tempdir().unwrap();
        let plan = ClaudeRuntime::with_program("/nonexistent/claude")
            .with_config_dir(dir.path())
            .account_plan()
            .await
            .unwrap();
        assert_eq!(plan, None);
    }

    #[tokio::test]
    async fn account_plan_is_none_for_broken_or_incomplete_files() {
        for content in [
            r#"{"claudeAiOauth": {"accessToken": "SECRET-"#,
            "{}",
            r#"{"claudeAiOauth": {"accessToken": "SECRET-ONLY"}}"#,
            r#"{"claudeAiOauth": "SECRET-STRING"}"#,
            r#"{"claudeAiOauth": {"subscriptionType": ""}}"#,
        ] {
            let dir = dir_with_credentials(content);
            let plan = ClaudeRuntime::new()
                .with_config_dir(dir.path())
                .account_plan()
                .await
                .unwrap();
            assert_eq!(plan, None, "{content}");
        }
    }
}

#[cfg(test)]
mod approval_path_tests {
    use super::*;

    fn control(tool: &str, input: Value) -> Value {
        json!({"type": "control_request", "request_id": "k1", "request": {
            "subtype": "can_use_tool", "tool_name": tool, "tool_use_id": "t1", "input": input}})
    }

    #[test]
    fn search_tools_path_is_checked() {
        let req = approval_from_control(&control("Grep", json!({"pattern": "x", "path": "/home/u/.bandito"}))).unwrap();
        assert!(req.paths.iter().any(|p| p == "/home/u/.bandito"), "{:?}", req.paths);
        let req = approval_from_control(&control("Glob", json!({"pattern": "*", "path": "/home/u/.bandito"}))).unwrap();
        assert!(req.paths.iter().any(|p| p == "/home/u/.bandito"), "{:?}", req.paths);
    }

    #[test]
    fn unknown_tool_path_like_fields_are_checked() {
        let req = approval_from_control(&control("SomeNewTool", json!({"target": "~/.bandito/x", "n": 3}))).unwrap();
        assert!(req.paths.iter().any(|p| p == "~/.bandito/x"), "{:?}", req.paths);
    }
}

#[cfg(test)]
mod login_tests {
    use super::*;
    use crate::runtime::{LoginCheck, ProbeOutput};

    fn exit0(stdout: &str) -> ProbeOutput {
        ProbeOutput {
            code: Some(0),
            stdout: stdout.into(),
            stderr: String::new(),
        }
    }

    #[test]
    fn logged_in_with_a_subscription_names_the_plan() {
        let check = login_from_auth_status(Some(&exit0(
            r#"{"loggedIn": true, "subscriptionType": "pro", "email": "a@b.example", "orgId": "org-1"}"#,
        )));
        assert_eq!(check.logged_in, Some(true));
        assert_eq!(
            check.plan,
            Some(Plan {
                id: "pro".into(),
                label: "Pro".into()
            })
        );
        assert!(
            !format!("{check:?}").contains("a@b.example"),
            "the account email is not kept"
        );
    }

    #[test]
    fn logged_out_is_false_without_a_plan() {
        assert_eq!(
            login_from_auth_status(Some(&exit0(r#"{"loggedIn": false}"#))),
            LoginCheck {
                logged_in: Some(false),
                plan: None
            }
        );
    }

    #[test]
    fn logged_in_without_a_subscription_has_no_plan() {
        assert_eq!(
            login_from_auth_status(Some(&exit0(r#"{"loggedIn": true}"#))),
            LoginCheck {
                logged_in: Some(true),
                plan: None
            }
        );
    }

    #[test]
    fn logged_out_exits_1_and_still_answers() {
        // Real output of claude 2.1.295 on a server where nobody signed in: exit 1 with the JSON.
        let logged_out = ProbeOutput {
            code: Some(1),
            stdout: r#"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#.into(),
            stderr: String::new(),
        };
        assert_eq!(
            login_from_auth_status(Some(&logged_out)),
            LoginCheck {
                logged_in: Some(false),
                plan: None
            }
        );
        let failed = ProbeOutput {
            code: Some(1),
            stdout: String::new(),
            stderr: "boom".into(),
        };
        assert_eq!(login_from_auth_status(Some(&failed)), LoginCheck::unknown());
    }

    #[test]
    fn a_killed_run_or_no_answer_is_unknown() {
        assert_eq!(login_from_auth_status(None), LoginCheck::unknown());
        let killed = ProbeOutput {
            code: None,
            stdout: r#"{"loggedIn": true}"#.into(),
            stderr: String::new(),
        };
        assert_eq!(login_from_auth_status(Some(&killed)), LoginCheck::unknown());
    }

    #[test]
    fn unreadable_output_is_unknown() {
        for stdout in ["", "hello", r#"{"loggedOn": true}"#, r#"{"loggedIn": "yes"}"#, "[1, 2]"] {
            assert_eq!(
                login_from_auth_status(Some(&exit0(stdout))),
                LoginCheck::unknown(),
                "{stdout}"
            );
        }
    }

    #[test]
    fn bandito_home_rules_escape_glob_characters_in_the_folder_name() {
        // Parentheses, brackets and wildcards in the folder's own name match themselves, not the pattern.
        let rules = bandito_home_rules(std::path::Path::new("/srv/a(b)[c]*d?"));
        assert_eq!(
            rules,
            [
                "Read(//srv/a[(]b[)][[]c[]][*]d[?]/**)",
                "Edit(//srv/a[(]b[)][[]c[]][*]d[?]/**)",
                "Write(//srv/a[(]b[)][[]c[]][*]d[?]/**)",
            ]
        );
        // Braces and `!` and backslashes match themselves too.
        let rules = bandito_home_rules(std::path::Path::new("/srv/a{b}!c\\d"));
        assert_eq!(rules[0], "Read(//srv/a[{]b[}]\\!c\\\\d/**)");
        // A plain path is unchanged.
        assert_eq!(
            bandito_home_rules(std::path::Path::new("/home/u/.bandito"))[0],
            "Read(//home/u/.bandito/**)"
        );
    }
}
