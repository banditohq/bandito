//! `browser.*` JSON-RPC methods (for the app) and `browser.agent.*` (for the crew MCP on this
//! server). The logic is in `crate::browser`. See docs/ARCHITECTURE.md#browser.

use super::ws::require_device;
use super::{
    App, BROWSER_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, UNAUTHORIZED, ok, params,
};
use crate::browser::{BrowserError, CLICK_APPROVAL_LIMIT, CdpSlot, DEFAULT_WORKSPACE, Holder, check_workspace};
use crate::cdp::CdpTransport;
use crate::cdp_pipe::LinkError;
use axum::Json;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use std::sync::Arc;

/// Largest message the app may send on a DevTools socket (a command, not a screenshot).
const CDP_MESSAGE_LIMIT: usize = 4 << 20;

#[derive(Deserialize, Default)]
pub(super) struct WorkspaceQuery {
    workspace: Option<String>,
}

/// `GET /v1/browser/tabs?workspace=`: the pages open in the browser, as a JSON array of
/// `{id, type, title, url}`. Needs a paired device; 409 `browser_not_running` without a browser.
pub(super) async fn tabs(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Query(query): Query<WorkspaceQuery>,
) -> Response {
    if let Err(e) = require_device(&app, &headers) {
        return e.into_response();
    }
    let Some(workspace) = workspace_of(&query) else {
        return bad_workspace();
    };
    match app.browser.pages(&workspace).await {
        Ok(pages) => Json(pages).into_response(),
        Err(e) => browser_error(e),
    }
}

/// `GET /v1/browser/cdp?workspace=`: a WebSocket on the browser level of the DevTools protocol.
pub(super) async fn cdp_browser(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Query(query): Query<WorkspaceQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let device = match require_device(&app, &headers) {
        Ok(device) => device,
        Err(e) => return e.into_response(),
    };
    let Some(workspace) = workspace_of(&query) else {
        return bad_workspace();
    };
    let relay = match app.browser.app_relay(&workspace).await {
        Ok(relay) => relay,
        Err(e) => return browser_error(e),
    };
    let Some(slot) = app.browser.cdp_slot(&device.id) else {
        return too_many_sockets();
    };
    let client = match relay.browser_client().await {
        Ok(client) => client,
        Err(_) => return not_running(),
    };
    ws.max_message_size(CDP_MESSAGE_LIMIT)
        .on_upgrade(move |socket| pump(socket, client, slot))
}

/// `GET /v1/browser/cdp/page/<target_id>?workspace=`: a WebSocket on one tab, as a plain CDP
/// session (no `sessionId` in the messages). Checks run before the upgrade.
pub(super) async fn cdp_page(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Path(target_id): Path<String>,
    Query(query): Query<WorkspaceQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let device = match require_device(&app, &headers) {
        Ok(device) => device,
        Err(e) => return e.into_response(),
    };
    if !valid_target_id(&target_id) {
        return (StatusCode::BAD_REQUEST, "target_id must be 1-64 letters or digits").into_response();
    }
    let Some(workspace) = workspace_of(&query) else {
        return bad_workspace();
    };
    let relay = match app.browser.app_relay(&workspace).await {
        Ok(relay) => relay,
        Err(e) => return browser_error(e),
    };
    let Some(slot) = app.browser.cdp_slot(&device.id) else {
        return too_many_sockets();
    };
    let page = match relay.page_client(&target_id).await {
        Ok(page) => page,
        Err(LinkError::NoTarget(_)) => {
            return (StatusCode::NOT_FOUND, Json(json!({"error": "no_such_tab"}))).into_response();
        }
        Err(LinkError::Closed) => return not_running(),
    };
    ws.max_message_size(CDP_MESSAGE_LIMIT)
        .on_upgrade(move |socket| pump(socket, page, slot))
}

