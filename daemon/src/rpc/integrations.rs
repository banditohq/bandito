//! `integrations.*` JSON-RPC methods: the owner's MCP servers for the agents, the template catalog, and a test
//! that starts a server and lists its tools. Owner and apps only. See docs/ARCHITECTURE.md#integrations.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::integrations::{self, Pair, Server, Transport};
use crate::mcp_oauth::{self, Outcome, Target, Why};
use crate::recommend;
use crate::redact::Redactor;
use crate::store::{Integration, IntegrationAuth, IntegrationPatch, IntegrationTool, NewIntegration, Store, now_ms};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

/// How long `integrations.test` may take, end to end.
const TEST_TIMEOUT: Duration = Duration::from_secs(15);

/// How long `integrations.call_tool` may take, end to end.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// How much text a tool's answer keeps, in all (`integrations.call_tool`); the structured content too, when it fits.
const CALL_TEXT_BYTES: usize = 64 * 1024;

/// The largest input schema kept for a tool; a larger one is kept as none.
const SCHEMA_BYTES: usize = 32 * 1024;

/// The catalog: ready templates for the owner to add, built into the daemon.
const CATALOG_JSON: &str = include_str!("../integrations_catalog.json");

#[derive(Deserialize)]
struct Id {
    id: String,
}

#[derive(Deserialize)]
struct UpdateParams {
    id: String,
    #[serde(flatten)]
    patch: IntegrationPatch,
}

#[derive(Deserialize)]
struct BeginParams {
    #[serde(default)]
    integration: Option<String>,
    #[serde(default)]
    draft: Option<NewIntegration>,
    /// A client registered with the service beforehand, for one without dynamic registration.
    #[serde(default)]
    client_id: Option<String>,
}

#[derive(Deserialize)]
struct CompleteParams {
    state: String,
    code: String,
    #[serde(default)]
    iss: Option<String>,
}

#[derive(Deserialize)]
struct StateParams {
    state: String,
}

#[derive(Deserialize)]
struct StatusParams {
    #[serde(default)]
    id: Option<String>,
}

#[derive(Deserialize)]
struct CallParams {
    id: String,
    tool: String,
    #[serde(default)]
    arguments: Option<Value>,
}

#[derive(Deserialize)]
struct DisconnectParams {
    id: String,
    /// Also delete the integration.
    #[serde(default)]
    remove: bool,
}

fn invalid(e: anyhow::Error) -> RpcError {
    RpcError::new(INVALID_PARAMS, format!("{e:#}"))
}

fn no_integration(id: &str) -> RpcError {
    RpcError::new(SERVER_ERROR, format!("no integration {id}"))
}

/// The templates of the built-in catalog, as far as the update checks need them.
fn catalog_templates() -> Result<Vec<integrations::Template>, RpcError> {
    serde_json::from_str(CATALOG_JSON).map_err(|e| RpcError::new(SERVER_ERROR, format!("catalog: {e}")))
}

/// The ids of the agents that get the integration in their sessions.
fn users_of(store: &Store, id: &str) -> Vec<String> {
    store
        .agent_list()
        .unwrap_or_default()
        .into_iter()
        .filter(|a| a.integrations.as_ref().is_none_or(|ids| ids.iter().any(|i| i == id)))
        .map(|a| a.id)
        .collect()
}

/// Their sessions start again from the next turn, with the token that is there now.
async fn reload_agents(app: &App, agents: Vec<String>) {
    for id in agents {
        app.sup.reload(&id, None).await;
    }
}

/// Renews the tokens that end soon, once a minute, and renews the sessions that held the old ones.
pub fn spawn_oauth_refresher(app: Arc<App>) {
    let mut renewed = mcp_oauth::renewed();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tokio::select! {
                _ = tick.tick() => {
                    mcp_oauth::refresh_due(&app.sup.hub().store, now_ms()).await;
                    // Whoever renewed a token meanwhile (a session start, a test, a retry), every agent that has
                    // the integration is looked at: the session itself compares the token and leaves the rest.
                    reload_sessions(&app, None).await;
                }
                got = renewed.recv() => match got {
                    Ok(id) => reload_sessions(&app, Some(&id)).await,
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => reload_sessions(&app, None).await,
                    Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                },
            }
        }
    });
}

/// Renews the session of each agent that has a browser-sign-in integration (`only`: that one), if the session runs
/// with an older token of it. An agent without a session, or with the current token, is left alone.
pub(crate) async fn reload_sessions(app: &App, only: Option<&str>) {
    let store = &app.sup.hub().store;
    let rows = match store.integration_list() {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!("integration list for the sessions: {e:#}");
            return;
        }
    };
    for row in rows
        .iter()
        .filter(|r| r.auth == IntegrationAuth::Oauth && only.is_none_or(|id| id == r.id))
    {
        for agent in users_of(store, &row.id) {
            app.sup.reload_for_tokens(&agent, vec![row.id.clone()]).await;
        }
    }
}

async fn oauth_dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    let store = &app.sup.hub().store;
    let device = super::redeem_source(peer);
    match method {
        "integrations.oauth_begin" => {
            let BeginParams {
                integration,
                draft,
                client_id,
            } = params(p)?;
            let target = match (integration, draft) {
                (Some(id), None) => Target::Existing(store.integration_get(&id)?.ok_or_else(|| no_integration(&id))?),
                (None, Some(draft)) => {
                    check_new(&draft)?;
                    if store.integration_list()?.iter().any(|i| i.name == draft.name) {
                        return Err(RpcError::new(
                            INVALID_PARAMS,
                            format!("an integration named '{}' already exists", draft.name),
                        ));
                    }
                    Target::Draft(draft)
                }
                _ => return Err(RpcError::new(INVALID_PARAMS, "give either integration or draft")),
            };
            let now = now_ms();
            let begun = mcp_oauth::begin(store, &app.oauth, &device, target, client_id, now)
                .await
                .map_err(invalid)?;
            ok(json!({
                "authorize_url": begun.authorize_url,
                "state": begun.state,
                "expires_at": now + mcp_oauth::FLOW_TTL_MS,
            }))
        }
        "integrations.oauth_complete" => {
            let CompleteParams { state, code, iss } = params(p)?;
            let now = now_ms();
            let done = mcp_oauth::complete(store, &app.oauth, &device, &state, &code, iss.as_deref(), now)
                .await
                .map_err(invalid)?;
            let id = done.integration.id.clone();
            reload_agents(app, users_of(store, &id)).await;
            let status = mcp_oauth::status(store, &id, now)?;
            ok(json!({
                "id": id,
                "name": done.integration.name,
                "created": done.created,
                "status": status.status,
                "expires_at": status.expires_at,
                "error": status.error,
            }))
        }
        "integrations.oauth_cancel" => {
            let StateParams { state } = params(p)?;
            ok(json!({ "cancelled": app.oauth.cancel(&state, &device) }))
        }
        "integrations.oauth_status" => {
            let StatusParams { id } = params(p)?;
            let now = now_ms();
            let mut items = Vec::new();
            for row in store.integration_list()? {
                if row.auth != IntegrationAuth::Oauth || id.as_ref().is_some_and(|id| *id != row.id) {
                    continue;
                }
                let s = mcp_oauth::status(store, &row.id, now)?;
                items.push(json!({
                    "id": row.id,
                    "name": row.name,
                    "status": s.status,
                    "expires_at": s.expires_at,
                    "scope": s.scope,
                    "error": s.error,
                }));
            }
            ok(json!({ "integrations": items }))
        }
        "integrations.oauth_disconnect" => {
            let DisconnectParams { id, remove } = params(p)?;
            let row = store.integration_get(&id)?.ok_or_else(|| no_integration(&id))?;
            if row.auth != IntegrationAuth::Oauth {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    "that integration does not sign in in the browser",
                ));
            }
            let users = users_of(store, &id);
            let revoked = mcp_oauth::disconnect(store, &row, remove).await?;
            if remove {
                store.integration_delete(&id)?;
            }
            reload_agents(app, users).await;
            ok(json!({ "revoked": revoked, "removed": remove }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    if method.starts_with("integrations.oauth_") {
        return oauth_dispatch(app, peer, method, p).await;
    }
    let store = &app.sup.hub().store;
    match method {
        "integrations.list" => {
            // Each row, with `template_update: {from, to}` when its catalog template has moved on (see `template_update`).
            let templates = catalog_templates()?;
            let mut items = Vec::new();
            for row in store.integration_list()? {
                let mut item = serde_json::to_value(&row).map_err(|e| RpcError::new(SERVER_ERROR, e.to_string()))?;
                if let Some(update) = integrations::template_update(&row, &templates) {
                    item["template_update"] = json!({ "from": update.from, "to": update.to });
                }
                items.push(item);
            }
            ok(items)
        }
        "integrations.update_from_template" => {
            // Only command, args and url change; secrets, headers, env, enabled and the agents stay as they are. Like
            // `integrations.update`, it neither restarts sessions nor sends an event.
            let Id { id } = params(p)?;
            let cur = store
                .integration_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no integration {id}")))?;
            let templates = catalog_templates()?;
            let update = integrations::template_update(&cur, &templates).ok_or_else(|| {
                RpcError::new(
                    INVALID_PARAMS,
                    "this integration has no update from its catalog template",
                )
            })?;
            let patch = IntegrationPatch {
                command: Some(update.template.command.clone()),
                args: Some(update.template.args.clone()),
                url: Some(update.template.url.clone()),
                ..IntegrationPatch::default()
            };
            check_definition(&apply(&cur, &patch))?;
            ok(store.integration_update(&id, patch)?)
        }
        "integrations.catalog" => ok(serde_json::from_str::<Value>(CATALOG_JSON)
            .map_err(|e| RpcError::new(SERVER_ERROR, format!("catalog: {e}")))?),
        "integrations.add" => {
            let n: NewIntegration = params(p.clone())?;
            if n.auth == IntegrationAuth::Oauth {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    "a browser sign-in is started with integrations.oauth_begin",
                ));
            }
            // What the tools may do can be named when the row is added; without it the row starts as the catalog says.
            let tools: ToolWords = params(p)?;
            check_tool_overrides(tools.tool_overrides.as_ref())?;
            check_new_name(&n.name)?;
            check_new(&n)?;
            if store.integration_list()?.iter().any(|i| i.name == n.name) {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("an integration named '{}' already exists", n.name),
                ));
            }
            let made = store.integration_create(n)?;
            if tools.tool_mode.is_some() || tools.tool_overrides.is_some() {
                let patch = IntegrationPatch {
                    tool_mode: tools.tool_mode,
                    tool_overrides: tools.tool_overrides,
                    ..Default::default()
                };
                let done = store.integration_update(&made.id, patch)?;
                // A new service whose tools are limited from the start: the sessions that would get it are
                // started again, so Claude is told to send its calls to the daemon.
                reload_agents(app, users_of(store, &done.id)).await;
                return ok(done);
            }
            ok(made)
        }
        "integrations.update" => {
            let UpdateParams { id, patch } = params(p)?;
            check_tool_overrides(patch.tool_overrides.as_ref())?;
            let cur = store
                .integration_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no integration {id}")))?;
            // Check the row as it will be after the patch.
            let after = apply(&cur, &patch);
            check_definition(&after)?;
            if cur.auth == IntegrationAuth::Oauth && (after.url != cur.url || after.kind != cur.kind) {
                // The tokens are for that server: another address needs another sign-in.
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    "disconnect the sign-in before changing the address",
                ));
            }
            if let Some(name) = patch.name.as_deref().filter(|n| *n != cur.name) {
                check_new_name(name)?;
            }
            if patch.name.as_deref().is_some_and(|n| n != cur.name)
                && store
                    .integration_list()?
                    .iter()
                    .any(|i| Some(&i.name) == patch.name.as_ref())
            {
                return Err(RpcError::new(INVALID_PARAMS, "that name is taken"));
            }
            let changes_tool_rules = changes_tool_rules(&patch);
            let updated = store.integration_update(&id, patch)?;
            if changes_tool_rules {
                // The agents that have the service start their sessions again, with the new rules: Claude lists
                // the service's calls as `permissions.ask` when the session starts.
                reload_agents(app, users_of(store, &id)).await;
            }
            ok(updated)
        }
        "integrations.remove" => {
            let Id { id } = params(p)?;
            if let Some(row) = store.integration_get(&id)?.filter(|r| r.auth == IntegrationAuth::Oauth) {
                // Its tokens go with it, and the service is told (a refusal there does not stop the removal).
                mcp_oauth::disconnect(store, &row, true).await?;
            }
            ok(json!({ "deleted": store.integration_delete(&id)? }))
        }
        "integrations.test" => {
            let Id { id } = params(p)?;
            let cur = store
                .integration_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no integration {id}")))?;
            probe_row(store, &cur, false).await
        }
        "integrations.tools" => {
            // The tools the last successful test listed, with their annotations (see docs/ARCHITECTURE.md#integrations).
            let Id { id } = params(p)?;
            if store.integration_get(&id)?.is_none() {
                return Err(no_integration(&id));
            }
            ok(store.integration_tools(&id)?)
        }
        "integrations.call_tool" => {
            let CallParams { id, tool, arguments } = params(p)?;
            if tool.trim().is_empty() {
                return Err(RpcError::new(INVALID_PARAMS, "name the tool to call"));
            }
            let arguments = match arguments {
                None | Some(Value::Null) => json!({}),
                Some(v @ Value::Object(_)) => v,
                Some(_) => return Err(RpcError::new(INVALID_PARAMS, "arguments must be an object")),
            };
            let cur = store.integration_get(&id)?.ok_or_else(|| no_integration(&id))?;
            if !cur.enabled {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("{} is turned off: turn it on to use its tools", cur.name),
                ));
            }
            // With a list from an earlier test, the tool must be on it; without one, any name is asked.
            let listed = store.integration_tools(&id)?;
            if !listed.is_empty() && !listed.iter().any(|t| t.name == tool) {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!(
                        "{} has no tool named {tool}: run its test to refresh the list",
                        cur.name
                    ),
                ));
            }
            match reach(store, &cur, false, &call_request(&tool, &arguments), CALL_TIMEOUT).await {
                Ok(reply) => ok(call_answer(&reply.result, &Redactor::exact(reply.secrets))),
                Err(Refused::SignIn) => Err(RpcError::new(SERVER_ERROR, "sign in to this service again")),
                Err(Refused::Failed(e)) => Err(RpcError::new(SERVER_ERROR, format!("{e:#}"))),
            }
        }
        "integrations.probe" => {
            #[derive(Deserialize)]
            struct ProbeParams {
                draft: NewIntegration,
            }
            let ProbeParams { draft } = params(p)?;
            check_new(&draft)?;
            // Nothing is saved: the draft runs as a row without an id, and its values stay in memory.
            probe_row(store, &draft_row(&draft), true).await
        }
        "integrations.recommend" => {
            #[derive(Deserialize)]
            struct RecommendParams {
                agent_id: String,
            }
            let RecommendParams { agent_id } = params(p)?;
            let agent = store
                .agent_get(&agent_id)?
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no agent {agent_id}")))?;
            // The agent's folder is its cwd when that is a path, else its home folder.
            let Some(folder) = [Some(agent.cwd.as_str()), agent.home_dir.as_deref()]
                .into_iter()
                .flatten()
                .find(|d| d.starts_with('/'))
                .map(PathBuf::from)
            else {
                return ok(json!([]));
            };
            let catalog: Vec<recommend::Template> =
                serde_json::from_str(CATALOG_JSON).map_err(|e| RpcError::new(SERVER_ERROR, format!("catalog: {e}")))?;
            let rows = store.integration_list()?;
            // The rules read a few small files and list folders: off the event loop.
            let found = tokio::task::spawn_blocking(move || recommend::for_folder(&folder, &catalog, &rows))
                .await
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("recommend: {e}")))?;
            ok(found)
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// Why a server could not be asked: its browser sign-in is over (the owner signs in again), or the exchange failed.
enum Refused {
    SignIn,
    Failed(anyhow::Error),
}

