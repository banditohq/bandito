//! The models each agent CLI offers, read from the CLI itself (`runtimes.models`). See docs/ARCHITECTURE.md#runtime-models.
//!
//! No model request is sent: Claude answers its `initialize` control request, Codex lists its models over
//! `app-server`, and Grok reads its own cache file or, without one, asks over ACP. Each CLI is asked in its own
//! process, which is killed as soon as the answer is in, on an error, or after [`LIST_TIMEOUT`].

use super::RuntimeKind;
use super::process::{self, JsonProcess, LineSink, Router};
use serde::Serialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::ffi::OsStr;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::process::Command;
use tokio::sync::{Mutex, oneshot};
use tokio::time::timeout;

/// How long one CLI may take to list its models, from start to answer.
pub const LIST_TIMEOUT: Duration = Duration::from_secs(20);
/// How long a good listing is reused before the CLI is asked again.
pub const CACHE_TTL: Duration = Duration::from_secs(15 * 60);
/// How long a failed listing is reused: a CLI that was not ready is asked again soon.
pub const ERROR_TTL: Duration = Duration::from_secs(30);
/// How long each kind of stored answer is reused.
#[derive(Clone, Copy)]
struct Ttl {
    answer: Duration,
    error: Duration,
}
const TTL: Ttl = Ttl {
    answer: CACHE_TTL,
    error: ERROR_TTL,
};
/// Codex lists its models in pages; at most this many are asked for.
const CODEX_MAX_PAGES: usize = 5;
/// `request_id` of Claude's `initialize` control request.
const CLAUDE_INIT_ID: &str = "bandito-models";
/// Codex and ACP request ids: `initialize` first, then the model list (Codex: one id per page) or `session/new`.
const CODEX_INIT_ID: i64 = 1;
const CODEX_FIRST_PAGE_ID: i64 = 2;
const ACP_INIT_ID: i64 = 1;
const ACP_SESSION_ID: i64 = 2;
/// The error text of a CLI that is not installed.
pub const NOT_INSTALLED: &str = "not_installed";

/// One model a CLI offers. `id` is what the CLI takes as its model name.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct RuntimeModel {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    /// The model the CLI uses when none is chosen. At most one model is marked.
    pub is_default: bool,
    /// Reasoning effort levels the model accepts; empty when it takes none.
    pub efforts: Vec<String>,
}

/// What `runtimes.models` answers for one runtime.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ModelsAnswer {
    pub runtime: RuntimeKind,
    pub models: Vec<RuntimeModel>,
    /// `not_installed`, or the reason the CLI gave no list. `None` when the list is good.
    pub error: Option<String>,
    /// Unix milliseconds when the list was read from the CLI.
    pub fetched_at: i64,
}

/// Why a CLI gave no model list.
#[derive(Debug, Clone, PartialEq)]
pub enum ListError {
    NotInstalled,
    Failed(String),
}

impl ListError {
    /// The text `runtimes.models` reports as `error`.
    pub fn message(&self) -> String {
        match self {
            ListError::NotInstalled => NOT_INSTALLED.to_string(),
            ListError::Failed(text) => text.clone(),
        }
    }
}

/// A non-empty text field of a JSON object, trimmed.
fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

/// The strings of a JSON array; anything else gives none.
fn strings(v: Option<&Value>) -> Vec<String> {
    v.and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
        .unwrap_or_default()
}

/// The models in Claude's `initialize` answer. `answer` is the object that holds `models`.
///
/// The `default` entry is not listed: the first other entry with the same `resolvedModel` is the default model.
pub fn parse_claude_models(answer: &Value) -> Vec<RuntimeModel> {
    let Some(items) = answer.get("models").and_then(Value::as_array) else {
        return Vec::new();
    };
    let is_default_entry = |m: &Value| m.get("value").and_then(Value::as_str) == Some("default");
    let default_model = items
        .iter()
        .find(|m| is_default_entry(m))
        .and_then(|m| text(m, "resolvedModel"));
    let mut marked = false;
    items
        .iter()
        .filter(|m| !is_default_entry(m))
        .filter_map(|m| {
            let id = text(m, "value")?;
            let is_default = !marked && default_model.is_some() && text(m, "resolvedModel") == default_model;
            marked |= is_default;
            Some(RuntimeModel {
                name: text(m, "displayName").unwrap_or_else(|| id.clone()),
                description: text(m, "description"),
                is_default,
                efforts: strings(m.get("supportedEffortLevels")),
                id,
            })
        })
        .collect()
}

/// One entry per id (the first one), and at most one default: the first marked.
fn settle_models(models: Vec<RuntimeModel>) -> Vec<RuntimeModel> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut has_default = false;
    models
        .into_iter()
        .filter(|m| seen.insert(m.id.clone()))
        .map(|mut m| {
            if m.is_default {
                m.is_default = !has_default;
                has_default = true;
            }
            m
        })
        .collect()
}

/// The models in Codex's `model/list` answer. `result` is the object that holds `data`.
///
/// Hidden models are not listed. The id is `model`, or `id` when there is no `model`. See [`settle_models`].
pub fn parse_codex_models(result: &Value) -> Vec<RuntimeModel> {
    let Some(items) = result.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    let listed = items
        .iter()
        .filter(|m| m.get("hidden").and_then(Value::as_bool) != Some(true))
        .filter_map(|m| {
            let id = text(m, "model").or_else(|| text(m, "id"))?;
            Some(RuntimeModel {
                name: text(m, "displayName").unwrap_or_else(|| id.clone()),
                description: text(m, "description"),
                is_default: m.get("isDefault").and_then(Value::as_bool) == Some(true),
                efforts: m
                    .get("supportedReasoningEfforts")
                    .and_then(Value::as_array)
                    .map(|levels| levels.iter().filter_map(|l| text(l, "reasoningEffort")).collect())
                    .unwrap_or_default(),
                id,
            })
        })
        .collect();
    settle_models(listed)
}

