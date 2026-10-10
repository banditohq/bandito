//! `integrations.*` JSON-RPC methods: the owner's MCP servers for the agents, the template catalog, and a test
//! that starts a server and lists its tools. Owner and apps only. See docs/ARCHITECTURE.md#integrations.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::integrations::{self, Pair, Server, Transport};
use crate::mcp_oauth::{self, Outcome, Target, Why};
use crate::recommend;
use crate::store::{Integration, IntegrationAuth, IntegrationPatch, NewIntegration, Store, now_ms};
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
        "integrations.list" => ok(store.integration_list()?),
        "integrations.catalog" => ok(serde_json::from_str::<Value>(CATALOG_JSON)
            .map_err(|e| RpcError::new(SERVER_ERROR, format!("catalog: {e}")))?),
        "integrations.add" => {
            let n: NewIntegration = params(p)?;
            if n.auth == IntegrationAuth::Oauth {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    "a browser sign-in is started with integrations.oauth_begin",
                ));
            }
            check_new(&n)?;
            if store.integration_list()?.iter().any(|i| i.name == n.name) {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("an integration named '{}' already exists", n.name),
                ));
            }
            ok(store.integration_create(n)?)
        }
        "integrations.update" => {
            let UpdateParams { id, patch } = params(p)?;
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
            if patch.name.as_deref().is_some_and(|n| n != cur.name)
                && store
                    .integration_list()?
                    .iter()
                    .any(|i| Some(&i.name) == patch.name.as_ref())
            {
                return Err(RpcError::new(INVALID_PARAMS, "that name is taken"));
            }
            ok(store.integration_update(&id, patch)?)
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

/// What `integrations.test` and `integrations.probe` answer for `row`: the server starts (or is reached) and its
/// tools come back, or the error. With `draft`, every value of the row's environment and headers is a secret for
/// the error text, since the owner typed them and they are not stored.
async fn probe_row(store: &Store, row: &Integration, draft: bool) -> RpcResult {
    let oauth = row.auth == IntegrationAuth::Oauth;
    let sign_in =
        || ok(json!({ "ok": false, "tools": [], "error": "sign in to this service again", "needs_login": true }));
    if oauth {
        if draft {
            return ok(
                json!({ "ok": false, "tools": [], "error": "a browser sign-in cannot be tried before it is done" }),
            );
        }
        // A token that is about to end is renewed first.
        match mcp_oauth::refresh(store, &row.id, Why::Expiring(mcp_oauth::SESSION_SKEW_MS), now_ms()).await {
            Ok(Outcome::NeedsLogin) => return sign_in(),
            Ok(_) => {}
            Err(e) => tracing::warn!(integration = row.name, "{e:#}"),
        }
    }
    let mut result = run_probe(store, row, draft).await;
    if oauth
        && let Err(e) = &result
        && e.downcast_ref::<HttpStatus>().is_some_and(|s| s.0 == 401)
        && let Some(stale) = mcp_oauth::access_token(store, &row.id)?
    {
        // The service refused the token: renew it once and try again.
        match mcp_oauth::refresh(store, &row.id, Why::Rejected(stale), now_ms()).await {
            Ok(Outcome::Refreshed) => result = run_probe(store, row, draft).await,
            Ok(Outcome::NeedsLogin) => return sign_in(),
            Ok(Outcome::Unchanged | Outcome::Waiting) => result = run_probe(store, row, draft).await,
            Err(e) => tracing::warn!(integration = row.name, "{e:#}"),
        }
    }
    match result {
        Ok(tools) => ok(json!({ "ok": true, "tools": tools })),
        Err(e) => ok(json!({ "ok": false, "tools": [], "error": format!("{e:#}") })),
    }
}

/// One run of the probe for `row`, with the secrets it names read now.
async fn run_probe(store: &Store, row: &Integration, draft: bool) -> anyhow::Result<Vec<String>> {
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
    probe_guarded(&server, TEST_TIMEOUT, row.auth == IntegrationAuth::Oauth).await
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

/// Start the server (or reach it) and ask for its tools: `initialize`, `notifications/initialized`,
/// `tools/list`. Stops after `limit`, and kills the whole process group it started: no child of the server
/// outlives the probe. Returns the tool names. A failure carries the tail of the server's stderr, redacted.
pub async fn probe(server: &Server, limit: Duration) -> anyhow::Result<Vec<String>> {
    probe_guarded(server, limit, false).await
}

/// [`probe`]; with `public_only` (a row that signs in in the browser, whose requests carry the daemon's token) an
/// http address gets the checks and the pinning of the sign-in itself (`mcp_oauth::guard_http`) before a token is sent.
async fn probe_guarded(server: &Server, limit: Duration, public_only: bool) -> anyhow::Result<Vec<String>> {
    match &server.transport {
        Transport::Stdio { command, args, env } => probe_stdio(command, args, env, limit).await,
        Transport::Http { url, headers } => probe_http(url, headers, limit, public_only).await,
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

async fn probe_stdio(command: &str, args: &[String], env: &[Pair], limit: Duration) -> anyhow::Result<Vec<String>> {
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
        let mut lines = BufReader::new(child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?).lines();
        send(&mut stdin, &initialize_request()).await?;
        read_reply(&mut lines, 1).await?;
        send(
            &mut stdin,
            &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
        )
        .await?;
        send(&mut stdin, &list_request()).await?;
        let tools = read_reply(&mut lines, 2).await?;
        anyhow::Ok(tool_names(&tools))
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

/// Reads lines until the reply with this id; other lines (notifications, logs) are skipped. Returns its result.
async fn read_reply<R: tokio::io::AsyncBufRead + Unpin>(
    lines: &mut tokio::io::Lines<R>,
    id: u64,
) -> anyhow::Result<Value> {
    while let Some(line) = lines.next_line().await? {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if msg.get("id").and_then(Value::as_u64) == Some(id) {
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

fn tool_names(result: &Value) -> Vec<String> {
    result
        .get("tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .filter_map(|t| t.get("name").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Streamable HTTP through `curl`, its config (URL, headers, body) fed on stdin so no header value reaches argv.
/// Stops after `limit` as the stdio probe does.
async fn probe_http(url: &str, headers: &[Pair], limit: Duration, public_only: bool) -> anyhow::Result<Vec<String>> {
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
        let listed = http_post(url, headers, &list_request(), session.as_deref(), public_only).await?;
        let reply = find_reply(&listed.body, 2).ok_or_else(|| anyhow::anyhow!("no tools/list answer"))?;
        anyhow::Ok(tool_names(&result_of(&reply)?))
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
    config.push_str("request = \"POST\"\nsilent\nshow-error\ninclude\nmax-time = 15\n");
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
        assert_eq!(tool_names(&result_of(&reply).unwrap()), ["fetch"]);
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