/// A server's answer to the request, with the secret values it was asked with (what its answer must not show).
struct Reply {
    result: Value,
    secrets: Vec<(String, String)>,
}

/// Asks the row's server once with `request` (the handshake first), as `integrations.test` and `integrations.call_tool`
/// do. A browser sign-in renews its token first when that is about to end, and once more after the service refused it
/// (HTTP 401), then asks again. With `draft`, every value of the row's environment and headers is a secret: the owner
/// typed them and they are not stored.
async fn reach(
    store: &Store,
    row: &Integration,
    draft: bool,
    request: &Value,
    limit: Duration,
) -> Result<Reply, Refused> {
    let oauth = row.auth == IntegrationAuth::Oauth;
    if oauth {
        // A token that is about to end is renewed first.
        match mcp_oauth::refresh(store, &row.id, Why::Expiring(mcp_oauth::SESSION_SKEW_MS), now_ms()).await {
            Ok(Outcome::NeedsLogin) => return Err(Refused::SignIn),
            Ok(_) => {}
            Err(e) => tracing::warn!(integration = row.name, "{e:#}"),
        }
    }
    let mut result = run_once(store, row, draft, request, limit).await;
    if oauth
        && let Err(e) = &result
        && e.downcast_ref::<HttpStatus>().is_some_and(|s| s.0 == 401)
        && let Some(stale) = mcp_oauth::access_token(store, &row.id).map_err(Refused::Failed)?
    {
        // The service refused the token: renew it once and try again.
        match mcp_oauth::refresh(store, &row.id, Why::Rejected(stale), now_ms()).await {
            Ok(Outcome::Refreshed | Outcome::Unchanged | Outcome::Waiting) => {
                result = run_once(store, row, draft, request, limit).await;
            }
            Ok(Outcome::NeedsLogin) => return Err(Refused::SignIn),
            Err(e) => tracing::warn!(integration = row.name, "{e:#}"),
        }
    }
    result.map_err(Refused::Failed)
}

/// One exchange with the row's server, with the secrets it names read now. A failure's text has every secret value of
/// the server hidden (`••••NAME`), as the stderr tail always was; a 401 keeps its type for the renewal.
async fn run_once(
    store: &Store,
    row: &Integration,
    draft: bool,
    request: &Value,
    limit: Duration,
) -> anyhow::Result<Reply> {
    let mut all = store.secrets_all()?;
    // A sign-in renewal the database refused is the live token.
    mcp_oauth::overlay_held(&mut all);
    let secrets: HashMap<String, String> = all.into_iter().collect();
    let servers = integrations::resolve(&[row], &secrets);
    let Some(mut server) = servers.into_iter().next() else {
        anyhow::bail!("a secret it names is not set");
    };
    if draft {
        server = all_secret(server);
    }
    let public_only = row.auth == IntegrationAuth::Oauth;
    let secrets = server_secrets(&server);
    match exchange(&server, limit, public_only, request).await {
        Ok(result) => Ok(Reply { result, secrets }),
        Err(e) if e.downcast_ref::<HttpStatus>().is_some() => Err(e),
        Err(e) => {
            let text = Redactor::exact(secrets).redact(&format!("{e:#}")).into_owned();
            Err(anyhow::anyhow!(text))
        }
    }
}

/// What `integrations.test` and `integrations.probe` answer for `row`: the server starts (or is reached) and its
/// tools come back, or the error. A draft saves nothing; a successful test keeps the tools for `integrations.tools`.
async fn probe_row(store: &Store, row: &Integration, draft: bool) -> RpcResult {
    if draft && row.auth == IntegrationAuth::Oauth {
        return ok(json!({ "ok": false, "tools": [], "error": "a browser sign-in cannot be tried before it is done" }));
    }
    match reach(store, row, draft, &list_request(), TEST_TIMEOUT).await {
        Ok(reply) => {
            let tools = tools_of(&reply.result, now_ms());
            if !draft {
                save_tools(store, row, &tools);
            }
            ok(json!({ "ok": true, "tools": names(&tools) }))
        }
        Err(Refused::SignIn) => {
            ok(json!({ "ok": false, "tools": [], "error": "sign in to this service again", "needs_login": true }))
        }
        Err(Refused::Failed(e)) => ok(json!({ "ok": false, "tools": [], "error": format!("{e:#}") })),
    }
}

/// Keeps the tools of a successful test: the list replaces the earlier one. A failure to write does not fail the
/// test; a row removed meanwhile keeps none.
fn save_tools(store: &Store, row: &Integration, tools: &[IntegrationTool]) {
    if let Err(e) = store.integration_tools_replace(&row.id, tools) {
        tracing::warn!(integration = row.name, "keeping the tools: {e:#}");
    }
}

fn names(tools: &[IntegrationTool]) -> Vec<&str> {
    tools.iter().map(|t| t.name.as_str()).collect()
}

/// An http server answered with this status: kept as a type so a 401 can be told from other failures.
#[derive(Debug)]
struct HttpStatus(u16);

impl std::fmt::Display for HttpStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the server answered with HTTP {}", self.0)
    }
}

impl std::error::Error for HttpStatus {}

/// Every environment and header value of a draft counts as a secret: a failure's stderr tail hides them all.
fn all_secret(mut server: Server) -> Server {
    match &mut server.transport {
        Transport::Stdio { env, .. } => env.iter_mut().for_each(|pair| pair.secret = true),
        Transport::Http { headers, .. } => headers.iter_mut().for_each(|pair| pair.secret = true),
    }
    server
}

/// The row with a patch applied, as it will be stored.
fn apply(cur: &Integration, p: &IntegrationPatch) -> Integration {
    let mut out = cur.clone();
    if let Some(v) = &p.name {
        out.name = v.clone();
    }
    if let Some(v) = p.kind {
        out.kind = v;
    }
    if let Some(v) = &p.command {
        out.command = v.clone();
    }
    if let Some(v) = &p.args {
        out.args = v.clone();
    }
    if let Some(v) = &p.url {
        out.url = v.clone();
    }
    if let Some(v) = &p.env {
        out.env = v.clone();
    }
    if let Some(v) = &p.headers {
        out.headers = v.clone();
    }
    out
}

/// A patch that moves what the agents may do with a service's tools.
fn changes_tool_rules(patch: &IntegrationPatch) -> bool {
    patch.tool_mode.is_some() || patch.tool_overrides.is_some()
}

/// A new name: two underscores in a row would make `mcp__<name>__<tool>` ambiguous, so none are taken. Names that
/// exist keep working (the policy reads such a call every way it can be read).
fn check_new_name(name: &str) -> Result<(), RpcError> {
    if name.contains("__") {
        return Err(RpcError::new(
            INVALID_PARAMS,
            "a name cannot hold two underscores in a row: use one, or a dash",
        ));
    }
    Ok(())
}

/// `tool_mode` and `tool_overrides` of an `integrations.add`, read beside the row's own fields.
#[derive(Deserialize)]
struct ToolWords {
    #[serde(default)]
    tool_mode: Option<crate::store::ToolMode>,
    #[serde(default)]
    tool_overrides: Option<std::collections::BTreeMap<String, crate::store::ToolOverride>>,
}

/// At most this many tools carry an override of their own.
const MAX_TOOL_OVERRIDES: usize = 500;
/// The longest tool name an override may name, in characters.
const MAX_TOOL_NAME: usize = 128;

/// The names an override list holds must be plain tool names, and there must not be a flood of them.
fn check_tool_overrides(
    overrides: Option<&std::collections::BTreeMap<String, crate::store::ToolOverride>>,
) -> Result<(), RpcError> {
    let Some(map) = overrides else {
        return Ok(());
    };
    if map.len() > MAX_TOOL_OVERRIDES {
        return Err(RpcError::new(
            INVALID_PARAMS,
            format!("at most {MAX_TOOL_OVERRIDES} tools can have a word of their own"),
        ));
    }
    if map.keys().any(|name| {
        name.trim().is_empty() || name.chars().count() > MAX_TOOL_NAME || name.chars().any(char::is_control)
    }) {
        return Err(RpcError::new(
            INVALID_PARAMS,
            "a tool name is 1 to 128 characters with no control characters",
        ));
    }
    Ok(())
}

fn check_new(n: &NewIntegration) -> Result<(), RpcError> {
    check_definition(&draft_row(n))
}

/// The row a new integration would be stored as, before it has an id.
fn draft_row(n: &NewIntegration) -> Integration {
    Integration {
        id: String::new(),
        name: n.name.clone(),
        kind: n.kind,
        command: n.command.clone(),
        args: n.args.clone(),
        url: n.url.clone(),
        env: n.env.clone(),
        headers: n.headers.clone(),
        enabled: n.enabled,
        created_at: 0,
        auth: n.auth,
        tool_mode: Default::default(),
        tool_overrides: Default::default(),
    }
}

/// The rules of [`crate::integrations`] for a whole row.
fn check_definition(row: &Integration) -> Result<(), RpcError> {
    let bad = |e: anyhow::Error| RpcError::new(INVALID_PARAMS, format!("{e:#}"));
    integrations::check_integration_name(&row.name).map_err(bad)?;
    integrations::check_definition(row.kind, row.command.as_deref(), row.url.as_deref()).map_err(bad)?;
    integrations::check_pairs("env", &row.env).map_err(bad)?;
    integrations::check_pairs("header", &row.headers).map_err(bad)?;
    Ok(())
}