/// The models in Grok's cache file (`~/.grok/models_cache.json`). `cache` is the root object, with `models` as a map.
///
/// The cache has no default flag: the model named `default_id` (from `~/.grok/settings_cache.json`) is the default,
/// and without one, or when that model is not listed, the newest visible model (see [`newest`]). Hidden models are not listed.
pub fn parse_grok_cache(cache: &Value, default_id: Option<&str>) -> Vec<RuntimeModel> {
    let Some(models) = cache.get("models").and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut listed: Vec<RuntimeModel> = models
        .iter()
        .filter_map(|(key, entry)| {
            let info = entry.get("info")?;
            if info.get("hidden").and_then(Value::as_bool) == Some(true) {
                return None;
            }
            let id = text(info, "id").unwrap_or_else(|| key.clone());
            Some(RuntimeModel {
                name: text(info, "name").unwrap_or_else(|| id.clone()),
                description: text(info, "description"),
                is_default: false,
                efforts: info
                    .get("reasoning_efforts")
                    .and_then(Value::as_array)
                    .map(|levels| levels.iter().filter_map(|l| text(l, "value")).collect())
                    .unwrap_or_default(),
                id,
            })
        })
        .collect();
    let chosen = default_id
        .and_then(|wanted| listed.iter().position(|m| m.id == wanted))
        .or_else(|| newest(&listed));
    if let Some(index) = chosen {
        listed[index].is_default = true;
    }
    listed
}

/// The index of the newest model: the one whose version numbers are the highest, compared part by part
/// (`grok-4.10` is newer than `grok-4.9`). On a tie the first one wins.
fn newest(models: &[RuntimeModel]) -> Option<usize> {
    let mut best: Option<(usize, Vec<u64>)> = None;
    for (index, model) in models.iter().enumerate() {
        let version = version_numbers(&model.id);
        if best.as_ref().is_none_or(|(_, top)| version > *top) {
            best = Some((index, version));
        }
    }
    best.map(|(index, _)| index)
}

/// The numbers in a model id, in order: `grok-4.10` gives `[4, 10]`.
fn version_numbers(id: &str) -> Vec<u64> {
    id.split(|c: char| !c.is_ascii_digit())
        .filter_map(|part| part.parse().ok())
        .collect()
}

/// The models in Grok's ACP `session/new` answer. `models` is the object with `currentModelId` and `availableModels`.
pub fn parse_grok_acp(models: &Value) -> Vec<RuntimeModel> {
    let current = text(models, "currentModelId");
    let Some(items) = models.get("availableModels").and_then(Value::as_array) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(|m| {
            let id = text(m, "modelId")?;
            Some(RuntimeModel {
                name: text(m, "name").unwrap_or_else(|| id.clone()),
                description: text(m, "description"),
                is_default: current.as_deref() == Some(id.as_str()),
                efforts: m
                    .get("_meta")
                    .and_then(|meta| meta.get("reasoningEfforts"))
                    .and_then(Value::as_array)
                    .map(|levels| levels.iter().filter_map(|l| text(l, "value")).collect())
                    .unwrap_or_default(),
                id,
            })
        })
        .collect()
}

/// Reads a JSON file; `None` when it is missing or not JSON.
fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_str(&std::fs::read_to_string(path).ok()?).ok()
}

/// The models from Grok's cache files under `home`. `None` when the cache is missing, broken, or lists no
/// visible model (an empty `models` map too); then the list is asked over ACP.
fn grok_from_cache_files(home: &Path) -> Option<Vec<RuntimeModel>> {
    let cache = read_json(&home.join(".grok/models_cache.json"))?;
    let default_id =
        read_json(&home.join(".grok/settings_cache.json")).and_then(|settings| text(&settings, "default_model"));
    let listed = parse_grok_cache(&cache, default_id.as_deref());
    (!listed.is_empty()).then_some(listed)
}

/// Reply to one message from a CLI's stdout. `Some` when the exchange is over: the models, or why there are none.
type Step = Box<dyn FnMut(&Value, &LineSink) -> Option<Result<Vec<RuntimeModel>, ListError>> + Send>;

/// The program called `name` in `path` (the daemon's `PATH`), found the way `runtimes.status` finds it.
/// The folders are read on a blocking thread.
async fn find_program(name: &str, path: &OsStr) -> Result<PathBuf, ListError> {
    let (name, path) = (name.to_string(), path.to_os_string());
    tokio::task::spawn_blocking(move || crate::setup::which(&name, &path).ok_or(ListError::NotInstalled))
        .await
        .unwrap_or_else(|e| Err(ListError::Failed(format!("the program search failed: {e}"))))
}

/// Starts `program args` in `cwd`, sends `first`, and returns what `step` answers within `limit`.
///
/// The process is dropped at the end in every case, which closes its stdin and kills its process group.
/// Lines that are not JSON are skipped by the reader.
async fn exchange(
    program: &Path,
    label: &'static str,
    args: &[&str],
    cwd: &Path,
    first: Vec<Value>,
    limit: Duration,
    step: Step,
) -> Result<Vec<RuntimeModel>, ListError> {
    let mut cmd = Command::new(program);
    cmd.args(args).current_dir(cwd);
    let (answer_tx, answer_rx) = oneshot::channel();
    let mut answer_tx = Some(answer_tx);
    let mut step = step;
    let router: Router = Box::new(move |msg: &Value, sink: &LineSink| {
        if let Some(answer) = step(msg, sink)
            && let Some(tx) = answer_tx.take()
        {
            // The caller may have given up already; then nobody needs the answer.
            let _ = tx.send(answer);
        }
        Vec::new()
    });
    let (proc, _output) = JsonProcess::spawn(cmd, label, router).map_err(|e| ListError::Failed(format!("{e:#}")))?;
    for message in &first {
        proc.send(message).map_err(|e| ListError::Failed(format!("{e:#}")))?;
    }
    let outcome = timeout(limit, answer_rx).await;
    drop(proc);
    match outcome {
        Err(_) => Err(ListError::Failed(format!("{label} gave no answer in time"))),
        Ok(Err(_)) => Err(ListError::Failed(format!("{label} exited before answering"))),
        Ok(Ok(answer)) => answer,
    }
}

