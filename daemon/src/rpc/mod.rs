//! JSON-RPC 2.0, the same on every transport (unix socket, WebSocket).
//! See docs/ARCHITECTURE.md#rpc.

use crate::browser::BrowserManager;
use crate::commands::prepare as prepare_message;
use crate::event::{Decision, Event, EventBody, Source};
use crate::files::FileService;
use crate::home;
use crate::host::Sampler;
use crate::logs;
use crate::pairing;
use crate::redact::Redactor;
use crate::runtime::RuntimeKind;
use crate::scheduler;
use crate::setup::Setup;
use crate::store::{
    AgentPatch, Device, Effort, NewAgent, NewSchedule, NextRun, RuleAction, SHARED_WORKSPACE, SchedulePatch, Store,
};
use crate::supervisor::Supervisor;
use crate::terminal::{Limits, TerminalManager};
use crate::update;
use chrono::{Local, NaiveDate, NaiveTime, TimeZone};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};

pub mod browser;
pub mod changes;
pub mod commands;
pub mod files;
pub mod host;
pub mod preview;
pub mod screen;
pub mod secrets;
pub mod setup;
pub mod term;
pub mod tunnel;
pub mod unix;
pub mod workspaces;
pub mod ws;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Capabilities this daemon offers. Clients show a feature only when it is
/// listed, so new apps keep working with older daemons. Add a string here in
/// the same PR that adds the feature. `screen` is offered on Linux only.
pub fn features() -> Vec<&'static str> {
    let mut list = vec![
        "approvals",
        "rules",
        "schedules",
        "crew",
        "pairing",
        "usage",
        "memory",
        "history",
        "terminals",
        "files",
        "tunnel",
        "changes",
        "secrets",
        "host",
        "setup",
        "commands",
        "workspaces",
        "browser",
        "update",
        "pause",
        "logs",
        "agent_own_folder",
        "runtime_models",
    ];
    if cfg!(target_os = "linux") {
        list.push("screen");
    }
    list
}

/// Context budget bounds for `smart` memory, in tokens.
const CONTEXT_BUDGET: std::ops::RangeInclusive<u32> = 20_000..=1_000_000;
/// How long one runtime may take to answer `usage.refresh`.
const USAGE_REFRESH_TIMEOUT: Duration = Duration::from_secs(20);

/// Shared state for all connections.
pub struct App {
    pub sup: Arc<Supervisor>,
    pub started_at: i64,
    pub hostname: String,
    /// Root of the per-agent folders (see `home::ensure_agent_home`).
    pub agents_root: PathBuf,
    /// Persistent terminals (see docs/ARCHITECTURE.md#terminals). Lives as long as the daemon.
    pub terminals: TerminalManager,
    /// Failed `pair.redeem` calls, for the rate limit (see [`RedeemLimiter`]).
    redeem: Mutex<RedeemLimiter>,
    /// Server files for the `fs.*` methods and `GET /v1/files/raw`.
    pub files: Arc<FileService>,
    /// Live TCP tunnels per device (see docs/ARCHITECTURE.md#tunnel).
    pub tunnels: Arc<tunnel::TunnelSlots>,
    /// Load, processes and ports of this server (see docs/ARCHITECTURE.md#host). Sampled by a task started in `main`.
    pub host: Arc<Sampler>,
    /// Components the features need, and installing them (see docs/ARCHITECTURE.md#setup).
    pub setup: Arc<Setup>,
    /// The server's browser, one per workspace (see docs/ARCHITECTURE.md#browser).
    pub browser: Arc<BrowserManager>,
    /// The server screen, one per workspace (see docs/ARCHITECTURE.md#screen).
    pub screens: Arc<crate::screen::ScreenManager>,
    /// The daemon's data folder (`--home`, `BANDITO_HOME` or `~/.bandito`): where its log file is.
    pub data_home: PathBuf,
    /// The models each agent CLI offers, as last read (see docs/ARCHITECTURE.md#runtime-models).
    pub models: crate::runtime::models::ModelCache,
}

impl App {
    /// Files are served from the home folder of the user running the daemon.
    pub fn new(sup: Arc<Supervisor>, agents_root: PathBuf) -> Arc<Self> {
        Self::new_with_files(sup, agents_root, Self::default_files())
    }

    /// The server files the `fs.*` methods serve: the home folder of the user running the daemon.
    pub fn default_files() -> FileService {
        FileService::new(dirs::home_dir().unwrap_or_else(|| PathBuf::from("/")), None)
    }

    pub fn new_with_files(sup: Arc<Supervisor>, agents_root: PathBuf, files: FileService) -> Arc<Self> {
        Self::new_in_home(sup, agents_root, files, crate::setup::default_home())
    }

    /// The daemon of data folder `data_home` (see `daemon.logs`).
    pub fn new_in_home(
        sup: Arc<Supervisor>,
        agents_root: PathBuf,
        files: FileService,
        data_home: PathBuf,
    ) -> Arc<Self> {
        Arc::new(Self {
            sup,
            started_at: crate::store::now_ms(),
            hostname: hostname(),
            agents_root,
            terminals: TerminalManager::new(Limits::default()),
            redeem: Mutex::new(RedeemLimiter::default()),
            files: Arc::new(files),
            tunnels: Arc::new(tunnel::TunnelSlots::default()),
            host: Sampler::new(),
            setup: Setup::system(),
            browser: BrowserManager::system(),
            screens: Arc::new(crate::screen::ScreenManager::new(screens_dir())),
            data_home,
            models: crate::runtime::models::ModelCache::default(),
        })
    }
}

/// Where screen state (VNC password files, one folder per workspace) lives: `<data dir>/screens`.
fn screens_dir() -> PathBuf {
    crate::setup::default_home().join("screens")
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "server".into())
}

/// Who is on the other end of a connection. What each one may call is in [`allowed`]
/// (see docs/ARCHITECTURE.md#trust-model).
#[derive(Debug, Clone)]
pub enum Peer {
    /// The owner's CLI on `bandito.sock`: same user, and not a process under the daemon.
    Local,
    /// A paired app.
    Device(Device),
    /// Not authenticated yet: only `daemon.hello` and `pair.redeem`. Holds where the
    /// connection came from (an IP for WebSocket), for the rate limit of `pair.redeem`.
    Anonymous(String),
    /// An agent's crew server on `agent.sock`, with the agent its session token names.
    Agent(String),
}

/// Methods an agent's crew server may call. Nothing else is open to agents.
const AGENT_METHODS: &[&str] = &[
    "daemon.hello",
    "crew.list",
    "crew.send",
    "history.day",
    "history.search",
    "browser.agent.back",
    "browser.agent.click",
    "browser.agent.open",
    "browser.agent.press",
    "browser.agent.screenshot",
    "browser.agent.snapshot",
    "browser.agent.switch",
    "browser.agent.tabs",
    "browser.agent.type",
    "screen.agent.click",
    "screen.agent.key",
    "screen.agent.launch",
    "screen.agent.move",
    "screen.agent.screenshot",
    "screen.agent.scroll",
    "screen.agent.type",
];

/// The calls only agents make (the crew tools). The owner's CLI and the apps may not make them,
/// so that nothing that speaks as the owner can pass for an agent.
pub fn is_agent_only(method: &str) -> bool {
    method == "crew.send"
        || method.starts_with("history.")
        || method.starts_with("browser.agent.")
        || method.starts_with("screen.agent.")
}

/// Whether `peer` may call `method` at all. [`dispatch`] and the event stream check it first.
pub fn allowed(peer: &Peer, method: &str) -> bool {
    match peer {
        Peer::Anonymous(_) => matches!(method, "daemon.hello" | "pair.redeem"),
        Peer::Agent(_) => AGENT_METHODS.contains(&method),
        Peer::Local | Peer::Device(_) => !is_agent_only(method),
    }
}

/// The refusal for a call `peer` may not make.
fn denied(peer: &Peer, method: &str) -> RpcError {
    match peer {
        Peer::Anonymous(_) => RpcError::new(UNAUTHORIZED, "not paired: run `bandito pair` on the server"),
        Peer::Agent(_) => RpcError::new(UNAUTHORIZED, format!("agents cannot call {method}")),
        Peer::Local | Peer::Device(_) => RpcError::new(UNAUTHORIZED, format!("{method} is only for agents")),
    }
}

/// Makes an agent's params its own: `agent_id` and `from` must name the agent its token names
/// (anything else is refused) and are filled in when missing.
fn bind_to_agent(agent: &str, mut p: Value) -> Result<Value, RpcError> {
    if p.is_null() {
        p = json!({});
    }
    let Some(object) = p.as_object_mut() else {
        return Ok(p);
    };
    for key in ["agent_id", "from"] {
        if object.get(key).is_some_and(|v| v.as_str() != Some(agent)) {
            return Err(RpcError::new(UNAUTHORIZED, "an agent can only act as itself"));
        }
        object.insert(key.to_string(), json!(agent));
    }
    Ok(p)
}