/// How much of a server's stderr is kept for an error answer: the tail, redacted.
const ERROR_TAIL_CHARS: usize = 2 * 1024;
/// How much is collected before redaction, so a secret cut at the edge is still caught.
const STDERR_KEEP_BYTES: usize = 16 * 1024;

/// Start the server (or reach it) and ask for its tools: `initialize`, `notifications/initialized`, `tools/list`.
/// Stops after `limit`, and kills the whole process group it started: no child of the server outlives the probe.
/// Returns the tool names. A failure carries the tail of the server's stderr, redacted.
pub async fn probe(server: &Server, limit: Duration) -> anyhow::Result<Vec<String>> {
    let tools = probe_guarded(server, limit, false).await?;
    Ok(names(&tools).into_iter().map(str::to_string).collect())
}

/// [`probe`] with the tools as the server listed them, annotations included. With `public_only` (a row that signs
/// in in the browser, whose requests carry the daemon's token) an http address gets the checks and the pinning of
/// the sign-in itself (`mcp_oauth::guard_http`) before a token is sent.
async fn probe_guarded(server: &Server, limit: Duration, public_only: bool) -> anyhow::Result<Vec<IntegrationTool>> {
    let result = exchange(server, limit, public_only, &list_request()).await?;
    Ok(tools_of(&result, now_ms()))
}

/// The handshake, then `last` (a request with id 2), and the `result` of `last`. Stops after `limit`.
async fn exchange(server: &Server, limit: Duration, public_only: bool, last: &Value) -> anyhow::Result<Value> {
    match &server.transport {
        Transport::Stdio { command, args, env } => exchange_stdio(command, args, env, limit, last).await,
        Transport::Http { url, headers } => exchange_http(url, headers, limit, public_only, last).await,
    }
}

/// The secret values of a server, by name: what an answer must not show (see [`secret_pairs`]).
fn server_secrets(server: &Server) -> Vec<(String, String)> {
    match &server.transport {
        Transport::Stdio { env, .. } => secret_pairs(env),
        Transport::Http { headers, .. } => secret_pairs(headers),
    }
}

const PROTOCOL: &str = "2025-06-18";

fn initialize_request() -> Value {
    json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL,
            "capabilities": {},
            "clientInfo": { "name": "bandito", "version": env!("CARGO_PKG_VERSION") },
        }
    })
}

fn list_request() -> Value {
    json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} })
}

/// Kills a process group when dropped. The probe's children are started in their own group (pgid = pid), so
/// this takes the server and whatever it started with it, on every way out: answer, error or timeout.
struct Group(i32);

impl Drop for Group {
    fn drop(&mut self) {
        if self.0 > 0 {
            // SAFETY: killpg only sends a signal; an unknown group yields ESRCH, which is ignored.
            let _ = unsafe { libc::killpg(self.0, libc::SIGKILL) };
        }
    }
}

/// Reads a child's stderr in the background, keeping its last bytes. The reader ends at the end of stderr; the
/// handle is for waiting on that (see `tail_after_exit`).
fn collect_stderr<R>(mut stderr: R) -> (std::sync::Arc<std::sync::Mutex<Vec<u8>>>, tokio::task::JoinHandle<()>)
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    let buf = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = std::sync::Arc::clone(&buf);
    let reader = tokio::spawn(async move {
        let mut chunk = [0u8; 4096];
        loop {
            match stderr.read(&mut chunk).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let mut kept = sink.lock().unwrap_or_else(|e| e.into_inner());
                    kept.extend_from_slice(&chunk[..n]);
                    if kept.len() > STDERR_KEEP_BYTES {
                        let cut = kept.len() - STDERR_KEEP_BYTES;
                        kept.drain(..cut);
                    }
                }
            }
        }
    });
    (buf, reader)
}

/// The stderr tail of a process that has ended. Waits, for at most two seconds, for the reader to reach the end of
/// stderr: the bytes the process wrote just before it exited are then all in the tail, not a race with the reader.
async fn tail_after_exit(
    reader: tokio::task::JoinHandle<()>,
    buf: &std::sync::Mutex<Vec<u8>>,
    secrets: &[(String, String)],
) -> String {
    let _ = tokio::time::timeout(Duration::from_secs(2), reader).await;
    stderr_tail(buf, secrets)
}

/// The last characters of the collected stderr, with every secret value replaced by its `••••NAME`, however short.
fn stderr_tail(buf: &std::sync::Mutex<Vec<u8>>, secrets: &[(String, String)]) -> String {
    let raw = String::from_utf8_lossy(&buf.lock().unwrap_or_else(|e| e.into_inner())).into_owned();
    let redacted = crate::redact::Redactor::exact(secrets.iter().cloned())
        .redact(&raw)
        .into_owned();
    let mut tail: Vec<char> = redacted.chars().rev().take(ERROR_TAIL_CHARS).collect();
    tail.reverse();
    tail.into_iter().collect::<String>().trim().to_string()
}

/// `, stderr: …` for an error message, or nothing when the server said nothing.
fn with_stderr(message: String, tail: String) -> String {
    if tail.is_empty() {
        message
    } else {
        format!("{message}; stderr: {tail}")
    }
}

/// The secret values of an environment or a header, by name: what the redaction must hide. A value with a template
/// (`Bearer {secret}`) also hides its last word, the secret without the prefix, since a server may print it alone.
fn secret_pairs(pairs: &[Pair]) -> Vec<(String, String)> {
    pairs
        .iter()
        .filter(|p| p.secret)
        .flat_map(|p| {
            let word = p.value.split_whitespace().last().filter(|w| *w != p.value.as_str());
            std::iter::once((p.key.clone(), p.value.clone())).chain(word.map(|w| (p.key.clone(), w.to_string())))
        })
        .collect()
}

async fn exchange_stdio(
    command: &str,
    args: &[String],
    env: &[Pair],
    limit: Duration,
    last: &Value,
) -> anyhow::Result<Value> {
    let mut cmd = tokio::process::Command::new(command);
    cmd.args(args)
        .envs(env.iter().map(|p| (&p.key, &p.value)))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    cmd.as_std_mut().process_group(0);
    let mut child = cmd
        .spawn()
        .map_err(|e| anyhow::anyhow!("cannot start {command}: {e}"))?;
    let _group = Group(child.id().unwrap_or(0) as i32);
    let (stderr, reader) = collect_stderr(child.stderr.take().ok_or_else(|| anyhow::anyhow!("no stderr"))?);
    let secrets = secret_pairs(env);
    let exchange = async {
        let mut stdin = child.stdin.take().ok_or_else(|| anyhow::anyhow!("no stdin"))?;
        let mut stdout = BufReader::new(child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?);
        send(&mut stdin, &initialize_request()).await?;
        read_reply(&mut stdout, 1).await?;
        send(
            &mut stdin,
            &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
        )
        .await?;
        send(&mut stdin, last).await?;
        read_reply(&mut stdout, 2).await
    };
    match tokio::time::timeout(limit, exchange).await {
        Ok(Ok(tools)) => Ok(tools),
        Ok(Err(e)) => {
            // The exchange failed because the process went away: wait for its exit, then for its whole stderr.
            let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
            let tail = tail_after_exit(reader, &stderr, &secrets).await;
            anyhow::bail!("{}", with_stderr(format!("{e:#}"), tail))
        }
        Err(_) => anyhow::bail!(
            "{}",
            with_stderr(
                format!("no answer within {} seconds", limit.as_secs()),
                stderr_tail(&stderr, &secrets)
            )
        ),
    }
}

async fn send(stdin: &mut tokio::process::ChildStdin, msg: &Value) -> anyhow::Result<()> {
    let mut line = msg.to_string();
    line.push('\n');
    stdin.write_all(line.as_bytes()).await?;
    stdin.flush().await?;
    Ok(())
}

/// The most a server may send in one message (one line of its stdout, or one http answer). A larger one is refused.
const MAX_MESSAGE_BYTES: usize = 1024 * 1024;

/// Reads the next line of a server's stdout, of at most [`MAX_MESSAGE_BYTES`]; `None` at the end of the output. A longer
/// line is refused as soon as it passes the limit, without being read in full.
async fn read_line_capped<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R) -> anyhow::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return Ok((!line.is_empty()).then_some(line));
        }
        let (take, end) = match chunk.iter().position(|b| *b == b'\n') {
            Some(i) => (i + 1, true),
            None => (chunk.len(), false),
        };
        line.extend_from_slice(if end { &chunk[..take - 1] } else { &chunk[..take] });
        reader.consume(take);
        if line.len() > MAX_MESSAGE_BYTES {
            anyhow::bail!("the server's answer is too large (over 1 MiB)");
        }
        if end {
            return Ok(Some(line));
        }
    }
}

/// Reads the server's lines until its reply to request `id`. A reply has that id and no `method`: a request or a
/// notification of the server carries one and is not an answer, so it is skipped, as are logs and other non-JSON lines.
/// Returns the reply's result.
async fn read_reply<R: tokio::io::AsyncBufRead + Unpin>(reader: &mut R, id: u64) -> anyhow::Result<Value> {
    while let Some(line) = read_line_capped(reader).await? {
        let Ok(msg) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        if msg.get("method").is_none() && msg.get("id").and_then(Value::as_u64) == Some(id) {
            return result_of(&msg);
        }
    }
    anyhow::bail!("the server closed its output before answering")
}

fn result_of(msg: &Value) -> anyhow::Result<Value> {
    if let Some(err) = msg.get("error") {
        let text = err.get("message").and_then(Value::as_str).unwrap_or("error");
        anyhow::bail!("the server answered with an error: {text}");
    }
    msg.get("result")
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("the server's answer has no result"))
}

/// The tools of a `tools/list` result, with the annotations the owner's rules read: `readOnlyHint` and
/// `destructiveHint` (anything but `true`, or no annotation, counts as `false`). A schema over 32 KB is kept as none.
fn tools_of(result: &Value, seen_at: i64) -> Vec<IntegrationTool> {
    let Some(tools) = result.get("tools").and_then(Value::as_array) else {
        return Vec::new();
    };
    tools
        .iter()
        .filter_map(|t| {
            let name = t.get("name").and_then(Value::as_str)?;
            let notes = t.get("annotations");
            let hint = |key: &str| notes.and_then(|a| a.get(key)).and_then(Value::as_bool).unwrap_or(false);
            let note_title = notes.and_then(|a| a.get("title"));
            Some(IntegrationTool {
                name: name.to_string(),
                title: t
                    .get("title")
                    .or(note_title)
                    .and_then(Value::as_str)
                    .map(str::to_string),
                description: t.get("description").and_then(Value::as_str).map(str::to_string),
                read_only: hint("readOnlyHint"),
                destructive: hint("destructiveHint"),
                input_schema: t
                    .get("inputSchema")
                    .filter(|s| s.to_string().len() <= SCHEMA_BYTES)
                    .cloned(),
                seen_at,
            })
        })
        .collect()
}

/// How long one http POST may take, in seconds: a tool call gets the call's limit, any other request 15 s.
fn max_time_for(msg: &Value) -> u64 {
    if msg.get("method").and_then(Value::as_str) == Some("tools/call") {
        CALL_TIMEOUT.as_secs()
    } else {
        15
    }
}

fn call_request(tool: &str, arguments: &Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": { "name": tool, "arguments": arguments } })
}

/// A `tools/call` result as the daemon answers it: `is_error`, the content (a text part with its text; any other part
/// with its type only, so an image or a file never leaves in full), and `structured` when it fits in 64 KB. Every
/// string is redacted first, then the text is cut after 64 KB in all; the parts after the cut are left out.
fn call_answer(result: &Value, red: &Redactor) -> Value {
    let mut result = result.clone();
    red.redact_json(&mut result);
    let mut budget = CALL_TEXT_BYTES;
    let mut content = Vec::new();
    for part in result.get("content").and_then(Value::as_array).into_iter().flatten() {
        let kind = part.get("type").and_then(Value::as_str).unwrap_or("unknown");
        if kind != "text" {
            content.push(json!({ "type": kind }));
            continue;
        }
        let text = part.get("text").and_then(Value::as_str).unwrap_or_default();
        let kept = cut_at(text, budget);
        content.push(json!({ "type": kind, "text": kept }));
        budget -= kept.len();
        if kept.len() < text.len() {
            break;
        }
    }
    let mut answer = json!({
        "is_error": result.get("isError").and_then(Value::as_bool).unwrap_or(false),
        "content": content,
    });
    if let Some(structured) = result
        .get("structuredContent")
        .filter(|s| s.to_string().len() <= CALL_TEXT_BYTES)
    {
        answer["structured"] = structured.clone();
    }
    answer
}

