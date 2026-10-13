//! The code sign-in against a fake provider (its code and token endpoints) and the fake MCP server of `fake.rs`.

use super::super::fake::{Fake, parse_form};
use super::*;
use crate::hub::Hub;
use crate::rpc::{App, Peer, dispatch, features};
use crate::supervisor::{Runtimes, Supervisor};
use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use std::collections::{BTreeMap, VecDeque};
use std::io::Write;
use std::sync::atomic::AtomicUsize;

const DEVICE_CODE: &str = "dc-secret-4f3a9b7e21";
const USER_CODE: &str = "WDJB-MJHT";

#[derive(Default)]
struct GhInner {
    code_requests: Vec<HashMap<String, String>>,
    polls: Vec<(HashMap<String, String>, std::time::Instant)>,
    /// Answers of the poll, one per request; when empty, `authorization_pending`.
    script: VecDeque<Value>,
    code_answer: Option<(u16, Value)>,
    expires_in: u64,
    interval: u64,
}

struct Gh {
    base: String,
    inner: Mutex<GhInner>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Gh {
    fn drop(&mut self) {
        if let Some(t) = self.task.lock().unwrap_or_else(|e| e.into_inner()).take() {
            t.abort();
        }
    }
}

fn answer(status: u16, body: Value) -> Response {
    (
        StatusCode::from_u16(status).unwrap(),
        [(header::CONTENT_TYPE, "application/json")],
        body.to_string(),
    )
        .into_response()
}

impl Gh {
    async fn start() -> Arc<Gh> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let gh = Arc::new(Gh {
            base: format!("http://localhost:{port}"),
            inner: Mutex::new(GhInner {
                expires_in: 900,
                interval: 1,
                ..Default::default()
            }),
            task: Mutex::new(None),
        });
        let app = Router::new()
            .route("/login/device/code", post(code))
            .route("/login/oauth/access_token", post(token))
            .with_state(gh.clone());
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        *gh.task.lock().unwrap() = Some(task);
        gh
    }

    fn provider(&self, mcp: &Fake) -> Provider {
        Provider {
            id: "fakehub".into(),
            client_id: "client-public".into(),
            scope: "repo read:user".into(),
            code_url: format!("{}/login/device/code", self.base),
            token_url: format!("{}/login/oauth/access_token", self.base),
            servers: vec![mcp.url()],
        }
    }

    fn set(&self, f: impl FnOnce(&mut GhInner)) {
        f(&mut self.inner.lock().unwrap());
    }

    fn polls(&self) -> usize {
        self.inner.lock().unwrap().polls.len()
    }
}

async fn code(State(g): State<Arc<Gh>>, body: Bytes) -> Response {
    let mut inner = g.inner.lock().unwrap();
    inner.code_requests.push(parse_form(&String::from_utf8_lossy(&body)));
    if let Some((status, body)) = inner.code_answer.clone() {
        return answer(status, body);
    }
    answer(
        200,
        json!({
            "device_code": DEVICE_CODE,
            "user_code": USER_CODE,
            "verification_uri": format!("{}/login/device", g.base),
            "expires_in": inner.expires_in,
            "interval": inner.interval,
        }),
    )
}

async fn token(State(g): State<Arc<Gh>>, body: Bytes) -> Response {
    let mut inner = g.inner.lock().unwrap();
    inner
        .polls
        .push((parse_form(&String::from_utf8_lossy(&body)), std::time::Instant::now()));
    let next = inner
        .script
        .pop_front()
        .unwrap_or_else(|| json!({ "error": "authorization_pending" }));
    answer(200, next)
}

fn granted(access: &str) -> Value {
    json!({ "access_token": access, "token_type": "bearer", "scope": "repo,read:user" })
}

fn pending() -> Value {
    json!({ "error": "authorization_pending" })
}

fn draft(name: &str, url: &str) -> NewIntegration {
    NewIntegration {
        name: name.into(),
        kind: IntegrationKind::Http,
        command: None,
        args: vec![],
        url: Some(url.into()),
        env: BTreeMap::new(),
        headers: BTreeMap::new(),
        enabled: true,
        auth: IntegrationAuth::None,
    }
}

/// One tick of the flows is 10 ms, so an interval of one second is a hundredth of one.
struct Rig {
    store: Arc<Store>,
    flows: DeviceFlows,
    gh: Arc<Gh>,
    mcp: Arc<Fake>,
    after: After,
    after_calls: Arc<AtomicUsize>,
}