/// Where a `pair.redeem` comes from, for its rate limit.
fn redeem_source(peer: &Peer) -> String {
    match peer {
        Peer::Local => "local".into(),
        Peer::Anonymous(source) => source.clone(),
        Peer::Device(device) => format!("device:{}", device.id),
        Peer::Agent(agent) => format!("agent:{agent}"),
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RpcError {
    pub code: i64,
    pub message: String,
    /// Machine-readable details, sent as JSON-RPC error.data.
    pub data: Option<Value>,
}

pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const SERVER_ERROR: i64 = -32000;
pub const UNAUTHORIZED: i64 = -32001;
pub const RATE_LIMITED: i64 = -32002;
pub const TERM_ERROR: i64 = -32021;
/// A file operation failed; `error.data.reason` says why (see rpc::files).
pub const FS_ERROR: i64 = -32020;
/// A checkpoint or git operation failed; `error.data.reason` says why (see rpc::changes).
pub const CHANGES_ERROR: i64 = -32022;
/// A host method failed; `error.data.reason` says why (see rpc::host).
pub const HOST_ERROR: i64 = -32023;
/// A setup method failed; `error.data.reason` says why (see rpc::setup).
pub const SETUP_ERROR: i64 = -32024;
/// A browser method failed; `error.data.reason` says why (see rpc::browser).
pub const BROWSER_ERROR: i64 = -32026;
/// A screen call failed; `error.data.reason` says why (see rpc::screen).
pub const SCREEN_ERROR: i64 = -32025;
/// A command or skill call failed; `error.data.reason` says why (see rpc::commands).
pub const COMMANDS_ERROR: i64 = -32027;
/// Workspace failures; `error.data.reason` says which (see docs/ARCHITECTURE.md#workspaces).
pub const WORKSPACE_ERROR: i64 = -32028;

impl RpcError {
    fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }

    pub fn with_data(code: i64, message: impl Into<String>, data: Value) -> Self {
        Self {
            code,
            message: message.into(),
            data: Some(data),
        }
    }
}

impl From<anyhow::Error> for RpcError {
    fn from(e: anyhow::Error) -> Self {
        match e.downcast_ref::<crate::workspace::WorkspaceError>() {
            Some(w) => Self::with_data(WORKSPACE_ERROR, w.to_string(), json!({ "reason": w.reason() })),
            None => Self::new(SERVER_ERROR, format!("{e:#}")),
        }
    }
}

type RpcResult = Result<Value, RpcError>;

fn params<T: DeserializeOwned>(v: Value) -> Result<T, RpcError> {
    let v = if v.is_null() { json!({}) } else { v };
    serde_json::from_value(v).map_err(|e| RpcError::new(INVALID_PARAMS, format!("invalid params: {e}")))
}

fn ok<T: serde::Serialize>(v: T) -> RpcResult {
    serde_json::to_value(v).map_err(|e| RpcError::new(SERVER_ERROR, e.to_string()))
}

const MAX_MESSAGE_BYTES: usize = 100 * 1024;
const REDEEM_WINDOW_MS: i64 = 10 * 60 * 1000;
/// Failed `pair.redeem` calls allowed in the window, for the whole daemon.
const REDEEM_MAX_FAILURES: usize = 100;
/// Failed `pair.redeem` calls allowed in the window from one source (an IP, or `local`).
const REDEEM_MAX_FAILURES_PER_SOURCE: usize = 5;

/// Failed `pair.redeem` calls by time, for the whole daemon and for each source.
#[derive(Default)]
pub struct RedeemLimiter {
    all: VecDeque<i64>,
    by_source: HashMap<String, VecDeque<i64>>,
}

impl RedeemLimiter {
    /// Whether a call from `source` may be tried at `now` (unix ms).
    pub fn allows(&mut self, source: &str, now: i64) -> bool {
        prune(&mut self.all, now);
        self.by_source.retain(|_, failures| {
            prune(failures, now);
            !failures.is_empty()
        });
        self.all.len() < REDEEM_MAX_FAILURES
            && self.by_source.get(source).map_or(0, VecDeque::len) < REDEEM_MAX_FAILURES_PER_SOURCE
    }

    /// Records a failed call from `source` at `now`.
    pub fn failed(&mut self, source: &str, now: i64) {
        self.all.push_back(now);
        self.by_source.entry(source.to_string()).or_default().push_back(now);
    }
}

/// Drops the failures older than the window.
fn prune(failures: &mut VecDeque<i64>, now: i64) {
    while failures.front().is_some_and(|t| *t < now - REDEEM_WINDOW_MS) {
        failures.pop_front();
    }
}

#[derive(Deserialize)]
struct Id {
    id: String,
}
#[derive(Deserialize)]
struct ModelsParams {
    runtime: Option<String>,
    refresh: Option<bool>,
}
#[derive(Deserialize)]
struct AgentRef {
    agent_id: String,
}
#[derive(Deserialize)]
struct MaybeAgent {
    #[serde(default)]
    agent_id: Option<String>,
}
/// `agents.create`: a new agent, optionally in a workspace other than `shared`.
#[derive(Deserialize)]
struct CreateAgent {
    #[serde(flatten)]
    agent: NewAgent,
    #[serde(default)]
    workspace_id: Option<String>,
}
#[derive(Deserialize)]
struct UpdateAgent {
    id: String,
    #[serde(flatten)]
    patch: AgentPatchParams,
}
/// `AgentPatch` with explicit nulls: `{"model": null}` clears the model.
#[derive(Deserialize, Default)]
struct AgentPatchParams {
    name: Option<String>,
    role: Option<String>,
    #[serde(default, deserialize_with = "double_option")]
    model: Option<Option<String>>,
    cwd: Option<String>,
    approval_mode: Option<crate::store::ApprovalMode>,
    #[serde(default, deserialize_with = "double_option")]
    system_prompt: Option<Option<String>>,
    #[serde(default, deserialize_with = "double_option")]
    effort: Option<Option<crate::store::Effort>>,
    memory_mode: Option<crate::store::MemoryMode>,
    #[serde(default, deserialize_with = "double_option")]
    context_budget: Option<Option<u32>>,
    workspace_id: Option<String>,
    runtime: Option<RuntimeKind>,
    #[serde(default, deserialize_with = "double_option")]
    fallback_runtime: Option<Option<RuntimeKind>>,
    #[serde(default, deserialize_with = "double_option")]
    fallback_model: Option<Option<String>>,
    /// Pauses or resumes the agent (see docs/ARCHITECTURE.md#pause). Not stored with the other fields.
    paused: Option<bool>,
    use_personal_settings: Option<bool>,
}
impl AgentPatchParams {
    /// Whether the patch changes something a running session was started with, so
    /// the session must be reloaded. Compared with the agent's current values: a
    /// form sent back unchanged changes nothing. `approval_mode` is not part of it:
    /// approvals read it from the store on every request.
    fn changes_session(&self, current: &crate::store::Agent) -> bool {
        let Self {
            name,
            role,
            model,
            cwd,
            approval_mode: _,
            system_prompt,
            effort,
            memory_mode,
            context_budget,
            runtime,
            // A fallback is read when a limit is hit: nothing to reload now.
            fallback_runtime: _,
            fallback_model: _,
            workspace_id,
            // Applied by `Supervisor::set_paused`: a pause starts no new session.
            paused: _,
            use_personal_settings,
        } = self;
        workspace_id.as_ref().is_some_and(|w| *w != current.workspace_id)
            || runtime.as_ref().is_some_and(|r| *r != current.runtime)
            || name.as_ref().is_some_and(|n| n.trim() != current.name)
            || role.as_ref().is_some_and(|r| *r != current.role)
            || model.as_ref().is_some_and(|m| *m != current.model)
            || cwd.as_ref().is_some_and(|c| *c != current.cwd)
            || system_prompt.as_ref().is_some_and(|p| *p != current.system_prompt)
            || effort.as_ref().is_some_and(|e| *e != current.effort)
            || memory_mode.as_ref().is_some_and(|m| *m != current.memory_mode)
            || context_budget.as_ref().is_some_and(|b| *b != current.context_budget)
            || use_personal_settings
                .as_ref()
                .is_some_and(|u| *u != current.use_personal_settings)
    }
}
/// `{"x": null}` → `Some(None)` (clear), missing → `None` (keep).
fn double_option<'de, D: serde::Deserializer<'de>, T: Deserialize<'de>>(d: D) -> Result<Option<Option<T>>, D::Error> {
    Option::<T>::deserialize(d).map(Some)
}
#[derive(Deserialize)]
struct PauseAllParams {
    paused: bool,
}
#[derive(Deserialize)]
struct LogsParams {
    #[serde(default = "default_log_lines")]
    lines: u32,
    #[serde(default)]
    level: Option<String>,
}
fn default_log_lines() -> u32 {
    logs::DEFAULT_LINES
}
#[derive(Deserialize)]
struct SendParams {
    agent_id: String,
    text: String,
}
#[derive(Deserialize)]
struct SinceParams {
    #[serde(default)]
    after: i64,
    #[serde(default = "default_limit")]
    limit: u32,
    #[serde(default)]
    agent_id: Option<String>,
}
fn default_limit() -> u32 {
    500
}
#[derive(Deserialize)]
struct ResolveParams {
    approval_id: String,
    decision: Decision,
    #[serde(default)]
    remember: bool,
}
#[derive(Deserialize)]
struct RuleParams {
    #[serde(default)]
    agent_id: Option<String>,
    pattern: String,
    action: RuleAction,
}
#[derive(Deserialize)]
struct ScheduleUpdate {
    id: String,
    #[serde(flatten)]
    patch: SchedulePatch,
}
#[derive(Deserialize)]
struct RedeemParams {
    code: String,
    device_name: String,
}
#[derive(Deserialize)]
struct CrewSendParams {
    from: String,
    to: String,
    message: String,
}
#[derive(Deserialize)]
struct HistorySearchParams {
    agent_id: String,
    query: String,
    #[serde(default = "default_history_limit")]
    limit: u32,
}
fn default_history_limit() -> u32 {
    20
}
#[derive(Deserialize)]
struct HistoryDayParams {
    agent_id: String,
    date: String,
}

/// Most messages `history.day` reads for one day.
const HISTORY_DAY_LIMIT: u32 = 500;
/// Longest text of one message in a history reply, in characters.
const HISTORY_LINE_CHARS: usize = 600;
/// Longest history reply, in characters.
const HISTORY_REPLY_CHARS: usize = 8000;
const HISTORY_MORE: &str = "… (more; narrow the search)";

fn check_cwd(cwd: &str) -> Result<(), RpcError> {
    let p = std::path::Path::new(cwd);
    if !p.is_absolute() {
        return Err(RpcError::new(
            INVALID_PARAMS,
            "cwd must be an absolute path on the server",
        ));
    }
    if !p.is_dir() {
        return Err(RpcError::new(
            INVALID_PARAMS,
            format!("folder not found on the server: {cwd}"),
        ));
    }
    Ok(())
}

/// Effort levels each runtime accepts (see docs/ARCHITECTURE.md#memory-and-context).
pub fn supported_efforts(kind: RuntimeKind) -> &'static [Effort] {
    match kind {
        RuntimeKind::Claude | RuntimeKind::Api => {
            &[Effort::Low, Effort::Medium, Effort::High, Effort::Xhigh, Effort::Max]
        }
        RuntimeKind::Codex => &[Effort::Low, Effort::Medium, Effort::High, Effort::Xhigh],
        RuntimeKind::Grok => &[Effort::Low, Effort::Medium, Effort::High],
    }
}

fn check_effort(kind: RuntimeKind, effort: Option<Effort>) -> Result<(), RpcError> {
    match effort {
        Some(e) if !supported_efforts(kind).contains(&e) => Err(RpcError::new(
            INVALID_PARAMS,
            format!("{} doesn't offer effort {}", kind.as_str(), e.as_str()),
        )),
        _ => Ok(()),
    }
}

/// A fallback is one of the subscription runtimes, and not the agent's primary runtime.
fn check_fallback(primary: RuntimeKind, fallback: Option<RuntimeKind>) -> Result<(), RpcError> {
    match fallback {
        None => Ok(()),
        Some(RuntimeKind::Api) => Err(RpcError::new(
            INVALID_PARAMS,
            "fallback runtime must be claude, codex or grok",
        )),
        Some(fb) if fb == primary => Err(RpcError::new(
            INVALID_PARAMS,
            "fallback runtime must differ from the agent's runtime",
        )),
        Some(_) => Ok(()),
    }
}

fn check_context_budget(budget: Option<u32>) -> Result<(), RpcError> {
    match budget {
        Some(b) if !CONTEXT_BUDGET.contains(&b) => Err(RpcError::new(
            INVALID_PARAMS,
            "context budget must be between 20 000 and 1 000 000 tokens",
        )),
        _ => Ok(()),
    }
}

fn history_agent_name(store: &Store, agent_id: &str) -> Result<String, RpcError> {
    store
        .agent_get(agent_id)?
        .map(|a| a.name)
        .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {agent_id}")))
}

/// Strict `YYYY-MM-DD`: the date must print back exactly as it was given.
fn parse_day(s: &str) -> Result<NaiveDate, RpcError> {
    NaiveDate::parse_from_str(s, "%Y-%m-%d")
        .ok()
        .filter(|d| d.format("%Y-%m-%d").to_string() == s)
        .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("date must be YYYY-MM-DD, got {s}")))
}

/// Unix milliseconds of local midnight at the start of `day` and of the next day.
fn local_day_bounds(day: NaiveDate) -> Result<(i64, i64), RpcError> {
    let midnight = |d: NaiveDate| {
        Local
            .from_local_datetime(&d.and_time(NaiveTime::MIN))
            .earliest()
            .map(|t| t.timestamp_millis())
            .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no local midnight on {d}")))
    };
    let next = day
        .succ_opt()
        .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("date out of range: {day}")))?;
    Ok((midnight(day)?, midnight(next)?))
}

/// Readable transcript of stored messages, one line each, in the order given:
/// `YYYY-MM-DD HH:MM · <who>: <text>`. Stays within `HISTORY_REPLY_CHARS`.
fn format_history(events: &[Event], agent_name: &str) -> String {
    let lines: Vec<String> = events.iter().filter_map(|e| history_line(e, agent_name)).collect();
    if lines.is_empty() {
        return "Nothing found.".into();
    }
    join_within(&lines, HISTORY_REPLY_CHARS)
}

fn history_line(e: &Event, agent_name: &str) -> Option<String> {
    let (who, text) = match &e.body {
        EventBody::MessageUser {
            text,
            source,
            from_agent,
            ..
        } => {
            let who = match source {
                Source::User => "user".to_string(),
                Source::Schedule => "schedule".to_string(),
                Source::Crew => from_agent.clone().unwrap_or_else(|| "crew".to_string()),
                Source::System => "system".to_string(),
            };
            (who, text.as_str())
        }
        EventBody::MessageAssistant { text } => (agent_name.to_string(), text.as_str()),
        // The history queries return messages only.
        _ => return None,
    };
    Some(format!(
        "{} · {who}: {}",
        local_minute(e.ts),
        one_line(text, HISTORY_LINE_CHARS)
    ))
}

fn local_minute(ts_ms: i64) -> String {
    match Local.timestamp_millis_opt(ts_ms).single() {
        Some(t) => t.format("%Y-%m-%d %H:%M").to_string(),
        None => "unknown time".into(),
    }
}

/// Line breaks become " ⏎ "; text longer than `max` characters is cut and marked with "…".
fn one_line(text: &str, max: usize) -> String {
    let joined = text.trim().lines().collect::<Vec<_>>().join(" ⏎ ");
    if joined.chars().count() <= max {
        return joined;
    }
    let mut cut: String = joined.chars().take(max.saturating_sub(1)).collect();
    cut.push('…');
    cut
}

/// Join lines with newlines. If the result would exceed `max` characters, keep
/// the lines that fit and end with the "more" marker, which counts toward `max`.
fn join_within(lines: &[String], max: usize) -> String {
    let full = lines.join("\n");
    if full.chars().count() <= max {
        return full;
    }
    let budget = max.saturating_sub(HISTORY_MORE.chars().count() + 1);
    let mut out = String::new();
    let mut used = 0;
    for line in lines {
        let add = line.chars().count() + usize::from(!out.is_empty());
        if used + add > budget {
            break;
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(line);
        used += add;
    }
    out.push('\n');
    out.push_str(HISTORY_MORE);
    out
}

/// `daemon.logs`: the newest daemon log lines, redacted (see docs/ARCHITECTURE.md#logs).
/// The file or journal is read off the async runtime.
async fn daemon_logs(app: &App, lines: usize, min: Option<logs::Level>) -> Result<Value, RpcError> {
    let redactor = Redactor::new(app.sup.hub().store.secrets_all()?);
    let source = logs::Source::for_home(&app.data_home);
    let name = source.name();
    let read = tokio::task::spawn_blocking(move || source.read(lines, min))
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("read the log: {e}")))?;
    let read = read.map_err(|e| RpcError::new(SERVER_ERROR, format!("read the log: {e}")))?;
    let lines: Vec<String> = read
        .iter()
        .map(|line| logs::mask_tokens(&redactor.redact(line)))
        .collect();
    Ok(json!({ "source": name, "lines": lines }))
}

/// One row of `devices.list`: the device, and whether it is the one asking.
#[derive(serde::Serialize)]
struct DeviceRow<'a> {
    #[serde(flatten)]
    device: &'a Device,
    current: bool,
}