/// The start of `text`, at most `max` bytes, cut at a character boundary.
fn cut_at(text: &str, max: usize) -> &str {
    let mut end = max.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    &text[..end]
}

/// Streamable HTTP through `curl`, its config (URL, headers, body) fed on stdin so no header value reaches argv.
/// The handshake, then `last`; stops after `limit` as the stdio exchange does.
async fn exchange_http(
    url: &str,
    headers: &[Pair],
    limit: Duration,
    public_only: bool,
    last: &Value,
) -> anyhow::Result<Value> {
    let exchange = async {
        // Every request is checked again: the name may lead somewhere else than a moment ago.
        let init = http_post(url, headers, &initialize_request(), None, public_only).await?;
        let session = init.session.clone();
        http_post(
            url,
            headers,
            &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
            session.as_deref(),
            public_only,
        )
        .await?;
        let answer = http_post(url, headers, last, session.as_deref(), public_only).await?;
        let reply = find_reply(&answer.body, 2).ok_or_else(|| anyhow::anyhow!("no answer to the request"))?;
        anyhow::Ok(result_of(&reply)?)
    };
    match tokio::time::timeout(limit, exchange).await {
        Ok(result) => result,
        Err(_) => anyhow::bail!("no answer within {} seconds", limit.as_secs()),
    }
}

struct HttpReply {
    session: Option<String>,
    body: String,
}

async fn http_post(
    url: &str,
    headers: &[Pair],
    msg: &Value,
    session: Option<&str>,
    public_only: bool,
) -> anyhow::Result<HttpReply> {
    let mut config = String::new();
    if public_only {
        let (checked, lines) = mcp_oauth::guard_http(url).await?;
        config.push_str(&format!("url = {}\n", json!(checked)));
        config.push_str(&lines);
    } else {
        config.push_str(&format!("url = {}\n", json!(url)));
    }
    config.push_str(&format!(
        "request = \"POST\"\nsilent\nshow-error\ninclude\nmax-time = {}\nmax-filesize = {MAX_MESSAGE_BYTES}\n",
        max_time_for(msg)
    ));
    config.push_str(&format!("header = {}\n", json!("Content-Type: application/json")));
    config.push_str(&format!(
        "header = {}\n",
        json!("Accept: application/json, text/event-stream")
    ));
    config.push_str(&format!(
        "header = {}\n",
        json!(format!("MCP-Protocol-Version: {PROTOCOL}"))
    ));
    if let Some(id) = session {
        config.push_str(&format!("header = {}\n", json!(format!("Mcp-Session-Id: {id}"))));
    }
    for h in headers {
        config.push_str(&format!("header = {}\n", json!(format!("{}: {}", h.key, h.value))));
    }
    config.push_str(&format!("data = {}\n", json!(msg.to_string())));
    let mut cmd = tokio::process::Command::new("curl");
    cmd.args(mcp_oauth::CURL_ARGS)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    cmd.as_std_mut().process_group(0);
    let mut child = cmd.spawn().map_err(|e| anyhow::anyhow!("cannot run curl: {e}"))?;
    // Killed with the group when this call ends, however it ends.
    let _group = Group(child.id().unwrap_or(0) as i32);
    let (stderr, reader) = collect_stderr(child.stderr.take().ok_or_else(|| anyhow::anyhow!("no stderr"))?);
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(config.as_bytes()).await?;
    }
    let out = child.wait_with_output().await?;
    // curl stops the transfer at the size limit (exit 63); the length is checked again for any other way it could pass.
    if out.status.code() == Some(63) || out.stdout.len() > MAX_MESSAGE_BYTES {
        anyhow::bail!("the server's answer is too large (over 1 MiB)");
    }
    let raw = String::from_utf8_lossy(&out.stdout).into_owned();
    if !out.status.success() {
        // The headers are in the config, not in curl's own messages; the tail is redacted with the secrets anyway.
        let secrets = secret_pairs(headers);
        let tail = tail_after_exit(reader, &stderr, &secrets).await;
        anyhow::bail!(
            "{}",
            with_stderr(
                format!(
                    "could not reach the server (curl exit {})",
                    out.status.code().unwrap_or(-1)
                ),
                tail
            )
        );
    }
    let parsed = parse_http(&raw)?;
    if parsed.status >= 400 {
        return Err(HttpStatus(parsed.status).into());
    }
    Ok(HttpReply {
        session: parsed.session,
        body: parsed.body,
    })
}

struct Parsed {
    status: u16,
    session: Option<String>,
    body: String,
}

/// Status, session id and body of a `curl -i` answer. The first blank line ends the headers.
fn parse_http(raw: &str) -> anyhow::Result<Parsed> {
    let (head, body) = raw
        .split_once("\r\n\r\n")
        .or_else(|| raw.split_once("\n\n"))
        .unwrap_or((raw, ""));
    let status = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse::<u16>().ok())
        .ok_or_else(|| anyhow::anyhow!("no HTTP status in the answer"))?;
    let session = head.lines().find_map(|l| {
        let (name, value) = l.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("mcp-session-id")
            .then(|| value.trim().to_string())
    });
    Ok(Parsed {
        status,
        session,
        body: body.to_string(),
    })
}