/// Writes frames to a CLI's stdin, in order.
fn send_all(sink: &LineSink, label: &'static str, frames: &[Value]) -> Result<(), ListError> {
    frames
        .iter()
        .try_for_each(|frame| process::push_line(sink, label, frame).map_err(|e| ListError::Failed(format!("{e:#}"))))
}

/// The text of an error value: its `message`, or the value itself when it is a string. `fallback` otherwise.
fn error_text(error: Option<&Value>, fallback: &str) -> String {
    error
        .and_then(|e| e.get("message").and_then(Value::as_str).or_else(|| e.as_str()))
        .filter(|s| !s.is_empty())
        .unwrap_or(fallback)
        .to_string()
}

const CLAUDE_LABEL: &str = "claude";
const CODEX_LABEL: &str = "codex";
const GROK_LABEL: &str = "grok";

fn claude_args() -> [&'static str; 9] {
    // The hooks of the user are not run: `--setting-sources ""` loads no settings file. No session is saved
    // in the user's Claude history for the probe.
    [
        "-p",
        "--setting-sources",
        "",
        "--no-session-persistence",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
    ]
}

fn claude_first() -> Value {
    json!({"type": "control_request", "request_id": CLAUDE_INIT_ID, "request": {"subtype": "initialize"}})
}

/// Claude's answer: a `control_response` with our request id, whose inner `response` holds `models`.
fn claude_step() -> Step {
    Box::new(|msg: &Value, _sink: &LineSink| {
        if msg.get("type").and_then(Value::as_str) != Some("control_response") {
            return None;
        }
        let response = msg.get("response")?;
        if response.get("request_id").and_then(Value::as_str) != Some(CLAUDE_INIT_ID) {
            return None;
        }
        if response.get("subtype").and_then(Value::as_str) == Some("error") {
            return Some(Err(ListError::Failed(error_text(
                response.get("error"),
                "initialize failed",
            ))));
        }
        let inner = response
            .get("response")
            .filter(|inner| inner.get("models").is_some_and(Value::is_array));
        Some(match inner {
            Some(inner) => Ok(parse_claude_models(inner)),
            None => Err(ListError::Failed("the answer has no model list".into())),
        })
    })
}

/// Codex: `initialize`, then `initialized`, then `model/list` page by page (at most [`CODEX_MAX_PAGES`]).
fn codex_step() -> Step {
    let mut models: Vec<RuntimeModel> = Vec::new();
    let mut pages = 0usize;
    Box::new(move |msg: &Value, sink: &LineSink| {
        if msg.get("method").is_some() {
            return None;
        }
        let id = msg.get("id").and_then(Value::as_i64)?;
        if msg.get("error").is_some() {
            return Some(Err(ListError::Failed(format!(
                "codex: {}",
                error_text(msg.get("error"), "request failed")
            ))));
        }
        if id == CODEX_INIT_ID {
            let initialized = json!({"jsonrpc": "2.0", "method": "initialized"});
            let first_page = codex_page(CODEX_FIRST_PAGE_ID, None);
            return send_all(sink, CODEX_LABEL, &[initialized, first_page]).err().map(Err);
        }
        if id < CODEX_FIRST_PAGE_ID {
            return None;
        }
        let result = msg.get("result")?;
        models.extend(parse_codex_models(result));
        pages += 1;
        let next = result
            .get("nextCursor")
            .and_then(Value::as_str)
            .filter(|cursor| !cursor.is_empty());
        if let Some(cursor) = next
            && pages < CODEX_MAX_PAGES
        {
            return send_all(sink, CODEX_LABEL, &[codex_page(id + 1, Some(cursor))])
                .err()
                .map(Err);
        }
        Some(Ok(settle_models(std::mem::take(&mut models))))
    })
}

fn codex_page(id: i64, cursor: Option<&str>) -> Value {
    let params = match cursor {
        Some(cursor) => json!({"cursor": cursor}),
        None => json!({}),
    };
    json!({"jsonrpc": "2.0", "id": id, "method": "model/list", "params": params})
}

/// Grok over ACP: `initialize`, then `session/new`, whose `models` lists the models.
fn grok_acp_step(cwd: String) -> Step {
    Box::new(move |msg: &Value, sink: &LineSink| {
        if msg.get("method").is_some() {
            return None;
        }
        let id = msg.get("id").and_then(Value::as_i64)?;
        if msg.get("error").is_some() {
            return Some(Err(ListError::Failed(format!(
                "grok: {}",
                error_text(msg.get("error"), "request failed")
            ))));
        }
        match id {
            ACP_INIT_ID => {
                let session = json!({
                    "jsonrpc": "2.0",
                    "id": ACP_SESSION_ID,
                    "method": "session/new",
                    "params": {"cwd": cwd, "mcpServers": []},
                });
                send_all(sink, GROK_LABEL, &[session]).err().map(Err)
            }
            ACP_SESSION_ID => Some(match msg.pointer("/result/models") {
                Some(models) if models.get("availableModels").is_some_and(Value::is_array) => {
                    Ok(parse_grok_acp(models))
                }
                _ => Err(ListError::Failed("the answer has no model list".into())),
            }),
            _ => None,
        }
    })
}