/// Handle one request. `events.subscribe` lives in [`serve`] because it needs
/// connection state.
pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    if !allowed(peer, method) {
        return Err(denied(peer, method));
    }
    let p = match peer {
        Peer::Agent(agent) => bind_to_agent(agent, p)?,
        _ => p,
    };
    if method.starts_with("fs.") {
        // Every `fs.*` name is answered there, unknown ones with METHOD_NOT_FOUND.
        return files::dispatch(app, method, p)
            .await
            .unwrap_or_else(|| Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))));
    }
    if method.starts_with("browser.") {
        // Every `browser.*` name is answered there, unknown ones with METHOD_NOT_FOUND.
        return browser::dispatch(app, peer, method, p).await;
    }
    if method.starts_with("screen.") {
        return screen::dispatch(app, peer, method, p).await;
    }
    if method.starts_with("workspaces.") {
        // Every `workspaces.*` name is answered there, unknown ones with METHOD_NOT_FOUND.
        return workspaces::dispatch(app, method, p).await;
    }
    if method.starts_with("commands.") {
        // Every `commands.*` name is answered there, unknown ones with METHOD_NOT_FOUND.
        return commands::dispatch(app, method, p).await;
    }
    if method.starts_with("changes.") {
        // Every `changes.*` name is answered there, unknown ones with METHOD_NOT_FOUND.
        return changes::dispatch(app, method, p)
            .await
            .unwrap_or_else(|| Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))));
    }
    let store = &app.sup.hub().store;
    match method {
        "daemon.hello" => ok(json!({
            "name": "bandito",
            "version": VERSION,
            "hostname": app.hostname,
            "authenticated": !matches!(peer, Peer::Anonymous(_)),
        })),
        "daemon.info" => ok(json!({
            "version": VERSION,
            "hostname": app.hostname,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "started_at": app.started_at,
            "last_seq": store.last_seq()?,
            "pid": std::process::id(),
            "features": features(),
            "update": update::last_check(),
        })),
        "runtimes.status" => {
            let mut out = Vec::new();
            for rt in app.sup.runtimes().all() {
                out.push(rt.status().await);
            }
            out.sort_by_key(|s| s.kind.as_str());
            ok(out)
        }

        "runtimes.models" => {
            let ModelsParams { runtime, refresh } = params(p)?;
            let kinds = match runtime.as_deref() {
                None => vec![RuntimeKind::Claude, RuntimeKind::Codex, RuntimeKind::Grok],
                Some(name) => match RuntimeKind::parse(name) {
                    Some(kind @ (RuntimeKind::Claude | RuntimeKind::Codex | RuntimeKind::Grok)) => vec![kind],
                    _ => return Err(RpcError::new(INVALID_PARAMS, format!("no model list for {name}"))),
                },
            };
            // The CLIs start in a folder of the daemon's own, so they find nothing of the user's project.
            let cwd = app.data_home.join("models-probe");
            let cwd = if tokio::fs::create_dir_all(&cwd).await.is_ok() {
                cwd
            } else {
                app.data_home.clone()
            };
            let refresh = refresh.unwrap_or(false);
            let path = std::env::var_os("PATH").unwrap_or_default();
            let answers = futures_util::future::join_all(
                kinds
                    .into_iter()
                    .map(|kind| app.models.answer(kind, &cwd, &path, refresh)),
            )
            .await;
            ok(answers)
        }

        "agents.list" => ok(store.agent_list_view()?),
        "agents.get" => {
            let Id { id } = params(p)?;
            ok(store
                .agent_view(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?)
        }
        "agents.create" => {
            let CreateAgent { agent: a, workspace_id } = params(p)?;
            // No cwd given: the agent's own folder is its cwd, which only exists once it is created.
            let own_folder = a.cwd.trim().is_empty();
            if !own_folder {
                check_cwd(&a.cwd)?;
            }
            check_effort(a.runtime, a.effort)?;
            check_context_budget(a.context_budget)?;
            if let Some(fallback) = a.fallback_runtime {
                check_fallback(a.runtime, Some(fallback))?;
            }
            let created = store.agent_create_in(a, workspace_id.as_deref().unwrap_or(SHARED_WORKSPACE))?;
            let folder = home::ensure_agent_home(&app.agents_root, &created.id, &created.name).and_then(|dir| {
                store.agent_set_home(&created.id, &dir.display().to_string())?;
                if own_folder {
                    let cwd = dir.display().to_string();
                    store.agent_update(
                        &created.id,
                        AgentPatch {
                            cwd: Some(cwd),
                            ..Default::default()
                        },
                    )?;
                }
                Ok(dir)
            });
            if let Err(e) = folder {
                // Without its folder the agent is useless: undo the create.
                store.agent_delete(&created.id)?;
                return Err(RpcError::new(
                    SERVER_ERROR,
                    format!("could not create the agent's folder: {e:#}"),
                ));
            }
            ok(store
                .agent_view(&created.id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {}", created.id)))?)
        }
        "agents.update" => {
            let UpdateAgent { id, mut patch } = params(p)?;
            let paused = patch.paused;
            if let Some(cwd) = &patch.cwd {
                check_cwd(cwd)?;
            }
            let current = store
                .agent_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?;
            let runtime = patch.runtime.unwrap_or(current.runtime);
            let runtime_changed = runtime != current.runtime;
            if runtime_changed && app.sup.runtimes().get(runtime).is_none() {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("{} is not available on this server", runtime.as_str()),
                ));
            }
            // Effort is checked against the runtime the agent will run on. One carried over from
            // the old runtime that the new one lacks is dropped, with a warning.
            let mut warnings: Vec<String> = Vec::new();
            match patch.effort {
                Some(explicit) => check_effort(runtime, explicit)?,
                None => {
                    if let Some(effort) = current
                        .effort
                        .filter(|e| runtime_changed && !supported_efforts(runtime).contains(e))
                    {
                        patch.effort = Some(None);
                        warnings.push(format!(
                            "effort {} is not offered by {}, so it was reset",
                            effort.as_str(),
                            runtime.as_str()
                        ));
                    }
                }
            }
            // A model name belongs to its runtime (`opus` means nothing to Codex): a runtime change
            // without a new model goes back to the runtime's default, with a warning.
            if runtime_changed
                && patch.model.is_none()
                && let Some(model) = current.model.as_deref()
            {
                patch.model = Some(None);
                warnings.push(format!(
                    "model {model} belongs to {}, so {} uses its default model",
                    current.runtime.as_str(),
                    runtime.as_str()
                ));
            }
            check_context_budget(patch.context_budget.flatten())?;
            // The fallback as it will be after the patch.
            let fallback_after = patch.fallback_runtime.unwrap_or(current.fallback_runtime);
            check_fallback(runtime, fallback_after)?;
            let reload = patch.changes_session(&current);
            // A session is tied to its folder, its runtime and its workspace: any of them changing starts a new chapter.
            let moved = patch.workspace_id.as_ref().is_some_and(|w| *w != current.workspace_id);
            let new_chapter = if patch.cwd.as_ref().is_some_and(|cwd| *cwd != current.cwd) {
                Some("folder changed")
            } else if runtime_changed {
                Some("runtime changed")
            } else if moved {
                Some("workspace changed")
            } else {
                None
            };
            let mut a = store.agent_update(
                &id,
                AgentPatch {
                    name: patch.name,
                    role: patch.role,
                    model: patch.model,
                    cwd: patch.cwd,
                    approval_mode: patch.approval_mode,
                    system_prompt: patch.system_prompt,
                    effort: patch.effort,
                    memory_mode: patch.memory_mode,
                    context_budget: patch.context_budget,
                    workspace_id: patch.workspace_id,
                    runtime: patch.runtime,
                    fallback_runtime: patch.fallback_runtime,
                    fallback_model: patch.fallback_model,
                    use_personal_settings: patch.use_personal_settings,
                },
            )?;
            // New config takes effect with the next session: the running one is
            // closed when idle, or once its turn ends. The chapter goes on, unless
            // the folder or the runtime changed.
            if reload {
                app.sup.reload(&id, new_chapter).await;
            }
            if let Some(paused) = paused {
                app.sup.set_paused(&id, paused).await?;
                a.paused = paused;
            }
            // The wire-only fields come from the view read, as in agents.get.
            let view = store
                .agent_view(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?;
            a.last_message = view.last_message;
            a.status = view.status;
            a.pending_approval_ids = view.pending_approval_ids;
            a.pending_approvals = view.pending_approvals;
            let mut body = serde_json::to_value(&a).map_err(|e| RpcError::new(SERVER_ERROR, e.to_string()))?;
            body["warnings"] = json!(warnings);
            ok(body)
        }
        "agents.delete" => {
            let Id { id } = params(p)?;
            app.sup.stop(&id).await;
            ok(json!({ "deleted": store.agent_delete(&id)? }))
        }
        "agents.send" => {
            let SendParams { agent_id, text } = params(p)?;
            if text.trim().is_empty() {
                return Err(RpcError::new(INVALID_PARAMS, "message is empty"));
            }
            if text.len() > MAX_MESSAGE_BYTES {
                return Err(RpcError::new(INVALID_PARAMS, "message is too long"));
            }
            // A slash command is expanded for runtimes that do not run it themselves; the thread keeps what was typed.
            let agent = store.agent_get(&agent_id)?;
            let prepared = prepare_message(agent.as_ref(), &text)?;
            // A paused agent takes the message into its thread and starts nothing: `queued` says so.
            let queued = app
                .sup
                .send_held(&agent_id, prepared.into_inbound(Source::User))
                .await?;
            ok(if queued { json!({ "queued": true }) } else { json!({}) })
        }
        "agents.interrupt" => {
            let AgentRef { agent_id } = params(p)?;
            app.sup.interrupt(&agent_id).await?;
            ok(json!({}))
        }
        "agents.pause_all" => {
            let PauseAllParams { paused } = params(p)?;
            let mut changed = 0usize;
            for agent in store.agent_list()? {
                if app.sup.set_paused(&agent.id, paused).await? {
                    changed += 1;
                }
            }
            ok(json!({ "changed": changed }))
        }
        "daemon.logs" => {
            let LogsParams { lines, level } = params(p)?;
            if lines == 0 || lines > logs::MAX_LINES {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("lines must be between 1 and {}", logs::MAX_LINES),
                ));
            }
            let min = match level.as_deref() {
                None => None,
                Some(name) => Some(logs::Level::parse_min(name).ok_or_else(|| {
                    RpcError::new(INVALID_PARAMS, format!("level must be info, warn or error, got {name}"))
                })?),
            };
            ok(daemon_logs(app, lines as usize, min).await?)
        }

        "crew.list" => {
            let AgentRef { agent_id } = params(p)?;
            let members: Vec<Value> = store
                .agent_list()?
                .into_iter()
                .filter(|a| a.id != agent_id)
                .map(|a| json!({ "name": a.name, "role": a.role, "runtime": a.runtime.as_str() }))
                .collect();
            ok(members)
        }
        "crew.send" => {
            let CrewSendParams { from, to, message } = params(p)?;
            let to_id = app.sup.crew_send(&from, &to, &message).await?;
            ok(json!({ "to_id": to_id }))
        }

        "history.search" => {
            let h: HistorySearchParams = params(p)?;
            let name = history_agent_name(store, &h.agent_id)?;
            let events = store.history_search(&h.agent_id, &h.query, h.limit)?;
            ok(json!({ "text": format_history(&events, &name) }))
        }
        "history.day" => {
            let d: HistoryDayParams = params(p)?;
            let day = parse_day(&d.date)?;
            let (from, to) = local_day_bounds(day)?;
            let name = history_agent_name(store, &d.agent_id)?;
            let events = store.history_range(&d.agent_id, from, to, HISTORY_DAY_LIMIT)?;
            let text = if events.is_empty() {
                format!("No messages on {}.", d.date)
            } else if events.len() as u32 >= HISTORY_DAY_LIMIT {
                format!(
                    "{}\n… (only the first {HISTORY_DAY_LIMIT} messages of the day; use history_search for the rest)",
                    format_history(&events, &name)
                )
            } else {
                format_history(&events, &name)
            };
            ok(json!({ "text": text }))
        }

        "events.since" => {
            let s: SinceParams = params(p)?;
            ok(store.events_since(s.after, s.limit, s.agent_id.as_deref())?)
        }

        "events.page" => {
            #[derive(Deserialize)]
            struct PageParams {
                agent_id: String,
                #[serde(default)]
                before: Option<i64>,
                #[serde(default = "default_page")]
                limit: u32,
            }
            fn default_page() -> u32 {
                200
            }
            let p: PageParams = params(p)?;
            ok(store.events_page(&p.agent_id, p.before, p.limit)?)
        }

        "approvals.list" => {
            let MaybeAgent { agent_id } = params(p)?;
            ok(store.approval_list_pending(agent_id.as_deref())?)
        }
        "approvals.resolve" => {
            let r: ResolveParams = params(p)?;
            app.sup.resolve(&r.approval_id, r.decision, r.remember).await?;
            ok(json!({}))
        }

        "rules.list" => {
            let MaybeAgent { agent_id } = params(p)?;
            ok(store.rule_list(agent_id.as_deref())?)
        }
        "rules.set" => {
            let r: RuleParams = params(p)?;
            if r.pattern.trim().is_empty() {
                return Err(RpcError::new(INVALID_PARAMS, "pattern is empty"));
            }
            ok(store.rule_set(r.agent_id.as_deref(), &r.pattern, r.action)?)
        }
        "rules.delete" => {
            let Id { id } = params(p)?;
            ok(json!({ "deleted": store.rule_delete(&id)? }))
        }

        "schedules.list" => {
            let MaybeAgent { agent_id } = params(p)?;
            ok(store.schedule_list(agent_id.as_deref())?)
        }
        "schedules.create" => {
            let s: NewSchedule = params(p)?;
            if store.agent_get(&s.agent_id)?.is_none() {
                return Err(RpcError::new(SERVER_ERROR, format!("no agent {}", s.agent_id)));
            }
            if s.prompt.trim().is_empty() {
                return Err(RpcError::new(INVALID_PARAMS, "prompt is empty"));
            }
            let next = scheduler::next_run(&s.cron, &s.tz, crate::store::now_ms())
                .map_err(|e| RpcError::new(INVALID_PARAMS, e.to_string()))?;
            ok(store.schedule_create(s, Some(next))?)
        }
        "schedules.update" => {
            let ScheduleUpdate { id, patch } = params(p)?;
            let Some(cur) = store.schedule_get(&id)? else {
                return Err(RpcError::new(SERVER_ERROR, format!("no schedule {id}")));
            };
            if patch.prompt.as_deref().is_some_and(|t| t.trim().is_empty()) {
                return Err(RpcError::new(INVALID_PARAMS, "prompt is empty"));
            }
            // Recompute the next run only when the timing changes (cron or zone) or the
            // schedule is switched on. A prompt edit or a switch off keeps next_run_at,
            // so a run that is already due is not pushed back or duplicated.
            let timing_changed = patch.cron.as_deref().is_some_and(|c| c != cur.cron)
                || patch.tz.as_deref().is_some_and(|z| z != cur.tz);
            let switched_on = patch.enabled == Some(true) && !cur.enabled;
            let next = if timing_changed || switched_on {
                let cron = patch.cron.as_deref().unwrap_or(&cur.cron);
                let tz = patch.tz.as_deref().unwrap_or(&cur.tz);
                NextRun::Set(Some(
                    scheduler::next_run(cron, tz, crate::store::now_ms())
                        .map_err(|e| RpcError::new(INVALID_PARAMS, e.to_string()))?,
                ))
            } else {
                NextRun::Keep
            };
            ok(store.schedule_update(&id, patch, next)?)
        }
        "schedules.delete" => {
            let Id { id } = params(p)?;
            ok(json!({ "deleted": store.schedule_delete(&id)? }))
        }
        "schedules.run_now" => {
            let Id { id } = params(p)?;
            scheduler::run_now(&app.sup, &id).await?;
            ok(json!({}))
        }

        "devices.list" => {
            // `current` is the device whose token made this request; the owner's CLI is no device.
            let asking = match peer {
                Peer::Device(me) => Some(me.id.as_str()),
                _ => None,
            };
            let devices = store.device_list()?;
            let rows: Vec<DeviceRow> = devices
                .iter()
                .map(|device| DeviceRow {
                    device,
                    current: asking == Some(device.id.as_str()),
                })
                .collect();
            ok(rows)
        }
        "devices.revoke" => {
            let Id { id } = params(p)?;
            ok(json!({ "revoked": store.device_revoke(&id)? }))
        }

        "usage.limits" => ok(store.usage_list()?),
        "usage.refresh" => {
            // Ask every runtime at once, for its windows and its plan; each question gets its own timeout.
            let mut rts = app.sup.runtimes().all();
            rts.sort_by_key(|rt| rt.kind().as_str());
            let asked = futures_util::future::join_all(rts.iter().map(|rt| async move {
                let kind = rt.kind();
                let (windows, plan) = tokio::join!(
                    tokio::time::timeout(USAGE_REFRESH_TIMEOUT, rt.refresh_usage()),
                    tokio::time::timeout(USAGE_REFRESH_TIMEOUT, rt.account_plan()),
                );
                (kind, windows, plan)
            }))
            .await;
            let mut errors = Vec::new();
            for (kind, windows, plan) in asked {
                // A plan that is not known (none, error, timeout) leaves the stored one as it is.
                match plan {
                    Ok(Ok(Some(plan))) => {
                        if let Err(e) = store.usage_set_plan(kind.as_str(), Some(&plan), crate::store::now_ms()) {
                            errors.push(json!({ "runtime": kind.as_str(), "message": format!("{e:#}") }));
                        }
                    }
                    Ok(Ok(None)) => tracing::debug!(runtime = kind.as_str(), "no plan reported"),
                    Ok(Err(e)) => tracing::warn!(runtime = kind.as_str(), "plan not read: {e:#}"),
                    Err(_) => tracing::warn!(runtime = kind.as_str(), "plan read timed out"),
                }
                let message = match windows {
                    Err(_) => format!("no answer within {} s", USAGE_REFRESH_TIMEOUT.as_secs()),
                    Ok(Err(e)) => format!("{e:#}"),
                    Ok(Ok(None)) => continue,
                    Ok(Ok(Some(windows))) => match store.usage_set(kind.as_str(), &windows, crate::store::now_ms()) {
                        Ok(()) => continue,
                        Err(e) => format!("{e:#}"),
                    },
                };
                errors.push(json!({ "runtime": kind.as_str(), "message": message }));
            }
            ok(json!({ "limits": store.usage_list()?, "errors": errors }))
        }

        "pair.create" => {
            let code = pairing::new_code();
            store.pairing_add(&code, pairing::CODE_TTL_MS)?;
            ok(json!({ "code": code, "expires_in_ms": pairing::CODE_TTL_MS }))
        }
        "pair.redeem" => {
            let r: RedeemParams = params(p)?;
            let now = crate::store::now_ms();
            let source = redeem_source(peer);
            let mut limiter = app.redeem.lock().unwrap_or_else(|e| e.into_inner());
            if !limiter.allows(&source, now) {
                return Err(RpcError::new(
                    RATE_LIMITED,
                    "too many attempts, try again in a few minutes",
                ));
            }
            if !store.pairing_take(&r.code)? {
                limiter.failed(&source, now);
                return Err(RpcError::new(UNAUTHORIZED, "invalid or expired code"));
            }
            drop(limiter);
            let name = r.device_name.trim();
            let name = if name.is_empty() { "device" } else { name };
            let token = pairing::new_token();
            let d = store.device_add(name, &token)?;
            ok(json!({ "token": token, "device": d }))
        }

        "term.list" | "term.open" | "term.input" | "term.resize" | "term.rename" | "term.close" => {
            term::dispatch(app, method, p).await
        }
        "secrets.list" | "secrets.set" | "secrets.delete" => secrets::dispatch(app, method, p).await,

        "host.stats" | "host.history" | "host.processes" | "host.ports" | "host.kill" | "host.kill_process" => {
            host::dispatch(app, method, p).await
        }

        "setup.status" | "setup.install" | "setup.job" => setup::dispatch(app, method, p).await,

        "daemon.update_check" => ok(update::check_async(VERSION).await?),
        "daemon.update_apply" => {
            let update::ApplyParams { version } = params(p)?;
            let restarting = update::rpc_apply(&version).await?;
            ok(json!({ "ok": true, "restarting": restarting }))
        }

        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

#[cfg(test)]
mod crew_tests {
    use super::*;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, Store};

    /// An app with a crew of two agents: Forge (builder) and Scout (reviewer).
    /// Returns the app and the ids of Forge and Scout.
    fn app_with_crew() -> (Arc<App>, String, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let hub = crate::hub::Hub::new(store.clone());
        let sup = Supervisor::new(hub, crate::supervisor::Runtimes::default(), None);
        let add = |name: &str, role: &str| {
            store
                .agent_create(NewAgent {
                    use_personal_settings: false,
                    name: name.into(),
                    role: role.into(),
                    runtime: RuntimeKind::Claude,
                    model: None,
                    cwd: "/tmp".into(),
                    approval_mode: ApprovalMode::Risky,
                    system_prompt: None,
                    effort: None,
                    memory_mode: crate::store::MemoryMode::Smart,
                    context_budget: None,
                    fallback_runtime: None,
                    fallback_model: None,
                })
                .unwrap()
                .id
        };
        let forge = add("Forge", "builder");
        let scout = add("Scout", "reviewer");
        (App::new(sup, std::env::temp_dir()), forge, scout)
    }

    #[tokio::test]
    async fn crew_list_excludes_the_asking_agent() {
        let (app, forge, scout) = app_with_crew();
        let v = dispatch(&app, &Peer::Local, "crew.list", json!({ "agent_id": forge }))
            .await
            .unwrap();
        assert_eq!(v, json!([{ "name": "Scout", "role": "reviewer", "runtime": "claude" }]));
        let v = dispatch(&app, &Peer::Local, "crew.list", json!({ "agent_id": scout }))
            .await
            .unwrap();
        assert_eq!(v.as_array().unwrap()[0]["name"], "Forge");
    }

    #[tokio::test]
    async fn crew_send_to_unknown_agent_fails() {
        let (app, forge, _) = app_with_crew();
        let err = dispatch(
            &app,
            &Peer::Agent(forge.clone()),
            "crew.send",
            json!({ "from": forge, "to": "Nobody", "message": "hi" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
        assert!(err.message.contains("no agent named"), "{}", err.message);
    }

    #[tokio::test]
    async fn crew_send_is_for_agents_only_while_crew_list_is_open_to_devices() {
        let (app, forge, scout) = app_with_crew();
        let device = Peer::Device(Device {
            id: "dev-1".into(),
            name: "Mac".into(),
            created_at: 0,
            last_seen_at: None,
        });
        let err = dispatch(
            &app,
            &device,
            "crew.send",
            json!({ "from": forge, "to": "Scout", "message": "hi" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err, RpcError::new(UNAUTHORIZED, "crew.send is only for agents"));
        // The owner's CLI is not an agent either.
        let err = dispatch(
            &app,
            &Peer::Local,
            "crew.send",
            json!({ "from": forge, "to": "Scout", "message": "hi" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        let v = dispatch(&app, &device, "crew.list", json!({ "agent_id": forge }))
            .await
            .unwrap();
        assert_eq!(v.as_array().unwrap().len(), 1);
        // An agent sends as itself: Scout's token cannot send for Forge.
        let err = dispatch(
            &app,
            &Peer::Agent(scout),
            "crew.send",
            json!({ "from": forge, "to": "Scout", "message": "hi" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
    }
}

#[cfg(test)]
mod history_tests {
    use super::*;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, Store};
    use crate::supervisor::Runtimes;

    fn app_with_agent() -> (Arc<App>, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                use_personal_settings: false,
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        (
            App::new(sup, std::env::temp_dir().join("bandito-history-tests")),
            agent.id,
        )
    }

    fn user(text: &str, source: Source, from_agent: Option<&str>) -> EventBody {
        EventBody::MessageUser {
            text: text.into(),
            source,
            from_agent: from_agent.map(str::to_string),
            command: None,
        }
    }

    fn event(body: EventBody, ts: i64) -> Event {
        Event {
            seq: 1,
            agent_id: "a".into(),
            ts,
            body,
        }
    }

    /// The line text after `YYYY-MM-DD HH:MM · who: `.
    fn text_of_line(line: &str) -> &str {
        line.split_once(": ").unwrap().1
    }

    #[test]
    fn format_labels_each_speaker() {
        let events = vec![
            event(user("hi", Source::User, None), 0),
            event(user("nightly", Source::Schedule, None), 0),
            event(user("review please", Source::Crew, Some("Scout")), 0),
            event(user("crew without a name", Source::Crew, None), 0),
            event(EventBody::MessageAssistant { text: "done".into() }, 0),
        ];
        let out = format_history(&events, "Forge");
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 5);
        let who: Vec<&str> = lines
            .iter()
            .map(|l| l.split_once(" · ").unwrap().1.split_once(": ").unwrap().0)
            .collect();
        assert_eq!(who, ["user", "schedule", "Scout", "crew", "Forge"]);
        let stamp = lines[0].split_once(" · ").unwrap().0;
        assert_eq!(stamp.len(), 16);
        assert_eq!(stamp.as_bytes()[10], b' ');
    }

    #[test]
    fn format_shows_line_breaks_inline() {
        let out = format_history(&[event(user("one\ntwo\r\nthree\n", Source::User, None), 0)], "Forge");
        assert_eq!(out.lines().count(), 1);
        assert_eq!(text_of_line(&out), "one ⏎ two ⏎ three");
    }

    #[test]
    fn format_cuts_each_message_to_600_chars() {
        let long = "ж".repeat(700);
        let out = format_history(&[event(user(&long, Source::User, None), 0)], "Forge");
        let text = text_of_line(&out);
        assert_eq!(text.chars().count(), 600);
        assert!(text.ends_with('…'));
        assert_eq!(text.chars().filter(|&c| c == 'ж').count(), 599);

        let exact = "a".repeat(600);
        let out = format_history(&[event(user(&exact, Source::User, None), 0)], "Forge");
        assert_eq!(text_of_line(&out), exact);
    }

    #[test]
    fn format_caps_the_whole_reply_and_says_so() {
        let body = "b".repeat(600);
        let events: Vec<Event> = (0..50).map(|i| event(user(&body, Source::User, None), i)).collect();
        let out = format_history(&events, "Forge");
        let total = out.chars().count();
        assert!(total <= HISTORY_REPLY_CHARS, "{total}");
        assert!(out.ends_with(HISTORY_MORE));
        // Each line is 625 characters; the next one did not fit.
        assert!(total > HISTORY_REPLY_CHARS - 626, "{total}");
    }

    #[test]
    fn format_empty_says_nothing_found() {
        assert_eq!(format_history(&[], "Forge"), "Nothing found.");
    }

    #[test]
    fn parse_day_is_strict() {
        assert_eq!(
            parse_day("2026-10-09").unwrap(),
            NaiveDate::from_ymd_opt(2026, 10, 9).unwrap()
        );
        for bad in ["2026-1-5", "2026-13-01", "2026-02-30", "10/09/2026", "", "yesterday"] {
            assert_eq!(parse_day(bad).unwrap_err().code, INVALID_PARAMS, "{bad}");
        }
    }

    #[tokio::test]
    async fn history_search_returns_matches_newest_first() {
        let (app, forge) = app_with_agent();
        let agent = Peer::Agent(forge.clone());
        let store = app.sup.hub().store.clone();
        store
            .append_event(&forge, user("deploy plan", Source::User, None))
            .unwrap();
        store
            .append_event(
                &forge,
                EventBody::MessageAssistant {
                    text: "deploy started".into(),
                },
            )
            .unwrap();
        store
            .append_event(
                &forge,
                EventBody::Error {
                    message: "deploy failed".into(),
                },
            )
            .unwrap();
        let v = dispatch(
            &app,
            &agent,
            "history.search",
            json!({ "agent_id": forge, "query": "deploy" }),
        )
        .await
        .unwrap();
        let text = v["text"].as_str().unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2, "{text}");
        assert!(lines[0].ends_with(" · Forge: deploy started"), "{text}");
        assert!(lines[1].ends_with(" · user: deploy plan"), "{text}");
    }

    #[tokio::test]
    async fn history_search_blank_query_and_unknown_agent() {
        let (app, forge) = app_with_agent();
        let agent = Peer::Agent(forge.clone());
        let v = dispatch(
            &app,
            &agent,
            "history.search",
            json!({ "agent_id": forge, "query": "  " }),
        )
        .await
        .unwrap();
        assert_eq!(v["text"], "Nothing found.");

        // An agent names only itself: another id is refused, whether it exists or not.
        let err = dispatch(
            &app,
            &agent,
            "history.search",
            json!({ "agent_id": "nope", "query": "x" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err, RpcError::new(UNAUTHORIZED, "an agent can only act as itself"));
        let err = dispatch(
            &app,
            &Peer::Agent("nope".into()),
            "history.search",
            json!({ "agent_id": "nope", "query": "x" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err, RpcError::new(SERVER_ERROR, "no agent nope"));
    }

    #[tokio::test]
    async fn history_day_reads_today_and_says_when_empty() {
        let (app, forge) = app_with_agent();
        let agent = Peer::Agent(forge.clone());
        let store = app.sup.hub().store.clone();
        store
            .append_event(&forge, user("standup notes", Source::User, None))
            .unwrap();
        let today = Local::now().format("%Y-%m-%d").to_string();
        let v = dispatch(&app, &agent, "history.day", json!({ "agent_id": forge, "date": today }))
            .await
            .unwrap();
        assert!(v["text"].as_str().unwrap().ends_with(" · user: standup notes"), "{v}");

        let v = dispatch(
            &app,
            &agent,
            "history.day",
            json!({ "agent_id": forge, "date": "2001-01-01" }),
        )
        .await
        .unwrap();
        assert_eq!(v["text"], "No messages on 2001-01-01.");
    }

    #[tokio::test]
    async fn history_day_rejects_bad_dates() {
        let (app, forge) = app_with_agent();
        let agent = Peer::Agent(forge.clone());
        for bad in ["2026-13-01", "2026-1-5", "2026-02-30", "yesterday"] {
            let err = dispatch(&app, &agent, "history.day", json!({ "agent_id": forge, "date": bad }))
                .await
                .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{bad}");
        }
    }

    #[tokio::test]
    async fn history_is_for_agents_only() {
        let (app, forge) = app_with_agent();
        let device = Peer::Device(Device {
            id: "dev-1".into(),
            name: "Mac".into(),
            created_at: 0,
            last_seen_at: None,
        });
        let search = dispatch(
            &app,
            &device,
            "history.search",
            json!({ "agent_id": forge, "query": "x" }),
        )
        .await
        .unwrap_err();
        assert_eq!(search, RpcError::new(UNAUTHORIZED, "history.search is only for agents"));
        // The owner's CLI reads no agent's history either.
        let owner = dispatch(
            &app,
            &Peer::Local,
            "history.day",
            json!({ "agent_id": forge, "date": "2026-10-09" }),
        )
        .await
        .unwrap_err();
        assert_eq!(owner.code, UNAUTHORIZED);
        let day = dispatch(
            &app,
            &device,
            "history.day",
            json!({ "agent_id": forge, "date": "2026-10-09" }),
        )
        .await
        .unwrap_err();
        assert_eq!(day.code, UNAUTHORIZED);
    }
}

fn response(id: Value, r: RpcResult) -> String {
    match r {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(e) => {
            let mut error = json!({ "code": e.code, "message": e.message });
            if let Some(data) = e.data {
                error["data"] = data;
            }
            json!({ "jsonrpc": "2.0", "id": id, "error": error })
        }
    }
    .to_string()
}

fn notification(ev: &Event) -> String {
    json!({ "jsonrpc": "2.0", "method": "event", "params": ev }).to_string()
}

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
struct SubscribeParams {
    #[serde(default)]
    after: i64,
}

/// Send stored events after `*last` until caught up.
async fn backfill(app: &App, last: &mut i64, out: &mpsc::Sender<String>) -> anyhow::Result<()> {
    loop {
        let page = app.sup.hub().store.events_since(*last, 500, None)?;
        if page.is_empty() {
            return Ok(());
        }
        for ev in page {
            *last = ev.seq;
            out.send(notification(&ev)).await?;
        }
    }
}

async fn recv_event(rx: &mut Option<broadcast::Receiver<Event>>) -> Result<Event, broadcast::error::RecvError> {
    match rx {
        Some(r) => r.recv().await,
        None => std::future::pending().await,
    }
}

/// Serve one connection: text messages in, text messages out. Returns when
/// the inbox closes or the client goes away.
pub async fn serve(app: Arc<App>, peer: Peer, mut inbox: mpsc::Receiver<String>, outbox: mpsc::Sender<String>) {
    let mut events: Option<broadcast::Receiver<Event>> = None;
    let mut last: i64 = 0;
    let mut terms = term::Stream::default();
    loop {
        tokio::select! {
            msg = inbox.recv() => {
                let Some(msg) = msg else { break };
                let req: Request = match serde_json::from_str::<Value>(&msg) {
                    Err(e) => {
                        let _ = outbox.send(response(Value::Null, Err(RpcError::new(PARSE_ERROR, e.to_string())))).await;
                        continue;
                    }
                    Ok(v) => match serde_json::from_value(v) {
                        Ok(r) => r,
                        Err(e) => {
                            let _ = outbox.send(response(Value::Null, Err(RpcError::new(INVALID_REQUEST, e.to_string())))).await;
                            continue;
                        }
                    },
                };
                let result = if !allowed(&peer, &req.method) {
                    Err(denied(&peer, &req.method))
                } else if req.method == "events.subscribe" {
                    match params::<SubscribeParams>(req.params) {
                        Err(e) => Err(e),
                        Ok(SubscribeParams { after }) => {
                            // Subscribe first so nothing falls between backlog and live.
                            events = Some(app.sup.hub().subscribe());
                            last = after;
                            match backfill(&app, &mut last, &outbox).await {
                                Ok(()) => Ok(json!({ "last_seq": last })),
                                Err(_) => break,
                            }
                        }
                    }
                } else if req.method == "term.attach" {
                    terms.attach(&app, &peer, req.params)
                } else if req.method == "term.detach" {
                    terms.detach(&peer, req.params)
                } else {
                    dispatch(&app, &peer, &req.method, req.params).await
                };
                if let Some(id) = req.id
                    && outbox.send(response(id, result)).await.is_err()
                {
                    break;
                }
            }
            ev = recv_event(&mut events) => match ev {
                Ok(ev) => {
                    if ev.seq == 0 || ev.seq > last {
                        if ev.seq > 0 {
                            last = ev.seq;
                        }
                        if outbox.send(notification(&ev)).await.is_err() {
                            break;
                        }
                    }
                }
                Err(broadcast::error::RecvError::Lagged(_)) => {
                    // Too slow: catch up from the store (deltas are lost, finals are not).
                    if backfill(&app, &mut last, &outbox).await.is_err() {
                        break;
                    }
                }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            ev = terms.next_event() => {
                let lines = terms.on_event(&app, ev);
                if term::send_all(&outbox, lines).await.is_err() {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod schedule_tests {
    use super::*;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, Store};
    use crate::supervisor::Runtimes;

    fn app_with_agent() -> (Arc<App>, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                use_personal_settings: false,
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        (App::new(sup, std::env::temp_dir()), agent.id)
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    #[tokio::test]
    async fn schedules_create_validates_input() {
        let (app, agent) = app_with_agent();

        let err = call(
            &app,
            "schedules.create",
            json!({"agent_id": agent, "cron": "61 * * * *", "prompt": "x"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("invalid schedule"), "{}", err.message);

        let err = call(
            &app,
            "schedules.create",
            json!({"agent_id": agent, "cron": "0 9 * * *", "prompt": "  "}),
        )
        .await
        .unwrap_err();
        assert_eq!(err, RpcError::new(INVALID_PARAMS, "prompt is empty"));

        let err = call(
            &app,
            "schedules.create",
            json!({"agent_id": "nope", "cron": "0 9 * * *", "prompt": "x"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err, RpcError::new(SERVER_ERROR, "no agent nope"));
    }

    #[tokio::test]
    async fn schedules_update_keeps_next_run_unless_timing_or_enabled_changes() {
        let (app, agent) = app_with_agent();
        let created = call(
            &app,
            "schedules.create",
            json!({"agent_id": agent, "cron": "0 2 * * *", "prompt": "report"}),
        )
        .await
        .unwrap();
        let id = created["id"].as_str().unwrap().to_string();
        let next = created["next_run_at"].as_i64().unwrap();

        let edited = call(&app, "schedules.update", json!({"id": id, "prompt": "new prompt"}))
            .await
            .unwrap();
        assert_eq!(edited["prompt"], "new prompt");
        assert_eq!(edited["next_run_at"], next);

        // Repeating the current cron and zone is not a change either.
        let same = call(
            &app,
            "schedules.update",
            json!({"id": id, "cron": "0 2 * * *", "tz": "UTC"}),
        )
        .await
        .unwrap();
        assert_eq!(same["next_run_at"], next);

        let off = call(&app, "schedules.update", json!({"id": id, "enabled": false}))
            .await
            .unwrap();
        assert_eq!(off["enabled"], false);
        assert_eq!(off["next_run_at"], next);

        // Switching on recomputes: a stale (already due) value is replaced by a future one.
        app.sup
            .hub()
            .store
            .schedule_update(&id, SchedulePatch::default(), NextRun::Set(Some(1_000)))
            .unwrap();
        let on = call(&app, "schedules.update", json!({"id": id, "enabled": true}))
            .await
            .unwrap();
        assert_eq!(on["enabled"], true);
        assert!(on["next_run_at"].as_i64().unwrap() > crate::store::now_ms());

        // A cron change moves the next run to 03:00.
        let moved = call(&app, "schedules.update", json!({"id": id, "cron": "0 3 * * *"}))
            .await
            .unwrap();
        assert_eq!(
            moved["next_run_at"].as_i64().unwrap().rem_euclid(86_400_000),
            3 * 3_600_000
        );
    }

    #[tokio::test]
    async fn schedules_crud_recomputes_next_run() {
        let (app, agent) = app_with_agent();

        let created = call(
            &app,
            "schedules.create",
            json!({"agent_id": agent, "cron": "0 2 * * *", "prompt": "report"}),
        )
        .await
        .unwrap();
        assert_eq!(created["tz"], "UTC");
        assert_eq!(created["enabled"], true);
        assert!(created["next_run_at"].as_i64().is_some());
        let id = created["id"].as_str().unwrap().to_string();

        let listed = call(&app, "schedules.list", json!({"agent_id": agent})).await.unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);

        // The next run moves to 03:00 UTC, i.e. the time of day is 03:00.
        let updated = call(&app, "schedules.update", json!({"id": id, "cron": "0 3 * * *"}))
            .await
            .unwrap();
        assert_eq!(updated["cron"], "0 3 * * *");
        assert_eq!(
            updated["next_run_at"].as_i64().unwrap().rem_euclid(86_400_000),
            3 * 3_600_000
        );

        let err = call(&app, "schedules.update", json!({"id": id, "cron": "bad"}))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);

        let err = call(&app, "schedules.update", json!({"id": "missing"}))
            .await
            .unwrap_err();
        assert_eq!(err, RpcError::new(SERVER_ERROR, "no schedule missing"));

        assert_eq!(
            call(&app, "schedules.delete", json!({"id": id})).await.unwrap(),
            json!({"deleted": true})
        );
        assert_eq!(
            call(&app, "schedules.delete", json!({"id": id})).await.unwrap(),
            json!({"deleted": false})
        );
    }
}

#[cfg(test)]
mod memory_tests {
    use super::*;
    use crate::event::{EventBody, LimitWindow};
    use crate::hub::Hub;
    use crate::runtime::{Runtime, RuntimeStatus, SpawnConfig, Spawned};
    use crate::store::{Store, UsageEntry};
    use crate::supervisor::Runtimes;
    use async_trait::async_trait;

    /// An app whose agent folders live under a fresh temp dir (kept alive by the caller).
    fn app_in_tempdir() -> (Arc<App>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let app = app_with_root(dir.path().join("agents"), Runtimes::default());
        (app, dir)
    }

    fn app_with_root(root: PathBuf, runtimes: Runtimes) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), runtimes, None);
        App::new(sup, root)
    }

    #[tokio::test]
    async fn personal_settings_are_off_by_default_and_travel_on_the_wire() {
        let (app, _dir) = app_in_tempdir();
        let created = call(&app, "agents.create", new_agent("Forge", "claude")).await.unwrap();
        assert_eq!(created["use_personal_settings"], json!(false));
        let id = created["id"].as_str().unwrap().to_string();
        let on = call(
            &app,
            "agents.update",
            json!({ "id": id, "use_personal_settings": true }),
        )
        .await
        .unwrap();
        assert_eq!(on["use_personal_settings"], json!(true));
        let got = call(&app, "agents.get", json!({ "id": id })).await.unwrap();
        assert_eq!(got["use_personal_settings"], json!(true));
        let mut p = new_agent("Scout", "claude");
        p["use_personal_settings"] = json!(true);
        let scout = call(&app, "agents.create", p).await.unwrap();
        assert_eq!(scout["use_personal_settings"], json!(true));
    }

    #[tokio::test]
    async fn a_personal_settings_change_reloads_the_session() {
        let (app, _dir) = app_in_tempdir();
        let created = call(&app, "agents.create", new_agent("Forge", "claude")).await.unwrap();
        let current = app
            .sup
            .hub()
            .store
            .agent_get(created["id"].as_str().unwrap())
            .unwrap()
            .unwrap();
        // The flag is read when a session starts, so changing it takes effect only with a new one.
        let same: AgentPatchParams = serde_json::from_value(json!({ "use_personal_settings": false })).unwrap();
        assert!(!same.changes_session(&current));
        let on: AgentPatchParams = serde_json::from_value(json!({ "use_personal_settings": true })).unwrap();
        assert!(on.changes_session(&current));
    }

    #[tokio::test]
    async fn update_reloads_the_session_only_when_it_changes_something() {
        use crate::event::TurnStatus;
        use crate::runtime::RuntimeOutput;
        use crate::store::ApprovalMode;
        use crate::supervisor::{Inbound, testing::MockRuntime};
        use std::time::Duration;

        let store = Arc::new(Store::open_in_memory().unwrap());
        let log: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
        let out: crate::supervisor::testing::Outs = Arc::default();
        let mut runtimes = Runtimes::default();
        runtimes.insert(Arc::new(MockRuntime {
            log: log.clone(),
            out: out.clone(),
            spawns: Arc::default(),
        }));
        let sup = Supervisor::new(Hub::new(store.clone()), runtimes, None);
        let app = App::new(sup.clone(), PathBuf::from("/unused"));
        let cwd = std::env::temp_dir().display().to_string();
        let id = store
            .agent_create(NewAgent {
                use_personal_settings: false,
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: cwd.clone(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
            .id;
        let has = |line: &str| log.lock().unwrap().iter().any(|l| l == line);
        let shutdowns = || log.lock().unwrap().iter().filter(|l| *l == "shutdown").count();
        let settle = || tokio::time::sleep(Duration::from_millis(50));

        sup.send(&id, Inbound::user("go")).await.unwrap();
        settle().await;
        assert!(has("send go"));

        // the form sent back with nothing changed, and an approval mode change, reload nothing
        call(
            &app,
            "agents.update",
            json!({ "id": id, "name": "Forge", "role": "", "model": null, "cwd": cwd, "approval_mode": "never" }),
        )
        .await
        .unwrap();
        settle().await;
        assert_eq!(shutdowns(), 0);

        // a rename during the turn waits for the turn to end
        call(&app, "agents.update", json!({ "id": id, "name": "Scout" }))
            .await
            .unwrap();
        settle().await;
        assert_eq!(shutdowns(), 0, "the turn is not cut");
        let tx = out.lock().unwrap().get(&id).cloned().unwrap();
        tx.send(RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: String::new(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: None,
        }))
        .await
        .unwrap();
        for _ in 0..300 {
            if shutdowns() == 1 {
                break;
            }
            settle().await;
        }
        assert_eq!(shutdowns(), 1);

        // the same rename again is no change: nothing to reload
        call(&app, "agents.update", json!({ "id": id, "name": "Scout" }))
            .await
            .unwrap();
        settle().await;
        assert_eq!(shutdowns(), 1);
    }

    #[tokio::test]
    async fn a_folder_change_starts_a_new_chapter_even_without_a_running_session() {
        let (app, dir) = app_in_tempdir();
        let agent = call(&app, "agents.create", new_agent("Scout", "claude")).await.unwrap();
        let id = agent["id"].as_str().unwrap().to_string();
        app.sup.hub().store.agent_set_session(&id, Some("sess-1")).unwrap();

        let other = dir.path().join("other");
        std::fs::create_dir_all(&other).unwrap();
        call(
            &app,
            "agents.update",
            json!({ "id": id, "cwd": other.display().to_string() }),
        )
        .await
        .unwrap();

        let stored = app.sup.hub().store.agent_get(&id).unwrap().unwrap();
        assert_eq!(stored.chapter, 2);
        assert_eq!(
            stored.runtime_session_id, None,
            "the new folder does not resume the old session"
        );
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn new_agent(name: &str, runtime: &str) -> Value {
        json!({
            "name": name,
            "runtime": runtime,
            "cwd": std::env::temp_dir().display().to_string(),
        })
    }

    fn window(name: &str, utilization: f64) -> LimitWindow {
        LimitWindow {
            name: name.into(),
            utilization,
            resets_at: None,
        }
    }

    use crate::event::Plan;

    /// A runtime that only answers `refresh_usage` and `account_plan`, with fixed answers or errors.
    struct UsageProbe {
        kind: RuntimeKind,
        answer: Result<Option<Vec<LimitWindow>>, String>,
        plan: Result<Option<Plan>, String>,
    }

    fn plan(id: &str, label: &str) -> Plan {
        Plan {
            id: id.into(),
            label: label.into(),
        }
    }

    #[async_trait]
    impl Runtime for UsageProbe {
        fn kind(&self) -> RuntimeKind {
            self.kind
        }
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus {
                kind: self.kind,
                installed: true,
                version: None,
                logged_in: None,
                detail: None,
            }
        }
        async fn spawn(&self, _cfg: SpawnConfig) -> anyhow::Result<Spawned> {
            anyhow::bail!("not used in this test")
        }
        async fn refresh_usage(&self) -> anyhow::Result<Option<Vec<LimitWindow>>> {
            self.answer.clone().map_err(anyhow::Error::msg)
        }
        async fn account_plan(&self) -> anyhow::Result<Option<Plan>> {
            self.plan.clone().map_err(anyhow::Error::msg)
        }
    }

    #[test]
    fn effort_support_per_runtime() {
        assert_eq!(supported_efforts(RuntimeKind::Claude).len(), 5);
        assert_eq!(supported_efforts(RuntimeKind::Api).len(), 5);
        assert!(!supported_efforts(RuntimeKind::Codex).contains(&Effort::Max));
        assert!(supported_efforts(RuntimeKind::Codex).contains(&Effort::Xhigh));
        assert_eq!(
            supported_efforts(RuntimeKind::Grok),
            &[Effort::Low, Effort::Medium, Effort::High]
        );
    }

    #[tokio::test]
    async fn daemon_advertises_usage_and_memory() {
        let (app, _dir) = app_in_tempdir();
        let info = call(&app, "daemon.info", json!({})).await.unwrap();
        let features = info["features"].as_array().unwrap();
        assert!(features.contains(&json!("usage")));
        assert!(features.contains(&json!("memory")));
        assert!(features.contains(&json!("update")));
        assert!(
            info.get("update").is_some(),
            "daemon.info carries the last update check"
        );
        assert_eq!(
            info["pid"],
            std::process::id(),
            "daemon.info names the daemon's own pid"
        );
    }

    #[tokio::test]
    async fn create_returns_the_agent_with_its_home_folder() {
        let (app, dir) = app_in_tempdir();
        let agent = call(&app, "agents.create", new_agent("Night Owl", "claude"))
            .await
            .unwrap();
        let home = PathBuf::from(agent["home_dir"].as_str().unwrap());
        assert_eq!(home, dir.path().join("agents").join("night-owl"));
        assert!(home.join("MEMORY.md").is_file());
        assert!(home.join("notes").is_dir());
        assert!(home.join("journal").is_dir());
        assert!(home.join("files").is_dir());
        // The stored agent carries the same folder.
        let stored = app.sup.hub().store.agent_list().unwrap();
        assert_eq!(stored[0].home_dir.as_deref(), Some(home.to_str().unwrap()));
    }

    #[tokio::test]
    async fn create_rejects_effort_the_runtime_lacks() {
        let (app, _dir) = app_in_tempdir();
        let mut p = new_agent("Forge", "codex");
        p["effort"] = json!("max");
        let err = call(&app, "agents.create", p).await.unwrap_err();
        assert_eq!(err, RpcError::new(INVALID_PARAMS, "codex doesn't offer effort max"));
        assert!(app.sup.hub().store.agent_list().unwrap().is_empty());

        let mut p = new_agent("Scout", "grok");
        p["effort"] = json!("xhigh");
        let err = call(&app, "agents.create", p).await.unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("grok doesn't offer effort xhigh"));
    }

    #[tokio::test]
    async fn create_checks_context_budget_range() {
        let (app, _dir) = app_in_tempdir();
        for bad in [10_000, 1_000_001] {
            let mut p = new_agent("Forge", "claude");
            p["context_budget"] = json!(bad);
            let err = call(&app, "agents.create", p).await.unwrap_err();
            assert_eq!(
                err,
                RpcError::new(
                    INVALID_PARAMS,
                    "context budget must be between 20 000 and 1 000 000 tokens"
                )
            );
        }
        let mut p = new_agent("Forge", "claude");
        p["context_budget"] = json!(20_000);
        assert!(call(&app, "agents.create", p).await.is_ok());
    }

    #[tokio::test]
    async fn update_checks_effort_against_the_agent_runtime() {
        let (app, _dir) = app_in_tempdir();
        let grok = call(&app, "agents.create", new_agent("Scout", "grok")).await.unwrap();
        let id = grok["id"].as_str().unwrap().to_string();

        let err = call(&app, "agents.update", json!({ "id": id, "effort": "xhigh" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("grok doesn't offer effort xhigh"));

        call(&app, "agents.update", json!({ "id": id, "effort": "high" }))
            .await
            .unwrap();

        let err = call(&app, "agents.update", json!({ "id": id, "context_budget": 5 }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
    }

    #[tokio::test]
    async fn create_removes_the_agent_when_its_folder_fails() {
        let dir = tempfile::tempdir().unwrap();
        // The agents root is a file, so no folder can be made under it.
        let root = dir.path().join("not-a-dir");
        std::fs::write(&root, "x").unwrap();
        let app = app_with_root(root, Runtimes::default());

        let err = call(&app, "agents.create", new_agent("Forge", "claude"))
            .await
            .unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
        assert!(
            err.message.starts_with("could not create the agent's folder:"),
            "{}",
            err.message
        );
        assert!(app.sup.hub().store.agent_list().unwrap().is_empty());
    }

    #[tokio::test]
    async fn usage_limits_events_fill_the_cache() {
        let (app, _dir) = app_in_tempdir();
        let windows = vec![LimitWindow {
            name: "5h".into(),
            utilization: 0.4,
            resets_at: Some(1_900_000_000),
        }];
        app.sup.hub().emit(
            "agent-1",
            EventBody::UsageLimits {
                runtime: "claude".into(),
                windows: windows.clone(),
            },
        );
        let v = call(&app, "usage.limits", json!({})).await.unwrap();
        let entries: Vec<UsageEntry> = serde_json::from_value(v).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].runtime, "claude");
        assert_eq!(entries[0].windows, windows);
    }

    #[tokio::test]
    async fn usage_refresh_caches_answers_and_reports_errors() {
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Codex,
            answer: Ok(Some(vec![window("5h", 0.25)])),
            plan: Ok(None),
        }));
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Grok,
            answer: Err("login expired".into()),
            plan: Ok(None),
        }));
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Claude,
            answer: Ok(None),
            plan: Ok(None),
        }));
        let dir = tempfile::tempdir().unwrap();
        let app = app_with_root(dir.path().to_path_buf(), rts);

        let v = call(&app, "usage.refresh", json!({})).await.unwrap();
        assert_eq!(v["limits"].as_array().unwrap().len(), 1);
        assert_eq!(v["limits"][0]["runtime"], "codex");
        assert_eq!(v["limits"][0]["windows"][0]["name"], "5h");
        assert_eq!(v["errors"], json!([{ "runtime": "grok", "message": "login expired" }]));

        // The cache now answers usage.limits with the same windows.
        assert_eq!(call(&app, "usage.limits", json!({})).await.unwrap(), v["limits"]);
    }

    #[tokio::test]
    async fn usage_refresh_stores_the_plan_with_or_without_windows() {
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Claude,
            answer: Ok(None),
            plan: Ok(Some(plan("max_20x", "Max ×20"))),
        }));
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Codex,
            answer: Ok(Some(vec![window("5h", 0.25)])),
            plan: Ok(Some(plan("pro", "Pro"))),
        }));
        let dir = tempfile::tempdir().unwrap();
        let app = app_with_root(dir.path().to_path_buf(), rts);

        let v = call(&app, "usage.refresh", json!({})).await.unwrap();
        assert_eq!(v["errors"], json!([]));
        let limits = v["limits"].as_array().unwrap();
        assert_eq!(limits.len(), 2);
        assert_eq!(limits[0]["runtime"], "claude");
        assert_eq!(limits[0]["windows"], json!([]));
        assert_eq!(limits[0]["plan"], json!({"id": "max_20x", "label": "Max ×20"}));
        assert_eq!(limits[1]["runtime"], "codex");
        assert_eq!(limits[1]["windows"][0]["name"], "5h");
        assert_eq!(limits[1]["plan"], json!({"id": "pro", "label": "Pro"}));
        assert_eq!(call(&app, "usage.limits", json!({})).await.unwrap(), v["limits"]);
    }

    #[tokio::test]
    async fn usage_refresh_keeps_the_stored_plan_when_none_or_an_error_comes_back() {
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Codex,
            answer: Ok(None),
            plan: Ok(None),
        }));
        rts.insert(Arc::new(UsageProbe {
            kind: RuntimeKind::Grok,
            answer: Ok(None),
            plan: Err("account read timed out".into()),
        }));
        let dir = tempfile::tempdir().unwrap();
        let app = app_with_root(dir.path().to_path_buf(), rts);
        app.sup
            .hub()
            .store
            .usage_set_plan("codex", Some(&plan("pro", "Pro")), 1)
            .unwrap();

        let v = call(&app, "usage.refresh", json!({})).await.unwrap();
        assert_eq!(v["errors"], json!([]), "a plan error is logged, not reported");
        assert_eq!(v["limits"][0]["runtime"], "codex");
        assert_eq!(v["limits"][0]["plan"], json!({"id": "pro", "label": "Pro"}));
    }
}

#[cfg(test)]
mod fallback_tests {
    use super::*;
    use crate::event::EventBody;
    use crate::hub::Hub;
    use crate::runtime::{Runtime, RuntimeKind, RuntimeStatus, SpawnConfig, Spawned};
    use crate::store::Store;
    use crate::supervisor::Runtimes;
    use async_trait::async_trait;

    /// A runtime that is installed on this server. The tests here never start a session on it.
    struct Installed(RuntimeKind);

    #[async_trait]
    impl Runtime for Installed {
        fn kind(&self) -> RuntimeKind {
            self.0
        }
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus {
                kind: self.0,
                installed: true,
                version: None,
                logged_in: None,
                detail: None,
            }
        }
        async fn spawn(&self, _cfg: SpawnConfig) -> anyhow::Result<Spawned> {
            anyhow::bail!("not spawned in these tests")
        }
    }

    /// An app whose server has `installed` runtimes; agent folders under a temp dir kept by the caller.
    fn app_with(installed: &[RuntimeKind]) -> (Arc<App>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let mut runtimes = Runtimes::default();
        for kind in installed {
            runtimes.insert(Arc::new(Installed(*kind)));
        }
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), runtimes, None);
        (App::new(sup, dir.path().join("agents")), dir)
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn new_agent(name: &str, runtime: &str) -> Value {
        json!({
            "name": name,
            "runtime": runtime,
            "cwd": std::env::temp_dir().display().to_string(),
        })
    }

    async fn create(app: &App, p: Value) -> Value {
        call(app, "agents.create", p).await.unwrap()
    }

    fn event_bodies(app: &App) -> Vec<EventBody> {
        app.sup
            .hub()
            .store
            .events_since(0, 1000, None)
            .unwrap()
            .into_iter()
            .map(|e| e.body)
            .collect()
    }

    #[tokio::test]
    async fn create_takes_a_fallback_and_refuses_a_bad_one() {
        let (app, _dir) = app_with(&[RuntimeKind::Codex]);
        let mut p = new_agent("Forge", "claude");
        p["fallback_runtime"] = json!("codex");
        p["fallback_model"] = json!("gpt-5.5");
        let created = create(&app, p).await;
        assert_eq!(created["fallback_runtime"], "codex");
        assert_eq!(created["fallback_model"], "gpt-5.5");
        assert!(created["active_runtime"].is_null());
        let got = call(&app, "agents.get", json!({ "id": created["id"] })).await.unwrap();
        assert_eq!(got["fallback_runtime"], "codex");

        // Not a subscription runtime, not the primary one, not a runtime name at all.
        for bad in ["api", "claude", "gemini"] {
            let mut p = new_agent("Scout", "claude");
            p["fallback_runtime"] = json!(bad);
            let err = call(&app, "agents.create", p).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "fallback {bad}: {}", err.message);
        }
    }

    #[tokio::test]
    async fn update_takes_the_model_as_typed_and_clears_it_with_null() {
        let (app, _dir) = app_with(&[]);
        let created = create(&app, new_agent("Forge", "claude")).await;
        let id = created["id"].clone();

        let set = call(&app, "agents.update", json!({ "id": id, "model": "claude-opus-5" }))
            .await
            .unwrap();
        assert_eq!(set["model"], "claude-opus-5");
        let cleared = call(&app, "agents.update", json!({ "id": id, "model": null }))
            .await
            .unwrap();
        assert!(cleared["model"].is_null());

        let fb = call(&app, "agents.update", json!({ "id": id, "fallback_model": "gpt-5.5" }))
            .await
            .unwrap();
        assert_eq!(fb["fallback_model"], "gpt-5.5");
    }

    #[tokio::test]
    async fn update_runtime_starts_a_new_chapter_and_drops_an_effort_the_new_runtime_lacks() {
        let (app, _dir) = app_with(&[RuntimeKind::Codex]);
        let mut p = new_agent("Forge", "claude");
        p["effort"] = json!("max");
        let created = create(&app, p).await;
        let id = created["id"].as_str().unwrap().to_string();
        app.sup.hub().store.agent_set_session(&id, Some("sess-1")).unwrap();

        let res = call(&app, "agents.update", json!({ "id": id, "runtime": "codex" }))
            .await
            .unwrap();
        assert_eq!(res["runtime"], "codex");
        assert!(res["effort"].is_null(), "max is not offered by codex");
        let warnings = res["warnings"].as_array().unwrap();
        assert_eq!(warnings.len(), 1, "{warnings:?}");
        assert!(warnings[0].as_str().unwrap().contains("max"));

        let stored = app.sup.hub().store.agent_get(&id).unwrap().unwrap();
        assert!(stored.runtime_session_id.is_none(), "the Claude session is not resumed");
        assert_eq!(stored.chapter, 2);
        assert!(event_bodies(&app).iter().any(|b| matches!(
            b,
            EventBody::SessionRotated { reason, .. } if reason == "runtime changed"
        )));
    }

    #[tokio::test]
    async fn update_runtime_keeps_an_effort_the_new_runtime_offers() {
        let (app, _dir) = app_with(&[RuntimeKind::Codex]);
        let mut p = new_agent("Forge", "claude");
        p["effort"] = json!("high");
        let created = create(&app, p).await;
        let res = call(
            &app,
            "agents.update",
            json!({ "id": created["id"], "runtime": "codex" }),
        )
        .await
        .unwrap();
        assert_eq!(res["effort"], "high");
        assert_eq!(res["warnings"], json!([]));
    }

    #[tokio::test]
    async fn update_runtime_refuses_a_runtime_that_is_not_installed_here() {
        let (app, _dir) = app_with(&[RuntimeKind::Codex]);
        let created = create(&app, new_agent("Forge", "claude")).await;
        let err = call(&app, "agents.update", json!({ "id": created["id"], "runtime": "grok" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(
            err.message.contains("grok is not available on this server"),
            "{}",
            err.message
        );
    }

    #[tokio::test]
    async fn the_fallback_must_differ_from_the_runtime_after_the_patch() {
        let (app, _dir) = app_with(&[RuntimeKind::Codex]);
        let mut p = new_agent("Forge", "claude");
        p["fallback_runtime"] = json!("codex");
        let created = create(&app, p).await;
        let id = created["id"].clone();

        // Switching to codex while codex is still the fallback is refused...
        let err = call(&app, "agents.update", json!({ "id": id, "runtime": "codex" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        // ...but clearing the fallback in the same patch is fine.
        let ok = call(
            &app,
            "agents.update",
            json!({ "id": id, "runtime": "codex", "fallback_runtime": null }),
        )
        .await
        .unwrap();
        assert_eq!(ok["runtime"], "codex");
        assert!(ok["fallback_runtime"].is_null());
    }
}

#[cfg(test)]
mod trust_tests {
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};

    fn app() -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, std::env::temp_dir().join("bandito-trust-tests"))
    }

    fn device() -> Peer {
        Peer::Device(Device {
            id: "dev-1".into(),
            name: "Mac".into(),
            created_at: 0,
            last_seen_at: None,
        })
    }

    /// Methods an agent must never reach: the owner's tools and the apps' administration.
    const OWNER_ONLY: &[&str] = &[
        "pair.create",
        "pair.redeem",
        "rules.list",
        "rules.set",
        "rules.delete",
        "approvals.list",
        "approvals.resolve",
        "devices.list",
        "devices.revoke",
        "secrets.list",
        "secrets.set",
        "secrets.delete",
        "agents.create",
        "agents.update",
        "agents.delete",
        "agents.get",
        "agents.list",
        "agents.send",
        "agents.interrupt",
        "commands.list",
        "workspaces.list",
        "workspaces.create",
        "workspaces.update",
        "workspaces.delete",
        "workspaces.start",
        "workspaces.stop",
        "setup.status",
        "setup.install",
        "setup.job",
        "schedules.create",
        "daemon.info",
        "fs.list",
        "term.open",
        "events.since",
        "usage.refresh",
        "host.stats",
        "host.kill_process",
        "changes.checkpoints",
        "browser.start",
        "browser.stop",
        "screen.start",
        "screen.stop",
    ];

    #[tokio::test]
    async fn agents_cannot_reach_the_owners_methods() {
        let agent = Peer::Agent("agent-a".into());
        for method in OWNER_ONLY {
            let err = dispatch(&app(), &agent, method, json!({})).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
    }

    #[tokio::test]
    async fn agents_cannot_install_commands_for_the_user() {
        let agent = Peer::Agent("agent-a".into());
        let err = dispatch(&app(), &agent, "commands.install", json!({ "scope": "user" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
    }

    #[tokio::test]
    async fn agents_cannot_reach_the_owners_methods_through_a_secret_or_a_rule() {
        let agent = Peer::Agent("agent-a".into());
        let cases = [
            ("rules.set", json!({ "pattern": "rm", "action": "allow" })),
            ("approvals.resolve", json!({ "approval_id": "x", "decision": "allow" })),
            ("agents.update", json!({ "id": "agent-a", "name": "Other" })),
            ("agents.create", json!({ "name": "x" })),
            ("agents.delete", json!({ "id": "agent-a" })),
            ("secrets.list", json!({})),
            ("pair.create", json!({})),
            ("devices.list", json!({})),
            ("setup.install", json!({})),
            ("workspaces.create", json!({ "name": "x" })),
        ];
        for (method, params) in cases {
            let err = dispatch(&app(), &agent, method, params).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
    }

    #[tokio::test]
    async fn owner_and_devices_cannot_use_the_agent_tools() {
        let calls = [
            ("browser.agent.click", json!({ "node": 1, "agent_id": "agent-a" })),
            ("screen.agent.click", json!({ "x": 1, "y": 1 })),
            ("crew.send", json!({ "from": "agent-a", "to": "x", "message": "hi" })),
            ("history.day", json!({ "agent_id": "agent-a", "date": "2026-10-09" })),
        ];
        for (method, params) in calls {
            for peer in [Peer::Local, device()] {
                let err = dispatch(&app(), &peer, method, params.clone()).await.unwrap_err();
                assert_eq!(err.code, UNAUTHORIZED, "{method} from {peer:?}");
            }
        }
    }

    #[tokio::test]
    async fn an_agent_may_call_its_crew_tools() {
        let agent = Peer::Agent("agent-a".into());
        let v = dispatch(&app(), &agent, "crew.list", json!({})).await.unwrap();
        assert_eq!(v, json!([]));
    }

    #[tokio::test]
    async fn only_the_owner_and_apps_may_update_the_daemon() {
        // Refused by the gate before anything runs, so no network call happens here.
        let agent = Peer::Agent("agent-a".into());
        let anonymous = Peer::Anonymous("203.0.113.7".into());
        for method in ["daemon.update_check", "daemon.update_apply"] {
            for peer in [&agent, &anonymous] {
                let err = dispatch(&app(), peer, method, json!({ "version": "9.9.9" }))
                    .await
                    .unwrap_err();
                assert_eq!(err.code, UNAUTHORIZED, "{method} from {peer:?}");
            }
            assert!(allowed(&Peer::Local, method), "{method} from the owner");
            assert!(allowed(&device(), method), "{method} from an app");
        }
    }

    #[test]
    fn who_may_call_what() {
        let agent = Peer::Agent("agent-a".into());
        let anonymous = Peer::Anonymous("203.0.113.7".into());
        for method in AGENT_METHODS {
            assert!(allowed(&agent, method), "{method}");
        }
        assert!(allowed(&agent, "daemon.hello"));
        assert!(!allowed(&agent, "events.subscribe"));
        assert!(!allowed(&agent, "term.attach"));
        assert!(!allowed(&agent, "rules.set"));
        assert!(allowed(&Peer::Local, "rules.set"));
        assert!(allowed(&Peer::Local, "events.subscribe"));
        assert!(!allowed(&Peer::Local, "history.day"));
        assert!(!allowed(&Peer::Local, "crew.send"));
        assert!(allowed(&device(), "rules.set"));
        assert!(allowed(&device(), "crew.list"));
        assert!(!allowed(&device(), "browser.agent.click"));
        assert!(allowed(&anonymous, "daemon.hello"));
        assert!(allowed(&anonymous, "pair.redeem"));
        assert!(!allowed(&anonymous, "crew.list"));
    }

    #[tokio::test]
    async fn an_agent_names_only_itself_in_its_params() {
        let agent = Peer::Agent("agent-a".into());
        let err = dispatch(&app(), &agent, "crew.list", json!({ "agent_id": "agent-b" }))
            .await
            .unwrap_err();
        assert_eq!(err, RpcError::new(UNAUTHORIZED, "an agent can only act as itself"));
        assert!(
            dispatch(&app(), &agent, "crew.list", json!({ "agent_id": "agent-a" }))
                .await
                .is_ok()
        );
    }

    async fn try_redeem(app: &Arc<App>, peer: &Peer) -> RpcResult {
        dispatch(
            app,
            peer,
            "pair.redeem",
            json!({ "code": "not-a-real-code", "device_name": "test" }),
        )
        .await
    }

    #[tokio::test]
    async fn a_source_gets_five_failed_redeems_then_is_stopped() {
        let app = app();
        let attacker = Peer::Anonymous("203.0.113.7".into());
        for _ in 0..REDEEM_MAX_FAILURES_PER_SOURCE {
            let err = try_redeem(&app, &attacker).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED);
        }
        let err = try_redeem(&app, &attacker).await.unwrap_err();
        assert_eq!(err.code, RATE_LIMITED);
        // Another source is not held back by it.
        let other = Peer::Anonymous("198.51.100.9".into());
        let err = try_redeem(&app, &other).await.unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
    }

    #[test]
    fn the_daemon_wide_budget_applies_to_every_source() {
        let mut limiter = RedeemLimiter::default();
        let now = 1_000_000;
        for i in 0..REDEEM_MAX_FAILURES {
            limiter.failed(&format!("ip-{i}"), now);
        }
        assert!(!limiter.allows("fresh-source", now));
        // The failures leave the window after ten minutes.
        assert!(limiter.allows("fresh-source", now + REDEEM_WINDOW_MS + 1));
    }

    #[test]
    fn a_failure_leaves_the_window_after_ten_minutes() {
        let mut limiter = RedeemLimiter::default();
        for _ in 0..REDEEM_MAX_FAILURES_PER_SOURCE {
            limiter.failed("ip", 0);
        }
        assert!(!limiter.allows("ip", REDEEM_WINDOW_MS - 1));
        assert!(limiter.allows("ip", REDEEM_WINDOW_MS + 1));
    }
}

#[cfg(test)]
mod pause_and_logs_tests {
    use super::*;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, Store};

    fn new_agent(store: &Store, name: &str) -> String {
        store
            .agent_create(NewAgent {
                use_personal_settings: false,
                name: name.into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
            .id
    }

    /// An app whose data folder is `home` (for `daemon.logs`), with two agents.
    fn app_in(home: &std::path::Path) -> (Arc<App>, Arc<Store>, String, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let forge = new_agent(&store, "Forge");
        let scout = new_agent(&store, "Scout");
        let sup = Supervisor::new(Hub::new(store.clone()), crate::supervisor::Runtimes::default(), None);
        let app = App::new_in_home(sup, home.join("agents"), App::default_files(), home.to_path_buf());
        (app, store, forge, scout)
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn user_texts(store: &Store, agent: &str) -> Vec<String> {
        store
            .events_since(0, 1000, Some(agent))
            .unwrap()
            .into_iter()
            .filter_map(|e| match e.body {
                EventBody::MessageUser { text, .. } => Some(text),
                _ => None,
            })
            .collect()
    }

    #[tokio::test]
    async fn agents_list_and_get_carry_the_last_message() {
        use crate::event::Source;
        let dir = tempfile::tempdir().unwrap();
        let (app, store, forge, scout) = app_in(dir.path());
        store
            .append_event(
                &forge,
                EventBody::MessageUser {
                    text: "hi".into(),
                    source: Source::User,
                    from_agent: None,
                    command: None,
                },
            )
            .unwrap();
        store
            .append_event(&forge, EventBody::MessageAssistant { text: "hello".into() })
            .unwrap();
        store
            .append_event(
                &scout,
                EventBody::MessageUser {
                    text: "wrap up".into(),
                    source: Source::System,
                    from_agent: None,
                    command: None,
                },
            )
            .unwrap();

        let got = call(&app, "agents.get", json!({ "id": forge })).await.unwrap();
        assert_eq!(got["last_message"]["role"], json!("assistant"));
        assert_eq!(got["last_message"]["text"], json!("hello"));
        assert!(got["last_message"]["ts"].is_i64());

        let list = call(&app, "agents.list", json!({})).await.unwrap();
        let of = |id: &str| {
            list.as_array()
                .unwrap()
                .iter()
                .find(|a| a["id"] == json!(id))
                .unwrap()
                .clone()
        };
        assert_eq!(of(&forge)["last_message"]["text"], json!("hello"));
        assert!(
            of(&scout)["last_message"].is_null(),
            "a message Bandito sent itself is no preview"
        );
    }

    #[tokio::test]
    async fn agents_list_carries_status_and_pending_approvals() {
        use crate::event::{AgentStatus, Decision};
        let dir = tempfile::tempdir().unwrap();
        let (app, store, forge, scout) = app_in(dir.path());
        store
            .append_event(
                &forge,
                EventBody::AgentStatus {
                    status: AgentStatus::NeedsYou,
                    detail: None,
                },
            )
            .unwrap();
        // Waiting for an answer before anyone opens the thread: the list is what the team shows from.
        let asked = store
            .approval_create(&forge, "call-1", "Bash", "git push", json!({}))
            .unwrap();
        let waiting = store
            .approval_create(&forge, "call-2", "Bash", "rm", json!({}))
            .unwrap();
        store.approval_resolve(&asked.id, Decision::Deny).unwrap();

        let list = call(&app, "agents.list", json!({})).await.unwrap();
        let of = |id: &str| {
            list.as_array()
                .unwrap()
                .iter()
                .find(|a| a["id"] == json!(id))
                .unwrap()
                .clone()
        };
        assert_eq!(of(&forge)["status"], json!("needs_you"));
        assert_eq!(of(&forge)["pending_approvals"], json!(1));
        assert_eq!(of(&forge)["pending_approval_ids"], json!([waiting.id]));
        assert_eq!(of(&scout)["status"], json!(null), "no status event yet");
        assert_eq!(of(&scout)["pending_approvals"], json!(0));

        let got = call(&app, "agents.get", json!({ "id": forge })).await.unwrap();
        assert_eq!(got["pending_approvals"], json!(1));
        assert_eq!(got["pending_approval_ids"], json!([waiting.id]));
    }

    #[tokio::test]
    async fn update_pauses_and_send_reports_it_is_queued() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store, forge, _) = app_in(dir.path());

        let paused = call(&app, "agents.update", json!({ "id": forge, "paused": true }))
            .await
            .unwrap();
        assert_eq!(paused["paused"], json!(true));
        assert_eq!(
            call(&app, "agents.get", json!({ "id": forge })).await.unwrap()["paused"],
            json!(true)
        );

        let sent = call(&app, "agents.send", json!({ "agent_id": forge, "text": "hello" }))
            .await
            .unwrap();
        assert_eq!(sent, json!({ "queued": true }));
        assert_eq!(user_texts(&store, &forge), vec!["hello"]);

        let resumed = call(&app, "agents.update", json!({ "id": forge, "paused": false }))
            .await
            .unwrap();
        assert_eq!(resumed["paused"], json!(false));
        // A patch without `paused` leaves the flag alone.
        let renamed = call(&app, "agents.update", json!({ "id": forge, "role": "reviewer" }))
            .await
            .unwrap();
        assert_eq!(renamed["paused"], json!(false));
    }

    #[tokio::test]
    async fn pause_all_pauses_every_agent_once() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store, _, _) = app_in(dir.path());

        assert_eq!(
            call(&app, "agents.pause_all", json!({ "paused": true })).await.unwrap(),
            json!({ "changed": 2 })
        );
        assert!(store.agent_list().unwrap().iter().all(|a| a.paused));
        assert_eq!(
            call(&app, "agents.pause_all", json!({ "paused": true })).await.unwrap(),
            json!({ "changed": 0 })
        );
        assert_eq!(
            call(&app, "agents.pause_all", json!({ "paused": false }))
                .await
                .unwrap(),
            json!({ "changed": 2 })
        );
        let err = call(&app, "agents.pause_all", json!({})).await.unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
    }

    #[test]
    fn pause_methods_are_the_owners_not_the_agents() {
        for method in ["agents.pause_all", "daemon.logs"] {
            assert!(allowed(&Peer::Local, method), "{method}");
            assert!(!allowed(&Peer::Agent("a".into()), method), "{method}");
        }
        assert!(allowed(&Peer::Local, "agents.update"));
        assert!(!allowed(&Peer::Agent("a".into()), "agents.update"));
    }

    #[tokio::test]
    async fn logs_return_the_newest_lines_redacted_and_validated() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store, _, _) = app_in(dir.path());
        store
            .secret_set("OPENAI_API_KEY", "sk-test-secret-123456", &["*".to_string()])
            .unwrap();
        let token = format!("bat_{}", "A".repeat(43));
        std::fs::create_dir_all(dir.path().join("logs")).unwrap();
        std::fs::write(
            dir.path().join("logs/daemon.log"),
            format!(
                "2026-10-09T10:00:00Z  INFO bandito: session {token} key sk-test-secret-123456\n\
                 2026-10-09T10:00:01Z  WARN bandito::sched: skipped\n\
                 2026-10-09T10:00:02Z  INFO bandito: idle\n"
            ),
        )
        .unwrap();

        let all = call(&app, "daemon.logs", json!({})).await.unwrap();
        assert_eq!(all["source"], json!("file"));
        let lines: Vec<String> = serde_json::from_value(all["lines"].clone()).unwrap();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].contains("bat_••••"), "{lines:?}");
        assert!(!lines.join("\n").contains(&"A".repeat(43)));
        assert!(!lines.join("\n").contains("sk-test-secret-123456"));
        assert!(lines[0].contains("••••OPENAI_API_KEY"), "{lines:?}");

        let last = call(&app, "daemon.logs", json!({ "lines": 1 })).await.unwrap();
        assert_eq!(last["lines"].as_array().unwrap().len(), 1);
        assert!(last["lines"][0].as_str().unwrap().ends_with("idle"));

        let warnings = call(&app, "daemon.logs", json!({ "level": "warn" })).await.unwrap();
        assert_eq!(warnings["lines"].as_array().unwrap().len(), 1);
        assert!(warnings["lines"][0].as_str().unwrap().contains("skipped"));

        for bad in [
            json!({ "lines": 0 }),
            json!({ "lines": 2001 }),
            json!({ "level": "debug" }),
        ] {
            let err = call(&app, "daemon.logs", bad.clone()).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{bad}");
        }
        let denied = dispatch(&app, &Peer::Agent("x".into()), "daemon.logs", json!({}))
            .await
            .unwrap_err();
        assert_eq!(denied.code, UNAUTHORIZED);
    }

    #[tokio::test]
    async fn logs_without_a_file_are_empty() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _, _, _) = app_in(dir.path());
        let reply = call(&app, "daemon.logs", json!({})).await.unwrap();
        assert_eq!(reply["lines"], json!([]));
    }

    #[test]
    fn logs_and_pause_are_advertised() {
        let f = features();
        assert!(f.contains(&"pause") && f.contains(&"logs"));
    }

    #[tokio::test]
    async fn runtimes_models_takes_only_the_three_agent_runtimes() {
        let store = Arc::new(crate::store::Store::open_in_memory().unwrap());
        let sup = crate::supervisor::Supervisor::new(
            crate::hub::Hub::new(store),
            crate::supervisor::Runtimes::default(),
            None,
        );
        let app = App::new(sup, std::env::temp_dir());
        let err = dispatch(&app, &Peer::Local, "runtimes.models", json!({"runtime": "api"}))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(features().contains(&"runtime_models"));
    }
}

