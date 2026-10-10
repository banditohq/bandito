//! `agents.templates` and `agents.create_from_template`: the built-in bot templates, and the bot a template makes.
//! `agents.bundles` and `agents.create_bundle` do the same for a bundle of templates (`agent_bundles.json`).
//! The catalog is `agent_templates.json` (see `crate::agent_templates`). The rules are in docs/ARCHITECTURE.md#agent-templates
//! and docs/ARCHITECTURE.md#agent-bundles.

use super::schedules;
use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, create_agent, ok, params};
use crate::agent_bundles;
use crate::agent_templates::{self, AgentTemplate, Effort as TemplateEffort, TemplateSchedule};
use crate::runtime::RuntimeKind;
use crate::schedule_text;
use crate::skills;
use crate::store::{Capability, Effort, NewAgent, NewSchedule, validate_name};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::PathBuf;

/// The integrations catalog, read for the url of an entry: a connected integration may match an entry by url.
const INTEGRATIONS_JSON: &str = include_str!("../integrations_catalog.json");

/// What `agents.create_from_template` takes. `runtime` defaults to the template's, `model` to none.
#[derive(Deserialize)]
struct CreateFromTemplate {
    template_id: String,
    name: String,
    #[serde(default)]
    runtime: Option<String>,
    #[serde(default)]
    model: Option<String>,
    language: String,
    /// Indexes into the template's `schedules`. Absent: the ones with `enabled_by_default`. Present, even empty: exactly
    /// these.
    #[serde(default)]
    schedules: Option<Vec<usize>>,
    #[serde(default)]
    workspace_id: Option<String>,
}

/// What `agents.create_bundle` takes. The bots keep their templates' schedules (`enabled_by_default`) and their models
/// (none).
#[derive(Deserialize)]
struct CreateBundle {
    bundle_id: String,
    language: String,
    #[serde(default)]
    runtime: Option<String>,
    #[serde(default)]
    workspace_id: Option<String>,
}

/// Answers the template and bundle methods. Unknown names get METHOD_NOT_FOUND.
pub(super) async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "agents.templates" => {
            // The file as it is: it is checked by the tests, so this parse cannot fail at run time.
            let catalog: Value = serde_json::from_str(agent_templates::CATALOG_JSON)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent templates: {e}")))?;
            ok(catalog)
        }
        "agents.create_from_template" => {
            let req: CreateFromTemplate = params(p)?;
            let template = agent_templates::find(&req.template_id)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent templates: {e}")))?
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no template {}", req.template_id)))?;
            create_from(app, &template, req).await
        }
        "agents.bundles" => {
            // As with the templates: the file is checked by the tests.
            let catalog: Value = serde_json::from_str(agent_bundles::CATALOG_JSON)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent bundles: {e}")))?;
            ok(catalog)
        }
        "agents.create_bundle" => {
            let req: CreateBundle = params(p)?;
            let bundle = agent_bundles::find(&req.bundle_id)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent bundles: {e}")))?
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no bundle {}", req.bundle_id)))?;
            if req.language.trim().is_empty() {
                return Err(RpcError::new(INVALID_PARAMS, "language is empty"));
            }
            let mut templates = Vec::with_capacity(bundle.templates.len());
            for id in &bundle.templates {
                let template = agent_templates::find(id)
                    .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent templates: {e}")))?
                    .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("bundle {} has no template {id}", bundle.id)))?;
                templates.push(template);
            }
            create_bundle(app, &templates, &req).await
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// Makes one bot per template, in the bundle's order, each the way `agents.create_from_template` makes it. A template
/// that fails (refused before anything is written, or a step after the agent exists) does not stop the rest: its entry
/// carries `error`, and an agent that exists is still named. A name taken by another agent gets " 2", " 3"… (agent
/// names are not unique in the store). `missing_integrations` lists each integration once, `required` when any of the
/// templates requires it.
async fn create_bundle(app: &App, templates: &[AgentTemplate], req: &CreateBundle) -> RpcResult {
    let mut agents: Vec<Value> = Vec::with_capacity(templates.len());
    let mut missing: Vec<(String, bool)> = Vec::new();
    for t in templates {
        let language = resolve_language(t, &req.language);
        let name = match free_name(app, &template_name(t, &language)) {
            Ok(name) => name,
            Err(e) => {
                agents.push(json!({ "template_id": t.id, "error": e.message }));
                continue;
            }
        };
        let request = CreateFromTemplate {
            template_id: t.id.clone(),
            name,
            runtime: req.runtime.clone(),
            model: None,
            language: req.language.clone(),
            schedules: None,
            workspace_id: req.workspace_id.clone(),
        };
        match create_from(app, t, request).await {
            Ok(reply) => {
                for m in reply["missing_integrations"].as_array().into_iter().flatten() {
                    let Some(id) = m["id"].as_str() else { continue };
                    let required = m["required"].as_bool().unwrap_or(false);
                    match missing.iter_mut().find(|(known, _)| known == id) {
                        Some(entry) => entry.1 |= required,
                        None => missing.push((id.to_string(), required)),
                    }
                }
                let mut entry = json!({ "template_id": t.id });
                if !reply["agent"].is_null() {
                    entry["agent"] = reply["agent"].clone();
                }
                let problems: Vec<&str> = reply["errors"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|e| e["message"].as_str())
                    .collect();
                if !problems.is_empty() {
                    entry["error"] = json!(problems.join("; "));
                }
                agents.push(entry);
            }
            Err(e) => agents.push(json!({ "template_id": t.id, "error": e.message })),
        }
    }
    let missing: Vec<Value> = missing
        .into_iter()
        .map(|(id, required)| json!({ "id": id, "required": required }))
        .collect();
    ok(json!({ "agents": agents, "missing_integrations": missing }))
}

