//! Signing in with a code (OAuth Device Flow, RFC 8628), the way `gh auth login` does: the person gets a short code,
//! types it on the provider's page, and the daemon, which polls the provider meanwhile, receives the token. No secret
//! is needed: the client id of a Device Flow app is public. See docs/ARCHITECTURE.md#integrations.
//!
//! The providers are a list in this file (addresses, client id, scope, the MCP address the token may be sent to).
//! Nothing of that comes from the catalog or from a request: a request names an integration, and its address picks
//! the provider. The token goes into the same secret as a browser sign-in's (`oauth_access_name`) and is put into the
//! `Authorization` header when a session starts; the app never sees it. Requests go through the same `send` as the
//! browser sign-in (public addresses only, pinned, the request on stdin), and nothing here writes the device code or
//! a token to a log or an error.

use super::*;
use crate::store::now_ms;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU64, Ordering};

/// How long a finished flow stays readable, for an app that asks late.
const KEEP_FINISHED_MS: i64 = 10 * 60 * 1000;
/// Flows kept at once; the oldest finished (then the oldest) is dropped past this.
const MAX_DEVICE_FLOWS: usize = 32;
/// Answers in a row that could not be read (no network, a 5xx, no JSON) before the flow gives up.
const MAX_TRANSIENT: u32 = 8;
/// `slow_down` makes the interval this much longer (RFC 8628, section 3.5).
const SLOW_DOWN_SECONDS: u64 = 5;
/// The grant type of the poll.
const GRANT_TYPE: &str = "urn:ietf:params:oauth:grant-type:device_code";

/// A service whose code sign-in Bandito knows.
#[derive(Clone, Debug)]
pub struct Provider {
    pub id: String,
    pub client_id: String,
    pub scope: String,
    /// Where the code is asked for.
    pub code_url: String,
    /// Where the token is polled for.
    pub token_url: String,
    /// The MCP servers the token may be sent to.
    pub servers: Vec<String>,
}

/// The providers built into the daemon.
fn builtin() -> Vec<Provider> {
    vec![Provider {
        id: "github".into(),
        client_id: "Ov23li0wlXVpaoceVJoD".into(),
        scope: "repo read:org read:user".into(),
        code_url: "https://github.com/login/device/code".into(),
        token_url: "https://github.com/login/oauth/access_token".into(),
        servers: vec!["https://api.githubcopilot.com/mcp/".into()],
    }]
}

/// A built-in provider by id (the catalog test holds the catalog's `device` field to it).
#[cfg(test)]
pub(crate) fn builtin_provider(id: &str) -> Option<Provider> {
    builtin().into_iter().find(|p| p.id == id)
}

/// Whether two server addresses are the same one (a trailing slash does not matter).
fn same_server(a: &str, b: &str) -> bool {
    match (Url::parse(a), Url::parse(b)) {
        (Ok(a), Ok(b)) => {
            a.https == b.https
                && a.host == b.host
                && a.port == b.port
                && a.trimmed_path() == b.trimmed_path()
                && a.query == b.query
        }
        _ => false,
    }
}

/// The servers a test's fake provider serves: a token of a code sign-in may go to them as to the built-in ones.
#[cfg(test)]
static TEST_SERVERS: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Whether a token of a code sign-in may be sent to this address: only a provider's own MCP server.
pub fn server_allowed(url: &str) -> bool {
    #[cfg(test)]
    if TEST_SERVERS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .any(|s| same_server(s, url))
    {
        return true;
    }
    builtin().iter().any(|p| p.servers.iter().any(|s| same_server(s, url)))
}

/// What the daemon keeps besides the token (secret `…_STATE`, JSON).
#[derive(Serialize, Deserialize, Clone)]
struct DeviceState {
    provider: String,
    #[serde(default)]
    scope: Option<String>,
    #[serde(default)]
    issued_at: Option<i64>,
    /// The service refused the token (HTTP 401): the person signs in again.
    #[serde(default)]
    needs_login: bool,
}

fn load_state(store: &Store, id: &str) -> Result<Option<DeviceState>> {
    let Some(text) = store.secret_get(&oauth_state_name(id))? else {
        return Ok(None);
    };
    Ok(serde_json::from_str(&text).ok())
}

/// Whether the person has to sign in: there is no token, or the service refused it.
pub fn needs_sign_in(store: &Store, id: &str) -> bool {
    let has_token = matches!(store.secret_get(&oauth_access_name(id)), Ok(Some(_)));
    let refused = load_state(store, id).ok().flatten().is_some_and(|s| s.needs_login);
    !has_token || refused
}

