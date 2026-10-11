//! `team.create`: the main agent creates another agent (the crew tool `crew_create_agent`).
//! See docs/ARCHITECTURE.md#agents-creating-agents.
//!
//! The rules, in the order they are applied:
//! - only the main agent of the crew may call it;
//! - the new agent never has more than its creator: capabilities and services are subsets of the creator's, its
//!   approval mode is not softer than the creator's (a creator in `never` makes agents that follow the server's default
//!   mode), and it lives in the creator's workspace;
//! - the runtime must be installed on the server and the model one the runtime offers;
//! - everything is checked before anyone is asked, and again after the answer, because the crew may have changed;
//! - the person sees a card in the creator's chat with a summary and decides (modes `always` and `risky`); a creator in
//!   `never` creates without being asked, and the chat shows a card all the same.

use super::schedules::{self, AgentCreate};
use super::{App, INVALID_PARAMS, RpcError, RpcResult, SERVER_ERROR, UNAUTHORIZED, ok, params};
use crate::event::{DecidedBy, EventBody};
use crate::home;
use crate::integrations;
use crate::runtime::RuntimeKind;
use crate::runtime::models::{ModelsAnswer, RuntimeModel};
use crate::schedule_text;
use crate::store::{
    ALL_CAPABILITIES, Agent, ApprovalMode, Capability, Effort, Integration, NewAgent, NewSchedule, Store,
};
use crate::supervisor::ApprovalSpec;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

/// How long the call waits for the person's answer to the card.
pub const APPROVAL_LIMIT: Duration = Duration::from_secs(10 * 60);

/// The tool name of the approval, which the apps draw a card for.
pub const APPROVAL_TOOL: &str = "agent.create";

/// Refusals by the person within an hour after which a creator's requests are turned away for an hour.
const MAX_REFUSALS: usize = 3;
/// Most agents one agent may create in an hour (counted when they are made).
const MAX_PER_HOUR: usize = 10;
const HOUR_MS: i64 = 60 * 60 * 1000;
/// Most agents the crew may hold for an agent to add one.
const MAX_CREW: usize = 64;
/// Most schedules in one request.
const MAX_SCHEDULES: usize = 20;
/// Longest role, instructions, in characters.
const ROLE_CHARS: usize = 200;
const INSTRUCTIONS_CHARS: usize = 6_000;
/// How many model ids an unknown-model error names.
const MODELS_SHOWN: usize = 12;

/// What the main agent sends.
#[derive(Deserialize)]
struct CreateParams {
    /// The creator: the agent the session's token names.
    agent_id: String,
    name: String,
    #[serde(default)]
    role: Option<String>,
    instructions: String,
    #[serde(default)]
    runtime: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    effort: Option<String>,
    #[serde(default)]
    capabilities: Option<Vec<String>>,
    #[serde(default)]
    integrations: Option<Vec<String>>,
    #[serde(default)]
    schedules: Vec<AgentCreate>,
    #[serde(default)]
    folder: Option<String>,
}

/// An agent creation in progress per creator, and how many each made lately.
#[derive(Default)]
pub struct Creations {
    state: Mutex<CreationState>,
}

#[derive(Default)]
struct CreationState {
    open: HashSet<String>,
    made: HashMap<String, VecDeque<i64>>,
    /// When the person said no, per creator, within the last hour.
    refused: HashMap<String, VecDeque<i64>>,
    /// Until when a creator that was refused too often is not asked about again.
    cooldown: HashMap<String, i64>,
}

/// Holds the creator's one open request; frees it when dropped (answered, refused, or the call went away).
struct OpenSlot<'a> {
    creations: &'a Creations,
    creator: String,
}

impl Drop for OpenSlot<'_> {
    fn drop(&mut self) {
        self.creations.lock().open.remove(&self.creator);
    }
}

impl Creations {
    fn lock(&self) -> std::sync::MutexGuard<'_, CreationState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Takes the creator's slot, or refuses: one request at a time, and a limit per hour.
    fn begin(&self, creator: &str, now: i64) -> Result<OpenSlot<'_>, RpcError> {
        let mut state = self.lock();
        if let Some(until) = state.cooldown.get(creator).copied() {
            if until > now {
                let minutes = ((until - now) + 59_999) / 60_000;
                return Err(RpcError::with_data(
                    INVALID_PARAMS,
                    format!(
                        "declined_too_often: the person said no {MAX_REFUSALS} times in an hour, so new requests are not shown for {minutes} more minutes. Do not ask again; tell the person what you wanted to create and let them ask"
                    ),
                    json!({ "reason": "declined_too_often", "retry_after_minutes": minutes }),
                ));
            }
            state.cooldown.remove(creator);
        }
        if state.open.contains(creator) {
            return Err(RpcError::new(
                INVALID_PARAMS,
                "another agent creation of yours waits for the person's answer: wait for it",
            ));
        }
        let recent = state.made.entry(creator.to_string()).or_default();
        while recent.front().is_some_and(|t| *t < now - HOUR_MS) {
            recent.pop_front();
        }
        if recent.len() >= MAX_PER_HOUR {
            return Err(RpcError::new(
                INVALID_PARAMS,
                format!("rate_limited: at most {MAX_PER_HOUR} agents an hour; tell the person and wait"),
            ));
        }
        state.open.insert(creator.to_string());
        Ok(OpenSlot {
            creations: self,
            creator: creator.to_string(),
        })
    }

    /// The person refused a request of this creator. The third refusal within an hour starts the cooldown.
    fn refused(&self, creator: &str, now: i64) {
        let mut state = self.lock();
        let recent = state.refused.entry(creator.to_string()).or_default();
        while recent.front().is_some_and(|t| *t < now - HOUR_MS) {
            recent.pop_front();
        }
        recent.push_back(now);
        if recent.len() >= MAX_REFUSALS {
            recent.clear();
            state.cooldown.insert(creator.to_string(), now + HOUR_MS);
        }
    }

    fn made(&self, creator: &str, now: i64) {
        self.lock().made.entry(creator.to_string()).or_default().push_back(now);
    }
}

/// `not_allowed: <what> — <why>`: the creator asked for more than it has.
fn not_allowed(what: &str, why: impl std::fmt::Display) -> RpcError {
    RpcError::with_data(
        UNAUTHORIZED,
        format!("not_allowed: {what} — {why}"),
        json!({ "reason": "not_allowed", "what": what }),
    )
}

fn invalid(message: impl Into<String>) -> RpcError {
    RpcError::new(INVALID_PARAMS, message)
}

fn server(e: impl std::fmt::Display) -> RpcError {
    RpcError::new(SERVER_ERROR, format!("{e:#}"))
}

/// How strict a mode is: the higher, the more the person is asked.
fn strictness(mode: ApprovalMode) -> u8 {
    match mode {
        ApprovalMode::Never => 0,
        ApprovalMode::Risky => 1,
        ApprovalMode::Always => 2,
    }
}

/// The mode of an agent made by `creator`: never softer than the creator's, nor than the server's default. A creator
/// in `never` therefore makes agents with the default mode.
pub fn mode_for_new(creator: ApprovalMode, server_default: ApprovalMode) -> ApprovalMode {
    if strictness(creator) >= strictness(server_default) {
        creator
    } else {
        server_default
    }
}

/// The capabilities of the new agent: the request, or the creator's own when it says nothing. `None` is all of them.
pub fn capabilities_for_new(
    creator: Option<&[Capability]>,
    asked: Option<&[String]>,
) -> Result<Option<Vec<Capability>>, RpcError> {
    let Some(asked) = asked else {
        return Ok(creator.map(<[Capability]>::to_vec));
    };
    let mut list: Vec<Capability> = Vec::new();
    for name in asked {
        let cap = Capability::parse(name.trim().to_lowercase().as_str()).ok_or_else(|| {
            let known: Vec<&str> = ALL_CAPABILITIES.iter().map(|c| c.as_str()).collect();
            invalid(format!("unknown capability {name}; use {}", known.join(", ")))
        })?;
        if !list.contains(&cap) {
            list.push(cap);
        }
    }
    let missing: Vec<&str> = list
        .iter()
        .filter(|c| creator.is_some_and(|mine| !mine.contains(c)))
        .map(|c| c.as_str())
        .collect();
    if !missing.is_empty() {
        return Err(not_allowed(
            "capabilities",
            format!("you cannot give what you do not have: {}", missing.join(", ")),
        ));
    }
    Ok(Some(list))
}