/// The reply with this id: a JSON body, or the `data:` events of an SSE body.
fn find_reply(body: &str, id: u64) -> Option<Value> {
    if let Ok(v) = serde_json::from_str::<Value>(body) {
        return (v.get("id").and_then(Value::as_u64) == Some(id)).then_some(v);
    }
    body.lines()
        .filter_map(|l| l.strip_prefix("data:"))
        .filter_map(|d| serde_json::from_str::<Value>(d.trim()).ok())
        .find(|v| v.get("id").and_then(Value::as_u64) == Some(id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::IntegrationKind;
    use std::collections::BTreeMap;

    #[test]
    fn the_catalog_parses_and_every_entry_is_complete() {
        use crate::integrations::{CATALOG_CATEGORIES, CATALOG_LANGUAGES, CatalogEntry};
        let cat: Vec<CatalogEntry> = serde_json::from_str(CATALOG_JSON).unwrap();
        assert!(cat.len() >= 18, "{}", cat.len());
        let mut ids = std::collections::HashSet::new();
        for e in &cat {
            assert!(ids.insert(e.id.as_str()), "duplicate id {}", e.id);
            // The id is the integration's name once connected, so it has to be a valid one.
            integrations::check_integration_name(&e.id).unwrap();
            assert!(e.docs_url.starts_with("https://"), "{}", e.id);
            assert!(
                e.homepage.as_deref().is_none_or(|h| h.starts_with("https://")),
                "{}",
                e.id
            );
            assert!(
                e.category.as_deref().is_some_and(|c| CATALOG_CATEGORIES.contains(&c)),
                "{}",
                e.id
            );
            assert!(e.publisher.is_some() && e.official.is_some(), "{}", e.id);
            let accent = e.accent.as_deref().unwrap_or_default();
            assert!(
                accent.len() == 7 && accent.starts_with('#') && accent[1..].chars().all(|c| c.is_ascii_hexdigit()),
                "{}: accent {accent}",
                e.id
            );
            assert!(e.long_en.is_some() && e.long_ru.is_some(), "{}", e.id);
            assert!(e.needs_en.is_some() && e.needs_ru.is_some(), "{}", e.id);
            for abilities in [&e.abilities_en, &e.abilities_ru] {
                let n = abilities.as_ref().map_or(0, Vec::len);
                assert!((2..=6).contains(&n), "{}: {n} abilities", e.id);
            }
            assert_eq!(
                e.abilities_en.as_ref().map(Vec::len),
                e.abilities_ru.as_ref().map(Vec::len),
                "{}",
                e.id
            );
            // The other app languages: every one of them, every field filled in, and a label for every key.
            let l10n = e.l10n.as_ref().unwrap_or_else(|| panic!("{}: no l10n", e.id));
            assert_eq!(l10n.len(), CATALOG_LANGUAGES.len(), "{}: every language", e.id);
            let mut keys: Vec<&str> = e
                .headers_keys
                .iter()
                .flatten()
                .chain(e.env_keys.iter().flatten())
                .map(|k| k.key.as_str())
                .collect();
            keys.sort_unstable();
            let en_abilities = e.abilities_en.as_ref().map_or(0, Vec::len);
            for (lang, t) in l10n {
                assert!(
                    CATALOG_LANGUAGES.contains(&lang.as_str()),
                    "{}: unknown language {lang}",
                    e.id
                );
                assert!(
                    !t.description.trim().is_empty() && !t.long.trim().is_empty() && !t.needs.trim().is_empty(),
                    "{} {lang}: an empty text",
                    e.id
                );
                assert_eq!(
                    t.abilities.len(),
                    en_abilities,
                    "{} {lang}: abilities as in English",
                    e.id
                );
                assert!(
                    t.abilities.iter().all(|a| !a.trim().is_empty()),
                    "{} {lang}: an empty ability",
                    e.id
                );
                let labels = t.labels.clone().unwrap_or_default();
                let mut label_keys: Vec<&str> = labels.keys().map(String::as_str).collect();
                label_keys.sort_unstable();
                assert_eq!(label_keys, keys, "{} {lang}: the labels cover the keys", e.id);
                assert!(
                    labels.values().all(|l| !l.trim().is_empty()),
                    "{} {lang}: an empty label",
                    e.id
                );
            }
            match e.kind {
                IntegrationKind::Stdio => {
                    assert!(
                        e.command.is_some() && e.url.is_none() && e.headers_keys.is_none(),
                        "{}",
                        e.id
                    );
                }
                IntegrationKind::Http => {
                    assert!(e.url.is_some() || e.url_hint.is_some(), "{}", e.id);
                    assert!(e.command.is_none() && e.env_keys.is_none(), "{}", e.id);
                    if let Some(url) = &e.url {
                        assert!(url.starts_with("https://"), "{}", e.id);
                    }
                }
            }
            match e.auth.as_deref() {
                None | Some("none") => {}
                Some("oauth") => assert!(
                    e.kind == IntegrationKind::Http && e.url.is_some() && e.headers_keys.is_none(),
                    "{}: a browser sign-in needs an http entry with a fixed url and no header keys",
                    e.id
                ),
                Some(other) => panic!("{}: unknown auth {other}", e.id),
            }
            for key in e.headers_keys.iter().flatten().chain(e.env_keys.iter().flatten()) {
                assert!(key.value_template.contains("{secret}"), "{}", e.id);
            }
        }
        // No key, token or password sits in the public catalog.
        let raw = CATALOG_JSON.to_lowercase();
        for needle in ["sk-", "ghp_", "xoxb-", "bearer ey"] {
            assert!(!raw.contains(needle), "{needle}");
        }
    }

    #[tokio::test]
    async fn the_probe_of_a_sign_in_row_refuses_a_name_that_leads_to_a_local_address() {
        crate::mcp_oauth::fake_dns()
            .lock()
            .unwrap()
            .insert("probe-rebind.test".into(), vec!["192.168.1.9".parse().unwrap()]);
        let server = Server {
            name: "notion".into(),
            transport: Transport::Http {
                url: "https://probe-rebind.test/mcp".into(),
                headers: vec![Pair {
                    key: "Authorization".into(),
                    value: "Bearer at-secret".into(),
                    secret: true,
                }],
            },
        };
        let err = probe_guarded(&server, Duration::from_secs(5), true).await.unwrap_err();
        let text = format!("{err:#}");
        assert!(text.contains("local address") && !text.contains("at-secret"), "{text}");
    }

    #[test]
    fn http_answers_split_status_session_and_body() {
        let raw =
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: abc\r\n\r\n{\"id\":2,\"result\":{}}";
        let p = parse_http(raw).unwrap();
        assert_eq!((p.status, p.session.as_deref()), (200, Some("abc")));
        assert_eq!(p.body, "{\"id\":2,\"result\":{}}");
        assert!(parse_http("garbage").is_err());
    }

    #[test]
    fn a_reply_comes_from_json_or_from_an_sse_event() {
        assert!(find_reply("{\"id\":2,\"result\":{\"tools\":[]}}", 2).is_some());
        assert!(find_reply("{\"id\":3,\"result\":{}}", 2).is_none());
        let sse = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"method\":\"ping\"}\n\nevent: message\ndata: {\"id\":2,\"result\":{\"tools\":[{\"name\":\"fetch\"}]}}\n\n";
        let reply = find_reply(sse, 2).unwrap();
        assert_eq!(names(&tools_of(&result_of(&reply).unwrap(), 0)), ["fetch"]);
    }

    #[test]
    fn an_mcp_error_is_a_failure() {
        let err = result_of(&json!({"id": 1, "error": {"code": -32600, "message": "bad"}})).unwrap_err();
        assert!(err.to_string().contains("bad"));
    }

    fn fake_server(tools: &str) -> Server {
        // A shell script that answers the handshake the way an MCP server does, one line per request.
        let script = format!(
            "read a; echo '{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"protocolVersion\":\"{PROTOCOL}\",\"capabilities\":{{}}}}}}'; \
             read b; read c; echo '{{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{{\"tools\":{tools}}}}}'"
        );
        Server {
            name: "fake".into(),
            transport: Transport::Stdio {
                command: "sh".into(),
                args: vec!["-c".into(), script],
                env: vec![],
            },
        }
    }

    #[tokio::test]
    async fn a_stdio_server_is_asked_for_its_tools() {
        let server = fake_server("[{\"name\":\"fetch\"},{\"name\":\"other\"}]");
        let tools = probe(&server, Duration::from_secs(10)).await.unwrap();
        assert_eq!(tools, ["fetch", "other"]);
    }

    #[tokio::test]
    async fn a_silent_server_times_out() {
        let server = Server {
            name: "silent".into(),
            transport: Transport::Stdio {
                command: "sleep".into(),
                args: vec!["30".into()],
                env: vec![],
            },
        };
        let err = probe(&server, Duration::from_millis(300)).await.unwrap_err();
        assert!(err.to_string().contains("no answer"), "{err}");
    }

    #[tokio::test]
    async fn a_missing_program_is_reported() {
        let server = Server {
            name: "nope".into(),
            transport: Transport::Stdio {
                command: "/definitely/not/here".into(),
                args: vec![],
                env: vec![],
            },
        };
        let err = probe(&server, Duration::from_secs(5)).await.unwrap_err();
        assert!(err.to_string().contains("cannot start"), "{err}");
    }

    #[tokio::test]
    async fn a_draft_is_probed_and_never_saved() {
        let app = app();
        let Transport::Stdio { command, args, .. } = fake_server("[{\"name\":\"fetch\"}]").transport else {
            unreachable!("fake_server is stdio");
        };
        let draft = json!({ "draft": { "name": "fake", "kind": "stdio", "command": command, "args": args } });
        let answer = owner(&app, "integrations.probe", draft).await.unwrap();
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["tools"], json!(["fetch"]), "{answer}");
        let listed = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert!(listed.as_array().unwrap().is_empty(), "a probe saves nothing: {listed}");
    }

    #[tokio::test]
    async fn a_probe_of_a_missing_program_answers_the_error() {
        let app = app();
        let draft = json!({ "draft": { "name": "nope", "kind": "stdio", "command": "/definitely/not/here" } });
        let answer = owner(&app, "integrations.probe", draft).await.unwrap();
        assert_eq!(answer["ok"], false, "{answer}");
        assert!(answer["error"].as_str().unwrap().contains("cannot start"), "{answer}");
    }

    #[tokio::test]
    async fn a_probe_checks_the_draft_like_add_does() {
        let app = app();
        let bad_name = json!({ "draft": { "name": "Bad Name", "kind": "stdio", "command": "sh" } });
        assert_eq!(
            owner(&app, "integrations.probe", bad_name).await.unwrap_err().code,
            INVALID_PARAMS
        );
        let no_command = json!({ "draft": { "name": "fine", "kind": "stdio" } });
        assert_eq!(
            owner(&app, "integrations.probe", no_command).await.unwrap_err().code,
            INVALID_PARAMS
        );
    }

    #[tokio::test]
    async fn a_probe_hides_the_draft_values_in_its_error() {
        let app = app();
        let draft = json!({ "draft": {
            "name": "tok",
            "kind": "stdio",
            "command": "sh",
            "args": ["-c", "echo 'boom tok-real-value' >&2; exit 1"],
            "env": { "TOKEN": "tok-real-value" }
        } });
        let answer = owner(&app, "integrations.probe", draft).await.unwrap();
        let error = answer["error"].as_str().unwrap();
        assert!(error.contains("boom") && !error.contains("tok-real-value"), "{answer}");
        assert!(error.contains("••••TOKEN"), "{answer}");
    }

    #[tokio::test]
    async fn a_probe_hides_a_template_secret_without_its_prefix_and_a_short_one_whole() {
        let app = app();
        // The header value is `Bearer <secret>`; the server prints the secret alone, and a 2-byte secret too.
        let draft = json!({ "draft": {
            "name": "tok",
            "kind": "stdio",
            "command": "sh",
            "args": ["-c", "echo 'got tok-real-value, q7 and Bearer tok-real-value' >&2; exit 1"],
            "env": { "AUTH": "Bearer tok-real-value", "TOKEN": "q7" }
        } });
        let answer = owner(&app, "integrations.probe", draft).await.unwrap();
        let error = answer["error"].as_str().unwrap();
        assert!(!error.contains("tok-real-value") && !error.contains("q7"), "{answer}");
        assert!(error.contains("••••AUTH") && error.contains("••••TOKEN"), "{answer}");
    }

    #[test]
    fn the_rules_apply_to_a_patched_row() {
        let cur = Integration {
            id: "i".into(),
            name: "fetch".into(),
            kind: IntegrationKind::Stdio,
            command: Some("uvx".into()),
            args: vec![],
            url: None,
            env: BTreeMap::new(),
            headers: BTreeMap::new(),
            enabled: true,
            created_at: 0,
            auth: Default::default(),
            tool_mode: Default::default(),
            tool_overrides: Default::default(),
        };
        let patch = IntegrationPatch {
            command: Some(None),
            ..Default::default()
        };
        assert!(
            check_definition(&apply(&cur, &patch)).is_err(),
            "a stdio row needs its command"
        );
        let renamed = IntegrationPatch {
            name: Some("Bad Name".into()),
            ..Default::default()
        };
        assert!(check_definition(&apply(&cur, &renamed)).is_err());
    }

    fn app() -> std::sync::Arc<App> {
        use crate::hub::Hub;
        use crate::store::Store;
        use crate::supervisor::{Runtimes, Supervisor};
        let sup = Supervisor::new(
            Hub::new(std::sync::Arc::new(Store::open_in_memory().unwrap())),
            Runtimes::default(),
            None,
        );
        App::new(
            sup,
            std::env::temp_dir().join(format!("bandito-int-{}", crate::store::new_id())),
        )
    }

    async fn owner(app: &App, method: &str, p: Value) -> RpcResult {
        super::super::dispatch(app, &super::super::Peer::Local, method, p).await
    }

    #[tokio::test]
    async fn add_list_update_remove_follow_the_rules() {
        let app = app();
        let bad = [
            json!({ "name": "Fetch", "kind": "stdio", "command": "uvx" }),
            json!({ "name": "fetch", "kind": "stdio" }),
            json!({ "name": "gh", "kind": "http", "url": "http://example.com/mcp" }),
            json!({ "name": "bandito", "kind": "stdio", "command": "x" }),
            json!({ "name": "fetch", "kind": "stdio", "command": "x", "env": { "TOKEN": "secret:lower" } }),
        ];
        for p in bad {
            let err = owner(&app, "integrations.add", p.clone()).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{p}");
        }

        let made = owner(
            &app,
            "integrations.add",
            json!({ "name": "fetch", "kind": "stdio", "command": "uvx", "args": ["mcp-server-fetch"] }),
        )
        .await
        .unwrap();
        let id = made["id"].as_str().unwrap().to_string();
        let again = owner(
            &app,
            "integrations.add",
            json!({ "name": "fetch", "kind": "stdio", "command": "x" }),
        )
        .await
        .unwrap_err();
        assert_eq!(again.code, INVALID_PARAMS, "names are unique");

        let other = owner(
            &app,
            "integrations.add",
            json!({ "name": "gh", "kind": "http", "url": "https://api.example.com/mcp", "headers": { "Authorization": "Bearer secret:GITHUB_TOKEN" } }),
        )
        .await
        .unwrap();
        let taken = owner(
            &app,
            "integrations.update",
            json!({ "id": other["id"], "name": "fetch" }),
        )
        .await
        .unwrap_err();
        assert_eq!(taken.code, INVALID_PARAMS);
        let no_command = owner(&app, "integrations.update", json!({ "id": id, "command": null }))
            .await
            .unwrap_err();
        assert_eq!(no_command.code, INVALID_PARAMS, "the row as it will be is checked");

        let listed = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert_eq!(listed.as_array().map(Vec::len), Some(2));
        assert_eq!(
            owner(&app, "integrations.remove", json!({ "id": id })).await.unwrap(),
            json!({ "deleted": true })
        );
        assert_eq!(
            owner(&app, "integrations.remove", json!({ "id": id })).await.unwrap(),
            json!({ "deleted": false })
        );
    }

    #[tokio::test]
    async fn an_agent_gets_only_integrations_that_exist() {
        let app = app();
        let fetch = owner(
            &app,
            "integrations.add",
            json!({ "name": "fetch", "kind": "stdio", "command": "uvx" }),
        )
        .await
        .unwrap();
        let agent = owner(
            &app,
            "agents.create",
            json!({ "name": "Forge", "runtime": "claude", "cwd": std::env::temp_dir().display().to_string(), "integrations": ["missing"] }),
        )
        .await
        .unwrap_err();
        assert_eq!(agent.code, INVALID_PARAMS);
        let created = owner(
            &app,
            "agents.create",
            json!({ "name": "Forge", "runtime": "claude", "cwd": std::env::temp_dir().display().to_string(), "integrations": [fetch["id"]] }),
        )
        .await
        .unwrap();
        assert_eq!(created["integrations"], json!([fetch["id"]]));
        let unknown = owner(
            &app,
            "agents.update",
            json!({ "id": created["id"], "integrations": ["nope"] }),
        )
        .await
        .unwrap_err();
        assert_eq!(unknown.code, INVALID_PARAMS);
        let cleared = owner(
            &app,
            "agents.update",
            json!({ "id": created["id"], "integrations": null }),
        )
        .await
        .unwrap();
        assert_eq!(cleared["integrations"], Value::Null, "null = every enabled one");
    }

    #[tokio::test]
    async fn agents_cannot_manage_integrations_and_the_catalog_is_served() {
        let app = app();
        let agent = super::super::Peer::Agent("agent-a".into());
        for method in [
            "integrations.list",
            "integrations.add",
            "integrations.update_from_template",
            "integrations.test",
            "integrations.probe",
        ] {
            let err = super::super::dispatch(&app, &agent, method, json!({}))
                .await
                .unwrap_err();
            assert_eq!(err.code, super::super::UNAUTHORIZED, "{method}");
        }
        let catalog = owner(&app, "integrations.catalog", json!({})).await.unwrap();
        assert!(catalog.as_array().is_some_and(|c| c.len() >= 18));
    }

    /// The `integrations.list` row called `name`.
    fn listed(list: &Value, name: &str) -> Value {
        list.as_array()
            .unwrap()
            .iter()
            .find(|r| r["name"] == name)
            .unwrap()
            .clone()
    }

    #[tokio::test]
    async fn a_template_version_behind_is_listed_and_updated_with_the_secrets_kept() {
        let app = app();
        let made = owner(
            &app,
            "integrations.add",
            json!({
                "name": "grafana", "kind": "stdio", "command": "uvx", "args": ["mcp-grafana==1.0.0"],
                "env": { "GRAFANA_TOKEN": "secret:GRAFANA_TOKEN" }, "enabled": false
            }),
        )
        .await
        .unwrap();
        let id = made["id"].as_str().unwrap().to_string();
        let list = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert_eq!(
            listed(&list, "grafana")["template_update"],
            json!({"from": "1.0.0", "to": "2.0.2"})
        );

        let done = owner(&app, "integrations.update_from_template", json!({ "id": id }))
            .await
            .unwrap();
        assert_eq!(done["args"], json!(["mcp-grafana==2.0.2"]));
        assert_eq!(done["command"], "uvx");
        assert_eq!(done["env"], json!({"GRAFANA_TOKEN": "secret:GRAFANA_TOKEN"}));
        assert_eq!(done["enabled"], false);
        let list = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert!(
            listed(&list, "grafana").get("template_update").is_none(),
            "up to date: no field"
        );
        let again = owner(&app, "integrations.update_from_template", json!({ "id": id }))
            .await
            .unwrap_err();
        assert_eq!(again.code, INVALID_PARAMS, "nothing left to take from the template");
    }

    #[tokio::test]
    async fn a_moved_template_address_is_taken_and_the_headers_stay() {
        let app = app();
        let made = owner(
            &app,
            "integrations.add",
            json!({
                "name": "exa", "kind": "http", "url": "https://mcp.exa.ai/old",
                "headers": { "x-api-key": "secret:EXA_API_KEY" }, "enabled": false
            }),
        )
        .await
        .unwrap();
        let id = made["id"].as_str().unwrap().to_string();
        let list = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert_eq!(
            listed(&list, "exa")["template_update"],
            json!({"from": null, "to": null})
        );

        let done = owner(&app, "integrations.update_from_template", json!({ "id": id }))
            .await
            .unwrap();
        assert_eq!(done["url"], "https://mcp.exa.ai/mcp");
        assert_eq!(done["headers"], json!({"x-api-key": "secret:EXA_API_KEY"}));
        assert_eq!(done["command"], Value::Null);
        assert_eq!(done["enabled"], false);
    }

    #[tokio::test]
    async fn an_integration_with_the_owners_own_change_or_no_template_is_not_updated() {
        let app = app();
        for p in [
            json!({"name": "my-grafana", "kind": "stdio", "command": "uvx", "args": ["mcp-grafana==1.0.0"]}),
            json!({"name": "git", "kind": "stdio", "command": "uvx",
                   "args": ["mcp-server-git", "--repository", "/Users/me/repo"]}),
        ] {
            let made = owner(&app, "integrations.add", p).await.unwrap();
            let id = made["id"].as_str().unwrap().to_string();
            let refused = owner(&app, "integrations.update_from_template", json!({ "id": id }))
                .await
                .unwrap_err();
            assert_eq!(refused.code, INVALID_PARAMS, "{}", made["name"]);
        }
        let list = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert!(listed(&list, "my-grafana").get("template_update").is_none());
        assert!(listed(&list, "git").get("template_update").is_none());
        assert_eq!(
            listed(&list, "git")["args"],
            json!(["mcp-server-git", "--repository", "/Users/me/repo"])
        );
    }

    #[tokio::test]
    async fn a_browser_sign_in_is_never_updated_from_its_template() {
        let app = app();
        let linear = app
            .sup
            .hub()
            .store
            .integration_create(
                serde_json::from_value(json!({
                    "name": "linear", "kind": "http", "url": "https://mcp.linear.app/old", "auth": "oauth"
                }))
                .unwrap(),
            )
            .unwrap();
        let list = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert!(listed(&list, "linear").get("template_update").is_none());
        let refused = owner(&app, "integrations.update_from_template", json!({ "id": linear.id }))
            .await
            .unwrap_err();
        assert_eq!(refused.code, INVALID_PARAMS);
        assert_eq!(
            app.sup
                .hub()
                .store
                .integration_get(&linear.id)
                .unwrap()
                .unwrap()
                .url
                .as_deref(),
            Some("https://mcp.linear.app/old"),
            "the address is untouched"
        );
    }

    #[tokio::test]
    async fn the_mode_and_the_words_for_tools_are_added_updated_and_checked() {
        let app = app();
        // A catalog service starts asking, an own one starts open; both are listed with the fields.
        let catalog = owner(
            &app,
            "integrations.add",
            json!({ "name": "fetch", "kind": "stdio", "command": "uvx", "args": ["mcp-server-fetch"] }),
        )
        .await
        .unwrap();
        assert_eq!(catalog["tool_mode"], "confirm_writes");
        assert_eq!(catalog["tool_overrides"], json!({}));
        let own = owner(
            &app,
            "integrations.add",
            json!({ "name": "mine", "kind": "stdio", "command": "mytool", "tool_mode": "read_only",
                    "tool_overrides": { "delete_all": "deny" } }),
        )
        .await
        .unwrap();
        assert_eq!(own["tool_mode"], "read_only", "named when added");
        assert_eq!(own["tool_overrides"], json!({ "delete_all": "deny" }));
        let plain = owner(
            &app,
            "integrations.add",
            json!({ "name": "plain", "kind": "stdio", "command": "x" }),
        )
        .await
        .unwrap();
        assert_eq!(plain["tool_mode"], "all");

        let id = plain["id"].clone();
        let updated = owner(
            &app,
            "integrations.update",
            json!({ "id": id, "tool_mode": "confirm_writes", "tool_overrides": { "search": "allow", "send": "ask" } }),
        )
        .await
        .unwrap();
        assert_eq!(updated["tool_mode"], "confirm_writes");
        assert_eq!(updated["tool_overrides"], json!({ "search": "allow", "send": "ask" }));
        // Another field leaves them as they are.
        let off = owner(&app, "integrations.update", json!({ "id": id, "enabled": false }))
            .await
            .unwrap();
        assert_eq!(off["tool_mode"], "confirm_writes");
        assert_eq!(off["tool_overrides"]["send"], "ask");

        for bad in [
            json!({ "id": id, "tool_mode": "everything" }),
            json!({ "id": id, "tool_overrides": { "x": "maybe" } }),
            json!({ "id": id, "tool_overrides": { "": "deny" } }),
            json!({ "id": id, "tool_overrides": { "a\nb": "deny" } }),
            json!({ "id": id, "tool_overrides": { "t".repeat(129): "deny" } }),
        ] {
            let err = owner(&app, "integrations.update", bad.clone()).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{bad}");
        }
        let too_many: serde_json::Map<String, Value> = (0..501).map(|i| (format!("tool{i}"), json!("deny"))).collect();
        let err = owner(
            &app,
            "integrations.update",
            json!({ "id": id, "tool_overrides": too_many }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        let listed = owner(&app, "integrations.list", json!({})).await.unwrap();
        assert!(listed.as_array().unwrap().iter().all(|r| r.get("tool_mode").is_some()));
    }

    #[test]
    fn only_a_patch_of_the_tool_rules_restarts_sessions() {
        assert!(changes_tool_rules(&IntegrationPatch {
            tool_mode: Some(crate::store::ToolMode::ReadOnly),
            ..Default::default()
        }));
        assert!(changes_tool_rules(&IntegrationPatch {
            tool_overrides: Some(Default::default()),
            ..Default::default()
        }));
        assert!(!changes_tool_rules(&IntegrationPatch {
            enabled: Some(false),
            ..Default::default()
        }));
    }

    #[tokio::test]
    async fn two_underscores_are_refused_in_a_new_name_but_an_old_one_still_works() {
        let app = app();
        for bad in [json!({ "name": "a__b", "kind": "stdio", "command": "x" })] {
            let err = owner(&app, "integrations.add", bad).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS);
            assert!(err.message.contains("two underscores"), "{}", err.message);
        }
        let ok = owner(
            &app,
            "integrations.add",
            json!({ "name": "a_b", "kind": "stdio", "command": "x" }),
        )
        .await
        .unwrap();
        let err = owner(&app, "integrations.update", json!({ "id": ok["id"], "name": "c__d" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        // A row that already has `__` (made before the rule) keeps its name through other changes.
        let old = app
            .sup
            .hub()
            .store
            .integration_create(crate::store::NewIntegration {
                name: "old__one".into(),
                kind: IntegrationKind::Stdio,
                command: Some("x".into()),
                args: vec![],
                url: None,
                env: BTreeMap::new(),
                headers: BTreeMap::new(),
                enabled: true,
                auth: Default::default(),
            })
            .unwrap();
        let still = owner(&app, "integrations.update", json!({ "id": old.id, "enabled": false }))
            .await
            .unwrap();
        assert_eq!(still["name"], "old__one");
        let same = owner(&app, "integrations.update", json!({ "id": old.id, "name": "old__one" }))
            .await
            .unwrap();
        assert_eq!(same["name"], "old__one");
    }

    #[test]
    fn the_tool_permissions_feature_is_offered() {
        assert!(crate::rpc::features().contains(&"tool_permissions"));
    }

    #[test]
    fn the_template_updates_feature_is_offered() {
        assert!(crate::rpc::features().contains(&"template_updates"));
    }

    #[tokio::test]
    async fn recommend_reads_the_agents_folder_and_leaves_out_connected_templates() {
        let app = app();
        let folder = tempfile::tempdir().unwrap();
        std::fs::write(folder.path().join("netlify.toml"), "[build]\n").unwrap();
        std::fs::write(folder.path().join("wrangler.toml"), "name = \"x\"\n").unwrap();
        let agent = owner(
            &app,
            "agents.create",
            json!({ "name": "Forge", "runtime": "claude", "cwd": folder.path().display().to_string() }),
        )
        .await
        .unwrap();
        let id = agent["id"].as_str().unwrap().to_string();
        let ids = |v: &Value| -> Vec<String> {
            v.as_array()
                .unwrap()
                .iter()
                .map(|s| s["template_id"].as_str().unwrap().to_string())
                .collect()
        };
        let got = owner(&app, "integrations.recommend", json!({ "agent_id": id }))
            .await
            .unwrap();
        assert_eq!(ids(&got), ["netlify", "cloudflare"]);
        assert_eq!(got[0]["reason_key"], "recommend.reason.netlifyToml");
        assert_eq!(got[0]["evidence"], "netlify.toml");
        // An integration named after a template, or at its address (a trailing `/` ignored), counts as connected.
        owner(
            &app,
            "integrations.add",
            json!({ "name": "netlify", "kind": "stdio", "command": "npx" }),
        )
        .await
        .unwrap();
        owner(
            &app,
            "integrations.add",
            json!({ "name": "cf", "kind": "http", "url": "https://mcp.cloudflare.com/mcp/" }),
        )
        .await
        .unwrap();
        let got = owner(&app, "integrations.recommend", json!({ "agent_id": id }))
            .await
            .unwrap();
        assert_eq!(got, json!([]));
        let err = owner(&app, "integrations.recommend", json!({ "agent_id": "nope" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        let err = super::super::dispatch(
            &app,
            &super::super::Peer::Agent(id),
            "integrations.recommend",
            json!({ "agent_id": "x" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, super::super::UNAUTHORIZED);
    }

    fn sh_server(script: &str, env: &[(&str, &str, bool)]) -> Server {
        Server {
            name: "sh".into(),
            transport: Transport::Stdio {
                command: "sh".into(),
                args: vec!["-c".into(), script.into()],
                env: env
                    .iter()
                    .map(|(k, v, secret)| Pair {
                        key: k.to_string(),
                        value: v.to_string(),
                        secret: *secret,
                    })
                    .collect(),
            },
        }
    }

    #[tokio::test]
    async fn a_failure_carries_the_redacted_tail_of_stderr() {
        let server = sh_server(
            "echo 'boom tok-real-value' >&2; exit 1",
            &[("TOKEN", "tok-real-value", true)],
        );
        let err = probe(&server, Duration::from_secs(5)).await.unwrap_err().to_string();
        assert!(err.contains("stderr: ") && err.contains("boom"), "{err}");
        assert!(
            !err.contains("tok-real-value"),
            "a secret value never reaches an answer: {err}"
        );
        assert!(err.contains("••••TOKEN"), "{err}");
    }

    #[tokio::test]
    async fn the_stderr_tail_is_at_most_two_kilobytes() {
        let server = sh_server(
            "head -c 9000 /dev/zero | tr '\\0' x >&2; echo END-MARK >&2; exit 1",
            &[],
        );
        let err = probe(&server, Duration::from_secs(5)).await.unwrap_err().to_string();
        let tail = err.split("stderr: ").nth(1).unwrap_or_default();
        assert!(tail.ends_with("END-MARK"), "the last line is kept: {err}");
        assert!(
            tail.chars().count() <= ERROR_TAIL_CHARS,
            "{} chars",
            tail.chars().count()
        );
    }

    #[tokio::test]
    async fn a_timeout_kills_the_whole_process_group() {
        let dir = std::env::temp_dir().join(format!("bandito-probe-{}", crate::store::new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pidfile = dir.join("child.pid");
        let script = format!("sleep 60 & echo $! > '{}'; wait", pidfile.display());
        let server = sh_server(&script, &[]);
        let err = probe(&server, Duration::from_millis(500)).await.unwrap_err();
        assert!(err.to_string().contains("no answer"), "{err}");
        let pid: i32 = std::fs::read_to_string(&pidfile)
            .expect("the grandchild wrote its pid")
            .trim()
            .parse()
            .unwrap();
        // The group was killed when the probe returned: the grandchild is gone (a zombie is not running either).
        let mut gone = false;
        for _ in 0..40 {
            let alive = std::process::Command::new("kill")
                .args(["-0", &pid.to_string()])
                .stderr(std::process::Stdio::null())
                .status()
                .map(|st| st.success())
                .unwrap_or(false);
            let state = std::process::Command::new("ps")
                .args(["-o", "stat=", "-p", &pid.to_string()])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .unwrap_or_default();
            if !alive || state.starts_with('Z') || state.is_empty() {
                gone = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        std::fs::remove_dir_all(&dir).ok();
        assert!(gone, "pid {pid} still runs after the probe");
    }

    /// The script of a stdio server: it answers the handshake, then `answer` (`"result":…` or `"error":…`) to its request.
    fn answering(answer: &str) -> String {
        answering_after("", answer)
    }

    /// As [`answering`], with `before` (shell commands) run before the answer is written.
    fn answering_after(before: &str, answer: &str) -> String {
        format!(
            "read a; echo '{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"protocolVersion\":\"{PROTOCOL}\",\"capabilities\":{{}}}}}}'; \
             read b; read c; {before} echo '{{\"jsonrpc\":\"2.0\",\"id\":2,{answer}}}'"
        )
    }

    /// Adds a stdio integration that runs `script` with `sh -c`, through the RPC; returns its id.
    async fn add_sh(app: &App, name: &str, script: &str, env: Value) -> String {
        let row = owner(
            app,
            "integrations.add",
            json!({ "name": name, "kind": "stdio", "command": "sh", "args": ["-c", script], "env": env }),
        )
        .await
        .unwrap();
        row["id"].as_str().unwrap().to_string()
    }

    /// The tool called `name` in a `integrations.tools` answer.
    fn tool_of(list: &Value, name: &str) -> Value {
        list.as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == name)
            .unwrap_or_else(|| panic!("no tool {name} in {list}"))
            .clone()
    }

    fn tool_names_of(list: &Value) -> Vec<String> {
        list.as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[tokio::test]
    async fn a_successful_test_keeps_the_annotated_tools_and_a_later_list_replaces_them() {
        let app = app();
        let first = answering(
            r#""result":{"tools":[{"name":"search","title":"Search","description":"Finds things","annotations":{"readOnlyHint":true},"inputSchema":{"type":"object"}},{"name":"drop","annotations":{"destructiveHint":true}},{"name":"plain"}]}"#,
        );
        let id = add_sh(&app, "tools-a", &first, json!({})).await;
        let answer = owner(&app, "integrations.test", json!({ "id": id })).await.unwrap();
        assert_eq!(answer["ok"], true, "{answer}");

        let list = owner(&app, "integrations.tools", json!({ "id": id })).await.unwrap();
        let search = tool_of(&list, "search");
        assert_eq!(search["read_only"], true, "{list}");
        assert_eq!(search["destructive"], false, "{list}");
        assert_eq!(search["title"], "Search", "{list}");
        assert_eq!(search["description"], "Finds things", "{list}");
        assert_eq!(search["input_schema"], json!({ "type": "object" }), "{list}");
        assert!(search["seen_at"].as_i64().unwrap() > 0, "{list}");
        let gone = tool_of(&list, "drop");
        assert_eq!(
            (gone["read_only"].clone(), gone["destructive"].clone()),
            (json!(false), json!(true))
        );
        assert!(gone["title"].is_null() && gone["input_schema"].is_null(), "{list}");
        let plain = tool_of(&list, "plain");
        assert_eq!(
            (plain["read_only"].clone(), plain["destructive"].clone()),
            (json!(false), json!(false))
        );

        // A later successful test lists only `search`: the others are gone.
        let second = answering(r#""result":{"tools":[{"name":"search","annotations":{"readOnlyHint":true}}]}"#);
        owner(&app, "integrations.update", json!({ "id": id, "args": ["-c", second] }))
            .await
            .unwrap();
        assert_eq!(
            owner(&app, "integrations.test", json!({ "id": id })).await.unwrap()["ok"],
            true
        );
        let list = owner(&app, "integrations.tools", json!({ "id": id })).await.unwrap();
        assert_eq!(tool_names_of(&list), ["search"], "{list}");

        // A test that fails keeps the list it had.
        owner(
            &app,
            "integrations.update",
            json!({ "id": id, "command": "/definitely/not/here" }),
        )
        .await
        .unwrap();
        assert_eq!(
            owner(&app, "integrations.test", json!({ "id": id })).await.unwrap()["ok"],
            false
        );
        let list = owner(&app, "integrations.tools", json!({ "id": id })).await.unwrap();
        assert_eq!(tool_names_of(&list), ["search"], "{list}");

        // Removing the integration removes its tools with it.
        owner(&app, "integrations.remove", json!({ "id": id })).await.unwrap();
        assert!(app.sup.hub().store.integration_tools(&id).unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_tool_call_over_stdio_returns_its_text_and_passes_is_error_through() {
        let app = app();
        let ok_id = add_sh(
            &app,
            "call-ok",
            &answering(r#""result":{"content":[{"type":"text","text":"hello"}],"isError":false}"#),
            json!({}),
        )
        .await;
        let answer = owner(
            &app,
            "integrations.call_tool",
            json!({ "id": ok_id, "tool": "echo", "arguments": { "text": "hello" } }),
        )
        .await
        .unwrap();
        assert_eq!(answer["is_error"], false, "{answer}");
        assert_eq!(
            answer["content"],
            json!([{ "type": "text", "text": "hello" }]),
            "{answer}"
        );

        let err_id = add_sh(
            &app,
            "call-err",
            &answering(r#""result":{"content":[{"type":"text","text":"no such row"}],"isError":true}"#),
            json!({}),
        )
        .await;
        let answer = owner(&app, "integrations.call_tool", json!({ "id": err_id, "tool": "get" }))
            .await
            .unwrap();
        assert_eq!(answer["is_error"], true, "{answer}");
        assert_eq!(answer["content"][0]["text"], "no such row", "{answer}");
    }

    #[tokio::test]
    async fn a_tool_call_over_http_sends_the_header_secret_and_returns_the_text() {
        let fake = crate::mcp_oauth::fake::Fake::start().await;
        let app = app();
        // The fake accepts the bearer token it issued first: `at-initial`.
        app.sup.hub().store.secret_set("FAKE_TOKEN", "at-initial", &[]).unwrap();
        let row = owner(
            &app,
            "integrations.add",
            json!({ "name": "fake-http", "kind": "http", "url": fake.url(),
                    "headers": { "Authorization": "Bearer secret:FAKE_TOKEN" } }),
        )
        .await
        .unwrap();
        let id = row["id"].as_str().unwrap().to_string();

        let answer = owner(
            &app,
            "integrations.call_tool",
            json!({ "id": id, "tool": "echo", "arguments": { "text": "hi" } }),
        )
        .await
        .unwrap();
        assert_eq!(answer["is_error"], false, "{answer}");
        assert_eq!(answer["content"][0]["text"], r#"echo {"text":"hi"}"#, "{answer}");

        let failed = owner(&app, "integrations.call_tool", json!({ "id": id, "tool": "fail" }))
            .await
            .unwrap();
        assert_eq!(failed["is_error"], true, "{failed}");
        assert!(!answer.to_string().contains("at-initial") && !failed.to_string().contains("at-initial"));
    }

    #[test]
    fn the_limit_of_an_http_post_is_the_call_limit_only_for_a_tool_call() {
        assert_eq!(max_time_for(&call_request("echo", &json!({}))), 30);
        assert_eq!(max_time_for(&list_request()), 15);
    }

    #[tokio::test]
    async fn a_request_of_the_server_is_not_taken_for_the_answer() {
        let app = app();
        // The server first sends its own request with id 2 (it has a `method`), then the answer to ours.
        let script = answering_after(
            r#"echo '{"jsonrpc":"2.0","id":2,"method":"roots/list"}';"#,
            r#""result":{"content":[{"type":"text","text":"the real answer"}],"isError":false}"#,
        );
        let id = add_sh(&app, "server-request", &script, json!({})).await;
        let answer = owner(&app, "integrations.call_tool", json!({ "id": id, "tool": "echo" }))
            .await
            .unwrap();
        assert_eq!(answer["content"][0]["text"], "the real answer", "{answer}");
    }

    #[tokio::test]
    async fn a_stdio_answer_over_one_megabyte_is_refused_without_being_read_in_full() {
        // A 5 MiB line comes before the answer: the reader stops at the limit and the server is killed.
        let server = Server {
            name: "big".into(),
            transport: Transport::Stdio {
                command: "sh".into(),
                args: vec![
                    "-c".into(),
                    answering_after(
                        "head -c 5242880 /dev/zero | tr '\\0' x; echo;",
                        r#""result":{"content":[],"isError":false}"#,
                    ),
                ],
                env: vec![],
            },
        };
        let started = std::time::Instant::now();
        let err = exchange(
            &server,
            Duration::from_secs(10),
            false,
            &call_request("echo", &json!({})),
        )
        .await
        .unwrap_err();
        assert!(err.to_string().contains("too large"), "{err}");
        assert!(
            started.elapsed() < Duration::from_secs(8),
            "refused at once, not at the timeout"
        );
    }

    #[tokio::test]
    async fn an_http_answer_over_one_megabyte_is_refused() {
        let fake = crate::mcp_oauth::fake::Fake::start().await;
        let app = app();
        app.sup.hub().store.secret_set("FAKE_TOKEN", "at-initial", &[]).unwrap();
        let row = owner(
            &app,
            "integrations.add",
            json!({ "name": "fake-big", "kind": "http", "url": fake.url(),
                    "headers": { "Authorization": "Bearer secret:FAKE_TOKEN" } }),
        )
        .await
        .unwrap();
        let id = row["id"].as_str().unwrap().to_string();
        let err = owner(&app, "integrations.call_tool", json!({ "id": id, "tool": "big" }))
            .await
            .unwrap_err();
        assert!(err.message.contains("too large"), "{}", err.message);
    }

    #[tokio::test]
    async fn a_turned_off_integration_is_not_called_and_a_tool_off_its_list_is_refused() {
        let app = app();
        let ran = answering(r#""result":{"content":[{"type":"text","text":"ran"}],"isError":false}"#);
        let id = add_sh(&app, "switched-off", &ran, json!({})).await;
        owner(&app, "integrations.update", json!({ "id": id, "enabled": false }))
            .await
            .unwrap();
        let err = owner(&app, "integrations.call_tool", json!({ "id": id, "tool": "echo" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("turned off"), "{}", err.message);

        // After a test, the list of tools is the check: a name off it is refused, a name on it is called.
        let listing = answering(r#""result":{"tools":[{"name":"search"}]}"#);
        let id = add_sh(&app, "listed-tools", &listing, json!({})).await;
        assert_eq!(
            owner(&app, "integrations.test", json!({ "id": id })).await.unwrap()["ok"],
            true
        );
        let err = owner(&app, "integrations.call_tool", json!({ "id": id, "tool": "missing" }))
            .await
            .unwrap_err();
        assert!(err.message.contains("no tool named missing"), "{}", err.message);
        let answer = owner(&app, "integrations.call_tool", json!({ "id": id, "tool": "search" }))
            .await
            .unwrap();
        assert_eq!(answer["is_error"], false, "{answer}");
    }

    #[tokio::test]
    async fn a_silent_tool_call_times_out_with_a_plain_message() {
        let server = Server {
            name: "silent".into(),
            transport: Transport::Stdio {
                command: "sleep".into(),
                args: vec!["30".into()],
                env: vec![],
            },
        };
        let request = call_request("echo", &json!({}));
        let err = exchange(&server, Duration::from_millis(300), false, &request)
            .await
            .unwrap_err();
        assert!(err.to_string().contains("no answer within"), "{err}");
        assert_eq!(CALL_TIMEOUT, Duration::from_secs(30));
    }

    #[tokio::test]
    async fn the_secret_of_a_header_or_env_never_shows_in_a_tool_answer_or_an_error() {
        let app = app();
        app.sup
            .hub()
            .store
            .secret_set("GITHUB_TOKEN", "tok-real-value", &[])
            .unwrap();
        let env = json!({ "TOKEN": "secret:GITHUB_TOKEN" });

        // The tool's text echoes the token: it is redacted.
        let echoing = add_sh(
            &app,
            "echo-secret",
            &answering(r#""result":{"content":[{"type":"text","text":"leaked tok-real-value"}],"isError":true}"#),
            env.clone(),
        )
        .await;
        let answer = owner(&app, "integrations.call_tool", json!({ "id": echoing, "tool": "t" }))
            .await
            .unwrap();
        let text = answer["content"][0]["text"].as_str().unwrap();
        assert!(
            text.contains("••••TOKEN") && !text.contains("tok-real-value"),
            "{answer}"
        );

        // The server's error echoes it: the RPC error hides it too.
        let failing = add_sh(
            &app,
            "error-secret",
            &answering(r#""error":{"code":-32602,"message":"bad token tok-real-value"}"#),
            env,
        )
        .await;
        let err = owner(&app, "integrations.call_tool", json!({ "id": failing, "tool": "t" }))
            .await
            .unwrap_err();
        assert!(
            err.message.contains("••••TOKEN") && !err.message.contains("tok-real-value"),
            "{}",
            err.message
        );
    }

    #[tokio::test]
    async fn a_tool_call_needs_an_owner_or_a_device_and_a_tool_name() {
        let app = app();
        let agent = super::super::Peer::Agent("someone".into());
        for method in ["integrations.call_tool", "integrations.tools"] {
            let err = super::super::dispatch(&app, &agent, method, json!({ "id": "x", "tool": "t" }))
                .await
                .unwrap_err();
            assert_eq!(err.code, super::super::UNAUTHORIZED, "{method}");
        }
        let nameless = owner(&app, "integrations.call_tool", json!({ "id": "x", "tool": " " }))
            .await
            .unwrap_err();
        assert_eq!(nameless.code, INVALID_PARAMS);
        assert!(super::super::features().contains(&"integrations_call_tool"));
    }

    #[test]
    fn a_schema_over_32_kilobytes_is_kept_as_none_and_annotations_read_as_hints() {
        let big = json!({ "type": "object", "description": "x".repeat(SCHEMA_BYTES) });
        let result = json!({ "tools": [
            { "name": "big", "inputSchema": big },
            { "name": "small", "inputSchema": { "type": "object" }, "annotations": { "readOnlyHint": "yes" } },
        ] });
        let tools = tools_of(&result, 7);
        assert_eq!(tools[0].input_schema, None);
        assert_eq!(tools[1].input_schema, Some(json!({ "type": "object" })));
        // A hint that is not `true` counts as not set.
        assert!(!tools[1].read_only && !tools[1].destructive);
        assert!(tools.iter().all(|t| t.seen_at == 7));
    }

    #[test]
    fn a_tool_answer_cuts_its_text_at_64_kilobytes_and_keeps_other_parts_by_type() {
        let long = "é".repeat(CALL_TEXT_BYTES); // two bytes each: 128 KB of text
        let result = json!({
            "content": [
                { "type": "text", "text": long },
                { "type": "text", "text": "after the cut" },
            ],
            "isError": false,
        });
        let answer = call_answer(&result, &Redactor::default());
        let parts = answer["content"].as_array().unwrap();
        assert_eq!(parts.len(), 1, "{answer}");
        assert_eq!(parts[0]["text"].as_str().unwrap().len(), CALL_TEXT_BYTES);

        let image = json!({ "content": [
            { "type": "image", "data": "AAAA", "mimeType": "image/png" },
            { "type": "text", "text": "a caption" },
        ] });
        let answer = call_answer(&image, &Redactor::default());
        assert_eq!(
            answer["content"],
            json!([{ "type": "image" }, { "type": "text", "text": "a caption" }])
        );
        assert_eq!(answer["is_error"], false);

        let echo = json!({ "content": [{ "type": "text", "text": "a tok-real-value b" }],
                           "structuredContent": { "k": "tok-real-value" } });
        let red = Redactor::exact([("TOKEN".to_string(), "tok-real-value".to_string())]);
        let answer = call_answer(&echo, &red);
        assert_eq!(answer["content"][0]["text"], "a ••••TOKEN b");
        assert_eq!(answer["structured"], json!({ "k": "••••TOKEN" }));
    }

    mod oauth {
        use super::super::super::{App, Peer, UNAUTHORIZED, dispatch, features};
        use crate::hub::Hub;
        use crate::mcp_oauth::fake::Fake;
        use crate::store::Store;
        use crate::supervisor::{Runtimes, Supervisor};
        use serde_json::{Value, json};
        use std::path::PathBuf;
        use std::sync::Arc;

        const METHODS: [&str; 5] = [
            "integrations.oauth_begin",
            "integrations.oauth_complete",
            "integrations.oauth_cancel",
            "integrations.oauth_status",
            "integrations.oauth_disconnect",
        ];

        fn app() -> Arc<App> {
            let store = Arc::new(Store::open_in_memory().unwrap());
            let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
            App::new(sup, PathBuf::from("unused-agents-root"))
        }

        async fn call(app: &App, method: &str, p: Value) -> super::super::RpcResult {
            dispatch(app, &Peer::Local, method, p).await
        }

        /// Sign in to the fake server as a new integration called `notion`.
        async fn sign_in(app: &App, fake: &Fake) -> Value {
            let begun = call(
                app,
                "integrations.oauth_begin",
                json!({ "draft": { "name": "notion", "kind": "http", "url": fake.url() } }),
            )
            .await
            .unwrap();
            let (code, state) = fake.authorize(begun["authorize_url"].as_str().unwrap());
            assert_eq!(begun["state"], state);
            call(
                app,
                "integrations.oauth_complete",
                json!({ "state": state, "code": code }),
            )
            .await
            .unwrap()
        }

        #[test]
        fn the_daemon_advertises_browser_sign_in() {
            assert!(features().contains(&"integrations_oauth"));
        }

        #[tokio::test]
        async fn agents_and_strangers_cannot_sign_in_to_anything() {
            let app = app();
            for method in METHODS {
                for peer in [Peer::Agent("a1".into()), Peer::Anonymous("1.2.3.4".into())] {
                    let err = dispatch(&app, &peer, method, json!({})).await.unwrap_err();
                    assert_eq!(err.code, UNAUTHORIZED, "{method}");
                    assert!(!crate::rpc::allowed(&peer, method), "{method}");
                }
            }
        }

        #[tokio::test]
        async fn a_sign_in_lists_as_oauth_hides_its_secrets_and_survives_a_probe() {
            let app = app();
            let fake = Fake::start().await;
            let done = sign_in(&app, &fake).await;
            let id = done["id"].as_str().unwrap().to_string();
            assert_eq!(
                (done["status"].as_str(), done["created"].as_bool()),
                (Some("connected"), Some(true))
            );
            // The list shows how it signs in, and no token.
            let access = fake.inner.lock().unwrap().access.clone();
            let list = call(&app, "integrations.list", json!({})).await.unwrap();
            assert_eq!(list[0]["auth"], "oauth");
            assert!(!list.to_string().contains(&access));
            // The secrets screen does not see the daemon's tokens, and cannot write or delete them.
            let secrets = call(&app, "secrets.list", json!({})).await.unwrap();
            assert_eq!(secrets, json!([]));
            let name = crate::integrations::oauth_access_name(&id);
            for (method, p) in [
                (
                    "secrets.set",
                    json!({ "name": name, "value": "stolen-value", "agents": [] }),
                ),
                ("secrets.delete", json!({ "name": name })),
            ] {
                assert!(call(&app, method, p).await.is_err(), "{method}");
            }
            // `integrations.test` reaches the server with the daemon's token.
            let tested = call(&app, "integrations.test", json!({ "id": id })).await.unwrap();
            assert_eq!(tested["ok"], true, "{tested}");
            assert_eq!(tested["tools"], json!(["search", "fetch"]));
            // Status.
            let st = call(&app, "integrations.oauth_status", json!({ "id": id }))
                .await
                .unwrap();
            assert_eq!(st["integrations"][0]["status"], "connected");
            assert!(!st.to_string().contains(&access));
        }

        #[tokio::test]
        async fn a_401_from_the_service_renews_the_token_and_tries_again() {
            let app = app();
            let fake = Fake::start().await;
            let done = sign_in(&app, &fake).await;
            let id = done["id"].as_str().unwrap();
            // The service stops accepting the stored token (revoked, rotated) but still honours the refresh token.
            fake.set(|i| i.access = "at-rotated-elsewhere".into());
            let stored_before = app
                .sup
                .hub()
                .store
                .secret_get(&crate::integrations::oauth_access_name(id))
                .unwrap();
            let tested = call(&app, "integrations.test", json!({ "id": id })).await.unwrap();
            assert_eq!(tested["ok"], true, "{tested}");
            let stored_after = app
                .sup
                .hub()
                .store
                .secret_get(&crate::integrations::oauth_access_name(id))
                .unwrap();
            assert_ne!(stored_before, stored_after);
            assert_eq!(stored_after, Some(fake.inner.lock().unwrap().access.clone()));
        }

        #[tokio::test]
        async fn when_the_service_refuses_the_refresh_too_the_answer_says_to_sign_in_again() {
            let app = app();
            let fake = Fake::start().await;
            let done = sign_in(&app, &fake).await;
            let id = done["id"].as_str().unwrap();
            fake.set(|i| {
                i.access = "at-rotated-elsewhere".into();
                i.refresh_failure = Some((400, "invalid_grant".into()));
            });
            let tested = call(&app, "integrations.test", json!({ "id": id })).await.unwrap();
            assert_eq!(
                (tested["ok"].as_bool(), tested["needs_login"].as_bool()),
                (Some(false), Some(true))
            );
            let st = call(&app, "integrations.oauth_status", json!({})).await.unwrap();
            assert_eq!(st["integrations"][0]["status"], "needs_login");
        }

        #[tokio::test]
        async fn disconnect_and_remove_delete_the_tokens_and_tell_the_service() {
            let app = app();
            let fake = Fake::start().await;
            let done = sign_in(&app, &fake).await;
            let id = done["id"].as_str().unwrap();
            let gone = call(&app, "integrations.oauth_disconnect", json!({ "id": id }))
                .await
                .unwrap();
            assert_eq!(gone, json!({ "revoked": true, "removed": false }));
            // The row stays, signed out.
            let st = call(&app, "integrations.oauth_status", json!({ "id": id }))
                .await
                .unwrap();
            assert_eq!(st["integrations"][0]["status"], "not_connected");
            // Signing in again, then removing the integration itself, takes the tokens with it.
            let begun = call(&app, "integrations.oauth_begin", json!({ "integration": id }))
                .await
                .unwrap();
            let (code, state) = fake.authorize(begun["authorize_url"].as_str().unwrap());
            let back = call(
                &app,
                "integrations.oauth_complete",
                json!({ "state": state, "code": code }),
            )
            .await
            .unwrap();
            assert_eq!(
                (back["id"].as_str(), back["created"].as_bool()),
                (Some(id), Some(false))
            );
            call(&app, "integrations.remove", json!({ "id": id })).await.unwrap();
            assert!(app.sup.hub().store.secrets_all().unwrap().is_empty());
            assert_eq!(fake.inner.lock().unwrap().revoked.len(), 4, "two tokens, twice");
        }

        #[tokio::test]
        async fn the_address_of_a_signed_in_integration_is_fixed_and_add_cannot_claim_oauth() {
            let app = app();
            let fake = Fake::start().await;
            let done = sign_in(&app, &fake).await;
            let id = done["id"].as_str().unwrap();
            let err = call(
                &app,
                "integrations.update",
                json!({ "id": id, "url": "https://other.example/mcp" }),
            )
            .await
            .unwrap_err();
            assert!(err.message.contains("disconnect"), "{}", err.message);
            call(&app, "integrations.update", json!({ "id": id, "enabled": false }))
                .await
                .unwrap();
            let err = call(
                &app,
                "integrations.add",
                json!({ "name": "x", "kind": "http", "url": "https://x.example/mcp", "auth": "oauth" }),
            )
            .await
            .unwrap_err();
            assert!(err.message.contains("oauth_begin"), "{}", err.message);
        }

        #[tokio::test]
        async fn a_draft_that_is_not_a_valid_integration_never_starts() {
            let app = app();
            for draft in [
                json!({ "name": "Bad Name", "kind": "http", "url": "https://x.example/mcp" }),
                json!({ "name": "stdio-one", "kind": "stdio", "command": "npx" }),
                json!({ "name": "plain", "kind": "http", "url": "http://x.example/mcp" }),
            ] {
                let err = call(&app, "integrations.oauth_begin", json!({ "draft": draft }))
                    .await
                    .unwrap_err();
                assert_eq!(err.code, crate::rpc::INVALID_PARAMS, "{draft}");
            }
            let err = call(&app, "integrations.oauth_begin", json!({})).await.unwrap_err();
            assert_eq!(err.code, crate::rpc::INVALID_PARAMS);
        }
    }
}
