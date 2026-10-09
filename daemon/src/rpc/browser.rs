//! `browser.*` JSON-RPC methods (for the app) and `browser.agent.*` (for the crew MCP on this
//! server). The logic is in `crate::browser`. See docs/ARCHITECTURE.md#browser.

use super::{
    App, BROWSER_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, UNAUTHORIZED, ok, params,
};
use crate::browser::{BrowserError, CLICK_APPROVAL_LIMIT, DEFAULT_WORKSPACE, Holder};
use serde::Deserialize;
use serde_json::{Value, json};

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