/// The sign-in state of a code-signed integration, in the words of the browser sign-in's: `connected`, `needs_login`
/// (the service refused the token) or `not_connected`.
pub fn status(store: &Store, id: &str) -> Result<Status> {
    let has_token = store.secret_get(&oauth_access_name(id))?.is_some();
    let state = load_state(store, id)?;
    let (status, scope) = match (has_token, state) {
        (false, _) => ("not_connected", None),
        (true, Some(s)) if s.needs_login => ("needs_login", s.scope),
        (true, Some(s)) => ("connected", s.scope),
        (true, None) => ("connected", None),
    };
    Ok(Status {
        status,
        expires_at: None,
        scope,
        error: None,
    })
}

/// The service said 401 to the token: marks it, so the app asks for a new sign-in. The token stays until then.
pub async fn mark_rejected(store: &Store, id: &str) {
    let _guard = lock(id).await;
    let mut state = load_state(store, id).ok().flatten().unwrap_or(DeviceState {
        provider: String::new(),
        scope: None,
        issued_at: None,
        needs_login: false,
    });
    state.needs_login = true;
    let saved = serde_json::to_string(&state)
        .map_err(anyhow::Error::from)
        .and_then(|text| store.secrets_set_many(&[(&oauth_state_name(id), &text)]));
    if let Err(e) = saved {
        tracing::warn!("could not mark a refused sign-in: {e:#}");
    }
}

/// Deletes the token and its state. The provider cannot be told without a client secret, so nothing is revoked
/// there (`false`): the person removes the access at the provider's page.
pub async fn disconnect(store: &Store, id: &str) -> Result<bool> {
    let _guard = lock(id).await;
    store.secrets_delete_many(&[&oauth_access_name(id), &oauth_state_name(id)])?;
    Ok(false)
}

// ---- flows ----

#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Pending,
    /// The token is being stored; a cancel no longer takes effect.
    Finishing,
    Done {
        integration_id: String,
        name: String,
        created: bool,
    },
    Failed {
        reason: &'static str,
        message: String,
    },
    Cancelled,
}

struct DeviceFlow {
    /// Who started it: only this device may read or cancel it.
    device: String,
    /// The integration id, or `draft:<name>`: one flow per target.
    key: String,
    user_code: String,
    verification_uri: String,
    expires_at: i64,
    interval: u64,
    phase: Phase,
    /// Set when a flow ends, for the keeping time.
    ended_at: Option<i64>,
    created_at: i64,
    task: Option<tokio::task::AbortHandle>,
}

#[derive(Default)]
struct Shared {
    map: Mutex<HashMap<String, DeviceFlow>>,
    /// Milliseconds per second of interval; 0 is 1000. Tests make it small.
    tick_ms: AtomicU64,
    #[cfg(test)]
    providers: Mutex<Option<Vec<Provider>>>,
}

/// The code sign-ins in progress or just ended.
#[derive(Clone, Default)]
pub struct DeviceFlows(Arc<Shared>);

/// What `begin` hands back.
#[derive(Debug, Clone)]
pub struct DeviceBegun {
    pub flow_id: String,
    pub user_code: String,
    pub verification_uri: String,
    pub expires_at: i64,
    pub interval: u64,
}

/// Run after a sign-in is stored, with the integration id: the daemon renews the sessions that have it.
pub type After = Arc<dyn Fn(String) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

