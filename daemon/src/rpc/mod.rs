//! JSON-RPC 2.0, the same on every transport (unix socket, WebSocket).
//! See docs/ARCHITECTURE.md#rpc.

use crate::browser::BrowserManager;
use crate::event::{Decision, Event, EventBody, Source};
use crate::files::FileService;
use crate::home;
use crate::host::Sampler;
use crate::pairing;
use crate::runtime::RuntimeKind;
use crate::scheduler;
use crate::setup::Setup;
use crate::store::{AgentPatch, Device, Effort, NewAgent, NewSchedule, NextRun, RuleAction, SchedulePatch, Store};
use crate::supervisor::{Inbound, Supervisor};
use crate::terminal::{Limits, TerminalManager};
use chrono::{Local, NaiveDate, NaiveTime, TimeZone};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc};

pub mod browser;
pub mod changes;
pub mod files;
pub mod host;
pub mod preview;
pub mod secrets;
pub mod setup;
pub mod term;
pub mod tunnel;
pub mod unix;
pub mod ws;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Capabilities this daemon offers. Clients show a feature only when it is
/// listed, so new apps keep working with older daemons. Add a string here in
/// the same PR that adds the feature.
pub const FEATURES: &[&str] = &[
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
    "browser",
];

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
    /// Timestamps of failed `pair.redeem` calls (rate limit).
    redeem_failures: Mutex<VecDeque<i64>>,
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
}

impl App {
    /// Files are served from the home folder of the user running the daemon.
    pub fn new(sup: Arc<Supervisor>, agents_root: PathBuf) -> Arc<Self> {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/"));
        Self::new_with_files(sup, agents_root, FileService::new(home, None))
    }

    pub fn new_with_files(sup: Arc<Supervisor>, agents_root: PathBuf, files: FileService) -> Arc<Self> {
        Arc::new(Self {
            sup,
            started_at: crate::store::now_ms(),
            hostname: hostname(),
            agents_root,
            terminals: TerminalManager::new(Limits::default()),
            redeem_failures: Mutex::new(VecDeque::new()),
            files: Arc::new(files),
            tunnels: Arc::new(tunnel::TunnelSlots::default()),
            host: Sampler::new(),
            setup: Setup::system(),
            browser: BrowserManager::system(),
        })
    }
}

fn hostname() -> String {
    std::process::Command::new("hostname")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "server".into())
}

/// Who is on the other end of a connection.
#[derive(Debug, Clone)]
pub enum Peer {
    /// Unix socket: same user on the server.
    Local,
    /// A paired app.
    Device(Device),
    /// Not authenticated yet: only `daemon.hello` and `pair.redeem`.
    Anonymous,
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
        Self::new(SERVER_ERROR, format!("{e:#}"))
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
const REDEEM_MAX_FAILURES: usize = 20;

#[derive(Deserialize)]
struct Id {
    id: String,
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
        } = self;
        name.as_ref().is_some_and(|n| n.trim() != current.name)
            || role.as_ref().is_some_and(|r| *r != current.role)
            || model.as_ref().is_some_and(|m| *m != current.model)
            || cwd.as_ref().is_some_and(|c| *c != current.cwd)
            || system_prompt.as_ref().is_some_and(|p| *p != current.system_prompt)
            || effort.as_ref().is_some_and(|e| *e != current.effort)
            || memory_mode.as_ref().is_some_and(|m| *m != current.memory_mode)
            || context_budget.as_ref().is_some_and(|b| *b != current.context_budget)
    }
}
/// `{"x": null}` → `Some(None)` (clear), missing → `None` (keep).
fn double_option<'de, D: serde::Deserializer<'de>, T: Deserialize<'de>>(d: D) -> Result<Option<Option<T>>, D::Error> {
    Option::<T>::deserialize(d).map(Some)
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

fn check_context_budget(budget: Option<u32>) -> Result<(), RpcError> {
    match budget {
        Some(b) if !CONTEXT_BUDGET.contains(&b) => Err(RpcError::new(
            INVALID_PARAMS,
            "context budget must be between 20 000 and 1 000 000 tokens",
        )),
        _ => Ok(()),
    }
}

