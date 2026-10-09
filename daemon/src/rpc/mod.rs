//! JSON-RPC 2.0, the same on every transport (unix socket, WebSocket).
//! See docs/ARCHITECTURE.md#rpc.

use crate::event::{Decision, Event};
use crate::pairing;
use crate::scheduler;
use crate::store::{AgentPatch, Device, NewAgent, NewSchedule, RuleAction, SchedulePatch};
use crate::supervisor::{Inbound, Supervisor};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};
use tokio::sync::{broadcast, mpsc};

pub mod unix;
pub mod ws;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Capabilities this daemon offers. Clients show a feature only when it is
/// listed, so new apps keep working with older daemons. Add a string here in
/// the same PR that adds the feature.
pub const FEATURES: &[&str] = &["approvals", "rules", "schedules", "crew", "pairing"];

/// Shared state for all connections.
pub struct App {
    pub sup: Arc<Supervisor>,
    pub started_at: i64,
    pub hostname: String,
    /// Timestamps of failed `pair.redeem` calls (rate limit).
    redeem_failures: Mutex<VecDeque<i64>>,
}

impl App {
    pub fn new(sup: Arc<Supervisor>) -> Arc<Self> {
        Arc::new(Self {
            sup,
            started_at: crate::store::now_ms(),
            hostname: hostname(),
            redeem_failures: Mutex::new(VecDeque::new()),
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
}

pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const SERVER_ERROR: i64 = -32000;
pub const UNAUTHORIZED: i64 = -32001;
pub const RATE_LIMITED: i64 = -32002;

impl RpcError {
    fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
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
}
fn double_option<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<Option<String>>, D::Error> {
    Option::<String>::deserialize(d).map(Some)
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

/// Handle one request. `events.subscribe` lives in [`serve`] because it needs
/// connection state.
pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    if matches!(peer, Peer::Anonymous) && !matches!(method, "daemon.hello" | "pair.redeem") {
        return Err(RpcError::new(
            UNAUTHORIZED,
            "not paired: run `bandito pair` on the server",
        ));
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
            ok(store.agent_create(a)?)
        }
        "agents.update" => {
            let UpdateAgent { id, patch } = params(p)?;
            if let Some(cwd) = &patch.cwd {
                check_cwd(cwd)?;
            }
            let a = store.agent_update(
                &id,
                AgentPatch {
                    name: patch.name,
                    role: patch.role,
                    model: patch.model,
                    cwd: patch.cwd,
                    approval_mode: patch.approval_mode,
                    system_prompt: patch.system_prompt,
                },
            )?;
            // New config takes effect with the next message.
            app.sup.stop(&id).await;
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

        "events.since" => {
            let s: SinceParams = params(p)?;
            ok(store.events_since(s.after, s.limit, s.agent_id.as_deref())?)
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
            let cron = patch.cron.as_deref().unwrap_or(&cur.cron);
            let tz = patch.tz.as_deref().unwrap_or(&cur.tz);
            let next = scheduler::next_run(cron, tz, crate::store::now_ms())
                .map_err(|e| RpcError::new(INVALID_PARAMS, e.to_string()))?;
            ok(store.schedule_update(&id, patch, Some(next))?)
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
                })
                .unwrap()
                .id
        };
        let forge = add("Forge", "builder");
        let scout = add("Scout", "reviewer");
        (App::new(sup), forge, scout)
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

fn response(id: Value, r: RpcResult) -> String {
    match r {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(e) => json!({ "jsonrpc": "2.0", "id": id, "error": { "code": e.code, "message": e.message } }),
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
            })
            .unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        (App::new(sup), agent.id)
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