impl DeviceFlows {
    fn providers(&self) -> Vec<Provider> {
        #[cfg(test)]
        if let Some(list) = self.0.providers.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return list;
        }
        builtin()
    }

    fn tick(&self) -> Duration {
        match self.0.tick_ms.load(Ordering::Relaxed) {
            0 => Duration::from_millis(1000),
            ms => Duration::from_millis(ms),
        }
    }

    /// Tests: other providers (a fake server) and a short second.
    #[cfg(test)]
    pub(crate) fn for_test(&self, providers: Vec<Provider>, tick_ms: u64) {
        TEST_SERVERS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .extend(providers.iter().flat_map(|p| p.servers.clone()));
        *self.0.providers.lock().unwrap_or_else(|e| e.into_inner()) = Some(providers);
        self.0.tick_ms.store(tick_ms.max(1), Ordering::Relaxed);
    }

    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<String, DeviceFlow>> {
        self.0.map.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Cancels the flows of a target that wait (a new begin for it, a disconnect). Returns whether there were any.
    pub fn cancel_target(&self, key: &str) -> bool {
        let mut map = self.map();
        let now = now_ms();
        let mut any = false;
        for flow in map.values_mut().filter(|f| f.key == key && f.phase == Phase::Pending) {
            flow.phase = Phase::Cancelled;
            flow.ended_at = Some(now);
            if let Some(task) = flow.task.take() {
                task.abort();
            }
            any = true;
        }
        any
    }

    /// Cancels one flow of `device`. `false` when it is not waiting (unknown, ended, or already storing its token).
    pub fn cancel(&self, flow_id: &str, device: &str) -> bool {
        let mut map = self.map();
        let Some(flow) = map.get_mut(flow_id).filter(|f| f.device == device) else {
            return false;
        };
        if flow.phase != Phase::Pending {
            return false;
        }
        flow.phase = Phase::Cancelled;
        flow.ended_at = Some(now_ms());
        if let Some(task) = flow.task.take() {
            task.abort();
        }
        true
    }

    /// The state of a flow of `device`, as the app reads it.
    pub fn view(&self, flow_id: &str, device: &str) -> Result<Value> {
        let map = self.map();
        let flow = map
            .get(flow_id)
            .filter(|f| f.device == device)
            .ok_or_else(|| anyhow!("this sign-in is not waiting any more: start it again"))?;
        let mut v = json!({
            "flow_id": flow_id,
            "user_code": flow.user_code,
            "verification_uri": flow.verification_uri,
            "expires_at": flow.expires_at,
            "interval": flow.interval,
        });
        match &flow.phase {
            Phase::Pending | Phase::Finishing => v["state"] = json!("pending"),
            Phase::Done {
                integration_id,
                name,
                created,
            } => {
                v["state"] = json!("done");
                v["id"] = json!(integration_id);
                v["name"] = json!(name);
                v["created"] = json!(created);
            }
            Phase::Failed { reason, message } => {
                v["state"] = json!("failed");
                v["reason"] = json!(reason);
                v["error"] = json!(message);
            }
            Phase::Cancelled => v["state"] = json!("cancelled"),
        }
        Ok(v)
    }

    /// Changes a flow only while it is `from`; `false` when it was not (cancelled meanwhile).
    fn advance(&self, flow_id: &str, from: &Phase, to: Phase) -> bool {
        let mut map = self.map();
        let Some(flow) = map.get_mut(flow_id).filter(|f| f.phase == *from) else {
            return false;
        };
        if !matches!(to, Phase::Pending | Phase::Finishing) {
            flow.ended_at = Some(now_ms());
        }
        flow.phase = to;
        true
    }

    fn pending(&self, flow_id: &str) -> bool {
        self.map().get(flow_id).is_some_and(|f| f.phase == Phase::Pending)
    }

    fn set_interval(&self, flow_id: &str, interval: u64) {
        if let Some(flow) = self.map().get_mut(flow_id) {
            flow.interval = interval;
        }
    }

    fn fail(&self, flow_id: &str, reason: &'static str, message: impl Into<String>) {
        self.advance(
            flow_id,
            &Phase::Pending,
            Phase::Failed {
                reason,
                message: message.into(),
            },
        );
    }
}

/// What a code sign-in is for.
pub enum DeviceTarget {
    Existing(Integration),
    Draft(NewIntegration),
}

/// The part of a target the poll task needs after the start.
enum Goal {
    Existing { id: String, url: String },
    Draft(Box<NewIntegration>),
}

/// The answer to the request for a code, read.
struct Code {
    device_code: String,
    user_code: String,
    verification_uri: String,
    expires_in: u64,
    interval: u64,
}