/// The integration rows the names or ids in `asked` mean, among those the creator may use. A catalog id (`gmail`), the
/// name of a row, or its id. A row that exists but the creator may not use is `not_allowed`; one that does not exist
/// is `invalid_params`, with the way out.
pub fn integrations_for_new(
    all: &[Integration],
    creator: Option<&[String]>,
    asked: Option<&[String]>,
) -> Result<Option<Vec<String>>, RpcError> {
    let Some(asked) = asked else {
        return Ok(creator.map(<[String]>::to_vec));
    };
    let usable = integrations::for_agent(all, creator);
    let templates = integrations::catalog_templates();
    let matches = |row: &Integration, want: &str| {
        let want = want.to_lowercase();
        row.id.to_lowercase() == want
            || row.name.to_lowercase() == want
            || integrations::template_id_of(row, &templates).is_some_and(|t| t.to_lowercase() == want)
    };
    let mut ids: Vec<String> = Vec::new();
    for want in asked {
        let want = want.trim();
        if want.is_empty() {
            return Err(invalid("an integration in the list is empty"));
        }
        let found: Vec<&&Integration> = usable.iter().filter(|row| matches(row, want)).collect();
        if found.is_empty() {
            let shown: String = want.chars().take(60).collect();
            return Err(if all.iter().any(|row| matches(row, want)) {
                not_allowed(
                    "integrations",
                    format!("{shown} is not available to you (off, or not in your list)"),
                )
            } else {
                invalid(format!(
                    "{shown} is not connected on this server: ask the person with request_connection first"
                ))
            });
        }
        for row in found {
            if !ids.contains(&row.id) {
                ids.push(row.id.clone());
            }
        }
    }
    Ok(Some(ids))
}

/// The model the runtime offers that `asked` names (its id or its name, in any case). Anything else is refused with the
/// models it does offer; a list that could not be read is refused too, since the name cannot be checked.
pub fn model_for_new(answer: &ModelsAnswer, asked: &str) -> Result<String, RpcError> {
    let kind = answer.runtime.as_str();
    if let Some(error) = &answer.error {
        return Err(invalid(format!(
            "cannot check the model: {kind} gave no model list ({error}); leave \"model\" out to use its default"
        )));
    }
    let want = asked.trim().to_lowercase();
    let found = answer
        .models
        .iter()
        .find(|m: &&RuntimeModel| m.id.to_lowercase() == want || m.name.to_lowercase() == want);
    match found {
        Some(m) => Ok(m.id.clone()),
        None => {
            let offered: Vec<&str> = answer.models.iter().take(MODELS_SHOWN).map(|m| m.id.as_str()).collect();
            Err(invalid(format!(
                "{kind} has no model {}; it offers: {}",
                asked.trim().chars().take(60).collect::<String>(),
                offered.join(", ")
            )))
        }
    }
}

/// The folder the new agent works in, checked: `None` for its own new folder, else the real path of an existing
/// folder. Never Bandito's own data folder or anything in it, and only the new folder inside a container workspace.
pub fn folder_for_new(asked: Option<&str>, data_home: &Path, in_container: bool) -> Result<Option<String>, RpcError> {
    let asked = asked.map(str::trim).unwrap_or_default();
    if asked.is_empty() || asked.eq_ignore_ascii_case("new") {
        return Ok(None);
    }
    if in_container {
        return Err(not_allowed(
            "folder",
            "you work in a container workspace: use \"new\" for the folder",
        ));
    }
    let path = Path::new(asked);
    if !path.is_absolute() {
        return Err(invalid(
            "folder must be \"new\" or an absolute path of a folder on the server",
        ));
    }
    if crate::sanitize::has_hidden(asked) {
        return Err(invalid("invalid: folder has invisible or control characters"));
    }
    let real = std::fs::canonicalize(path).map_err(|_| invalid(format!("folder not found on the server: {asked}")))?;
    if !real.is_dir() {
        return Err(invalid(format!("folder not found on the server: {asked}")));
    }
    let shown = real.display().to_string();
    if crate::sanitize::has_hidden(&shown) {
        return Err(invalid("invalid: folder has invisible or control characters"));
    }
    let data = std::fs::canonicalize(data_home).unwrap_or_else(|_| data_home.to_path_buf());
    // Inside Bandito's folder, or a folder that holds it (its parents, the whole home folder, the root): the agent
    // would work in a place where Bandito's files are part of its project.
    if real.starts_with(&data) || data.starts_with(&real) {
        return Err(not_allowed(
            "folder",
            "Bandito's own files are off limits to agents: pick a folder that is neither inside Bandito's data folder nor one that contains it (not / and not the whole home folder)",
        ));
    }
    let home = dirs::home_dir().and_then(|h| std::fs::canonicalize(h).ok());
    if home.as_ref() == Some(&real) {
        return Err(not_allowed(
            "folder",
            "the whole home folder is too much: pick a folder inside it",
        ));
    }
    Ok(Some(shown))
}

/// What the call comes to, checked and ready to run.
struct Plan {
    /// Everything that will be created, as data: compared after the person answers, so what is made is what was shown.
    fingerprint: Value,
    agent: NewAgent,
    workspace_id: String,
    schedules: Vec<NewSchedule>,
    summary: Value,
}

/// The names of the capabilities in the list (`None` is all of them).
fn capability_names(list: Option<&[Capability]>) -> Vec<&'static str> {
    list.unwrap_or(&ALL_CAPABILITIES).iter().map(|c| c.as_str()).collect()
}

/// The runtime asked for, or the creator's own (an API-key creator gets Claude); it must be installed here.
async fn runtime_for_new(app: &App, creator: &Agent, asked: Option<&str>) -> Result<RuntimeKind, RpcError> {
    let kind = match asked.map(str::trim).filter(|r| !r.is_empty()) {
        Some(name) => match RuntimeKind::parse(&name.to_lowercase()) {
            Some(kind @ (RuntimeKind::Claude | RuntimeKind::Codex | RuntimeKind::Grok)) => kind,
            _ => return Err(invalid(format!("unknown runtime {name}; use claude, codex or grok"))),
        },
        None => match creator.runtime {
            RuntimeKind::Api => RuntimeKind::Claude,
            other => other,
        },
    };
    let installed = match app.sup.runtimes().get(kind) {
        Some(rt) => rt.status().await.installed,
        None => false,
    };
    if !installed {
        return Err(invalid(format!("{} is not installed on this server", kind.as_str())));
    }
    Ok(kind)
}