async fn rig() -> Rig {
    let store = Arc::new(Store::open_in_memory().unwrap());
    let gh = Gh::start().await;
    let mcp = Fake::start().await;
    let flows = DeviceFlows::default();
    flows.for_test(vec![gh.provider(&mcp)], 10);
    let after_calls = Arc::new(AtomicUsize::new(0));
    let counter = after_calls.clone();
    let after: After = Arc::new(move |_id| {
        let counter = counter.clone();
        Box::pin(async move {
            counter.fetch_add(1, Ordering::SeqCst);
        })
    });
    Rig {
        store,
        flows,
        gh,
        mcp,
        after,
        after_calls,
    }
}

impl Rig {
    async fn begin(&self, name: &str) -> DeviceBegun {
        begin(
            &self.store,
            &self.flows,
            "dev1",
            DeviceTarget::Draft(draft(name, &self.mcp.url())),
            self.after.clone(),
        )
        .await
        .unwrap()
    }

    fn view(&self, flow_id: &str) -> Value {
        self.flows.view(flow_id, "dev1").unwrap()
    }

    /// Waits until the flow is no longer pending, and returns its state.
    async fn ended(&self, flow_id: &str) -> Value {
        for _ in 0..600 {
            let v = self.view(flow_id);
            if v["state"] != "pending" {
                return v;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("the flow did not end: {}", self.view(flow_id));
    }
}

/// A log writer the tests read back.
#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl Write for LogBuf {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for LogBuf {
    type Writer = LogBuf;
    fn make_writer(&'a self) -> LogBuf {
        self.clone()
    }
}

impl LogBuf {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

#[tokio::test]
async fn a_confirmed_code_stores_the_token_and_creates_the_integration() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([pending(), pending(), granted(&access)]));
    let begun = r.begin("github").await;
    assert_eq!((begun.user_code.as_str(), begun.interval), (USER_CODE, 1));
    assert_eq!(begun.verification_uri, format!("{}/login/device", r.gh.base));
    assert!(begun.expires_at > now_ms());
    let done = r.ended(&begun.flow_id).await;
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(
        (done["name"].as_str(), done["created"].as_bool()),
        (Some("github"), Some(true))
    );
    // The request for the code carried the public client and the scope; the polls carried the grant and the code.
    {
        let gh = r.gh.inner.lock().unwrap();
        assert_eq!(gh.code_requests[0]["client_id"], "client-public");
        assert_eq!(gh.code_requests[0]["scope"], "repo read:user");
        assert_eq!(gh.polls.len(), 3);
        assert_eq!(gh.polls[0].0["grant_type"], GRANT_TYPE);
        assert_eq!(gh.polls[0].0["device_code"], DEVICE_CODE);
        assert_eq!(gh.polls[0].0["client_id"], "client-public");
    }
    // The integration and its secrets.
    let id = done["id"].as_str().unwrap();
    let row = r.store.integration_get(id).unwrap().unwrap();
    assert_eq!(row.auth, IntegrationAuth::Device);
    assert_eq!(
        r.store.secret_get(&oauth_access_name(id)).unwrap().as_deref(),
        Some(access.as_str())
    );
    let st = status(&r.store, id).unwrap();
    assert_eq!((st.status, st.scope.as_deref()), ("connected", Some("repo,read:user")));
    assert!(!needs_sign_in(&r.store, id));
    // The sessions are told, once, and the header is the token.
    assert_eq!(r.after_calls.load(Ordering::SeqCst), 1);
    let secrets: HashMap<String, String> = r.store.secrets_all().unwrap().into_iter().collect();
    let servers = crate::integrations::resolve(&[&row], &secrets);
    match &servers[0].transport {
        crate::integrations::Transport::Http { headers, .. } => {
            assert!(
                headers
                    .iter()
                    .any(|h| h.key == "Authorization" && h.value == format!("Bearer {access}"))
            );
        }
        _ => panic!("an http server"),
    }
    // The finished flow stays readable, and the poll stopped.
    let polls = r.gh.polls();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(r.gh.polls(), polls);
}