fn bounded(v: Option<&Value>, default: u64, min: u64, max: u64) -> u64 {
    v.and_then(|v| v.as_u64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        .unwrap_or(default)
        .clamp(min, max)
}

/// Reads the provider's answer to the request for a code. The device code is for the poll alone; the user code is
/// short and typed by a person; the page to open must be on the provider's own host.
fn read_code(resp: &Resp, provider: &Provider) -> Result<Code> {
    let body = resp.json().ok();
    if let Some(code) = body.as_ref().and_then(error_code) {
        if code == "device_flow_disabled" {
            bail!("the service has the code sign-in turned off for Bandito");
        }
        bail!("the service refused to start the sign-in ({code})");
    }
    if resp.status != 200 {
        bail!("the service answered HTTP {} to the sign-in", resp.status);
    }
    let body = body.ok_or_else(|| anyhow!("the service did not answer the sign-in with JSON"))?;
    let text = |key: &str| body.get(key).and_then(Value::as_str).unwrap_or_default().to_string();
    let (device_code, user_code, verification_uri) = (text("device_code"), text("user_code"), text("verification_uri"));
    if device_code.is_empty()
        || device_code.len() > 1024
        || device_code.chars().any(|c| c.is_control() || c.is_whitespace())
    {
        bail!("the service's sign-in answer has no usable device code");
    }
    if user_code.is_empty() || user_code.len() > 32 || !user_code.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
    {
        bail!("the service's sign-in answer has no usable code");
    }
    let page = Url::parse(&verification_uri).map_err(|_| anyhow!("the service's sign-in page is not valid"))?;
    let home = Url::parse(&provider.code_url)?;
    if page.host != home.host || (!page.https && !allow_local()) {
        bail!("the service's sign-in page is not on the service's own site");
    }
    Ok(Code {
        device_code,
        user_code,
        verification_uri: page.text(),
        expires_in: bounded(body.get("expires_in"), 900, 1, 1800),
        interval: bounded(body.get("interval"), 5, 1, 60),
    })
}

/// Starts a code sign-in for `device`: asks the provider for a code and starts the task that polls for the token.
/// A flow still waiting for the same target is cancelled. The target's address picks the provider.
pub async fn begin(
    store: &Arc<Store>,
    flows: &DeviceFlows,
    device: &str,
    target: DeviceTarget,
    after: After,
) -> Result<DeviceBegun> {
    let (key, goal, kind, url) = match target {
        DeviceTarget::Existing(row) => {
            if row.auth == IntegrationAuth::Oauth {
                bail!("this integration signs in in the browser: disconnect it first");
            }
            (
                row.id.clone(),
                Goal::Existing {
                    id: row.id,
                    url: row.url.clone().unwrap_or_default(),
                },
                row.kind,
                row.url,
            )
        }
        DeviceTarget::Draft(n) => {
            let (kind, url) = (n.kind, n.url.clone());
            (format!("draft:{}", n.name), Goal::Draft(Box::new(n)), kind, url)
        }
    };
    if kind != IntegrationKind::Http {
        bail!("only an http integration can sign in with a code");
    }
    let url = url
        .filter(|u| !u.trim().is_empty())
        .ok_or_else(|| anyhow!("the integration has no url"))?;
    let provider = flows
        .providers()
        .into_iter()
        .find(|p| p.servers.iter().any(|s| same_server(s, &url)))
        .ok_or_else(|| anyhow!("this service has no sign-in with a code"))?;
    let code_url = Url::parse(&provider.code_url)?;
    check_remote_url(&code_url, "sign-in address", allow_local())?;
    let body = form(&[("client_id", &provider.client_id), ("scope", &provider.scope)]);
    let resp = send(Req::post(&code_url, "application/x-www-form-urlencoded", body))
        .await
        .map_err(|e| {
            anyhow!(
                "the sign-in could not be started: {}",
                clean(&format!("{e:#}"), &Redactor::default(), 200)
            )
        })?;
    let code = read_code(&resp, &provider)?;
    let now = now_ms();
    let flow_id = crate::store::new_id();
    let expires_at = now + code.expires_in as i64 * 1000;
    {
        let mut map = flows.map();
        // A flow still waiting for this target ends: its code would only confuse the person.
        for old in map.values_mut().filter(|f| f.key == key && f.phase == Phase::Pending) {
            old.phase = Phase::Cancelled;
            old.ended_at = Some(now);
            if let Some(task) = old.task.take() {
                task.abort();
            }
        }
        map.retain(|_, f| f.ended_at.is_none_or(|t| now - t <= KEEP_FINISHED_MS));
        while map.len() >= MAX_DEVICE_FLOWS {
            // A flow that is storing its token is never dropped: when all are, the new sign-in is refused.
            let oldest = map
                .iter()
                .filter(|(_, f)| f.phase != Phase::Finishing)
                .min_by_key(|(_, f)| f.created_at)
                .map(|(id, _)| id.clone());
            let Some(id) = oldest else {
                bail!("busy: too many code sign-ins are being stored, try again in a moment");
            };
            if let Some(task) = map.remove(&id).and_then(|f| f.task) {
                task.abort();
            }
        }
        let ctx = Ctx {
            flows: flows.clone(),
            store: store.clone(),
            flow_id: flow_id.clone(),
            provider,
            goal,
            after,
        };
        let handle = tokio::spawn(poll(ctx, code.device_code, code.interval, expires_at));
        map.insert(
            flow_id.clone(),
            DeviceFlow {
                device: device.to_string(),
                key,
                user_code: code.user_code.clone(),
                verification_uri: code.verification_uri.clone(),
                expires_at,
                interval: code.interval,
                phase: Phase::Pending,
                ended_at: None,
                created_at: now,
                task: Some(handle.abort_handle()),
            },
        );
    }
    Ok(DeviceBegun {
        flow_id,
        user_code: code.user_code,
        verification_uri: code.verification_uri,
        expires_at,
        interval: code.interval,
    })
}

struct Ctx {
    flows: DeviceFlows,
    store: Arc<Store>,
    flow_id: String,
    provider: Provider,
    goal: Goal,
    after: After,
}

/// What one poll came to.
enum Poll {
    Token { access: String, scope: Option<String> },
    Pending,
    SlowDown,
    Expired,
    Denied,
    Refused(String),
    Transient,
}

async fn poll_once(provider: &Provider, device_code: &str) -> Poll {
    let Ok(url) = Url::parse(&provider.token_url) else {
        return Poll::Refused("bad_address".into());
    };
    let body = form(&[
        ("client_id", &provider.client_id),
        ("device_code", device_code),
        ("grant_type", GRANT_TYPE),
    ]);
    let Ok(resp) = send(Req::post(&url, "application/x-www-form-urlencoded", body)).await else {
        return Poll::Transient;
    };
    let Ok(body) = resp.json() else {
        return Poll::Transient;
    };
    if let Some(access) = body
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty() && resp.status == 200)
    {
        if body
            .get("token_type")
            .and_then(Value::as_str)
            .is_some_and(|t| !t.eq_ignore_ascii_case("bearer"))
        {
            return Poll::Refused("token_type".into());
        }
        return Poll::Token {
            access: access.to_string(),
            scope: body
                .get("scope")
                .and_then(Value::as_str)
                .map(|s| clean(s, &Redactor::default(), 500))
                .filter(|s| !s.is_empty()),
        };
    }
    match error_code(&body).as_deref() {
        Some("authorization_pending") => Poll::Pending,
        Some("slow_down") => Poll::SlowDown,
        Some("expired_token") => Poll::Expired,
        Some("access_denied") => Poll::Denied,
        Some(other) => Poll::Refused(other.to_string()),
        None => Poll::Transient,
    }
}