/// History is read by the crew MCP servers (same user, unix socket) only.
fn ensure_local(peer: &Peer) -> Result<(), RpcError> {
    if matches!(peer, Peer::Local) {
        Ok(())
    } else {
        Err(RpcError::new(
            UNAUTHORIZED,
            "history can only be read by agents on the server",
        ))
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

/// Handle one request. `events.subscribe` lives in [`serve`] because it needs
/// connection state.
pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    if matches!(peer, Peer::Anonymous) && !matches!(method, "daemon.hello" | "pair.redeem") {
        return Err(RpcError::new(
            UNAUTHORIZED,
            "not paired: run `bandito pair` on the server",
        ));
    }
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
            "authenticated": !matches!(peer, Peer::Anonymous),
        })),
        "daemon.info" => ok(json!({
            "version": VERSION,
            "hostname": app.hostname,
            "os": std::env::consts::OS,
            "arch": std::env::consts::ARCH,
            "started_at": app.started_at,
            "last_seq": store.last_seq()?,
            "features": FEATURES,
        })),
        "runtimes.status" => {
            let mut out = Vec::new();
            for rt in app.sup.runtimes().all() {
                out.push(rt.status().await);
            }
            out.sort_by_key(|s| s.kind.as_str());
            ok(out)
        }

        "agents.list" => ok(store.agent_list()?),
        "agents.get" => {
            let Id { id } = params(p)?;
            ok(store
                .agent_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?)
        }
        "agents.create" => {
            let a: NewAgent = params(p)?;
            check_cwd(&a.cwd)?;
            check_effort(a.runtime, a.effort)?;
            check_context_budget(a.context_budget)?;
            let created = store.agent_create(a)?;
            let folder = home::ensure_agent_home(&app.agents_root, &created.id, &created.name).and_then(|dir| {
                store.agent_set_home(&created.id, &dir.display().to_string())?;
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
                .agent_get(&created.id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {}", created.id)))?)
        }
        "agents.update" => {
            let UpdateAgent { id, patch } = params(p)?;
            if let Some(cwd) = &patch.cwd {
                check_cwd(cwd)?;
            }
            // Effort is checked against the agent's runtime, which a patch cannot change.
            let current = store
                .agent_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?;
            check_effort(current.runtime, patch.effort.flatten())?;
            check_context_budget(patch.context_budget.flatten())?;
            let reload = patch.changes_session(&current);
            // A session is tied to its folder: a folder change starts a new chapter.
            let new_chapter = patch.cwd.as_ref().is_some_and(|cwd| *cwd != current.cwd);
            let a = store.agent_update(
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
                },
            )?;
            // New config takes effect with the next session: the running one is
            // closed when idle, or once its turn ends. The chapter goes on, unless
            // the folder changed.
            if reload {
                app.sup.reload(&id, new_chapter).await;
            }
            ok(a)
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
            app.sup.send(&agent_id, Inbound::user(text)).await?;
            ok(json!({}))
        }
        "agents.interrupt" => {
            let AgentRef { agent_id } = params(p)?;
            app.sup.interrupt(&agent_id).await?;
            ok(json!({}))
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
            // Only the crew MCP servers (same user, unix socket) may send.
            if !matches!(peer, Peer::Local) {
                return Err(RpcError::new(
                    UNAUTHORIZED,
                    "crew messages can only come from agents on the server",
                ));
            }
            let CrewSendParams { from, to, message } = params(p)?;
            let to_id = app.sup.crew_send(&from, &to, &message).await?;
            ok(json!({ "to_id": to_id }))
        }

        "history.search" => {
            ensure_local(peer)?;
            let h: HistorySearchParams = params(p)?;
            let name = history_agent_name(store, &h.agent_id)?;
            let events = store.history_search(&h.agent_id, &h.query, h.limit)?;
            ok(json!({ "text": format_history(&events, &name) }))
        }
        "history.day" => {
            ensure_local(peer)?;
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

        "devices.list" => ok(store.device_list()?),
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
            {
                let mut f = app.redeem_failures.lock().unwrap_or_else(|e| e.into_inner());
                while f.front().is_some_and(|t| *t < now - REDEEM_WINDOW_MS) {
                    f.pop_front();
                }
                if f.len() >= REDEEM_MAX_FAILURES {
                    return Err(RpcError::new(
                        RATE_LIMITED,
                        "too many attempts, try again in a few minutes",
                    ));
                }
            }
            if !store.pairing_take(&r.code)? {
                app.redeem_failures
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push_back(now);
                return Err(RpcError::new(UNAUTHORIZED, "invalid or expired code"));
            }
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

        "host.stats" | "host.history" | "host.processes" | "host.ports" | "host.kill" => {
            host::dispatch(app, method, p).await
        }

        "setup.status" | "setup.install" | "setup.job" => setup::dispatch(app, method, p).await,

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
            &Peer::Local,
            "crew.send",
            json!({ "from": forge, "to": "Nobody", "message": "hi" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
        assert!(err.message.contains("no agent named"), "{}", err.message);
    }

    #[tokio::test]
    async fn crew_send_is_local_only_while_crew_list_is_open_to_devices() {
        let (app, forge, _) = app_with_crew();
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
        assert_eq!(
            err,
            RpcError::new(UNAUTHORIZED, "crew messages can only come from agents on the server")
        );
        let v = dispatch(&app, &device, "crew.list", json!({ "agent_id": forge }))
            .await
            .unwrap();
        assert_eq!(v.as_array().unwrap().len(), 1);
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
            &Peer::Local,
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
        let v = dispatch(
            &app,
            &Peer::Local,
            "history.search",
            json!({ "agent_id": forge, "query": "  " }),
        )
        .await
        .unwrap();
        assert_eq!(v["text"], "Nothing found.");

        let err = dispatch(
            &app,
            &Peer::Local,
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
        let store = app.sup.hub().store.clone();
        store
            .append_event(&forge, user("standup notes", Source::User, None))
            .unwrap();
        let today = Local::now().format("%Y-%m-%d").to_string();
        let v = dispatch(
            &app,
            &Peer::Local,
            "history.day",
            json!({ "agent_id": forge, "date": today }),
        )
        .await
        .unwrap();
        assert!(v["text"].as_str().unwrap().ends_with(" · user: standup notes"), "{v}");

        let v = dispatch(
            &app,
            &Peer::Local,
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
        for bad in ["2026-13-01", "2026-1-5", "2026-02-30", "yesterday"] {
            let err = dispatch(
                &app,
                &Peer::Local,
                "history.day",
                json!({ "agent_id": forge, "date": bad }),
            )
            .await
            .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{bad}");
        }
    }

    #[tokio::test]
    async fn history_is_local_only() {
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
        assert_eq!(
            search,
            RpcError::new(UNAUTHORIZED, "history can only be read by agents on the server")
        );
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
                let result = if req.method == "events.subscribe" {
                    if matches!(peer, Peer::Anonymous) {
                        Err(RpcError::new(UNAUTHORIZED, "not paired"))
                    } else {
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