/// `base`, or `base 2`, `base 3`… : the first that no agent has, compared without case and outer spaces.
fn free_name(app: &App, base: &str) -> Result<String, RpcError> {
    let taken: HashSet<String> = app
        .sup
        .hub()
        .store
        .agent_list()
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("agents: {e:#}")))?
        .iter()
        .map(|a| a.name.trim().to_lowercase())
        .collect();
    let base = base.trim();
    if !taken.contains(&base.to_lowercase()) {
        return Ok(base.to_string());
    }
    let mut n = 2;
    loop {
        let candidate = format!("{base} {n}");
        if !taken.contains(&candidate.to_lowercase()) {
            return Ok(candidate);
        }
        n += 1;
    }
}

/// The bot's name in `language` (a tag `resolve_language` returned), by the rule of `template_role`.
fn template_name(t: &AgentTemplate, language: &str) -> String {
    match language {
        "ru" => t.name_ru.clone(),
        "en" => t.name_en.clone(),
        other => t
            .l10n
            .get(other)
            .map(|l| l.name.clone())
            .filter(|n| !n.trim().is_empty())
            .unwrap_or_else(|| t.name_en.clone()),
    }
}

/// Makes the bot of `t` as the owner asked. Every check runs before anything is written, so a refusal leaves no
/// agent behind. From the agent's creation on, nothing is rolled back: a step that fails is listed in `errors`, and
/// the reply still names the agent.
async fn create_from(app: &App, t: &AgentTemplate, req: CreateFromTemplate) -> RpcResult {
    let name = req.name.trim().to_string();
    validate_name(&name).map_err(|e| RpcError::new(INVALID_PARAMS, format!("{e:#}")))?;
    let runtime_name = req.runtime.as_deref().unwrap_or(&t.runtime);
    let runtime = RuntimeKind::parse(runtime_name)
        .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("unknown runtime {runtime_name}")))?;
    if req.language.trim().is_empty() {
        return Err(RpcError::new(INVALID_PARAMS, "language is empty"));
    }
    let language = resolve_language(t, &req.language);
    // Every schedule is checked before the agent exists: one bad schedule refuses the whole request.
    let tz = schedule_text::local_zone();
    let indexes = match &req.schedules {
        Some(list) => list.clone(),
        None => (0..t.schedules.len())
            .filter(|&i| t.schedules[i].enabled_by_default)
            .collect(),
    };
    check_schedule_indexes(t, &indexes)?;
    let mut planned = Vec::with_capacity(indexes.len());
    for &index in &indexes {
        let s = &t.schedules[index];
        schedules::check_agent_interval(&s.cron, &tz)?;
        planned.push((index, schedule_prompt(t, index, s, &language)));
    }
    let capabilities = t
        .capabilities
        .iter()
        .map(|c| Capability::parse(c).ok_or_else(|| RpcError::new(SERVER_ERROR, format!("template {} has {c}", t.id))))
        .collect::<Result<Vec<_>, _>>()?;

    // The same defaults as `agents.create` (the serde defaults of NewAgent), then the template's fields.
    let mut new_agent: NewAgent = serde_json::from_value(json!({ "name": name, "runtime": runtime }))
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("agent defaults: {e}")))?;
    new_agent.role = template_role(t, &language);
    new_agent.model = req.model;
    new_agent.system_prompt = Some(t.system_prompt.clone());
    new_agent.effort = t.effort.map(store_effort);
    new_agent.capabilities = Some(capabilities);
    let id = create_agent(app, new_agent, req.workspace_id)?;

    let store = &app.sup.hub().store;
    let mut errors: Vec<Value> = Vec::new();
    // The mark comes first, so the reply's agent carries it. A failure is listed; the agent stays.
    if let Err(e) = store.agent_set_template(&id, &t.id) {
        errors.push(json!({ "step": "agent", "message": format!("agent {id} was created but its template is not saved: {e:#}") }));
    }
    let agent = match store.agent_view(&id) {
        Ok(Some(agent)) => Some(agent),
        Ok(None) => {
            errors.push(json!({ "step": "agent", "message": format!("agent {id} was created but is not found") }));
            None
        }
        Err(e) => {
            errors.push(
                json!({ "step": "agent", "message": format!("agent {id} was created but cannot be read: {e:#}") }),
            );
            None
        }
    };

    let mut skills_installed = Vec::new();
    for skill in &t.skills {
        let Some(agent) = &agent else {
            errors.push(json!({ "step": "skill", "id": skill, "message": "the agent cannot be read: not installed" }));
            continue;
        };
        // The agent's folder is the project scope of `skills.install`.
        let base = PathBuf::from(&agent.cwd);
        let skill_id = skill.clone();
        match tokio::task::spawn_blocking(move || skills::install(&base, &skill_id)).await {
            Ok(Ok(_)) => skills_installed.push(skill.clone()),
            Ok(Err(e)) => errors.push(json!({ "step": "skill", "id": skill, "message": e.message })),
            Err(e) => {
                errors.push(json!({ "step": "skill", "id": skill, "message": format!("skill task failed: {e}") }))
            }
        }
    }

    // Enabled, in the server's time zone, as for the schedules an agent makes itself.
    let mut schedule_ids = Vec::new();
    for (index, prompt) in planned {
        let new = NewSchedule {
            agent_id: id.clone(),
            cron: t.schedules[index].cron.clone(),
            tz: tz.clone(),
            prompt,
            enabled: true,
            title: None,
        };
        match schedules::create(app, new) {
            Ok(view) => schedule_ids.push(view["id"].clone()),
            Err(e) => errors.push(json!({ "step": "schedule", "index": index, "message": e.message })),
        }
    }

    let mut missing_integrations = Vec::new();
    match store.integration_list() {
        Ok(connected) => {
            for wanted in &t.integrations {
                let url = catalog_url(&wanted.id);
                let present = connected
                    .iter()
                    .any(|i| i.enabled && (i.name == wanted.id || (url.is_some() && i.url == url)));
                if !present {
                    missing_integrations.push(json!({ "id": wanted.id, "required": wanted.required }));
                }
            }
        }
        Err(e) => errors.push(json!({ "step": "integrations", "message": format!("{e:#}") })),
    }

    ok(json!({
        "agent": agent,
        "schedule_ids": schedule_ids,
        "skills_installed": skills_installed,
        "missing_integrations": missing_integrations,
        "errors": errors,
    }))
}