/// Every check; nothing is stored. Run before the card and again after the answer.
async fn plan(app: &App, p: &CreateParams) -> Result<Plan, RpcError> {
    let store: &Store = &app.sup.hub().store;
    let creator = store
        .agent_get(&p.agent_id)
        .map_err(server)?
        .ok_or_else(|| server(format!("no agent {}", p.agent_id)))?;
    if !creator.lead {
        return Err(not_allowed("team", "only the main agent of the crew can create agents"));
    }
    let name = p.name.trim().to_string();
    let crew_names: Vec<String> = store
        .agent_list()
        .map_err(server)?
        .into_iter()
        .map(|a| a.name)
        .collect();
    // Hidden characters first (they would also fail the plain rules, with a worse message), then the plain rules.
    if crate::sanitize::has_hidden(&name) {
        return Err(invalid(crate::sanitize::name_problem(&name, &[]).unwrap_or_default()));
    }
    crate::store::validate_name(&name).map_err(|e| invalid(format!("invalid: name: {e:#}")))?;
    // Same-looking names count as the same name: compared in Rust (Unicode case folding and lookalikes), not by SQLite.
    if let Some(why) = crate::sanitize::name_problem(&name, &crew_names) {
        return Err(invalid(why));
    }
    let crew = crew_names.len();
    if crew >= MAX_CREW {
        return Err(invalid(format!(
            "the crew already has {crew} agents: ask the person to remove some"
        )));
    }
    let role = crate::sanitize::line(p.role.as_deref().unwrap_or_default());
    if role.chars().count() > ROLE_CHARS {
        return Err(invalid(format!("role is longer than {ROLE_CHARS} characters")));
    }
    let instructions = crate::sanitize::block(&p.instructions);
    if instructions.is_empty() {
        return Err(invalid("instructions are empty: say what the agent is for"));
    }
    if instructions.chars().count() > INSTRUCTIONS_CHARS {
        return Err(invalid(format!(
            "instructions are longer than {INSTRUCTIONS_CHARS} characters"
        )));
    }

    let kind = runtime_for_new(app, &creator, p.runtime.as_deref()).await?;
    let model = match p.model.as_deref().map(str::trim).filter(|m| !m.is_empty()) {
        None => None,
        Some(asked) => {
            // The CLIs start in a folder of the daemon's own, as for `runtimes.models`.
            let cwd = app.data_home.join("models-probe");
            let cwd = if std::fs::create_dir_all(&cwd).is_ok() {
                cwd
            } else {
                app.data_home.clone()
            };
            let path = std::env::var_os("PATH").unwrap_or_default();
            let answer = app.models.answer(kind, &cwd, &path, false).await;
            Some(model_for_new(&answer, asked)?)
        }
    };
    let effort = match p.effort.as_deref().map(str::trim).filter(|e| !e.is_empty()) {
        None => None,
        Some(asked) => {
            let effort =
                Effort::parse(&asked.to_lowercase()).ok_or_else(|| invalid(format!("unknown effort {asked}")))?;
            super::check_effort(kind, Some(effort))?;
            Some(effort)
        }
    };

    let capabilities = capabilities_for_new(creator.capabilities.as_deref(), p.capabilities.as_deref())?;
    super::check_capabilities(kind, capabilities.as_deref())?;
    let all_integrations = store.integration_list().map_err(server)?;
    let integration_ids = integrations_for_new(
        &all_integrations,
        creator.integrations.as_deref(),
        p.integrations.as_deref(),
    )?;
    let approval_mode = mode_for_new(
        creator.approval_mode,
        store.server_settings_or_default().default_approval_mode,
    );
    let in_container = creator.workspace_id != crate::store::SHARED_WORKSPACE;
    let cwd = folder_for_new(p.folder.as_deref(), &app.data_home, in_container)?;

    if p.schedules.len() > MAX_SCHEDULES {
        return Err(invalid(format!("at most {MAX_SCHEDULES} schedules")));
    }
    let tz = schedule_text::local_zone();
    let mut schedule_rows: Vec<NewSchedule> = Vec::new();
    let mut schedule_lines: Vec<Value> = Vec::new();
    for s in &p.schedules {
        let (row, line) = schedules::check_new_for_agent(s, &tz)?;
        schedule_rows.push(row);
        schedule_lines.push(line);
    }

    let mut value = json!({
        "name": name,
        "role": role,
        "runtime": kind.as_str(),
        "model": model,
        "cwd": cwd.clone().unwrap_or_default(),
        "approval_mode": approval_mode.as_str(),
        "system_prompt": instructions,
        "effort": effort.map(Effort::as_str),
        "use_personal_settings": false,
    });
    value["capabilities"] = json!(capabilities.as_ref().map(|c| capability_names(Some(c))));
    value["integrations"] = json!(integration_ids);
    let agent: NewAgent = serde_json::from_value(value).map_err(server)?;

    // What the card shows, in the names a person knows.
    let usable = integrations::for_agent(&all_integrations, integration_ids.as_deref());
    let service_names: Vec<String> = usable.iter().map(|row| crate::sanitize::line(&row.name)).collect();
    let folder = match &cwd {
        Some(path) => json!({ "mode": "existing", "path": path }),
        None => json!({ "mode": "new", "path": app.agents_root.join(home::slug(&name)).display().to_string() }),
    };
    let summary = json!({
        "name": name,
        "role": role,
        "runtime": kind.as_str(),
        "model": model,
        "effort": effort.map(Effort::as_str),
        "approval_mode": approval_mode.as_str(),
        "capabilities": capability_names(capabilities.as_deref()),
        "integrations": service_names,
        "integrations_all": integration_ids.is_none(),
        "schedules": schedule_lines,
        "folder": folder,
        // All of it: what the new agent is told is what the person is asked to allow.
        "instructions": instructions,
        "creator": creator.name,
    });
    let fingerprint = json!({
        "summary": summary,
        "integration_ids": integration_ids,
        "capabilities": capabilities.as_ref().map(|c| capability_names(Some(c))),
        "cwd": cwd,
        "workspace": creator.workspace_id,
        "schedules": schedule_rows.iter().map(|r| json!([r.cron, r.tz, r.prompt, r.title])).collect::<Vec<_>>(),
    });
    Ok(Plan {
        fingerprint,
        agent,
        workspace_id: creator.workspace_id.clone(),
        schedules: schedule_rows,
        summary,
    })
}

/// The summary as plain lines: what Telegram and an app without the card show as the approval's command.
pub fn summary_text(summary: &Value) -> String {
    let text = |key: &str| summary.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let list = |key: &str| -> Vec<String> {
        summary
            .get(key)
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default()
    };
    let mut head = text("name");
    if !text("role").is_empty() {
        head.push_str(&format!(" ({})", text("role")));
    }
    head.push_str(&format!(" · {}", text("runtime")));
    if !text("model").is_empty() {
        head.push_str(&format!(" {}", text("model")));
    }
    let folder = &summary["folder"];
    let mut lines = vec![
        head,
        format!(
            "Folder: {}{}",
            if folder["mode"] == json!("new") { "new, " } else { "" },
            folder["path"].as_str().unwrap_or_default()
        ),
        format!("Approval mode: {}", text("approval_mode")),
    ];
    let capabilities = list("capabilities");
    lines.push(format!(
        "Can use: {}",
        if capabilities.is_empty() {
            "nothing extra".to_string()
        } else {
            capabilities.join(", ")
        }
    ));
    let services = list("integrations");
    lines.push(format!(
        "Services: {}",
        if services.is_empty() {
            "none".to_string()
        } else if summary["integrations_all"] == json!(true) {
            format!("all enabled ({})", services.join(", "))
        } else {
            services.join(", ")
        }
    ));
    // The instructions and the runs last, whole: they are the long part, and what a person must be able to read.
    let instructions = text("instructions");
    if !instructions.is_empty() {
        lines.push(format!(
            "Instructions ({} characters, {} lines):\n{instructions}",
            instructions.chars().count(),
            instructions.lines().count()
        ));
    }
    for run in summary
        .get("schedules")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let when = run["human_en"].as_str().unwrap_or_default();
        let title = run["title"].as_str().filter(|t| !t.is_empty());
        let prompt = run["prompt"].as_str().unwrap_or_default();
        lines.push(match title {
            Some(title) => format!("Runs {when}: {title}\n{prompt}"),
            None => format!("Runs {when}:\n{prompt}"),
        });
    }
    lines.join("\n")
}

/// `team.create`.
pub async fn create(app: &App, p: Value) -> RpcResult {
    create_within(app, p, APPROVAL_LIMIT).await
}