#[tokio::test]
async fn an_existing_integration_gets_the_token_and_becomes_a_code_sign_in() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    let row = r.store.integration_create(draft("gh", &r.mcp.url())).unwrap();
    let begun = begin(
        &r.store,
        &r.flows,
        "dev1",
        DeviceTarget::Existing(row.clone()),
        r.after.clone(),
    )
    .await
    .unwrap();
    let done = r.ended(&begun.flow_id).await;
    assert_eq!(
        (done["state"].as_str(), done["id"].as_str(), done["created"].as_bool()),
        (Some("done"), Some(row.id.as_str()), Some(false))
    );
    assert_eq!(
        r.store.integration_get(&row.id).unwrap().unwrap().auth,
        IntegrationAuth::Device
    );
    assert_eq!(r.store.integration_list().unwrap().len(), 1);
}

#[tokio::test]
async fn slow_down_makes_the_interval_five_seconds_longer_and_the_polls_wait_for_it() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([json!({ "error": "slow_down" }), granted(&access)]));
    let begun = r.begin("github").await;
    let done = r.ended(&begun.flow_id).await;
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(done["interval"], 6);
    let gh = r.gh.inner.lock().unwrap();
    assert_eq!(gh.polls.len(), 2);
    // A tick is 10 ms: the second poll came six intervals' worth after the first, not one.
    let gap = gh.polls[1].1.duration_since(gh.polls[0].1);
    assert!(gap >= Duration::from_millis(55), "{gap:?}");
}

#[tokio::test]
async fn an_expired_code_and_a_refusal_end_the_flow_with_their_reason_and_store_nothing() {
    for (answer, reason) in [
        (json!({ "error": "expired_token" }), "expired"),
        (json!({ "error": "access_denied" }), "denied"),
        (
            json!({ "error": "incorrect_device_code", "error_description": format!("no such code {DEVICE_CODE}") }),
            "refused",
        ),
        (json!({ "error": "device_flow_disabled" }), "refused"),
    ] {
        let r = rig().await;
        r.gh.set(|g| g.script = VecDeque::from([answer]));
        let begun = r.begin("github").await;
        let ended = r.ended(&begun.flow_id).await;
        assert_eq!(
            (ended["state"].as_str(), ended["reason"].as_str()),
            (Some("failed"), Some(reason)),
            "{ended}"
        );
        // The message names no device code, and the poll stopped.
        assert!(!ended.to_string().contains(DEVICE_CODE), "{ended}");
        assert!(r.store.integration_list().unwrap().is_empty());
        assert!(r.store.secrets_all().unwrap().is_empty());
        assert_eq!(r.after_calls.load(Ordering::SeqCst), 0);
        let polls = r.gh.polls();
        tokio::time::sleep(Duration::from_millis(80)).await;
        assert_eq!(r.gh.polls(), polls);
    }
}

#[tokio::test]
async fn a_code_that_runs_out_by_the_clock_ends_the_flow() {
    let r = rig().await;
    r.gh.set(|g| g.expires_in = 1);
    let begun = r.begin("github").await;
    let ended = r.ended(&begun.flow_id).await;
    assert_eq!(
        (ended["state"].as_str(), ended["reason"].as_str()),
        (Some("failed"), Some("expired")),
        "{ended}"
    );
}

#[tokio::test]
async fn answers_that_cannot_be_read_end_the_flow_after_a_while_not_at_once() {
    let r = rig().await;
    // Not JSON at all, over and over: a gateway in the way.
    r.gh.set(|g| g.script = (0..20).map(|_| json!("<html>bad gateway</html>")).collect());
    let begun = r.begin("github").await;
    let ended = r.ended(&begun.flow_id).await;
    assert_eq!(
        (ended["state"].as_str(), ended["reason"].as_str()),
        (Some("failed"), Some("network")),
        "{ended}"
    );
    assert_eq!(r.gh.polls(), MAX_TRANSIENT as usize);
}