/// Carries one DevTools socket: each text message from the app is a command, and each answer or
/// event goes back as a text message. Ends when either side closes, or when the browser or the
/// tab goes away. The slot is held until then.
async fn pump<T: CdpTransport>(socket: WebSocket, mut link: T, _slot: CdpSlot) {
    let (mut to_app, mut from_app) = socket.split();
    loop {
        tokio::select! {
            incoming = from_app.next() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    if link.send(text.to_string()).await.is_err() {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | Some(Err(_)) | None => break,
                // Binary frames are not CDP; pings are answered by axum.
                Some(Ok(_)) => {}
            },
            outgoing = link.recv() => match outgoing {
                Ok(text) => {
                    if to_app.send(Message::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                Err(_) => break,
            },
        }
    }
    let _ = to_app.send(Message::Close(None)).await;
}

/// The `workspace` query value, `shared` by default. `None` for a bad name (a 400).
fn workspace_of(query: &WorkspaceQuery) -> Option<String> {
    let name = query.workspace.as_deref().unwrap_or(DEFAULT_WORKSPACE);
    check_workspace(name).ok().map(|()| name.to_string())
}

/// Target ids are DevTools' ids: 1 to 64 ASCII letters or digits.
fn valid_target_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric())
}

fn bad_workspace() -> Response {
    (
        StatusCode::BAD_REQUEST,
        "workspace must be 1-64 letters, digits, - or _",
    )
        .into_response()
}

fn not_running() -> Response {
    (StatusCode::CONFLICT, Json(json!({"error": "browser_not_running"}))).into_response()
}

fn too_many_sockets() -> Response {
    (StatusCode::TOO_MANY_REQUESTS, "too many browser sockets").into_response()
}

/// The HTTP answer for a browser failure on the app routes.
fn browser_error(e: BrowserError) -> Response {
    match e {
        BrowserError::NotRunning => not_running(),
        BrowserError::InvalidWorkspace => bad_workspace(),
        BrowserError::Failed(message) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "browser_failed", "message": message})),
        )
            .into_response(),
        other => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({"error": "browser_failed", "message": format!("{other:?}")})),
        )
            .into_response(),
    }
}

#[derive(Deserialize, Default)]
struct WorkspaceParams {
    workspace: Option<String>,
}

impl WorkspaceParams {
    fn name(&self) -> &str {
        self.workspace.as_deref().unwrap_or(DEFAULT_WORKSPACE)
    }
}

#[derive(Deserialize)]
struct ControlParams {
    workspace: Option<String>,
    holder: Holder,
}

#[derive(Deserialize)]
struct OpenParams {
    url: String,
    #[serde(default)]
    new_tab: bool,
}

#[derive(Deserialize)]
struct ClickParams {
    /// The agent that clicks: a risky click asks the user in its feed.
    agent_id: String,
    #[serde(rename = "ref")]
    node: i64,
}

#[derive(Deserialize)]
struct TypeParams {
    #[serde(rename = "ref")]
    node: i64,
    text: String,
    #[serde(default)]
    submit: bool,
}

#[derive(Deserialize)]
struct PressParams {
    key: String,
}

#[derive(Deserialize)]
struct SwitchParams {
    index: usize,
}