#[cfg(test)]
mod folder_and_device_tests {
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};

    fn app_with(store: Arc<Store>, root: PathBuf) -> Arc<App> {
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, root)
    }

    #[tokio::test]
    async fn create_without_a_cwd_uses_the_agent_folder() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let app = app_with(store, dir.path().join("agents"));
        // No `cwd` key at all, then an empty one: both mean "the agent's own folder".
        for (name, p) in [
            ("Night Owl", json!({"name": "Night Owl", "runtime": "claude"})),
            ("Forge", json!({"name": "Forge", "runtime": "claude", "cwd": "  "})),
        ] {
            let agent = dispatch(&app, &Peer::Local, "agents.create", p).await.unwrap();
            let home = agent["home_dir"].as_str().unwrap();
            assert_eq!(agent["cwd"].as_str(), Some(home), "{name}: cwd is the agent folder");
            assert!(PathBuf::from(home).join("MEMORY.md").is_file());
        }
    }

    #[tokio::test]
    async fn create_with_a_missing_cwd_still_fails() {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let app = app_with(store.clone(), dir.path().join("agents"));
        let p = json!({"name": "Forge", "runtime": "claude", "cwd": "/nonexistent/folder/for/test"});
        assert!(dispatch(&app, &Peer::Local, "agents.create", p).await.is_err());
        assert!(store.agent_list().unwrap().is_empty(), "nothing is left behind");
    }

    #[tokio::test]
    async fn devices_list_marks_the_device_that_asks() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let mine = store.device_add("My phone", "tok-1").unwrap();
        store.device_add("Other Mac", "tok-2").unwrap();
        let app = app_with(store, PathBuf::from("/unused"));

        let asked = dispatch(&app, &Peer::Device(mine), "devices.list", json!({}))
            .await
            .unwrap();
        let rows: Vec<(String, bool)> = asked
            .as_array()
            .unwrap()
            .iter()
            .map(|d| (d["name"].as_str().unwrap().to_string(), d["current"].as_bool().unwrap()))
            .collect();
        assert_eq!(
            rows,
            vec![("My phone".to_string(), true), ("Other Mac".to_string(), false)]
        );

        let local = dispatch(&app, &Peer::Local, "devices.list", json!({})).await.unwrap();
        assert!(local.as_array().unwrap().iter().all(|d| d["current"] == json!(false)));
    }
}