/// [`create`] with the longest wait for the person's answer given.
pub(super) async fn create_within(app: &App, p: Value, limit: Duration) -> RpcResult {
    let p: CreateParams = params(p)?;
    let now = crate::store::now_ms();
    let first = plan(app, &p).await?;
    let slot = app.creations.begin(&p.agent_id, now)?;

    let store = &app.sup.hub().store;
    let creator = store
        .agent_get(&p.agent_id)
        .map_err(server)?
        .ok_or_else(|| server(format!("no agent {}", p.agent_id)))?;
    let (approved_by, plan) = if creator.approval_mode == ApprovalMode::Never {
        (DecidedBy::Policy, first)
    } else {
        let spec = ApprovalSpec {
            tool: APPROVAL_TOOL.to_string(),
            title: format!("Create agent «{}»", first.agent.name.trim()),
            command: Some(summary_text(&first.summary)),
            reason: "agent: create".to_string(),
            input: first.summary.clone(),
        };
        let asked_at = std::time::Instant::now();
        let decision = app.sup.ask_external(&p.agent_id, spec, limit).await.map_err(server)?;
        if decision != crate::event::Decision::Allow {
            // A no from the person counts; running out of time does not.
            if asked_at.elapsed() < limit {
                app.creations.refused(&p.agent_id, crate::store::now_ms());
            }
            return Err(RpcError::with_data(
                INVALID_PARAMS,
                "declined: the person did not allow this agent. Do not try again unless they ask for it",
                json!({ "reason": "declined" }),
            ));
        }
        // The crew, a folder or a service may have changed while the card waited: check again, and create only
        // what the person was shown.
        let second = plan(app, &p).await?;
        if second.fingerprint != first.fingerprint {
            return Err(RpcError::with_data(
                INVALID_PARAMS,
                "changed_since_approval: something the card showed (a folder, a service, a name, the crew) is different now, so nothing was created. Ask again if the person still wants it",
                json!({ "reason": "changed_since_approval" }),
            ));
        }
        (DecidedBy::User, second)
    };
    let created = make(app, &creator, plan, approved_by)?;
    app.creations.made(&p.agent_id, crate::store::now_ms());
    drop(slot);
    ok(created)
}

/// Creates the agent, its schedules and the two events.
fn make(app: &App, creator: &Agent, plan: Plan, approved_by: DecidedBy) -> RpcResult {
    let store = &app.sup.hub().store;
    let id = super::create_agent(app, plan.agent, Some(plan.workspace_id))?;
    let created = store
        .agent_get(&id)
        .map_err(server)?
        .ok_or_else(|| server(format!("no agent {id}")))?;
    let hub = app.sup.hub();
    hub.emit(
        &id,
        EventBody::AgentCreatedBy {
            by_agent_id: creator.id.clone(),
            by_name: creator.name.clone(),
            approved_by,
        },
    );
    hub.emit(
        &creator.id,
        EventBody::AgentSpawned {
            agent_id: id.clone(),
            name: created.name.clone(),
            role: Some(created.role.clone()).filter(|r| !r.is_empty()),
            runtime: created.runtime.as_str().to_string(),
            model: created.model.clone(),
            approved_by,
        },
    );
    let mut schedule_ids: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    for mut row in plan.schedules {
        row.agent_id = id.clone();
        match schedules::create(app, row) {
            Ok(v) => schedule_ids.push(v["id"].as_str().unwrap_or_default().to_string()),
            Err(e) => warnings.push(format!("a schedule was not set: {}", e.message)),
        }
    }
    Ok(json!({
        "agent_id": id,
        "name": created.name,
        "runtime": created.runtime.as_str(),
        "model": created.model,
        "folder": created.cwd,
        "approval_mode": created.approval_mode.as_str(),
        "schedule_ids": schedule_ids,
        "warnings": warnings,
        "next": "Hand it its first task with team_assign. Its regular runs go through schedule_create with agent_id.",
    }))
}

#[cfg(test)]
mod tests {
    use super::super::{Peer, dispatch};
    use super::*;
    use crate::event::Decision;
    use crate::hub::Hub;
    use crate::runtime::{Runtime, RuntimeStatus, SpawnConfig, Spawned};
    use crate::store::{IntegrationKind, NewIntegration, NewWorkspace};
    use crate::supervisor::{Runtimes, Supervisor};
    use std::path::PathBuf;
    use std::sync::Arc;

    /// A runtime that is installed and never runs anything.
    struct Installed(RuntimeKind);