/// Lists Claude's models. `cwd` is an empty folder for the CLI to start in.
pub async fn list_claude(cwd: &Path, path: &OsStr, limit: Duration) -> Result<Vec<RuntimeModel>, ListError> {
    let program = find_program(RuntimeKind::Claude.as_str(), path).await?;
    exchange(
        &program,
        CLAUDE_LABEL,
        &claude_args(),
        cwd,
        vec![claude_first()],
        limit,
        claude_step(),
    )
    .await
}

/// Lists Codex's models with `codex app-server`.
pub async fn list_codex(cwd: &Path, path: &OsStr, limit: Duration) -> Result<Vec<RuntimeModel>, ListError> {
    let program = find_program(RuntimeKind::Codex.as_str(), path).await?;
    let first =
        json!({"jsonrpc": "2.0", "id": CODEX_INIT_ID, "method": "initialize", "params": super::codex::client_info()});
    exchange(
        &program,
        CODEX_LABEL,
        &["app-server", "--stdio"],
        cwd,
        vec![first],
        limit,
        codex_step(),
    )
    .await
}

/// Lists Grok's models: from its cache files under the home folder, else over ACP.
pub async fn list_grok(cwd: &Path, path: &OsStr, limit: Duration) -> Result<Vec<RuntimeModel>, ListError> {
    let program = find_program(RuntimeKind::Grok.as_str(), path).await?;
    if let Some(home) = dirs::home_dir() {
        let cached = tokio::task::spawn_blocking(move || grok_from_cache_files(&home))
            .await
            .ok()
            .flatten();
        if let Some(models) = cached {
            return Ok(models);
        }
    }
    let first = json!({
        "jsonrpc": "2.0",
        "id": ACP_INIT_ID,
        "method": "initialize",
        "params": {"protocolVersion": 1, "clientCapabilities": {}},
    });
    exchange(
        &program,
        GROK_LABEL,
        &["agent", "--no-leader", "stdio"],
        cwd,
        vec![first],
        limit,
        grok_acp_step(cwd.display().to_string()),
    )
    .await
}

/// The stored answer of one runtime and when it was read.
#[derive(Clone)]
struct Entry {
    /// When it was stored (monotonic, for the TTL).
    at: Instant,
    /// Unix milliseconds of the same moment.
    fetched_at: i64,
    answer: Result<Vec<RuntimeModel>, ListError>,
}

/// The stored answer for each runtime, with [`TTL`]. Concurrent askers share one listing.
#[derive(Default)]
pub struct ModelCache {
    claude: Mutex<Option<Entry>>,
    codex: Mutex<Option<Entry>>,
    grok: Mutex<Option<Entry>>,
}

impl ModelCache {
    fn slot(&self, kind: RuntimeKind) -> Option<&Mutex<Option<Entry>>> {
        match kind {
            RuntimeKind::Claude => Some(&self.claude),
            RuntimeKind::Codex => Some(&self.codex),
            RuntimeKind::Grok => Some(&self.grok),
            RuntimeKind::Api => None,
        }
    }

    /// The models of `kind`. `cwd` is the folder the CLI starts in; `path` is where it is looked for.
    /// A missing CLI is answered at once and not stored.
    pub async fn answer(&self, kind: RuntimeKind, cwd: &Path, path: &OsStr, refresh: bool) -> ModelsAnswer {
        let Some(slot) = self.slot(kind) else {
            return ModelsAnswer {
                runtime: kind,
                models: Vec::new(),
                error: Some("this runtime has no model list".into()),
                fetched_at: crate::store::now_ms(),
            };
        };
        if let Err(e) = find_program(kind.as_str(), path).await {
            return ModelsAnswer {
                runtime: kind,
                models: Vec::new(),
                error: Some(e.message()),
                fetched_at: crate::store::now_ms(),
            };
        }
        let entry = fetch_slot(slot, refresh, TTL, || list(kind, cwd, path)).await;
        let (models, error) = match entry.answer {
            Ok(models) => (models, None),
            Err(e) => (Vec::new(), Some(e.message())),
        };
        ModelsAnswer {
            runtime: kind,
            models,
            error,
            fetched_at: entry.fetched_at,
        }
    }
}

async fn list(kind: RuntimeKind, cwd: &Path, path: &OsStr) -> Result<Vec<RuntimeModel>, ListError> {
    match kind {
        RuntimeKind::Claude => list_claude(cwd, path, LIST_TIMEOUT).await,
        RuntimeKind::Codex => list_codex(cwd, path, LIST_TIMEOUT).await,
        RuntimeKind::Grok => list_grok(cwd, path, LIST_TIMEOUT).await,
        RuntimeKind::Api => Err(ListError::Failed("this runtime has no model list".into())),
    }
}