/// Answers `browser.*` and `browser.agent.*`. `rpc::dispatch` has already refused anonymous peers.
pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    let browser = &app.browser;
    if let Some(tool) = method.strip_prefix("browser.agent.") {
        if !matches!(peer, Peer::Local) {
            return Err(RpcError::new(
                UNAUTHORIZED,
                "browser tools can only be used by agents on the server",
            ));
        }
        return agent(app, tool, p).await;
    }
    match method {
        "browser.start" => {
            let w: WorkspaceParams = params(p)?;
            ok(browser.start(w.name()).await.map_err(to_rpc)?)
        }
        "browser.status" => {
            let w: WorkspaceParams = params(p)?;
            ok(browser.status(w.name()).await)
        }
        "browser.stop" => {
            let w: WorkspaceParams = params(p)?;
            browser.stop(w.name()).await;
            ok(browser.status(w.name()).await)
        }
        "browser.control" => {
            let c: ControlParams = params(p)?;
            let workspace = c.workspace.as_deref().unwrap_or(DEFAULT_WORKSPACE);
            ok(browser.control(workspace, c.holder).await.map_err(to_rpc)?)
        }
        "browser.touch" => {
            let w: WorkspaceParams = params(p)?;
            browser.touch(w.name()).await;
            ok(json!({}))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// The agent tools' methods. Each answers `{text}`, or `{png_base64}` for the screenshot.
async fn agent(app: &App, tool: &str, p: Value) -> RpcResult {
    let browser = &app.browser;
    match tool {
        "open" => {
            let a: OpenParams = params(p)?;
            let text = browser.agent_open(&a.url, a.new_tab).await.map_err(to_rpc)?;
            ok(json!({ "text": text }))
        }
        "snapshot" => ok(json!({ "text": browser.agent_snapshot().await.map_err(to_rpc)? })),
        "click" => {
            let a: ClickParams = params(p)?;
            let node = node_ref(a.node)?;
            let text = browser
                .agent_click(&app.sup, &a.agent_id, node, CLICK_APPROVAL_LIMIT)
                .await
                .map_err(to_rpc)?;
            ok(json!({ "text": text }))
        }
        "type" => {
            let a: TypeParams = params(p)?;
            let node = node_ref(a.node)?;
            let text = browser.agent_type(node, &a.text, a.submit).await.map_err(to_rpc)?;
            ok(json!({ "text": text }))
        }
        "press" => {
            let a: PressParams = params(p)?;
            ok(json!({ "text": browser.agent_press(&a.key).await.map_err(to_rpc)? }))
        }
        "back" => ok(json!({ "text": browser.agent_back().await.map_err(to_rpc)? })),
        "screenshot" => ok(json!({ "png_base64": browser.agent_screenshot().await.map_err(to_rpc)? })),
        "tabs" => ok(json!({ "text": browser.agent_tabs().await.map_err(to_rpc)? })),
        "switch" => {
            let a: SwitchParams = params(p)?;
            ok(json!({ "text": browser.agent_switch(a.index).await.map_err(to_rpc)? }))
        }
        _ => Err(RpcError::new(
            METHOD_NOT_FOUND,
            format!("unknown method browser.agent.{tool}"),
        )),
    }
}

/// A ref is a `backendDOMNodeId` from a snapshot, so it is at least 1.
fn node_ref(node: i64) -> Result<i64, RpcError> {
    if node >= 1 {
        Ok(node)
    } else {
        Err(RpcError::new(
            INVALID_PARAMS,
            "ref must be a number from browser_snapshot",
        ))
    }
}

/// The RPC error for a browser failure. `error.data.reason` says which kind it is.
fn to_rpc(e: BrowserError) -> RpcError {
    match e {
        BrowserError::MissingComponent => RpcError::with_data(
            BROWSER_ERROR,
            "no Chrome or Chromium on this server; install the browser component in setup",
            json!({ "reason": "missing_component", "component": "browser" }),
        ),
        BrowserError::StartFailed(message) => RpcError::with_data(
            BROWSER_ERROR,
            format!("the browser did not start: {message}"),
            json!({ "reason": "start_failed" }),
        ),
        BrowserError::Unsupported => RpcError::with_data(
            BROWSER_ERROR,
            "the browser runs on Linux and macOS only",
            json!({ "reason": "unsupported" }),
        ),
        BrowserError::NotRunning => RpcError::with_data(
            BROWSER_ERROR,
            "the browser is not running",
            json!({ "reason": "not_running" }),
        ),
        BrowserError::UserControls => RpcError::with_data(
            BROWSER_ERROR,
            "The user is using the browser. Wait or ask them to hand it back.",
            json!({ "reason": "user_controls" }),
        ),
        BrowserError::Declined => RpcError::with_data(
            BROWSER_ERROR,
            "The user declined this click.",
            json!({ "reason": "declined" }),
        ),
        BrowserError::Failed(message) => RpcError::with_data(BROWSER_ERROR, message, json!({ "reason": "failed" })),
        BrowserError::InvalidWorkspace => {
            RpcError::new(INVALID_PARAMS, "workspace must be 1-64 letters, digits, - or _")
        }
        BrowserError::UnsupportedUrl => RpcError::new(
            INVALID_PARAMS,
            "only http, https, data: and about:blank URLs can be opened",
        ),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn browser_is_offered_on_every_system() {
        assert!(crate::rpc::features().contains(&"browser"));
    }
}

#[cfg(test)]
mod route_tests {
    use super::*;
    use crate::browser::BrowserManager;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use axum::body::Body;
    use axum::http::{Method, Request};
    use http_body_util::BodyExt;
    use std::net::SocketAddr;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
    use tokio_tungstenite::tungstenite::{self, Message};
    use tower::ServiceExt;

    const TOKEN: &str = "bdt_browser_test";
    const AUTH: (&str, &str) = ("authorization", "Bearer bdt_browser_test");
    const ORIGIN: (&str, &str) = ("origin", "https://evil.example");

    /// An app with one paired device and a browser manager over `dir`. No browser is started.
    fn app(dir: &std::path::Path) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        store.device_add("test", TOKEN).unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let mut app = App::new(sup, dir.to_path_buf());
        Arc::get_mut(&mut app).expect("the app is not shared yet").browser = BrowserManager::new(dir.to_path_buf());
        app
    }

    /// A plain GET through the router: the status and the body.
    async fn get(app: &Arc<App>, uri: &str, headers: &[(&str, &str)]) -> (StatusCode, String) {
        let mut request = Request::builder().method(Method::GET).uri(uri);
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let response = crate::rpc::ws::router(app.clone())
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

    /// The router on a real socket, so that WebSocket upgrades work.
    async fn serve(app: Arc<App>) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, crate::rpc::ws::router(app)).await.unwrap() });
        addr
    }

    /// Opens a WebSocket to `path` with these headers; returns the socket, or the HTTP status it was refused with.
    async fn upgrade(
        addr: SocketAddr,
        path: &str,
        headers: &[(&str, &str)],
    ) -> Result<tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>, u16> {
        let mut request = format!("ws://{addr}{path}").into_client_request().unwrap();
        for (name, value) in headers {
            let name = HeaderName::from_bytes(name.as_bytes()).unwrap();
            request
                .headers_mut()
                .insert(name, HeaderValue::from_str(value).unwrap());
        }
        match tokio_tungstenite::connect_async(request).await {
            Ok((ws, _)) => Ok(ws),
            Err(tungstenite::Error::Http(res)) => Err(res.status().as_u16()),
            Err(other) => panic!("expected an HTTP refusal, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn the_tabs_route_needs_a_device_and_a_running_browser() {
        let dir = tempfile::tempdir().unwrap();
        let app = app(dir.path());
        assert_eq!(get(&app, "/v1/browser/tabs", &[]).await.0, StatusCode::UNAUTHORIZED);
        assert_eq!(
            get(&app, "/v1/browser/tabs", &[AUTH, ORIGIN]).await.0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            get(&app, "/v1/browser/tabs", &[AUTH]).await,
            (StatusCode::CONFLICT, r#"{"error":"browser_not_running"}"#.to_string())
        );
        assert_eq!(
            get(&app, "/v1/browser/tabs?workspace=a%2Fb", &[AUTH]).await.0,
            StatusCode::BAD_REQUEST
        );
    }

    #[tokio::test]
    async fn the_cdp_routes_check_the_device_and_the_target_before_the_upgrade() {
        let dir = tempfile::tempdir().unwrap();
        let addr = serve(app(dir.path())).await;
        let long_path = format!("/v1/browser/cdp/page/{}", "A".repeat(65));
        let cases = [
            ("/v1/browser/cdp", vec![], 401),
            ("/v1/browser/cdp", vec![AUTH, ORIGIN], 403),
            ("/v1/browser/cdp", vec![AUTH], 409),
            ("/v1/browser/cdp/page/T1", vec![], 401),
            ("/v1/browser/cdp/page/T1", vec![AUTH, ORIGIN], 403),
            ("/v1/browser/cdp/page/bad-id", vec![AUTH], 400),
            // An empty segment matches no route at all.
            ("/v1/browser/cdp/page/", vec![AUTH], 404),
            (long_path.as_str(), vec![AUTH], 400),
            ("/v1/browser/cdp/page/T1", vec![AUTH], 409),
        ];
        for (path, headers, status) in cases {
            match upgrade(addr, path, &headers).await {
                Err(got) => assert_eq!(got, status, "{path} {headers:?}"),
                Ok(_) => panic!("{path} {headers:?} upgraded"),
            }
        }
    }

    /// Real Chrome behind the app's routes: the tab list, a browser-level socket, and a tab socket
    /// that sees plain CDP. Run with: `BANDITO_BROWSER_IT=1 cargo test -- --ignored browser_it_app`.
    #[tokio::test]
    #[ignore = "starts a real Chrome; BANDITO_BROWSER_IT=1 cargo test -- --ignored browser_it_app"]
    async fn browser_it_app_sockets_speak_plain_cdp() {
        if std::env::var("BANDITO_BROWSER_IT").as_deref() != Ok("1") {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let app = app(dir.path());
        app.browser.start(DEFAULT_WORKSPACE).await.expect("start");
        let page = "data:text/html;charset=utf-8,<title>relay-check</title><p>hi</p>";
        app.browser.agent_open(page, false).await.expect("open");
        let addr = serve(app.clone()).await;

        let (status, body) = get(&app, "/v1/browser/tabs", &[AUTH]).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        let tabs: Value = serde_json::from_str(&body).unwrap();
        let tab = tabs
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["title"] == "relay-check")
            .unwrap_or_else(|| panic!("no tab titled 'relay-check' in {body}"));
        assert_eq!(tab["type"], "page");
        let target = tab["id"].as_str().unwrap().to_string();

        // Browser level: a command, and its answer under the same id.
        let mut browser = upgrade(addr, "/v1/browser/cdp", &[AUTH]).await.expect("browser socket");
        browser
            .send(Message::Text(
                json!({"id": 7, "method": "Browser.getVersion"}).to_string().into(),
            ))
            .await
            .unwrap();
        let answer = next_json(&mut browser).await;
        assert_eq!(answer["id"], 7);
        assert!(answer["result"]["product"].is_string(), "{answer}");

        // One tab: plain CDP, no sessionId on either side.
        let path = format!("/v1/browser/cdp/page/{target}");
        let mut tab_socket = upgrade(addr, &path, &[AUTH]).await.expect("tab socket");
        tab_socket
            .send(Message::Text(
                json!({"id": 3, "method": "Runtime.evaluate", "params": {"expression": "document.title", "returnByValue": true}})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        let answer = next_json(&mut tab_socket).await;
        assert_eq!(answer["id"], 3);
        assert_eq!(answer["result"]["result"]["value"], "relay-check", "{answer}");
        assert!(answer.get("sessionId").is_none(), "{answer}");

        let missing = upgrade(addr, "/v1/browser/cdp/page/NOSUCHTAB", &[AUTH]).await;
        assert_eq!(missing.err(), Some(404));

        app.browser.stop(DEFAULT_WORKSPACE).await;
    }

    /// The next text message on a socket, as JSON.
    async fn next_json<S>(socket: &mut S) -> Value
    where
        S: futures_util::Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
    {
        use futures_util::StreamExt;
        loop {
            match tokio::time::timeout(std::time::Duration::from_secs(10), socket.next())
                .await
                .expect("no message")
                .expect("socket closed")
                .expect("socket error")
            {
                Message::Text(text) => return serde_json::from_str(&text).unwrap(),
                _ => continue,
            }
        }
    }
}