/// Every index must name one of the template's schedules, and none may be listed twice.
fn check_schedule_indexes(t: &AgentTemplate, indexes: &[usize]) -> Result<(), RpcError> {
    let mut seen = HashSet::new();
    for &index in indexes {
        if index >= t.schedules.len() {
            return Err(RpcError::new(
                INVALID_PARAMS,
                format!("template {} has no schedule {index}", t.id),
            ));
        }
        if !seen.insert(index) {
            return Err(RpcError::new(
                INVALID_PARAMS,
                format!("schedule {index} is listed twice"),
            ));
        }
    }
    Ok(())
}

/// The prompt of schedule `index` in `language`: `ru` and `en` take the template's own pair. Any other language takes
/// its `l10n` list; English when that list has no prompt for the schedule.
fn schedule_prompt(t: &AgentTemplate, index: usize, s: &TemplateSchedule, language: &str) -> String {
    match language {
        "ru" => s.prompt_ru.clone(),
        "en" => s.prompt_en.clone(),
        other => t
            .l10n
            .get(other)
            .and_then(|l| l.schedule_prompts.get(index))
            .filter(|p| !p.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| s.prompt_en.clone()),
    }
}

/// The bot's role in `language` (a tag `resolve_language` returned), by the rule of the schedule prompts: `ru` and `en`
/// take the template's own role, another language its `l10n` role, English when that is empty.
fn template_role(t: &AgentTemplate, language: &str) -> String {
    match language {
        "ru" => t.role_ru.clone(),
        "en" => t.role_en.clone(),
        other => t
            .l10n
            .get(other)
            .map(|l| l.role.clone())
            .filter(|r| !r.trim().is_empty())
            .unwrap_or_else(|| t.role_en.clone()),
    }
}