/// The task of a flow: polls at the provider's interval until the person confirms, refuses, or the code ends.
async fn poll(ctx: Ctx, device_code: String, mut interval: u64, expires_at: i64) {
    let mut transient = 0u32;
    loop {
        tokio::time::sleep(ctx.flows.tick() * interval as u32).await;
        if !ctx.flows.pending(&ctx.flow_id) {
            return;
        }
        if now_ms() >= expires_at {
            ctx.flows
                .fail(&ctx.flow_id, "expired", "the code expired: start the sign-in again");
            return;
        }
        match poll_once(&ctx.provider, &device_code).await {
            Poll::Token { access, scope } => {
                finish(&ctx, access, scope).await;
                return;
            }
            Poll::Pending => transient = 0,
            Poll::SlowDown => {
                transient = 0;
                interval = (interval + SLOW_DOWN_SECONDS).min(600);
                ctx.flows.set_interval(&ctx.flow_id, interval);
            }
            Poll::Expired => {
                ctx.flows
                    .fail(&ctx.flow_id, "expired", "the code expired: start the sign-in again");
                return;
            }
            Poll::Denied => {
                ctx.flows
                    .fail(&ctx.flow_id, "denied", "the sign-in was refused on the service's page");
                return;
            }
            Poll::Refused(code) => {
                ctx.flows.fail(
                    &ctx.flow_id,
                    "refused",
                    format!("the service refused the sign-in ({code})"),
                );
                return;
            }
            Poll::Transient => {
                transient += 1;
                if transient >= MAX_TRANSIENT {
                    ctx.flows.fail(
                        &ctx.flow_id,
                        "network",
                        "the service could not be reached: check the connection and start again",
                    );
                    return;
                }
            }
        }
    }
}