#[tokio::test]
async fn a_cancel_stops_the_poll_and_a_token_that_comes_later_is_not_kept() {
    let r = rig().await;
    let begun = r.begin("github").await;
    assert!(
        !r.flows.cancel(&begun.flow_id, "another-device"),
        "only the device that started it"
    );
    assert!(r.flows.cancel(&begun.flow_id, "dev1"));
    assert!(!r.flows.cancel(&begun.flow_id, "dev1"), "once");
    assert_eq!(r.view(&begun.flow_id)["state"], "cancelled");
    let polls = r.gh.polls();
    // The provider would grant now; nobody asks.
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(r.gh.polls(), polls);
    assert!(r.store.integration_list().unwrap().is_empty());
    assert!(r.store.secrets_all().unwrap().is_empty());
    assert_eq!(r.after_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_new_begin_for_the_same_integration_cancels_the_earlier_flow() {
    let r = rig().await;
    let first = r.begin("github").await;
    let second = r.begin("github").await;
    assert_ne!(first.flow_id, second.flow_id);
    assert_eq!(r.view(&first.flow_id)["state"], "cancelled");
    assert_eq!(r.view(&second.flow_id)["state"], "pending");
    // Another target does not cancel it.
    let other = r.begin("other").await;
    assert_eq!(r.view(&second.flow_id)["state"], "pending");
    assert_eq!(r.view(&other.flow_id)["state"], "pending");
    // Only the second one's grant is taken: the first is gone.
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    let done = {
        for _ in 0..300 {
            if r.view(&second.flow_id)["state"] == "done" || r.view(&other.flow_id)["state"] == "done" {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        (
            r.view(&first.flow_id)["state"].clone(),
            r.store.integration_list().unwrap().len(),
        )
    };
    assert_eq!(done, (json!("cancelled"), 1));
}

#[tokio::test]
async fn an_unknown_flow_a_bad_target_and_a_bad_answer_are_refused_with_plain_words() {
    let r = rig().await;
    assert!(r.flows.view("nope", "dev1").is_err());
    // A service the daemon has no provider for gets no request at all.
    let err = begin(
        &r.store,
        &r.flows,
        "dev1",
        DeviceTarget::Draft(draft("x", "https://x.example/mcp")),
        r.after.clone(),
    )
    .await
    .unwrap_err();
    assert!(format!("{err:#}").contains("no sign-in with a code"), "{err:#}");
    assert!(r.gh.inner.lock().unwrap().code_requests.is_empty());
    // A browser sign-in is not turned into a code one.
    let mut oauth = draft("o", &r.mcp.url());
    oauth.auth = IntegrationAuth::Oauth;
    let row = r.store.integration_create(oauth).unwrap();
    let err = begin(&r.store, &r.flows, "dev1", DeviceTarget::Existing(row), r.after.clone())
        .await
        .unwrap_err();
    assert!(format!("{err:#}").contains("browser"), "{err:#}");
    // The provider turned the flow off, or answered nonsense.
    for (status, body, words) in [
        (400, json!({ "error": "device_flow_disabled" }), "turned off"),
        (
            200,
            json!({ "device_code": "a b", "user_code": USER_CODE, "verification_uri": "http://localhost/x" }),
            "device code",
        ),
        (
            200,
            json!({ "device_code": DEVICE_CODE, "user_code": "no spaces allowed", "verification_uri": "http://localhost/x" }),
            "usable code",
        ),
        (
            200,
            json!({ "device_code": DEVICE_CODE, "user_code": USER_CODE, "verification_uri": "http://evil.example/login" }),
            "own site",
        ),
        (500, json!("oops"), "HTTP 500"),
    ] {
        r.gh.set(|g| g.code_answer = Some((status, body)));
        let err = begin(
            &r.store,
            &r.flows,
            "dev1",
            DeviceTarget::Draft(draft("gh", &r.mcp.url())),
            r.after.clone(),
        )
        .await
        .unwrap_err();
        assert!(format!("{err:#}").contains(words), "{words}: {err:#}");
    }
}

#[tokio::test]
async fn the_token_and_the_device_code_are_in_no_argument_log_or_error() {
    let logs = LogBuf::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(logs.clone())
        .with_ansi(false)
        .finish();
    let _log = tracing::subscriber::set_default(subscriber);
    let r = rig().await;
    let access = "at-very-secret-token-91c2".to_string();
    r.mcp.set(|i| i.access = access.clone());
    // A curl takes its request from stdin, so neither value is ever an argument. A sampler of the process list
    // looks for them while the flow runs (it can only find a leak, not prove there is none).
    assert_eq!(CURL_ARGS, ["-q", "--config", "-"]);
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let seen = Arc::new(Mutex::new(Vec::<String>::new()));
    let sampler = {
        let (stop, seen) = (stop.clone(), seen.clone());
        let needles = [DEVICE_CODE.to_string(), access.clone()];
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                if let Ok(out) = std::process::Command::new("ps").args(["-axww", "-o", "args="]).output() {
                    for line in String::from_utf8_lossy(&out.stdout).lines() {
                        if needles.iter().any(|n| line.contains(n.as_str())) {
                            seen.lock().unwrap().push(line.to_string());
                        }
                    }
                }
                std::thread::sleep(Duration::from_millis(3));
            }
        })
    };
    r.gh.set(|g| g.script = VecDeque::from([pending(), granted(&access)]));
    let begun = r.begin("github").await;
    let done = r.ended(&begun.flow_id).await;
    assert_eq!(done["state"], "done", "{done}");
    // A failing one too, whose answer repeats the device code.
    r.gh.set(|g| {
        g.script = VecDeque::from([json!({ "error": "incorrect_device_code", "error_description": DEVICE_CODE })])
    });
    let failing = r.begin("again").await;
    let failed = r.ended(&failing.flow_id).await;
    stop.store(true, Ordering::SeqCst);
    sampler.join().unwrap();
    assert_eq!(failed["state"], "failed");
    assert!(seen.lock().unwrap().is_empty(), "{:?}", seen.lock().unwrap());
    for text in [done.to_string(), failed.to_string(), logs.text()] {
        assert!(!text.contains(&access) && !text.contains(DEVICE_CODE), "{text}");
    }
    // The token is only in the daemon's hidden secrets.
    let listed: Vec<String> = r.store.secret_list().unwrap().into_iter().map(|s| s.name).collect();
    assert!(
        listed.iter().all(|n| crate::integrations::is_daemon_secret(n)),
        "{listed:?}"
    );
}

#[tokio::test]
async fn a_token_the_store_refuses_fails_the_flow_and_leaves_no_integration() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    // The secrets table is gone: writing the token fails after the row was made.
    r.store.break_for_test("DROP TABLE secrets");
    let begun = r.begin("github").await;
    let ended = r.ended(&begun.flow_id).await;
    assert_eq!(
        (ended["state"].as_str(), ended["reason"].as_str()),
        (Some("failed"), Some("store")),
        "{ended}"
    );
    assert!(!ended.to_string().contains(&access));
    assert!(r.store.integration_list().unwrap().is_empty());
    assert_eq!(r.after_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_refused_token_asks_for_a_new_sign_in_and_a_disconnect_forgets_it() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    let begun = r.begin("github").await;
    let done = r.ended(&begun.flow_id).await;
    let id = done["id"].as_str().unwrap().to_string();
    mark_rejected(&r.store, &id).await;
    assert_eq!(status(&r.store, &id).unwrap().status, "needs_login");
    assert!(needs_sign_in(&r.store, &id));
    // A session start leaves it out and says the person has to sign in.
    let row = r.store.integration_get(&id).unwrap().unwrap();
    let skipped = ready_for_session(&r.store, &[&row], now_ms()).await;
    assert_eq!(skipped, vec![(id.clone(), true)]);
    // Signing in again clears it.
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    let again = begin(
        &r.store,
        &r.flows,
        "dev1",
        DeviceTarget::Existing(row.clone()),
        r.after.clone(),
    )
    .await
    .unwrap();
    assert_eq!(r.ended(&again.flow_id).await["state"], "done");
    assert_eq!(status(&r.store, &id).unwrap().status, "connected");
    assert!(ready_for_session(&r.store, &[&row], now_ms()).await.is_empty());
    // Disconnect: nothing is revoked at the provider, and the token is gone.
    assert!(!disconnect(&r.store, &id).await.unwrap());
    assert_eq!(status(&r.store, &id).unwrap().status, "not_connected");
    assert!(r.store.secrets_all().unwrap().is_empty());
    assert!(needs_sign_in(&r.store, &id));
}

// ---- over the RPC ----

fn app(flows: impl FnOnce(&DeviceFlows)) -> Arc<App> {
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
    let app = App::new(sup, std::path::PathBuf::from("unused-agents-root"));
    flows(&app.device);
    app
}

async fn call(app: &App, method: &str, p: Value) -> Result<Value, crate::rpc::RpcError> {
    dispatch(app, &Peer::Local, method, p).await
}

/// Waits for the flow of `begun` to end, as the app does, by asking for its status.
async fn wait_status(app: &App, flow_id: &str) -> Value {
    for _ in 0..600 {
        let v = call(app, "integrations.device_status", json!({ "flow_id": flow_id }))
            .await
            .unwrap();
        if v["state"] != "pending" {
            return v;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the flow did not end");
}

#[test]
fn the_daemon_advertises_the_code_sign_in_and_only_the_owner_may_use_it() {
    assert!(features().contains(&"integrations_device"));
    for method in [
        "integrations.device_begin",
        "integrations.device_status",
        "integrations.device_cancel",
    ] {
        assert!(crate::rpc::allowed(&Peer::Local, method), "{method}");
        for peer in [Peer::Agent("a1".into()), Peer::Anonymous("1.2.3.4".into(), None)] {
            assert!(!crate::rpc::allowed(&peer, method), "{method}");
        }
    }
}

#[tokio::test]
async fn the_whole_sign_in_over_the_rpc_lists_tests_and_disconnects() {
    let gh = Gh::start().await;
    let mcp = Fake::start().await;
    let app = app(|f| f.for_test(vec![gh.provider(&mcp)], 10));
    let access = mcp.inner.lock().unwrap().access.clone();
    gh.set(|g| g.script = VecDeque::from([pending(), granted(&access)]));
    let begun = call(
        &app,
        "integrations.device_begin",
        json!({ "draft": { "name": "github", "kind": "http", "url": mcp.url() } }),
    )
    .await
    .unwrap();
    assert_eq!(begun["user_code"], USER_CODE);
    assert!(begun["verification_uri"].as_str().unwrap().ends_with("/login/device"));
    assert!(begun["expires_at"].as_i64().unwrap() > now_ms());
    assert_eq!(begun["interval"], 1);
    // Another device cannot read the flow.
    let flow_id = begun["flow_id"].as_str().unwrap();
    let stranger = dispatch(
        &app,
        &Peer::Device(crate::store::Device {
            id: "d2".into(),
            name: "Other".into(),
            created_at: 0,
            last_seen_at: None,
        }),
        "integrations.device_status",
        json!({ "flow_id": flow_id }),
    )
    .await;
    assert!(stranger.is_err());
    let done = wait_status(&app, flow_id).await;
    assert_eq!(
        (done["state"].as_str(), done["created"].as_bool()),
        (Some("done"), Some(true)),
        "{done}"
    );
    let id = done["id"].as_str().unwrap().to_string();
    // The list says how it signs in and shows no token; the secrets screen does not see it.
    let list = call(&app, "integrations.list", json!({})).await.unwrap();
    assert_eq!(list[0]["auth"], "device");
    assert!(!list.to_string().contains(&access));
    assert_eq!(call(&app, "secrets.list", json!({})).await.unwrap(), json!([]));
    let st = call(&app, "integrations.oauth_status", json!({ "id": id }))
        .await
        .unwrap();
    assert_eq!(st["integrations"][0]["status"], "connected");
    // `integrations.test` reaches the server with the token.
    let tested = call(&app, "integrations.test", json!({ "id": id })).await.unwrap();
    assert_eq!(tested["ok"], true, "{tested}");
    // The address of a signed-in integration is fixed, and `add` cannot claim the kind.
    let moved = call(
        &app,
        "integrations.update",
        json!({ "id": id, "url": "https://other.example/mcp" }),
    )
    .await;
    assert!(moved.unwrap_err().message.contains("disconnect"));
    let added = call(
        &app,
        "integrations.add",
        json!({ "name": "x", "kind": "http", "url": "https://x.example/mcp", "auth": "device" }),
    )
    .await;
    assert!(added.unwrap_err().message.contains("device_begin"));
    // The service refuses the token (revoked on its side): the test says to sign in again, the status follows.
    mcp.set(|i| i.access = "at-revoked-elsewhere".into());
    let refused = call(&app, "integrations.test", json!({ "id": id })).await.unwrap();
    assert_eq!(
        (refused["ok"].as_bool(), refused["needs_login"].as_bool()),
        (Some(false), Some(true)),
        "{refused}"
    );
    let st = call(&app, "integrations.oauth_status", json!({})).await.unwrap();
    assert_eq!(st["integrations"][0]["status"], "needs_login");
    // Signing in again with a good token makes it work.
    mcp.set(|i| i.access = "at-new".into());
    gh.set(|g| g.script = VecDeque::from([granted("at-new")]));
    let again = call(&app, "integrations.device_begin", json!({ "integration": id }))
        .await
        .unwrap();
    let done = wait_status(&app, again["flow_id"].as_str().unwrap()).await;
    assert_eq!(
        (done["state"].as_str(), done["created"].as_bool()),
        (Some("done"), Some(false)),
        "{done}"
    );
    let tested = call(&app, "integrations.test", json!({ "id": id })).await.unwrap();
    assert_eq!(tested["ok"], true, "{tested}");
    // Disconnect: the token is gone, the integration stays.
    let gone = call(&app, "integrations.oauth_disconnect", json!({ "id": id }))
        .await
        .unwrap();
    assert_eq!(gone, json!({ "revoked": false, "removed": false }));
    let st = call(&app, "integrations.oauth_status", json!({ "id": id }))
        .await
        .unwrap();
    assert_eq!(st["integrations"][0]["status"], "not_connected");
    assert!(app.sup.hub().store.secrets_all().unwrap().is_empty());
    // Remove deletes a pending flow's target along with the row and the token.
    gh.set(|g| g.script = VecDeque::from([granted("at-new")]));
    let third = call(&app, "integrations.device_begin", json!({ "integration": id }))
        .await
        .unwrap();
    wait_status(&app, third["flow_id"].as_str().unwrap()).await;
    let fourth = call(&app, "integrations.device_begin", json!({ "integration": id }))
        .await
        .unwrap();
    call(&app, "integrations.remove", json!({ "id": id })).await.unwrap();
    assert_eq!(
        call(
            &app,
            "integrations.device_status",
            json!({ "flow_id": fourth["flow_id"] })
        )
        .await
        .unwrap()["state"],
        "cancelled"
    );
    assert!(app.sup.hub().store.secrets_all().unwrap().is_empty());
    assert!(app.sup.hub().store.integration_list().unwrap().is_empty());
}

#[tokio::test]
async fn the_rpc_checks_its_params_and_cancels() {
    let gh = Gh::start().await;
    let mcp = Fake::start().await;
    let app = app(|f| f.for_test(vec![gh.provider(&mcp)], 10));
    for p in [
        json!({}),
        json!({ "integration": "nope" }),
        json!({ "draft": { "name": "Bad Name!", "kind": "http", "url": mcp.url() } }),
    ] {
        assert!(call(&app, "integrations.device_begin", p).await.is_err());
    }
    let both = call(
        &app,
        "integrations.device_begin",
        json!({ "integration": "i", "draft": { "name": "g", "kind": "http", "url": mcp.url() } }),
    )
    .await;
    assert!(both.is_err());
    let begun = call(
        &app,
        "integrations.device_begin",
        json!({ "draft": { "name": "github", "kind": "http", "url": mcp.url() } }),
    )
    .await
    .unwrap();
    // A name already taken is refused at once.
    app.sup
        .hub()
        .store
        .integration_create(draft("taken", &mcp.url()))
        .unwrap();
    let taken = call(
        &app,
        "integrations.device_begin",
        json!({ "draft": { "name": "taken", "kind": "http", "url": mcp.url() } }),
    )
    .await;
    assert!(taken.unwrap_err().message.contains("already exists"));
    let cancelled = call(
        &app,
        "integrations.device_cancel",
        json!({ "flow_id": begun["flow_id"] }),
    )
    .await
    .unwrap();
    assert_eq!(cancelled, json!({ "cancelled": true }));
    let again = call(
        &app,
        "integrations.device_cancel",
        json!({ "flow_id": begun["flow_id"] }),
    )
    .await
    .unwrap();
    assert_eq!(again, json!({ "cancelled": false }));
    assert!(
        call(&app, "integrations.device_status", json!({ "flow_id": "nope" }))
            .await
            .is_err()
    );
}

#[tokio::test]
async fn the_built_in_github_provider_is_the_one_the_catalog_names() {
    let github = builtin_provider("github").unwrap();
    assert_eq!(github.code_url, "https://github.com/login/device/code");
    assert_eq!(github.token_url, "https://github.com/login/oauth/access_token");
    assert!(same_server(&github.servers[0], "https://api.githubcopilot.com/mcp"));
    assert!(!same_server(
        &github.servers[0],
        "https://api.githubcopilot.com.evil.example/mcp/"
    ));
    assert!(!same_server(&github.servers[0], "http://api.githubcopilot.com/mcp/"));
    // Without a test override, the flows use the built-in list.
    let flows = DeviceFlows::default();
    assert_eq!(flows.providers().len(), 1);
}

#[tokio::test]
async fn an_address_changed_while_the_sign_in_is_open_keeps_no_token_and_no_device_sign_in() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    let row = r.store.integration_create(draft("gh", &r.mcp.url())).unwrap();
    let begun = begin(
        &r.store,
        &r.flows,
        "dev1",
        DeviceTarget::Existing(row.clone()),
        r.after.clone(),
    )
    .await
    .unwrap();
    // The person moves the integration to another host while the code is still waiting.
    r.store
        .integration_update(
            &row.id,
            crate::store::IntegrationPatch {
                url: Some(Some("https://evil.example/mcp/".into())),
                ..Default::default()
            },
        )
        .unwrap();
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    let ended = r.ended(&begun.flow_id).await;
    assert_eq!(
        (ended["state"].as_str(), ended["reason"].as_str()),
        (Some("failed"), Some("changed")),
        "{ended}"
    );
    assert_eq!(
        r.store.integration_get(&row.id).unwrap().unwrap().auth,
        IntegrationAuth::None
    );
    assert!(r.store.secrets_all().unwrap().is_empty());
    assert_eq!(r.after_calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn a_row_removed_as_the_token_is_stored_keeps_no_token_and_ends_gone() {
    let r = rig().await;
    let access = r.mcp.inner.lock().unwrap().access.clone();
    let row = r.store.integration_create(draft("gh", &r.mcp.url())).unwrap();
    let begun = begin(
        &r.store,
        &r.flows,
        "dev1",
        DeviceTarget::Existing(row.clone()),
        r.after.clone(),
    )
    .await
    .unwrap();
    // The row is deleted just before its sign-in is set: the update finds no row and changes nothing.
    r.store.break_for_test(
        "CREATE TRIGGER drop_on_sign_in BEFORE UPDATE OF auth ON integrations
         BEGIN DELETE FROM integrations WHERE id = NEW.id; SELECT RAISE(IGNORE); END;",
    );
    r.gh.set(|g| g.script = VecDeque::from([granted(&access)]));
    let ended = r.ended(&begun.flow_id).await;
    assert_eq!(
        (ended["state"].as_str(), ended["reason"].as_str()),
        (Some("failed"), Some("gone")),
        "{ended}"
    );
    assert!(
        r.store.secrets_all().unwrap().is_empty(),
        "the stored token is deleted again"
    );
    assert!(r.store.integration_list().unwrap().is_empty());
    assert_eq!(r.after_calls.load(Ordering::SeqCst), 0);
}

/// A flow as the map keeps it, with no task: the room rules need no provider.
fn parked(key: &str, phase: Phase, created_at: i64) -> DeviceFlow {
    let ended_at = matches!(phase, Phase::Done { .. } | Phase::Failed { .. } | Phase::Cancelled).then(now_ms);
    DeviceFlow {
        device: "dev1".into(),
        key: key.into(),
        user_code: "AAAA-BBBB".into(),
        verification_uri: "https://github.com/login/device".into(),
        expires_at: i64::MAX,
        interval: 5,
        phase,
        ended_at,
        created_at,
        task: None,
    }
}

#[tokio::test]
async fn a_full_list_drops_the_oldest_flow_that_is_not_storing_a_token() {
    let r = rig().await;
    {
        let mut map = r.flows.map();
        // The oldest is storing its token: it stays. The next oldest has ended: it goes.
        map.insert("storing".into(), parked("draft:storing", Phase::Finishing, 1));
        map.insert("ended".into(), parked("draft:ended", Phase::Cancelled, 2));
        for i in 0..MAX_DEVICE_FLOWS - 2 {
            map.insert(
                format!("f{i}"),
                parked(&format!("draft:f{i}"), Phase::Finishing, 10 + i as i64),
            );
        }
    }
    let begun = r.begin("fresh").await;
    let map = r.flows.map();
    assert!(map.contains_key("storing"), "a token being stored is not cut off");
    assert!(!map.contains_key("ended"));
    assert!(map.contains_key(&begun.flow_id));
    assert_eq!(map.len(), MAX_DEVICE_FLOWS);
}

#[tokio::test]
async fn a_full_list_of_tokens_being_stored_refuses_a_new_sign_in_as_busy() {
    let r = rig().await;
    {
        let mut map = r.flows.map();
        for i in 0..MAX_DEVICE_FLOWS {
            map.insert(
                format!("f{i}"),
                parked(&format!("draft:f{i}"), Phase::Finishing, i as i64),
            );
        }
    }
    let err = begin(
        &r.store,
        &r.flows,
        "dev1",
        DeviceTarget::Draft(draft("fresh", &r.mcp.url())),
        r.after.clone(),
    )
    .await
    .unwrap_err();
    assert!(format!("{err:#}").contains("busy"), "{err:#}");
    assert_eq!(r.flows.map().len(), MAX_DEVICE_FLOWS, "none is dropped");
    assert!(r.flows.map().values().all(|f| f.phase == Phase::Finishing));
    assert!(r.store.integration_list().unwrap().is_empty());
}