/// The stored entry when it is fresh and nobody asked for a refresh, else a new one from `fetch`.
///
/// The lock is held while `fetch` runs, so a caller that comes meanwhile waits and gets the same entry. A caller
/// that asks for a refresh reuses an entry that was stored after its own call began, too.
async fn fetch_slot<F, Fut>(slot: &Mutex<Option<Entry>>, refresh: bool, ttl: Ttl, fetch: F) -> Entry
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<Vec<RuntimeModel>, ListError>>,
{
    let asked = Instant::now();
    let mut stored = slot.lock().await;
    if let Some(entry) = stored.as_ref() {
        let lifetime = if entry.answer.is_ok() { ttl.answer } else { ttl.error };
        let fresh = entry.at.elapsed() < lifetime;
        if entry.at >= asked || (fresh && !refresh) {
            return entry.clone();
        }
    }
    // Stamped after the listing ends: a caller that waited for it then sees an entry newer than its own call.
    let answer = fetch().await;
    let entry = Entry {
        at: Instant::now(),
        fetched_at: crate::store::now_ms(),
        answer,
    };
    *stored = Some(entry.clone());
    entry
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::Mutex as StdMutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn ids(models: &[RuntimeModel]) -> Vec<&str> {
        models.iter().map(|m| m.id.as_str()).collect()
    }

    const CLAUDE_INIT: &str = r#"{"type":"control_response","response":{"request_id":"bandito-models","subtype":"success","response":{"commands":[],"models":[
        {"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
        {"value":"opus","resolvedModel":"claude-opus-5-5","displayName":"Opus 5.5","description":"For complex work and everyday tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},
        {"value":"claude-haiku-4-5-20251001","resolvedModel":"claude-haiku-4-5-20251001","displayName":"Haiku 4.5","description":"Fastest for quick answers"}
    ]}}}"#;

    #[test]
    fn claude_default_entry_is_not_listed_and_its_model_is_marked_once() {
        let answer: Value = serde_json::from_str(CLAUDE_INIT).unwrap();
        let models = parse_claude_models(&answer["response"]["response"]);
        assert_eq!(ids(&models), vec!["opus", "claude-haiku-4-5-20251001"]);
        assert!(models[0].is_default);
        assert!(!models[1].is_default);
        assert_eq!(models[0].name, "Opus 5.5");
        assert_eq!(models[0].efforts, vec!["low", "medium", "high", "xhigh", "max"]);
        assert_eq!(models[1].name, "Haiku 4.5");
        assert!(models[1].efforts.is_empty(), "no effort levels reported");
    }

    #[test]
    fn claude_without_a_default_entry_marks_nobody_and_empty_name_falls_back_to_value() {
        let answer = json!({"models": [
            {"value": "opus", "resolvedModel": "m1", "displayName": "  "},
            {"value": "haiku", "resolvedModel": "m2", "displayName": "Haiku"},
        ]});
        let models = parse_claude_models(&answer);
        assert_eq!(ids(&models), vec!["opus", "haiku"]);
        assert!(models.iter().all(|m| !m.is_default));
        assert_eq!(models[0].name, "opus");
    }

    #[test]
    fn claude_answer_without_models_is_empty() {
        assert!(parse_claude_models(&json!({"commands": []})).is_empty());
    }

    #[test]
    fn codex_hidden_models_are_skipped_and_the_default_is_marked() {
        let result = json!({
            "data": [
                {"id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol", "description": "Best",
                 "hidden": false, "isDefault": true,
                 "supportedReasoningEfforts": [{"reasoningEffort": "low", "description": "fast"}, {"reasoningEffort": "high", "description": "deep"}],
                 "defaultReasoningEffort": "low"},
                {"id": "old", "model": "old-1", "displayName": "Old", "hidden": true, "isDefault": false},
                {"id": "mini", "model": "mini-2", "hidden": false, "isDefault": false},
            ],
            "nextCursor": "page-2"
        });
        let models = parse_codex_models(&result);
        assert_eq!(ids(&models), vec!["gpt-6.1-sol", "mini-2"]);
        assert!(models[0].is_default);
        assert_eq!(models[0].name, "GPT-6.1-Sol");
        assert_eq!(models[0].description.as_deref(), Some("Best"));
        assert_eq!(models[0].efforts, vec!["low", "high"]);
        assert_eq!(models[1].name, "mini-2", "no displayName: the id is the name");
        assert!(!models[1].is_default);
    }

    #[test]
    fn codex_lists_each_id_once_and_marks_one_default() {
        let result = json!({"data": [
            {"model": "a", "isDefault": true},
            {"model": "b", "isDefault": true},
            {"model": "a", "displayName": "again", "isDefault": false},
            {"model": "c"},
        ]});
        let models = parse_codex_models(&result);
        assert_eq!(ids(&models), vec!["a", "b", "c"]);
        let defaults: Vec<&str> = models.iter().filter(|m| m.is_default).map(|m| m.id.as_str()).collect();
        assert_eq!(defaults, vec!["a"]);
        assert_eq!(models[0].name, "a", "the first entry of an id is kept");
    }

    #[test]
    fn codex_pages_are_settled_together() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let sink: LineSink = Arc::new(StdMutex::new(Some(tx)));
        let mut step = codex_step();
        step(&json!({"jsonrpc": "2.0", "id": 1, "result": {}}), &sink);
        let page1 = json!({"jsonrpc": "2.0", "id": 2, "result": {"data": [{"model": "a", "isDefault": true}], "nextCursor": "c2"}});
        assert_eq!(step(&page1, &sink), None);
        let page2 =
            json!({"jsonrpc": "2.0", "id": 3, "result": {"data": [{"model": "a"}, {"model": "b", "isDefault": true}]}});
        let models = step(&page2, &sink).unwrap().unwrap();
        assert_eq!(ids(&models), vec!["a", "b"]);
        assert_eq!(models.iter().filter(|m| m.is_default).count(), 1);
        assert!(models[0].is_default, "the first default stays");
    }

    #[test]
    fn codex_model_falls_back_to_id_and_missing_data_is_empty() {
        let models = parse_codex_models(&json!({"data": [{"id": "only-id"}, {"displayName": "no id"}]}));
        assert_eq!(ids(&models), vec!["only-id"]);
        assert!(parse_codex_models(&json!({})).is_empty());
    }

    const GROK_CACHE: &str = r#"{"models": {
        "grok-4.7": {"info": {"id": "grok-4.7", "name": "Grok 4.7", "description": "Newest", "hidden": false,
            "reasoning_efforts": [{"value": "xhigh", "default": false}, {"value": "high", "default": true}]}},
        "grok-old": {"info": {"id": "grok-old", "name": "Old", "hidden": true, "reasoning_efforts": []}},
        "grok-4.6": {"info": {"id": "grok-4.6", "name": "Grok 4.6", "hidden": false, "reasoning_efforts": []}}
    }}"#;

    #[test]
    fn grok_cache_marks_the_settings_default_and_skips_hidden() {
        let cache: Value = serde_json::from_str(GROK_CACHE).unwrap();
        let models = parse_grok_cache(&cache, Some("grok-4.6"));
        assert_eq!(ids(&models), vec!["grok-4.6", "grok-4.7"]);
        let default: Vec<&str> = models.iter().filter(|m| m.is_default).map(|m| m.id.as_str()).collect();
        assert_eq!(default, vec!["grok-4.6"]);
        let newest = models.iter().find(|m| m.id == "grok-4.7").unwrap();
        assert_eq!(newest.efforts, vec!["xhigh", "high"]);
        assert_eq!(newest.description.as_deref(), Some("Newest"));
    }

    #[test]
    fn grok_cache_without_a_matching_default_marks_the_newest_visible() {
        let cache: Value = serde_json::from_str(GROK_CACHE).unwrap();
        for default in [Some("not-here"), None] {
            let models = parse_grok_cache(&cache, default);
            let marked: Vec<&str> = models.iter().filter(|m| m.is_default).map(|m| m.id.as_str()).collect();
            assert_eq!(marked, vec!["grok-4.7"], "default {default:?}");
        }
        let unknown = parse_grok_cache(&json!({"models": {}}), None);
        assert!(unknown.is_empty());
        assert!(parse_grok_cache(&json!({"other": 1}), None).is_empty());
    }

    #[test]
    fn grok_versions_compare_part_by_part() {
        let cache = json!({"models": {
            "grok-4.9": {"info": {"id": "grok-4.9"}},
            "grok-4.10": {"info": {"id": "grok-4.10"}},
            "grok-3": {"info": {"id": "grok-3"}},
        }});
        let models = parse_grok_cache(&cache, None);
        let marked: Vec<&str> = models.iter().filter(|m| m.is_default).map(|m| m.id.as_str()).collect();
        assert_eq!(marked, vec!["grok-4.10"]);
        // Ties keep the first one.
        let tie = json!({"models": {"b-1": {"info": {"id": "b-1"}}, "a-1": {"info": {"id": "a-1"}}}});
        let models = parse_grok_cache(&tie, None);
        assert_eq!(
            models
                .iter()
                .filter(|m| m.is_default)
                .map(|m| m.id.as_str())
                .collect::<Vec<_>>(),
            vec!["a-1"]
        );
    }

    #[test]
    fn grok_cache_marks_nothing_without_a_visible_model() {
        let cache = json!({"models": {"x-1": {"info": {"id": "x-1", "hidden": true}}}});
        assert!(parse_grok_cache(&cache, None).is_empty());
    }

    #[test]
    fn grok_cache_without_models_marks_nothing() {
        assert!(parse_grok_cache(&json!({"models": {}}), None).is_empty());
        assert!(parse_grok_cache(&json!({"other": 1}), None).is_empty());
    }

    #[test]
    fn grok_acp_marks_the_current_model() {
        let models = json!({
            "currentModelId": "grok-4.7",
            "availableModels": [
                {"modelId": "grok-4.7", "name": "Grok 4.7", "description": "Newest",
                 "_meta": {"reasoningEfforts": [{"value": "high"}]}},
                {"modelId": "grok-4.6", "name": "Grok 4.6"},
                {"name": "no id"},
            ]
        });
        let parsed = parse_grok_acp(&models);
        assert_eq!(ids(&parsed), vec!["grok-4.7", "grok-4.6"]);
        assert!(parsed[0].is_default);
        assert!(!parsed[1].is_default);
        assert_eq!(parsed[0].efforts, vec!["high"]);
    }

    #[test]
    fn grok_cache_files_are_read_from_home_with_the_settings_default() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join(".grok")).unwrap();
        assert!(grok_from_cache_files(home.path()).is_none(), "no cache file");
        std::fs::write(home.path().join(".grok/models_cache.json"), "not json").unwrap();
        assert!(grok_from_cache_files(home.path()).is_none(), "broken cache file");
        std::fs::write(home.path().join(".grok/models_cache.json"), r#"{"models": {}}"#).unwrap();
        assert!(
            grok_from_cache_files(home.path()).is_none(),
            "an empty cache goes to ACP"
        );
        std::fs::write(
            home.path().join(".grok/models_cache.json"),
            r#"{"models": {"x-1": {"info": {"id": "x-1", "hidden": true}}}}"#,
        )
        .unwrap();
        assert!(
            grok_from_cache_files(home.path()).is_none(),
            "a cache with only hidden models goes to ACP"
        );
        std::fs::write(home.path().join(".grok/models_cache.json"), GROK_CACHE).unwrap();
        std::fs::write(
            home.path().join(".grok/settings_cache.json"),
            r#"{"default_model": "grok-4.6"}"#,
        )
        .unwrap();
        let models = grok_from_cache_files(home.path()).expect("cache read");
        assert!(models.iter().any(|m| m.id == "grok-4.6" && m.is_default));
    }

    #[test]
    fn list_error_reports_not_installed_as_its_wire_text() {
        assert_eq!(ListError::NotInstalled.message(), "not_installed");
        assert_eq!(ListError::Failed("boom".into()).message(), "boom");
    }

    #[tokio::test]
    async fn a_cli_is_not_installed_when_the_given_path_has_no_such_program() {
        let empty = tempfile::tempdir().unwrap();
        let path = std::env::join_paths([empty.path()]).unwrap();
        assert_eq!(find_program("claude", &path).await, Err(ListError::NotInstalled));
        assert_eq!(
            find_program("claude", OsStr::new("")).await,
            Err(ListError::NotInstalled)
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_cli_is_found_in_the_given_path_only() {
        let bin = tempfile::tempdir().unwrap();
        let program = fake_cli(bin.path(), "exit 0");
        let path = std::env::join_paths([bin.path()]).unwrap();
        assert_eq!(find_program("fake-cli", &path).await, Ok(program));
        assert_eq!(
            find_program("fake-cli", OsStr::new("")).await,
            Err(ListError::NotInstalled)
        );
    }

    /// A fake CLI: a shell script in its own folder.
    #[cfg(unix)]
    fn fake_cli(dir: &Path, body: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join("fake-cli");
        std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn claude_answer_is_read_past_noise_and_the_process_is_not_waited_for() {
        let dir = tempfile::tempdir().unwrap();
        let program = fake_cli(
            dir.path(),
            &format!(
                "echo 'a line that is not json'\nread line\necho '{CLAUDE_INIT}' | tr -d '\\n'\necho\nexec sleep 30"
            ),
        );
        let started = Instant::now();
        let models = exchange(
            &program,
            CLAUDE_LABEL,
            &claude_args(),
            dir.path(),
            vec![claude_first()],
            Duration::from_secs(10),
            claude_step(),
        )
        .await
        .unwrap();
        assert_eq!(ids(&models), vec!["opus", "claude-haiku-4-5-20251001"]);
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the process was waited for"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_silent_cli_is_stopped_at_the_limit() {
        let dir = tempfile::tempdir().unwrap();
        let program = fake_cli(dir.path(), "exec sleep 30");
        let started = Instant::now();
        let err = exchange(
            &program,
            CLAUDE_LABEL,
            &[],
            dir.path(),
            vec![claude_first()],
            Duration::from_millis(200),
            claude_step(),
        )
        .await
        .unwrap_err();
        assert_eq!(err, ListError::Failed("claude gave no answer in time".into()));
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    /// Whether a process with this pid exists (`kill -0` succeeds).
    #[cfg(unix)]
    fn process_alive(pid: i32) -> bool {
        std::process::Command::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .stderr(std::process::Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_cli_that_gives_no_answer_is_killed_at_the_limit() {
        let dir = tempfile::tempdir().unwrap();
        let pidfile = dir.path().join("pid");
        // `exec` keeps the shell's pid, so the pid written is the pid of the process that must die.
        let program = fake_cli(dir.path(), &format!("echo $$ > '{}'\nexec sleep 30", pidfile.display()));
        let err = exchange(
            &program,
            CLAUDE_LABEL,
            &[],
            dir.path(),
            vec![claude_first()],
            // Generous: a freshly written script can take a moment to start on macOS.
            Duration::from_secs(2),
            claude_step(),
        )
        .await
        .unwrap_err();
        assert_eq!(err, ListError::Failed("claude gave no answer in time".into()));

        let mut pid = None;
        for _ in 0..250 {
            if let Ok(text) = std::fs::read_to_string(&pidfile)
                && let Ok(value) = text.trim().parse::<i32>()
            {
                pid = Some(value);
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        let pid = pid.expect("the fake CLI wrote its pid");
        // The kill is sent when the process is dropped; its reader then reaps it. Give that a few seconds.
        let mut alive = true;
        for _ in 0..150 {
            if !process_alive(pid) {
                alive = false;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(!alive, "the CLI (pid {pid}) is still running after its limit");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_cli_that_exits_without_answer_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let program = fake_cli(dir.path(), "echo 'junk'\nexit 3");
        let err = exchange(
            &program,
            CODEX_LABEL,
            &[],
            dir.path(),
            vec![claude_first()],
            Duration::from_secs(5),
            claude_step(),
        )
        .await
        .unwrap_err();
        assert_eq!(err, ListError::Failed("codex exited before answering".into()));
    }

    #[test]
    fn claude_error_answer_is_reported_with_its_text() {
        let mut step = claude_step();
        let sink: LineSink = Arc::new(StdMutex::new(None));
        let msg = json!({"type": "control_response", "response": {"request_id": CLAUDE_INIT_ID, "subtype": "error", "error": "not logged in"}});
        assert_eq!(step(&msg, &sink), Some(Err(ListError::Failed("not logged in".into()))));
        let other =
            json!({"type": "control_response", "response": {"request_id": "someone-else", "subtype": "success"}});
        assert_eq!(step(&other, &sink), None);
    }

    #[test]
    fn codex_pages_are_requested_with_the_cursor_and_joined() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let sink: LineSink = Arc::new(StdMutex::new(Some(tx)));
        let mut step = codex_step();
        let frame = |rx: &mut tokio::sync::mpsc::UnboundedReceiver<String>| -> Value {
            serde_json::from_str(&rx.try_recv().expect("a frame")).unwrap()
        };

        assert_eq!(step(&json!({"jsonrpc": "2.0", "id": 1, "result": {}}), &sink), None);
        assert_eq!(frame(&mut rx), json!({"jsonrpc": "2.0", "method": "initialized"}));
        assert_eq!(
            frame(&mut rx),
            json!({"jsonrpc": "2.0", "id": 2, "method": "model/list", "params": {}})
        );

        let page1 = json!({"jsonrpc": "2.0", "id": 2, "result": {"data": [{"model": "a", "isDefault": true}], "nextCursor": "c2"}});
        assert_eq!(step(&page1, &sink), None);
        assert_eq!(
            frame(&mut rx),
            json!({"jsonrpc": "2.0", "id": 3, "method": "model/list", "params": {"cursor": "c2"}})
        );

        let page2 = json!({"jsonrpc": "2.0", "id": 3, "result": {"data": [{"model": "b"}], "nextCursor": ""}});
        let models = step(&page2, &sink).unwrap().unwrap();
        assert_eq!(ids(&models), vec!["a", "b"]);
        assert!(models[0].is_default);
    }

    #[test]
    fn codex_stops_after_the_page_limit() {
        let (tx, _rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let sink: LineSink = Arc::new(StdMutex::new(Some(tx)));
        let mut step = codex_step();
        let mut answer = None;
        for id in 2..(2 + CODEX_MAX_PAGES as i64) {
            let page = json!({"jsonrpc": "2.0", "id": id, "result": {"data": [{"model": format!("m{id}")}], "nextCursor": "more"}});
            answer = step(&page, &sink);
        }
        let models = answer.expect("finished").expect("ok");
        assert_eq!(models.len(), CODEX_MAX_PAGES);
    }

    #[test]
    fn grok_acp_asks_for_a_session_and_reads_its_models() {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        let sink: LineSink = Arc::new(StdMutex::new(Some(tx)));
        let mut step = grok_acp_step("/data/models-probe".into());
        assert_eq!(step(&json!({"jsonrpc": "2.0", "id": 1, "result": {}}), &sink), None);
        let sent: Value = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
        assert_eq!(sent["method"], "session/new");
        assert_eq!(sent["params"]["cwd"], "/data/models-probe");
        let answer = json!({"jsonrpc": "2.0", "id": 2, "result": {"models": {
            "currentModelId": "grok-4.7", "availableModels": [{"modelId": "grok-4.7", "name": "Grok 4.7"}]}}});
        let models = step(&answer, &sink).unwrap().unwrap();
        assert_eq!(ids(&models), vec!["grok-4.7"]);
        assert!(models[0].is_default);
    }

    #[tokio::test]
    async fn one_listing_serves_concurrent_askers_and_refresh_asks_again() {
        let slot = Mutex::new(None);
        let calls = AtomicUsize::new(0);
        let fetch = || async {
            calls.fetch_add(1, Ordering::SeqCst);
            tokio::time::sleep(Duration::from_millis(50)).await;
            Ok(vec![RuntimeModel {
                id: "m".into(),
                name: "M".into(),
                description: None,
                is_default: true,
                efforts: vec![],
            }])
        };
        let (a, b) = tokio::join!(
            fetch_slot(&slot, false, TTL, fetch),
            fetch_slot(&slot, false, TTL, fetch),
        );
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "the second caller waited for the first listing"
        );
        assert_eq!(a.answer, b.answer);

        let c = fetch_slot(&slot, false, TTL, fetch).await;
        assert_eq!(calls.load(Ordering::SeqCst), 1, "fresh answer reused");
        assert_eq!(c.fetched_at, a.fetched_at);

        fetch_slot(&slot, true, TTL, fetch).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2, "refresh asks the CLI again");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn two_refreshes_at_once_start_the_cli_once() {
        let dir = tempfile::tempdir().unwrap();
        let starts = dir.path().join("starts.txt");
        let body = format!(
            "echo start >> '{}'\nread line\necho '{CLAUDE_INIT}' | tr -d '\\n'\necho\nexec sleep 30",
            starts.display()
        );
        let program = fake_cli(dir.path(), &body);
        let slot = Mutex::new(None);
        let args = claude_args();
        let run = || {
            exchange(
                &program,
                CLAUDE_LABEL,
                &args,
                dir.path(),
                vec![claude_first()],
                Duration::from_secs(10),
                claude_step(),
            )
        };
        let (a, b) = tokio::join!(fetch_slot(&slot, true, TTL, run), fetch_slot(&slot, true, TTL, run),);
        assert!(a.answer.is_ok(), "{:?}", a.answer);
        assert_eq!(a.answer, b.answer);
        let launches = std::fs::read_to_string(&starts).unwrap();
        assert_eq!(
            launches.lines().count(),
            1,
            "the CLI was started {} times",
            launches.lines().count()
        );
    }

    #[tokio::test]
    async fn a_failed_listing_is_asked_again_sooner_than_a_good_one() {
        let slot = Mutex::new(None);
        let ttl = Ttl {
            answer: Duration::from_secs(3600),
            error: Duration::ZERO,
        };
        let calls = AtomicUsize::new(0);
        let failing = || async {
            calls.fetch_add(1, Ordering::SeqCst);
            Err(ListError::Failed("not ready".into()))
        };
        fetch_slot(&slot, false, ttl, failing).await;
        tokio::time::sleep(Duration::from_millis(2)).await;
        fetch_slot(&slot, false, ttl, failing).await;
        assert_eq!(
            calls.load(Ordering::SeqCst),
            2,
            "a failed listing is not reused past its TTL"
        );

        let good = || async {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(Vec::new())
        };
        fetch_slot(&slot, false, ttl, good).await;
        fetch_slot(&slot, false, ttl, good).await;
        assert_eq!(
            calls.load(Ordering::SeqCst),
            3,
            "a good listing is reused within its TTL"
        );
    }

    #[tokio::test]
    async fn an_expired_answer_is_listed_again() {
        let slot = Mutex::new(None);
        let calls = AtomicUsize::new(0);
        let fetch = || async {
            calls.fetch_add(1, Ordering::SeqCst);
            Err(ListError::Failed("gone".into()))
        };
        let zero = Ttl {
            answer: Duration::ZERO,
            error: Duration::ZERO,
        };
        fetch_slot(&slot, false, zero, fetch).await;
        tokio::time::sleep(Duration::from_millis(2)).await;
        let again = fetch_slot(&slot, false, zero, fetch).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert_eq!(again.answer, Err(ListError::Failed("gone".into())));
    }

    #[tokio::test]
    async fn a_missing_cli_is_answered_without_a_listing_and_not_stored() {
        let cache = ModelCache::default();
        let dir = tempfile::tempdir().unwrap();
        let answer = cache
            .answer(RuntimeKind::Claude, dir.path(), OsStr::new(""), false)
            .await;
        assert_eq!(answer.error.as_deref(), Some(NOT_INSTALLED));
        assert!(answer.models.is_empty());
        assert!(cache.claude.lock().await.is_none(), "a missing CLI is not stored");
        let api = cache.answer(RuntimeKind::Api, dir.path(), OsStr::new(""), false).await;
        assert!(api.error.is_some());
        assert!(api.models.is_empty());
    }
}