/// Stores the token and the integration it signs in, then lets the daemon renew the sessions. A cancel that came
/// first wins: the token is dropped.
async fn finish(ctx: &Ctx, access: String, scope: Option<String>) {
    if !ctx.flows.advance(&ctx.flow_id, &Phase::Pending, Phase::Finishing) {
        return;
    }
    match commit(ctx, &access, scope).await {
        Ok((row, created)) => {
            let id = row.id.clone();
            ctx.flows.advance(
                &ctx.flow_id,
                &Phase::Finishing,
                Phase::Done {
                    integration_id: row.id,
                    name: row.name,
                    created,
                },
            );
            (ctx.after)(id).await;
        }
        Err(e) => {
            let reason = lost_reason(&e);
            let text = Redactor::exact([("TOKEN".to_string(), access)])
                .redact(&format!("{e:#}"))
                .into_owned();
            tracing::warn!("a code sign-in could not be stored");
            ctx.flows.advance(
                &ctx.flow_id,
                &Phase::Finishing,
                Phase::Failed {
                    reason,
                    message: clean(&text, &Redactor::default(), 300),
                },
            );
        }
    }
}

/// Why a code sign-in cannot be stored: its integration went away or changed while the sign-in was open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Lost {
    Changed,
    Gone,
}

impl std::fmt::Display for Lost {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Lost::Changed => "the integration changed while the sign-in was open",
            Lost::Gone => "that integration was removed while the sign-in was open",
        })
    }
}

impl std::error::Error for Lost {}

/// The reason a flow ends with, for an error of `commit`: `store` unless the integration was lost.
fn lost_reason(e: &anyhow::Error) -> &'static str {
    match e.downcast_ref::<Lost>() {
        Some(Lost::Changed) => "changed",
        Some(Lost::Gone) => "gone",
        None => "store",
    }
}

/// Marks the row as signed in with a code, if it still has the address the token was asked for.
fn set_device_sign_in(store: &Store, id: &str, url: &str) -> Result<()> {
    if store.integration_set_auth_if_url(id, url, IntegrationAuth::Device)? {
        return Ok(());
    }
    match store.integration_get(id)? {
        Some(_) => Err(Lost::Changed.into()),
        None => Err(Lost::Gone.into()),
    }
}

async fn commit(ctx: &Ctx, access: &str, scope: Option<String>) -> Result<(Integration, bool)> {
    let store = &ctx.store;
    let (row, created) = match &ctx.goal {
        Goal::Existing { id, url } => {
            let Some(row) = store.integration_get(id)? else {
                return Err(Lost::Gone.into());
            };
            if row.auth == IntegrationAuth::Oauth {
                bail!("that integration signs in in the browser now");
            }
            if row.url.as_deref() != Some(url.as_str()) {
                return Err(Lost::Changed.into());
            }
            (row, false)
        }
        Goal::Draft(draft) => {
            if store.integration_list()?.iter().any(|i| i.name == draft.name) {
                bail!("an integration named '{}' already exists", draft.name);
            }
            let mut draft = (**draft).clone();
            draft.auth = IntegrationAuth::Device;
            (store.integration_create(draft)?, true)
        }
    };
    let _guard = lock(&row.id).await;
    let state = DeviceState {
        provider: ctx.provider.id.clone(),
        scope: scope.or_else(|| Some(ctx.provider.scope.clone())),
        issued_at: Some(now_ms()),
        needs_login: false,
    };
    let url = row.url.clone().unwrap_or_default();
    let saved = serde_json::to_string(&state)
        .map_err(anyhow::Error::from)
        .and_then(|text| {
            store.secrets_set_many(&[
                (&oauth_access_name(&row.id), access),
                (&oauth_state_name(&row.id), &text),
            ])
        })
        .and_then(|()| set_device_sign_in(store, &row.id, &url));
    if let Err(e) = saved {
        // Nothing of this sign-in stays: the token is deleted again, and a row made for it goes too.
        let _ = store.secrets_delete_many(&[&oauth_access_name(&row.id), &oauth_state_name(&row.id)]);
        if created {
            let _ = store.integration_delete(&row.id);
        }
        return Err(e.context("could not store the sign-in"));
    }
    let row = store.integration_get(&row.id)?.unwrap_or(row);
    Ok((row, created))
}

#[cfg(test)]
mod tests;