    #[async_trait::async_trait]
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
            anyhow::bail!("not in these tests")
        }
    }

    struct World {
        app: Arc<App>,
        lead: String,
        scout: String,
        root: PathBuf,
    }

    impl Drop for World {
        fn drop(&mut self) {
            // Only the folder this world made itself.
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn new_agent(store: &Store, name: &str, extra: Value) -> Agent {
        let mut base = json!({ "name": name, "runtime": "claude", "cwd": "/tmp", "approval_mode": "risky" });
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            base[&k] = v;
        }
        store.agent_create(serde_json::from_value(base).unwrap()).unwrap()
    }

    /// A crew with the main agent "Forge" (the fields given on top of `risky`) and a plain agent "Scout".
    fn world(lead_extra: Value) -> World {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let mut runtimes = Runtimes::default();
        runtimes.insert(Arc::new(Installed(RuntimeKind::Claude)));
        runtimes.insert(Arc::new(Installed(RuntimeKind::Grok)));
        let sup = Supervisor::new(Hub::new(store.clone()), runtimes, None);
        let lead = new_agent(&store, "Forge", lead_extra);
        store.agent_set_lead(&lead.id, true).unwrap();
        let scout = new_agent(&store, "Scout", json!({}));
        let root = std::env::temp_dir().join(format!("bandito-team-create-{}", crate::store::new_id()));
        World {
            app: App::new(sup, root.join("agents")),
            lead: lead.id,
            scout: scout.id,
            root,
        }
    }

    fn req(extra: Value) -> Value {
        let mut base = json!({ "name": "Mailer", "instructions": "Watch the mailbox and report new letters." });
        for (k, v) in extra.as_object().cloned().unwrap_or_default() {
            base[&k] = v;
        }
        base
    }

    async fn create_as(w: &World, who: &str, p: Value) -> RpcResult {
        dispatch(&w.app, &Peer::Agent(who.to_string()), "team.create", p).await
    }

    async fn pending_card(w: &World) -> crate::store::Approval {
        for _ in 0..200 {
            if let Some(a) = w
                .app
                .sup
                .hub()
                .store
                .approval_list_pending(Some(&w.lead))
                .unwrap()
                .pop()
            {
                return a;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("no card");
    }

    fn events_of(w: &World, agent: &str) -> Vec<EventBody> {
        w.app
            .sup
            .hub()
            .store
            .events_since(0, 1000, Some(agent))
            .unwrap()
            .into_iter()
            .map(|e| e.body)
            .collect()
    }

    #[test]
    fn a_new_agent_is_never_softer_than_its_creator_or_the_server() {
        use ApprovalMode::{Always, Never, Risky};
        for (creator, default, want) in [
            (Always, Risky, Always),
            (Always, Never, Always),
            (Risky, Risky, Risky),
            (Risky, Always, Always),
            (Risky, Never, Risky),
            (Never, Risky, Risky),
            (Never, Always, Always),
            (Never, Never, Never),
        ] {
            assert_eq!(mode_for_new(creator, default), want, "{creator:?} / {default:?}");
        }
    }

    #[test]
    fn capabilities_are_a_subset_of_the_creators() {
        use Capability::{Browser, Files, Team, Terminal};
        let mine = [Team, Browser];
        // Nothing said: the creator's own list, or all of them for a creator that has all.
        assert_eq!(
            capabilities_for_new(Some(&mine), None).unwrap(),
            Some(vec![Team, Browser])
        );
        assert_eq!(capabilities_for_new(None, None).unwrap(), None);
        // A subset, in any case and with repeats.
        let asked = ["Browser".to_string(), "browser".to_string()];
        assert_eq!(
            capabilities_for_new(Some(&mine), Some(&asked)).unwrap(),
            Some(vec![Browser])
        );
        assert_eq!(capabilities_for_new(Some(&mine), Some(&[])).unwrap(), Some(vec![]));
        // Past the creator's: refused, with the names.
        let more = ["terminal".to_string(), "files".to_string(), "browser".to_string()];
        let err = capabilities_for_new(Some(&mine), Some(&more)).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        assert!(err.message.starts_with("not_allowed: capabilities"), "{}", err.message);
        assert!(err.message.contains("terminal, files"), "{}", err.message);
        // A creator with all of them may give any.
        assert_eq!(
            capabilities_for_new(None, Some(&["terminal".to_string()])).unwrap(),
            Some(vec![Terminal])
        );
        assert_eq!(
            capabilities_for_new(None, Some(&["files".to_string()])).unwrap(),
            Some(vec![Files])
        );
        // A name nobody knows is a mistake in the request, not a refusal.
        let err = capabilities_for_new(None, Some(&["root".to_string()])).unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
    }

    fn row(id: &str, name: &str, enabled: bool) -> Integration {
        Integration {
            id: id.into(),
            name: name.into(),
            kind: IntegrationKind::Http,
            command: None,
            args: Vec::new(),
            url: None,
            env: Default::default(),
            headers: Default::default(),
            enabled,
            created_at: 0,
            auth: Default::default(),
            tool_mode: Default::default(),
            tool_overrides: Default::default(),
        }
    }

    #[test]
    fn services_are_a_subset_of_those_the_creator_can_use() {
        let all = vec![
            row("i1", "github", true),
            row("i2", "notion", true),
            row("i3", "slack", false),
        ];
        let ask = |names: &[&str]| names.iter().map(|n| n.to_string()).collect::<Vec<_>>();
        // The creator may use all enabled ones: a name, an id or another case all find the row.
        let got = integrations_for_new(&all, None, Some(&ask(&["GitHub", "i2"]))).unwrap();
        assert_eq!(got, Some(vec!["i1".to_string(), "i2".to_string()]));
        // Nothing said: the creator's own setting (all, or its list).
        assert_eq!(integrations_for_new(&all, None, None).unwrap(), None);
        let mine = vec!["i1".to_string()];
        assert_eq!(
            integrations_for_new(&all, Some(&mine), None).unwrap(),
            Some(mine.clone())
        );
        // A creator with a list: a row outside it is refused, a switched-off row too.
        let err = integrations_for_new(&all, Some(&mine), Some(&ask(&["notion"]))).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        assert!(err.message.starts_with("not_allowed: integrations"), "{}", err.message);
        let err = integrations_for_new(&all, None, Some(&ask(&["slack"]))).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        // A service that is not connected at all: how to get it.
        let err = integrations_for_new(&all, None, Some(&ask(&["gmail"]))).unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("request_connection"), "{}", err.message);
        // None at all is allowed.
        assert_eq!(integrations_for_new(&all, None, Some(&[])).unwrap(), Some(vec![]));
    }

    #[test]
    fn the_plain_summary_has_the_order_and_the_whole_text() {
        let long = "word ".repeat(100);
        let lines = summary_text(&json!({
            "name": "Mailer", "role": "", "runtime": "claude", "approval_mode": "risky",
            "capabilities": ["browser"], "integrations": [], "integrations_all": false, "schedules": [],
            "folder": { "mode": "existing", "path": "/work" }, "instructions": long,
        }));
        assert!(
            lines.contains("Instructions (500 characters, 1 lines):\nword word"),
            "{lines}"
        );
        assert!(
            lines.contains(long.trim_end()),
            "the whole text is there, not a start of it"
        );
        assert!(lines.contains("Folder: /work\n"), "{lines}");
        assert!(lines.contains("Services: none"), "{lines}");
    }

    #[test]
    fn a_model_must_be_one_the_runtime_offers() {
        let model = |id: &str, name: &str| RuntimeModel {
            id: id.into(),
            name: name.into(),
            description: None,
            is_default: false,
            efforts: Vec::new(),
            context_window: None,
        };
        let answer = ModelsAnswer {
            runtime: RuntimeKind::Claude,
            models: vec![model("opus", "Opus"), model("sonnet", "Sonnet")],
            error: None,
            fetched_at: 0,
        };
        assert_eq!(model_for_new(&answer, " Sonnet ").unwrap(), "sonnet");
        let err = model_for_new(&answer, "gpt-9").unwrap_err();
        assert!(err.message.contains("opus, sonnet"), "{}", err.message);
        let broken = ModelsAnswer {
            error: Some("not_installed".into()),
            models: Vec::new(),
            ..answer
        };
        let err = model_for_new(&broken, "opus").unwrap_err();
        assert!(err.message.contains("cannot check the model"), "{}", err.message);
    }

    #[test]
    fn the_folder_is_new_or_a_real_folder_outside_bandito() {
        let tmp = std::env::temp_dir().join(format!("bandito-folder-{}", crate::store::new_id()));
        let data = tmp.join("data");
        let work = tmp.join("work");
        std::fs::create_dir_all(data.join("run")).unwrap();
        std::fs::create_dir_all(&work).unwrap();
        assert_eq!(folder_for_new(None, &data, false).unwrap(), None);
        assert_eq!(folder_for_new(Some(" NEW "), &data, false).unwrap(), None);
        let real = std::fs::canonicalize(&work).unwrap().display().to_string();
        assert_eq!(
            folder_for_new(Some(work.to_str().unwrap()), &data, false).unwrap(),
            Some(real)
        );
        // Bandito's own folder, or anything in it, and a link into it.
        let err = folder_for_new(Some(data.to_str().unwrap()), &data, false).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        let err = folder_for_new(Some(data.join("run").to_str().unwrap()), &data, false).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        std::os::unix::fs::symlink(&data, tmp.join("link")).unwrap();
        let err = folder_for_new(Some(tmp.join("link").to_str().unwrap()), &data, false).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        // Not absolute, not there, not a folder, and any path from a container workspace.
        for bad in ["relative/dir", "/definitely/not/here"] {
            assert_eq!(
                folder_for_new(Some(bad), &data, false).unwrap_err().code,
                INVALID_PARAMS
            );
        }
        std::fs::write(tmp.join("file"), "x").unwrap();
        assert!(folder_for_new(Some(tmp.join("file").to_str().unwrap()), &data, false).is_err());
        let err = folder_for_new(Some(work.to_str().unwrap()), &data, true).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        assert_eq!(folder_for_new(Some("new"), &data, true).unwrap(), None);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn only_the_main_agent_creates_agents_and_only_an_agent_asks() {
        let w = world(json!({ "approval_mode": "never" }));
        let err = create_as(&w, &w.scout, req(json!({}))).await.unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        assert!(err.message.starts_with("not_allowed"), "{}", err.message);
        let err = dispatch(&w.app, &Peer::Local, "team.create", req(json!({ "agent_id": w.lead })))
            .await
            .unwrap_err();
        assert_eq!(err.message, "team.create is only for agents");
        // Another agent's id in the params does not make the caller the main agent.
        let err = create_as(&w, &w.scout, req(json!({ "agent_id": w.lead })))
            .await
            .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn in_never_mode_an_agent_is_made_at_once_and_both_feeds_say_so() {
        let w = world(json!({ "approval_mode": "never", "capabilities": ["team", "browser"] }));
        let made = create_as(
            &w,
            &w.lead,
            req(json!({
                "role": "mail watcher",
                "capabilities": ["browser"],
                "schedules": [{ "every": "5m", "prompt": "Check the mail", "title": "Mail" }],
            })),
        )
        .await
        .unwrap();
        let id = made["agent_id"].as_str().unwrap().to_string();
        let store = &w.app.sup.hub().store;
        let agent = store.agent_get(&id).unwrap().unwrap();
        assert_eq!((agent.name.as_str(), agent.role.as_str()), ("Mailer", "mail watcher"));
        assert_eq!(agent.capabilities, Some(vec![Capability::Browser]));
        assert_eq!(
            agent.system_prompt.as_deref(),
            Some("Watch the mailbox and report new letters.")
        );
        assert!(!agent.lead);
        assert!(!agent.use_personal_settings);
        // The creator was in `never`: the new agent follows the server's default, which is `risky`.
        assert_eq!(agent.approval_mode, ApprovalMode::Risky);
        assert_eq!(agent.workspace_id, crate::store::SHARED_WORKSPACE);
        // Its own folder under the agents folder.
        assert!(
            agent.cwd.starts_with(w.app.agents_root.to_str().unwrap()),
            "{}",
            agent.cwd
        );
        assert!(Path::new(&agent.cwd).is_dir());
        // The schedule is its own.
        let list = store.schedule_list(Some(&id)).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].cron, "*/5 * * * *");
        assert_eq!(made["schedule_ids"][0].as_str(), Some(list[0].id.as_str()));
        // No card was asked for.
        assert!(store.approval_list_pending(None).unwrap().is_empty());
        // The creator's feed: a card line; the new agent's feed: who made it.
        assert!(events_of(&w, &w.lead).iter().any(|e| matches!(e,
            EventBody::AgentSpawned { name, approved_by: DecidedBy::Policy, .. } if name == "Mailer")));
        assert!(events_of(&w, &id).iter().any(|e| matches!(e,
            EventBody::AgentCreatedBy { by_name, approved_by: DecidedBy::Policy, .. } if by_name == "Forge")));
    }

    #[tokio::test]
    async fn in_risky_and_always_modes_the_person_decides_on_a_card() {
        for mode in ["risky", "always"] {
            let w = world(json!({ "approval_mode": mode }));
            let app = w.app.clone();
            let lead = w.lead.clone();
            let call = tokio::spawn(async move {
                create_within(
                    &app,
                    req(json!({
                        "agent_id": lead, "role": "mail watcher",
                        "schedules": [{ "at": "09:00", "days": ["mon", "fri"], "prompt": "Morning digest" }],
                    })),
                    Duration::from_secs(20),
                )
                .await
            });
            let card = pending_card(&w).await;
            assert_eq!(card.tool, "agent.create");
            assert_eq!(card.title, "Create agent «Mailer»");
            // An app without the card (and Telegram) reads the same facts as lines.
            let lines = card.payload["command"].as_str().unwrap().to_string();
            assert!(lines.starts_with("Mailer (mail watcher) · claude\n"), "{lines}");
            assert!(lines.contains(&format!("Approval mode: {mode}")), "{lines}");
            assert!(
                lines.contains("Can use: terminal, files, browser, team, screen"),
                "{lines}"
            );
            assert!(lines.contains("Runs ") && lines.contains("Morning digest"), "{lines}");
            assert!(lines.contains("Folder: new, "), "{lines}");
            // The summary the card is drawn from, in the stored payload and in the event.
            let input = &card.payload["input"];
            assert_eq!(input["name"], "Mailer");
            assert_eq!(input["role"], "mail watcher");
            assert_eq!(input["runtime"], "claude");
            assert_eq!(input["approval_mode"], mode);
            assert_eq!(
                input["capabilities"],
                json!(["terminal", "files", "browser", "team", "screen"])
            );
            assert_eq!(input["schedules"][0]["prompt"], "Morning digest");
            assert!(
                input["schedules"][0]["human_en"]
                    .as_str()
                    .is_some_and(|t| !t.is_empty())
            );
            assert_eq!(input["folder"]["mode"], "new");
            assert_eq!(input["creator"], "Forge");
            assert_eq!(input["instructions"], "Watch the mailbox and report new letters.");
            assert!(
                lines.contains("Instructions (41 characters, 1 lines):\nWatch the mailbox and report new letters."),
                "{lines}"
            );
            assert!(events_of(&w, &w.lead).iter().any(|e| matches!(e,
                EventBody::ApprovalRequested { tool, input: Some(i), .. } if tool == "agent.create" && i["name"] == "Mailer")));
            // Nothing exists before the answer.
            assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
            w.app.sup.resolve(&card.id, Decision::Allow, false).await.unwrap();
            let made = call.await.unwrap().unwrap();
            let id = made["agent_id"].as_str().unwrap();
            let agent = w.app.sup.hub().store.agent_get(id).unwrap().unwrap();
            // A creator in `risky` or `always` makes agents in the same mode.
            assert_eq!(agent.approval_mode.as_str(), mode);
            assert!(events_of(&w, &w.lead).iter().any(|e| matches!(
                e,
                EventBody::AgentSpawned {
                    approved_by: DecidedBy::User,
                    ..
                }
            )));
            assert!(events_of(&w, id).iter().any(|e| matches!(
                e,
                EventBody::AgentCreatedBy {
                    approved_by: DecidedBy::User,
                    ..
                }
            )));
            assert_eq!(w.app.sup.hub().store.schedule_list(Some(id)).unwrap().len(), 1);
        }
    }

    #[tokio::test]
    async fn a_refused_card_creates_nothing() {
        let w = world(json!({}));
        let app = w.app.clone();
        let lead = w.lead.clone();
        let call = tokio::spawn(async move {
            create_within(&app, req(json!({ "agent_id": lead })), Duration::from_secs(20)).await
        });
        let card = pending_card(&w).await;
        w.app.sup.resolve(&card.id, Decision::Deny, false).await.unwrap();
        let err = call.await.unwrap().unwrap_err();
        assert!(err.message.starts_with("declined:"), "{}", err.message);
        assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
        assert!(
            !events_of(&w, &w.lead)
                .iter()
                .any(|e| matches!(e, EventBody::AgentSpawned { .. }))
        );
        // The slot is free again: the next ask is not "busy".
        let err = create_within(&w.app, req(json!({ "agent_id": w.lead })), Duration::from_millis(100))
            .await
            .unwrap_err();
        assert!(err.message.starts_with("declined:"), "{}", err.message);
    }

    #[tokio::test]
    async fn no_answer_in_time_declines_and_a_dropped_call_closes_the_card() {
        let w = world(json!({}));
        let err = create_within(&w.app, req(json!({ "agent_id": w.lead })), Duration::from_millis(50))
            .await
            .unwrap_err();
        assert!(err.message.starts_with("declined:"), "{}", err.message);
        assert!(w.app.sup.hub().store.approval_list_pending(None).unwrap().is_empty());

        // The agent's connection closes while the card waits: the call is dropped, and the card with it.
        let app = w.app.clone();
        let lead = w.lead.clone();
        let call = tokio::spawn(async move {
            create_within(&app, req(json!({ "agent_id": lead })), Duration::from_secs(60)).await
        });
        let card = pending_card(&w).await;
        call.abort();
        let _ = call.await;
        let mut closed = false;
        for _ in 0..200 {
            if w.app.sup.hub().store.approval_list_pending(None).unwrap().is_empty() {
                closed = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        assert!(closed, "the card {} is still open", card.id);
        assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn only_one_request_waits_at_a_time() {
        let w = world(json!({}));
        let app = w.app.clone();
        let lead = w.lead.clone();
        let first = tokio::spawn(async move {
            create_within(&app, req(json!({ "agent_id": lead })), Duration::from_secs(20)).await
        });
        let card = pending_card(&w).await;
        let err = create_within(
            &w.app,
            req(json!({ "agent_id": w.lead, "name": "Second" })),
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert!(err.message.contains("waits for the person"), "{}", err.message);
        w.app.sup.resolve(&card.id, Decision::Allow, false).await.unwrap();
        first.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn everything_is_checked_before_the_person_is_asked() {
        let w = world(json!({ "capabilities": ["team", "browser"] }));
        let cases = [
            req(json!({ "name": "" })),
            req(json!({ "name": "bad/name" })),
            req(json!({ "name": "scout" })),
            req(json!({ "instructions": "  " })),
            req(json!({ "instructions": "x".repeat(INSTRUCTIONS_CHARS + 1) })),
            req(json!({ "role": "r".repeat(201) })),
            req(json!({ "runtime": "codex" })),
            req(json!({ "runtime": "api" })),
            req(json!({ "runtime": "emacs" })),
            req(json!({ "capabilities": ["terminal"] })),
            req(json!({ "capabilities": ["wizard"] })),
            req(json!({ "integrations": ["gmail"] })),
            req(json!({ "effort": "ludicrous" })),
            req(json!({ "folder": "relative" })),
            req(json!({ "schedules": [{ "prompt": "x" }] })),
            req(json!({ "schedules": [{ "every": "1m", "prompt": "x" }] })),
            req(json!({ "schedules": [{ "every": "15m", "prompt": " " }] })),
            req(json!({ "capabilities": ["browser"], "runtime": "grok" })),
        ];
        for p in cases {
            let mut p = p;
            p["agent_id"] = json!(w.lead);
            let err = create_within(&w.app, p.clone(), Duration::from_millis(10))
                .await
                .unwrap_err();
            assert!(
                !err.message.starts_with("declined"),
                "{p}: asked the person: {}",
                err.message
            );
        }
        assert!(w.app.sup.hub().store.approval_list_pending(None).unwrap().is_empty());
        assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn a_new_agent_stays_in_the_creators_workspace() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let mut runtimes = Runtimes::default();
        runtimes.insert(Arc::new(Installed(RuntimeKind::Claude)));
        let sup = Supervisor::new(Hub::new(store.clone()), runtimes, None);
        let ws = store
            .workspace_create(NewWorkspace {
                name: "Box".into(),
                kind: crate::store::WorkspaceKind::Container,
                image: None,
                cpus: None,
                memory_mb: None,
                network: Default::default(),
                mounts: Vec::new(),
            })
            .unwrap();
        let base = json!({ "name": "Boxed", "runtime": "claude", "cwd": "", "approval_mode": "never" });
        let lead = store
            .agent_create_in(serde_json::from_value::<NewAgent>(base).unwrap(), &ws.id)
            .unwrap();
        store.agent_set_lead(&lead.id, true).unwrap();
        let root = std::env::temp_dir().join(format!("bandito-team-create-{}", crate::store::new_id()));
        let app = App::new(sup, root.join("agents"));
        let made = dispatch(&app, &Peer::Agent(lead.id.clone()), "team.create", req(json!({})))
            .await
            .unwrap();
        let agent = store.agent_get(made["agent_id"].as_str().unwrap()).unwrap().unwrap();
        assert_eq!(agent.workspace_id, ws.id);
        // An existing host folder is not offered to a container's agent.
        let err = dispatch(
            &app,
            &Peer::Agent(lead.id),
            "team.create",
            req(json!({ "name": "Other", "folder": "/tmp" })),
        )
        .await
        .unwrap_err();
        assert!(err.message.starts_with("not_allowed: folder"), "{}", err.message);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[tokio::test]
    async fn services_come_from_the_creators_list_and_default_to_it() {
        let w = world(json!({ "approval_mode": "never" }));
        let store = &w.app.sup.hub().store;
        let mail = store
            .integration_create(NewIntegration {
                name: "gmail".into(),
                kind: IntegrationKind::Http,
                command: None,
                args: Vec::new(),
                url: Some("https://example.com/mcp".into()),
                env: Default::default(),
                headers: Default::default(),
                enabled: true,
                auth: Default::default(),
            })
            .unwrap();
        let made = create_as(&w, &w.lead, req(json!({ "integrations": ["gmail"] })))
            .await
            .unwrap();
        let agent = store.agent_get(made["agent_id"].as_str().unwrap()).unwrap().unwrap();
        assert_eq!(agent.integrations, Some(vec![mail.id.clone()]));
        // Nothing said: the creator has all enabled ones, so does the new agent.
        let made = create_as(&w, &w.lead, req(json!({ "name": "Plain" }))).await.unwrap();
        let agent = store.agent_get(made["agent_id"].as_str().unwrap()).unwrap().unwrap();
        assert_eq!(agent.integrations, None);
        // A creator limited to no services cannot hand one on.
        store
            .agent_update(
                &w.lead,
                crate::store::AgentPatch {
                    integrations: Some(Some(vec![])),
                    ..Default::default()
                },
            )
            .unwrap();
        let err = create_as(&w, &w.lead, req(json!({ "name": "Third", "integrations": ["gmail"] })))
            .await
            .unwrap_err();
        assert!(err.message.starts_with("not_allowed: integrations"), "{}", err.message);
    }

    #[tokio::test]
    async fn a_runtime_that_is_not_installed_is_refused() {
        let w = world(json!({ "approval_mode": "never" }));
        // The world has Claude and Grok; Codex is not there.
        let err = create_as(&w, &w.lead, req(json!({ "runtime": "codex" })))
            .await
            .unwrap_err();
        assert!(err.message.contains("codex is not installed"), "{}", err.message);
        let made = create_as(&w, &w.lead, req(json!({ "runtime": "grok" }))).await.unwrap();
        assert_eq!(made["runtime"], "grok");
    }

    #[tokio::test]
    async fn an_agent_makes_few_agents_an_hour() {
        let w = world(json!({ "approval_mode": "never" }));
        for i in 0..MAX_PER_HOUR {
            create_as(&w, &w.lead, req(json!({ "name": format!("Bot {i}") })))
                .await
                .unwrap();
        }
        let err = create_as(&w, &w.lead, req(json!({ "name": "One too many" })))
            .await
            .unwrap_err();
        assert!(err.message.starts_with("rate_limited"), "{}", err.message);
    }

    // ---- the review of the security of creation: what is read is what is made ----

    #[test]
    fn the_plain_summary_lists_folder_mode_rights_services_then_instructions_and_runs() {
        let lines = summary_text(&json!({
            "name": "Mailer", "role": "mail watcher", "runtime": "claude", "model": "sonnet", "approval_mode": "always",
            "capabilities": ["browser"], "integrations": ["Gmail"], "integrations_all": false,
            "schedules": [{ "title": "Mail", "prompt": "Check the mail.\nSay nothing else.", "human_en": "every 5 minutes", "human_ru": "" }],
            "folder": { "mode": "existing", "path": "/work" }, "instructions": "Watch the mail.",
        }));
        let at = |needle: &str| lines.find(needle).unwrap_or_else(|| panic!("{needle} in {lines}"));
        assert!(at("Mailer (mail watcher)") < at("Folder:"));
        assert!(at("Folder:") < at("Approval mode:"));
        assert!(at("Approval mode:") < at("Can use:"));
        assert!(at("Can use:") < at("Services:"));
        assert!(at("Services:") < at("Instructions"));
        assert!(at("Instructions") < at("Runs every 5 minutes: Mail"));
        // A run says its whole prompt, not only its title.
        assert!(lines.ends_with("Check the mail.\nSay nothing else."), "{lines}");
    }

    #[tokio::test]
    async fn a_schedule_prompt_reaches_the_card_whole() {
        let w = world(json!({}));
        let prompt = format!("Check the mail. {}", "Then report it. ".repeat(40));
        assert!(prompt.chars().count() > 160);
        let app = w.app.clone();
        let lead = w.lead.clone();
        let sent = prompt.clone();
        let call = tokio::spawn(async move {
            create_within(
                &app,
                req(json!({ "agent_id": lead, "schedules": [{ "every": "15m", "prompt": sent, "title": "Mail" }] })),
                Duration::from_secs(20),
            )
            .await
        });
        let card = pending_card(&w).await;
        assert_eq!(card.payload["input"]["schedules"][0]["prompt"], prompt.trim());
        assert!(card.payload["command"].as_str().unwrap().contains(prompt.trim()));
        w.app.sup.resolve(&card.id, Decision::Deny, false).await.unwrap();
        let _ = call.await;
    }

    #[tokio::test]
    async fn hidden_characters_never_reach_the_card_or_the_agent() {
        let w = world(json!({ "approval_mode": "never" }));
        let made = create_as(
            &w,
            &w.lead,
            req(json!({
                "role": "mail\u{202E} watcher\nbot\u{200B}",
                "instructions": "Watch\u{200D} the mail.\u{202E}\r\n\r\n\r\n\r\n\r\nNever send.\u{0000}",
                "schedules": [{ "every": "15m", "prompt": "Check\u{2066} mail\n\n\n\n\nnow", "title": "Mail\nLine\u{200B}" }],
            })),
        )
        .await
        .unwrap();
        let store = &w.app.sup.hub().store;
        let agent = store.agent_get(made["agent_id"].as_str().unwrap()).unwrap().unwrap();
        assert_eq!(agent.role, "mail watcher bot");
        assert_eq!(agent.system_prompt.as_deref(), Some("Watch the mail.\n\n\nNever send."));
        let run = &store.schedule_list(Some(&agent.id)).unwrap()[0];
        assert_eq!(run.prompt, "Check mail\n\n\nnow");
        assert_eq!(run.title.as_deref(), Some("Mail Line"));
    }

    #[tokio::test]
    async fn a_name_with_hidden_characters_or_mixed_alphabets_is_refused() {
        let w = world(json!({ "approval_mode": "never" }));
        // Zero-width, a right-to-left override, a line break; a Cyrillic "а" inside a Latin word and the reverse.
        for name in [
            "Mail\u{200B}er",
            "Mail\u{202E}er",
            "Mail\ner",
            "M\u{0430}iler",
            "Почт\u{0061}",
            "Ｍailer",
        ] {
            let err = create_as(&w, &w.lead, req(json!({ "name": name }))).await.unwrap_err();
            assert!(err.message.starts_with("invalid: name"), "{name:?}: {}", err.message);
        }
        // Words of one alphabet each, in one name, are fine.
        create_as(&w, &w.lead, req(json!({ "name": "Mail Почта" })))
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn a_folder_swapped_after_the_card_means_nothing_is_created() {
        let w = world(json!({}));
        let a = w.root.join("a");
        let b = w.root.join("b");
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        let link = w.root.join("work");
        std::os::unix::fs::symlink(&a, &link).unwrap();
        let app = w.app.clone();
        let lead = w.lead.clone();
        let path = link.display().to_string();
        let call = tokio::spawn(async move {
            create_within(
                &app,
                req(json!({ "agent_id": lead, "folder": path })),
                Duration::from_secs(20),
            )
            .await
        });
        let card = pending_card(&w).await;
        assert_eq!(
            card.payload["input"]["folder"]["path"],
            std::fs::canonicalize(&a).unwrap().display().to_string()
        );
        // The link is pointed somewhere else while the card waits.
        std::fs::remove_file(&link).unwrap();
        std::os::unix::fs::symlink(&b, &link).unwrap();
        w.app.sup.resolve(&card.id, Decision::Allow, false).await.unwrap();
        let err = call.await.unwrap().unwrap_err();
        assert!(err.message.starts_with("changed_since_approval"), "{}", err.message);
        assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn a_service_list_that_changed_after_the_card_means_nothing_is_created() {
        let w = world(json!({}));
        let app = w.app.clone();
        let lead = w.lead.clone();
        let call = tokio::spawn(async move {
            create_within(&app, req(json!({ "agent_id": lead })), Duration::from_secs(20)).await
        });
        let card = pending_card(&w).await;
        // A service is connected meanwhile: the creator has "all enabled", so the new agent would get it too.
        w.app
            .sup
            .hub()
            .store
            .integration_create(NewIntegration {
                name: "gmail".into(),
                kind: IntegrationKind::Http,
                command: None,
                args: Vec::new(),
                url: Some("https://example.com/mcp".into()),
                env: Default::default(),
                headers: Default::default(),
                enabled: true,
                auth: Default::default(),
            })
            .unwrap();
        w.app.sup.resolve(&card.id, Decision::Allow, false).await.unwrap();
        let err = call.await.unwrap().unwrap_err();
        assert!(err.message.starts_with("changed_since_approval"), "{}", err.message);
        assert_eq!(w.app.sup.hub().store.agent_list().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn three_refusals_in_an_hour_close_the_door_for_an_hour() {
        let w = world(json!({}));
        for _ in 0..MAX_REFUSALS {
            let app = w.app.clone();
            let lead = w.lead.clone();
            let call = tokio::spawn(async move {
                create_within(&app, req(json!({ "agent_id": lead })), Duration::from_secs(20)).await
            });
            let card = pending_card(&w).await;
            w.app.sup.resolve(&card.id, Decision::Deny, false).await.unwrap();
            let err = call.await.unwrap().unwrap_err();
            assert!(err.message.starts_with("declined:"), "{}", err.message);
        }
        // The next request is turned away at once, with the reason, and no card is shown.
        let err = create_within(&w.app, req(json!({ "agent_id": w.lead })), Duration::from_secs(2))
            .await
            .unwrap_err();
        assert!(err.message.starts_with("declined_too_often"), "{}", err.message);
        assert!(
            err.message.contains("59 more minutes") || err.message.contains("60 more minutes"),
            "{}",
            err.message
        );
        assert!(w.app.sup.hub().store.approval_list_pending(None).unwrap().is_empty());
        // After the hour it is open again.
        let later = crate::store::now_ms() + HOUR_MS + 1;
        assert!(w.app.creations.begin(&w.lead, later).is_ok());
    }

    #[tokio::test]
    async fn running_out_of_time_is_not_a_refusal() {
        let w = world(json!({}));
        for _ in 0..MAX_REFUSALS + 1 {
            let err = create_within(&w.app, req(json!({ "agent_id": w.lead })), Duration::from_millis(30))
                .await
                .unwrap_err();
            assert!(err.message.starts_with("declined:"), "{}", err.message);
        }
    }

    #[test]
    fn a_folder_that_holds_bandito_or_is_the_home_or_the_root_is_refused() {
        let tmp = std::env::temp_dir().join(format!("bandito-folder-{}", crate::store::new_id()));
        let data = tmp.join("deep").join("data");
        std::fs::create_dir_all(&data).unwrap();
        // The parents of the data folder: they contain it.
        for holder in [tmp.clone(), tmp.join("deep")] {
            let err = folder_for_new(Some(holder.to_str().unwrap()), &data, false).unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{}", holder.display());
        }
        let err = folder_for_new(Some("/"), &data, false).unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
        // A sibling that is not an ancestor is fine.
        let sibling = tmp.join("deep").join("work");
        std::fs::create_dir_all(&sibling).unwrap();
        assert!(
            folder_for_new(Some(sibling.to_str().unwrap()), &data, false)
                .unwrap()
                .is_some()
        );
        // The whole home folder, even when Bandito's folder is somewhere else.
        if let Some(home) = dirs::home_dir().filter(|h| h.is_dir()) {
            let err = folder_for_new(Some(home.to_str().unwrap()), &data, false).unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{}", home.display());
        }
        // Invisible characters in a path.
        std::fs::create_dir_all(tmp.join("odd")).unwrap();
        let odd = format!("{}\u{200B}", tmp.join("odd").display());
        assert_eq!(
            folder_for_new(Some(&odd), &data, false).unwrap_err().code,
            INVALID_PARAMS
        );
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn a_new_name_may_not_look_like_a_teammate_s_in_any_case_or_alphabet() {
        let w = world(json!({ "approval_mode": "never" }));
        let store = &w.app.sup.hub().store;
        new_agent(store, "COPEX", json!({}));
        new_agent(store, "Ärger", json!({}));
        for (name, like) in [
            ("СОРЕХ", "COPEX"),
            ("copex", "COPEX"),
            ("ärger", "Ärger"),
            ("ÄRGER", "Ärger"),
            ("scout", "Scout"),
        ] {
            let err = create_as(&w, &w.lead, req(json!({ "name": name }))).await.unwrap_err();
            assert_eq!(err.message, format!("invalid: name (looks like {like})"), "{name}");
        }
        // Another name is fine, and the check is not SQLite's ASCII-only case folding.
        create_as(&w, &w.lead, req(json!({ "name": "Почта" }))).await.unwrap();
        // Lookalike letters of the compatibility kind, and invisible ones.
        for name in [
            "Ｍailer",
            "𝐌ailer",
            "Mail\u{FE0F}er",
            "Mail\u{3164}er",
            "Mail\u{2800}er",
        ] {
            let err = create_as(&w, &w.lead, req(json!({ "name": name }))).await.unwrap_err();
            assert!(err.message.starts_with("invalid: name"), "{name:?}: {}", err.message);
        }
    }
}