/// The language a request names, as the template's schedule prompts know it: `ru`, `en` or a key of `l10n`. Matching
/// ignores case (`pt-br` is `pt-BR`). A tag that matches nothing falls back to its primary subtag (`ru-RU` is `ru`),
/// then to `en`.
fn resolve_language(t: &AgentTemplate, tag: &str) -> String {
    let known = |code: &str| -> Option<String> {
        if code == "ru" || code == "en" {
            return Some(code.to_string());
        }
        t.l10n.keys().find(|k| k.to_lowercase() == code).cloned()
    };
    let lower = tag.trim().to_lowercase();
    known(&lower)
        .or_else(|| known(lower.split(['-', '_']).next().unwrap_or("")))
        .unwrap_or_else(|| "en".to_string())
}

fn store_effort(e: TemplateEffort) -> Effort {
    match e {
        TemplateEffort::Medium => Effort::Medium,
        TemplateEffort::High => Effort::High,
    }
}

/// The url of catalog entry `id`, if the entry has one (stdio entries have none).
fn catalog_url(id: &str) -> Option<String> {
    let entries: Vec<Value> = serde_json::from_str(INTEGRATIONS_JSON).ok()?;
    entries
        .iter()
        .find(|e| e["id"].as_str() == Some(id))
        .and_then(|e| e["url"].as_str())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::Hub;
    use crate::rpc::{Peer, UNAUTHORIZED, dispatch, features};
    use crate::store::{Integration, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use std::sync::Arc;

    /// An app whose agents' folders are in `root`, a temp folder the test made. Its data folder is never used.
    fn app(root: &std::path::Path) -> (Arc<App>, Arc<Store>) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        (App::new(sup, root.join("agents")), store)
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn template(id: &str) -> AgentTemplate {
        agent_templates::find(id).unwrap().expect("a shipped template")
    }

    fn request(template: &str, name: &str, language: &str, schedules: Value) -> Value {
        json!({ "template_id": template, "name": name, "language": language, "schedules": schedules })
    }

    /// The `agents.create_from_template` request without the `schedules` key at all.
    fn request_without_schedules(template: &str, name: &str, language: &str) -> Value {
        json!({ "template_id": template, "name": name, "language": language })
    }

    /// The prompts of the schedules the reply's agent holds, in creation order.
    fn scheduled_prompts(store: &Store, reply: &Value) -> Vec<String> {
        let id = reply["agent"]["id"].as_str().unwrap();
        store
            .schedule_list(Some(id))
            .unwrap()
            .into_iter()
            .map(|s| s.prompt)
            .collect()
    }

    fn connect(store: &Store, value: Value) -> Integration {
        let n = serde_json::from_value(value).unwrap();
        store.integration_create(n).unwrap()
    }

    #[tokio::test]
    async fn templates_are_served_as_the_catalog_and_advertised() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let list = call(&app, "agents.templates", json!({})).await.unwrap();
        let list = list.as_array().unwrap();
        assert_eq!(list.len(), 16);
        assert_eq!(list[0]["id"], "morning-digest");
        assert!(features().contains(&"agent_templates"));
    }

    #[tokio::test]
    async fn create_from_template_makes_the_agent_the_template_describes() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let t = template("code-reviewer");
        let reply = call(
            &app,
            "agents.create_from_template",
            request("code-reviewer", "Reviewer", "ru", json!([0])),
        )
        .await
        .unwrap();

        let agent = &reply["agent"];
        assert_eq!(agent["name"], "Reviewer");
        assert_eq!(
            agent["role"], t.role_ru,
            "the role is in the language the request names (ru)"
        );
        assert_eq!(agent["system_prompt"], t.system_prompt);
        assert_eq!(agent["runtime"], "claude", "the template's runtime by default");
        assert_eq!(agent["capabilities"], json!(t.capabilities));
        assert_eq!(reply["errors"], json!([]));
        assert_eq!(reply["skills_installed"], json!([]));

        let id = agent["id"].as_str().unwrap();
        let schedules = store.schedule_list(Some(id)).unwrap();
        assert_eq!(schedules.len(), 1);
        assert_eq!(schedules[0].prompt, t.schedules[0].prompt_ru);
        assert_eq!(schedules[0].cron, t.schedules[0].cron);
        assert!(schedules[0].enabled, "the owner chose it, so it is on");
        assert_eq!(reply["schedule_ids"], json!([schedules[0].id]));
    }

    #[tokio::test]
    async fn the_role_follows_the_language_ru_de_and_unknown_falls_back_to_english() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let t = template("morning-digest");
        let cases = [
            ("ru", t.role_ru.clone()),
            ("de", t.l10n["de"].role.clone()),
            ("xx", t.role_en.clone()),
        ];
        for (language, expected) in cases {
            let reply = call(
                &app,
                "agents.create_from_template",
                request("morning-digest", &format!("Role {language}"), language, json!([])),
            )
            .await
            .unwrap();
            assert_eq!(reply["agent"]["role"], expected, "{language}");
        }
    }

    #[tokio::test]
    async fn schedules_follow_the_language_ru_de_and_unknown_falls_back_to_english() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let t = template("morning-digest");
        let cases = [
            ("ru", t.schedules[0].prompt_ru.clone()),
            ("de", t.l10n["de"].schedule_prompts[0].clone()),
            ("xx", t.schedules[0].prompt_en.clone()),
        ];
        for (language, expected) in cases {
            let reply = call(
                &app,
                "agents.create_from_template",
                request("morning-digest", &format!("Digest {language}"), language, json!([0])),
            )
            .await
            .unwrap();
            let id = reply["agent"]["id"].as_str().unwrap();
            let schedules = store.schedule_list(Some(id)).unwrap();
            assert_eq!(schedules[0].prompt, expected, "{language}");
        }
    }

    #[tokio::test]
    async fn a_skill_of_the_template_is_installed_and_a_failed_one_is_listed() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        // The shipped templates list no skills yet, so the test gives one in code.
        let mut t = template("code-reviewer");
        t.skills = vec!["systematic-debugging".into(), "no-such-skill".into()];
        let req: CreateFromTemplate =
            serde_json::from_value(request("code-reviewer", "Skilled", "en", json!([]))).unwrap();
        let reply = create_from(&app, &t, req).await.unwrap();

        assert_eq!(reply["skills_installed"], json!(["systematic-debugging"]));
        let cwd = PathBuf::from(reply["agent"]["cwd"].as_str().unwrap());
        assert!(cwd.join(".claude/skills/systematic-debugging/SKILL.md").is_file());
        assert!(cwd.join(".claude/skills/systematic-debugging/.bandito-skill").is_file());
        let errors = reply["errors"].as_array().unwrap();
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert_eq!(errors[0]["step"], "skill");
        assert_eq!(errors[0]["id"], "no-such-skill");
        // The agent stays, and the reply says what went wrong.
        assert_eq!(store.agent_list().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn a_missing_required_integration_is_reported_and_a_connected_one_is_not() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let first = call(
            &app,
            "agents.create_from_template",
            request("task-manager", "Tasks", "en", json!([])),
        )
        .await
        .unwrap();
        assert_eq!(
            first["missing_integrations"],
            json!([
                { "id": "linear", "required": true },
                { "id": "notion", "required": false },
                { "id": "atlassian", "required": false },
            ])
        );

        // Connected by name, linear is no longer missing. A disabled notion does not count as connected.
        connect(
            &store,
            json!({ "name": "linear", "kind": "http", "url": "https://mcp.linear.app/mcp" }),
        );
        connect(
            &store,
            json!({ "name": "notion", "kind": "http", "url": "https://mcp.notion.com/mcp", "enabled": false }),
        );
        let second = call(
            &app,
            "agents.create_from_template",
            request("task-manager", "Tasks 2", "en", json!([])),
        )
        .await
        .unwrap();
        assert_eq!(
            second["missing_integrations"],
            json!([
                { "id": "notion", "required": false },
                { "id": "atlassian", "required": false },
            ])
        );
    }

    #[tokio::test]
    async fn a_connected_integration_matches_by_catalog_url_too() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        connect(
            &store,
            json!({ "name": "My Linear", "kind": "http", "url": "https://mcp.linear.app/mcp" }),
        );
        let reply = call(
            &app,
            "agents.create_from_template",
            request("task-manager", "Tasks", "en", json!([])),
        )
        .await
        .unwrap();
        let missing: Vec<&str> = reply["missing_integrations"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert!(!missing.contains(&"linear"), "{missing:?}");
    }

    #[tokio::test]
    async fn bad_requests_are_refused_before_anything_is_created() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let cases = [
            (request("nope", "Ok", "en", json!([])), "unknown template"),
            (request("code-reviewer", "   ", "en", json!([])), "empty name"),
            (request("code-reviewer", "Bad/Name", "en", json!([])), "name characters"),
            (request("code-reviewer", "Ok", "en", json!([1])), "index out of range"),
            (
                request("code-reviewer", "Ok", "en", json!([0, 0])),
                "index listed twice",
            ),
            (
                json!({ "template_id": "code-reviewer", "name": "Ok", "language": "en", "runtime": "nope" }),
                "unknown runtime",
            ),
        ];
        for (p, why) in cases {
            let err = call(&app, "agents.create_from_template", p).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{why}");
        }
        assert!(store.agent_list().unwrap().is_empty(), "nothing was created");
    }

    #[test]
    fn resolve_language_matches_case_then_primary_subtag_then_english() {
        let t = template("morning-digest");
        for (tag, want) in [
            ("zh-hans", "zh-Hans"),
            ("pt-br", "pt-BR"),
            ("ja-JP", "ja"),
            ("en-GB", "en"),
            ("RU", "ru"),
            ("xx", "en"),
            ("", "en"),
        ] {
            assert_eq!(resolve_language(&t, tag), want, "{tag}");
        }
    }

    #[tokio::test]
    async fn language_tags_pick_the_prompt_they_name() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let t = template("morning-digest");
        let cases = [
            ("ru-RU", t.schedules[0].prompt_ru.clone()),
            ("RU", t.schedules[0].prompt_ru.clone()),
            ("pt-br", t.l10n["pt-BR"].schedule_prompts[0].clone()),
            ("de-DE", t.l10n["de"].schedule_prompts[0].clone()),
            ("xx", t.schedules[0].prompt_en.clone()),
        ];
        for (i, (language, expected)) in cases.into_iter().enumerate() {
            let name = format!("Lang {i}");
            let reply = call(
                &app,
                "agents.create_from_template",
                request("morning-digest", &name, language, json!([0])),
            )
            .await
            .unwrap();
            assert_eq!(scheduled_prompts(&store, &reply), vec![expected], "{language}");
        }
    }

    #[tokio::test]
    async fn a_bad_schedule_refuses_the_request_before_the_agent_exists() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let mut t = template("code-reviewer");
        let mut every_minute = t.schedules[0].clone();
        every_minute.cron = "* * * * *".into();
        let mut broken = t.schedules[0].clone();
        broken.cron = "61 * * * *".into();
        t.schedules.push(every_minute); // index 1: runs closer than the 5-minute gap
        t.schedules.push(broken); // index 2: not a cron
        for indexes in [json!([1]), json!([0, 1]), json!([2])] {
            let req: CreateFromTemplate =
                serde_json::from_value(request("code-reviewer", "Checked", "en", indexes.clone())).unwrap();
            let err = create_from(&app, &t, req).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{indexes}");
        }
        assert!(store.agent_list().unwrap().is_empty(), "no agent was created");
    }

    #[tokio::test]
    async fn schedules_default_to_the_enabled_ones_and_a_given_list_is_exact() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        // The shipped catalog: morning-digest's schedule is on by default, code-reviewer's is not.
        let digest = call(
            &app,
            "agents.create_from_template",
            request_without_schedules("morning-digest", "Default digest", "en"),
        )
        .await
        .unwrap();
        assert_eq!(scheduled_prompts(&store, &digest).len(), 1);
        let review = call(
            &app,
            "agents.create_from_template",
            request_without_schedules("code-reviewer", "Default review", "en"),
        )
        .await
        .unwrap();
        assert!(scheduled_prompts(&store, &review).is_empty());
        let empty = call(
            &app,
            "agents.create_from_template",
            request("morning-digest", "Empty digest", "en", json!([])),
        )
        .await
        .unwrap();
        assert!(scheduled_prompts(&store, &empty).is_empty(), "an empty list means none");

        // A template in code with one schedule off (index 0) and one on (index 1).
        let mut t = template("code-reviewer");
        let mut off = t.schedules[0].clone();
        off.enabled_by_default = false;
        off.cron = "0 10 * * *".into();
        off.prompt_en = "Off by default".into();
        let mut on = t.schedules[0].clone();
        on.enabled_by_default = true;
        on.prompt_en = "On by default".into();
        t.schedules = vec![off, on];
        let cases = [
            (
                request_without_schedules("code-reviewer", "Pick on", "en"),
                vec!["On by default"],
            ),
            (
                request("code-reviewer", "Pick off", "en", json!([0])),
                vec!["Off by default"],
            ),
        ];
        for (i, (p, want)) in cases.into_iter().enumerate() {
            let mut p = p;
            p["name"] = json!(format!("Pick {i}"));
            let req: CreateFromTemplate = serde_json::from_value(p).unwrap();
            let reply = create_from(&app, &t, req).await.unwrap();
            assert_eq!(scheduled_prompts(&store, &reply), want);
        }
    }

    #[tokio::test]
    async fn an_agent_made_from_a_template_is_marked_and_the_mark_is_read_back() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let made = call(
            &app,
            "agents.create_from_template",
            request("code-reviewer", "Marked", "en", json!([])),
        )
        .await
        .unwrap();
        assert_eq!(made["agent"]["template_id"], "code-reviewer");
        let id = made["agent"]["id"].as_str().unwrap().to_string();

        let got = call(&app, "agents.get", json!({ "id": id })).await.unwrap();
        assert_eq!(got["template_id"], "code-reviewer");
        let listed = call(&app, "agents.list", json!({})).await.unwrap();
        let mine = listed.as_array().unwrap().iter().find(|a| a["id"] == id).unwrap();
        assert_eq!(mine["template_id"], "code-reviewer");

        // Not accepted on the wire: an update leaves the mark as it is.
        let updated = call(&app, "agents.update", json!({ "id": id, "template_id": "nope" }))
            .await
            .unwrap();
        assert_eq!(updated["template_id"], "code-reviewer");
    }

    #[tokio::test]
    async fn agents_create_ignores_a_template_id_and_leaves_the_mark_empty() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let created = call(
            &app,
            "agents.create",
            json!({ "name": "Hand made", "runtime": "claude", "template_id": "code-reviewer" }),
        )
        .await
        .unwrap();
        assert_eq!(created["template_id"], Value::Null);
        assert_eq!(created["name"], "Hand made");
    }

    #[tokio::test]
    async fn agents_cannot_list_or_create_from_templates() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let agent = Peer::Agent("agent-a".into());
        for (method, p) in [
            ("agents.templates", json!({})),
            (
                "agents.create_from_template",
                request("code-reviewer", "Sneaky", "en", json!([0])),
            ),
        ] {
            let err = dispatch(&app, &agent, method, p).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
        assert!(store.agent_list().unwrap().is_empty());
    }

    /// The entry of `template` in a `create_bundle` reply.
    fn entry<'a>(reply: &'a Value, template: &str) -> &'a Value {
        reply["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["template_id"] == template)
            .unwrap_or_else(|| panic!("no entry for {template}"))
    }

    fn bundle_request(bundle: &str, language: &str) -> Value {
        json!({ "bundle_id": bundle, "language": language })
    }

    const STARTUP_TEAM: [&str; 4] = ["task-manager", "code-reviewer", "sentry-on-call", "docs-writer"];

    #[tokio::test]
    async fn bundles_are_served_as_the_catalog_and_advertised() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let list = call(&app, "agents.bundles", json!({})).await.unwrap();
        let list = list.as_array().unwrap();
        assert_eq!(list.len(), 6);
        assert_eq!(list[0]["id"], "startup-team");
        assert!(features().contains(&"agent_bundles"));
    }

    #[tokio::test]
    async fn a_bundle_makes_one_bot_per_template_in_the_language_with_its_schedules() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let reply = call(&app, "agents.create_bundle", bundle_request("startup-team", "ru"))
            .await
            .unwrap();

        assert_eq!(reply["agents"].as_array().unwrap().len(), 4);
        assert_eq!(store.agent_list().unwrap().len(), 4);
        for id in STARTUP_TEAM {
            let t = template(id);
            let e = entry(&reply, id);
            assert!(e.get("error").is_none(), "{id}: {e}");
            let agent = &e["agent"];
            assert_eq!(agent["name"], t.name_ru, "{id}");
            assert_eq!(agent["role"], t.role_ru, "{id}");
            assert_eq!(agent["template_id"], id);
            assert_eq!(agent["system_prompt"], t.system_prompt);
            let agent_id = agent["id"].as_str().unwrap();
            let enabled = t.schedules.iter().filter(|s| s.enabled_by_default).count();
            assert_eq!(store.schedule_list(Some(agent_id)).unwrap().len(), enabled, "{id}");
        }
        assert_eq!(reply["missing_integrations"].as_array().unwrap().len(), 6);
    }

    #[tokio::test]
    async fn a_bundle_in_another_language_takes_its_own_names_and_roles() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let reply = call(&app, "agents.create_bundle", bundle_request("content-studio", "de"))
            .await
            .unwrap();
        let t = template("translator");
        let l = &t.l10n["de"];
        let agent = &entry(&reply, "translator")["agent"];
        assert_eq!(agent["name"], l.name.as_str());
        assert_eq!(agent["role"], l.role.as_str());
    }

    #[tokio::test]
    async fn a_name_taken_by_another_agent_gets_a_number() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let reviewer = template("code-reviewer");
        // The owner already has a bot named like the template, in another case.
        call(
            &app,
            "agents.create_from_template",
            request("code-reviewer", &reviewer.name_ru.to_uppercase(), "ru", json!([0])),
        )
        .await
        .unwrap();

        let first = call(&app, "agents.create_bundle", bundle_request("startup-team", "ru"))
            .await
            .unwrap();
        assert_eq!(
            entry(&first, "code-reviewer")["agent"]["name"],
            format!("{} 2", reviewer.name_ru)
        );
        let second = call(&app, "agents.create_bundle", bundle_request("startup-team", "ru"))
            .await
            .unwrap();
        assert_eq!(
            entry(&second, "code-reviewer")["agent"]["name"],
            format!("{} 3", reviewer.name_ru)
        );
        assert_eq!(
            entry(&second, "task-manager")["agent"]["name"],
            format!("{} 2", template("task-manager").name_ru)
        );
    }

    #[tokio::test]
    async fn one_template_that_fails_does_not_stop_the_others() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        // A template the daemon refuses at run time: an unknown runtime (the shipped ones are all valid).
        let mut broken = template("code-reviewer");
        broken.runtime = "no-such-runtime".into();
        let templates = vec![template("task-manager"), broken, template("docs-writer")];
        let req = CreateBundle {
            bundle_id: "startup-team".into(),
            language: "en".into(),
            runtime: None,
            workspace_id: None,
        };
        let reply = create_bundle(&app, &templates, &req).await.unwrap();

        let refused = entry(&reply, "code-reviewer");
        assert!(refused.get("agent").is_none(), "{refused}");
        assert!(
            refused["error"].as_str().unwrap().contains("unknown runtime"),
            "{refused}"
        );
        assert_eq!(
            entry(&reply, "task-manager")["agent"]["name"],
            template("task-manager").name_en
        );
        assert_eq!(
            entry(&reply, "docs-writer")["agent"]["name"],
            template("docs-writer").name_en
        );
        assert_eq!(store.agent_list().unwrap().len(), 2, "the refused one left no agent");
    }

    #[tokio::test]
    async fn missing_integrations_are_listed_once_and_required_if_any_template_needs_them() {
        let dir = tempfile::tempdir().unwrap();
        let (app, _) = app(dir.path());
        let reply = call(&app, "agents.create_bundle", bundle_request("startup-team", "en"))
            .await
            .unwrap();
        // `github` is required by code-reviewer and optional for sentry-on-call.
        let mut expected = std::collections::BTreeMap::new();
        for id in STARTUP_TEAM {
            for i in template(id).integrations {
                let e = expected.entry(i.id).or_insert(false);
                *e |= i.required;
            }
        }
        let listed = reply["missing_integrations"].as_array().unwrap();
        let mut got = std::collections::BTreeMap::new();
        for m in listed {
            let id = m["id"].as_str().unwrap().to_string();
            assert!(
                got.insert(id.clone(), m["required"].as_bool().unwrap()).is_none(),
                "{id} listed twice"
            );
        }
        assert_eq!(got, expected);
        assert!(got["github"]);
    }

    #[tokio::test]
    async fn a_bundle_request_that_is_wrong_is_refused_before_anything_is_created() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        for p in [
            bundle_request("no-such-bundle", "en"),
            bundle_request("startup-team", "  "),
        ] {
            let err = call(&app, "agents.create_bundle", p).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS);
        }
        assert!(store.agent_list().unwrap().is_empty());
    }

    #[tokio::test]
    async fn agents_cannot_list_or_create_bundles() {
        let dir = tempfile::tempdir().unwrap();
        let (app, store) = app(dir.path());
        let agent = Peer::Agent("agent-a".into());
        for (method, p) in [
            ("agents.bundles", json!({})),
            ("agents.create_bundle", bundle_request("startup-team", "en")),
        ] {
            let err = dispatch(&app, &agent, method, p).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
        assert!(store.agent_list().unwrap().is_empty());
    }

    #[test]
    fn every_bundle_name_is_a_valid_agent_name_in_every_language() {
        const TAGS: [&str; 9] = ["en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"];
        for b in agent_bundles::catalog().unwrap() {
            for id in &b.templates {
                let t = template(id);
                for tag in TAGS {
                    let name = template_name(&t, &resolve_language(&t, tag));
                    assert!(crate::store::validate_name(&name).is_ok(), "{id} {tag}: {name:?}");
                    assert!(
                        name.chars().count() <= 29,
                        "{id} {tag}: {name:?} leaves no room for a number"
                    );
                }
            }
        }
    }
}
