//! Browser feature: pure helpers, the agent's MCP tools, and one real-Chrome test (ignored by default).
//! Unit tests of private helpers live next to the code (browser.rs, cdp.rs, rpc/preview.rs).

use async_trait::async_trait;
use bandito::browser::{BrowserError, chrome_args, is_risky_name};
use bandito::cdp::render_snapshot;
use bandito::crew::{CrewBackend, CrewMember, serve};
use bandito::rpc::preview::{is_hop_by_hop, rewrite_location};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Mutex;

// --- snapshot rendering from a recorded AX tree ---

#[test]
fn snapshot_keeps_interactive_nodes_with_refs_and_truncates_names() {
    let fixture: Value = serde_json::from_str(include_str!("fixtures/browser/ax_tree.json")).unwrap();
    let expected = include_str!("fixtures/browser/ax_tree.snapshot.txt").trim_end();
    let nodes = fixture["nodes"].as_array().unwrap();
    let text = render_snapshot(
        fixture["title"].as_str().unwrap(),
        fixture["url"].as_str().unwrap(),
        nodes,
    );
    assert_eq!(text, expected);
}

#[test]
fn snapshot_stops_after_600_element_lines() {
    let nodes: Vec<Value> = (1..=700)
        .map(|i| json!({"ignored": false, "role": {"value": "link"}, "name": {"value": format!("l{i}")}, "backendDOMNodeId": i}))
        .collect();
    let text = render_snapshot("T", "https://x.test/", &nodes);
    let element_lines = text.lines().filter(|l| l.starts_with('[')).count();
    assert_eq!(element_lines, 600);
    assert!(text.lines().last().unwrap().starts_with('…'), "{text}");
}

// --- risky names (approval of browser clicks) ---

#[test]
fn risky_names_match_in_english_and_russian_ignoring_case() {
    for name in [
        "Pay now",
        "BUY",
        "Purchase",
        "Checkout",
        "Place order",
        "Subscribe",
        "Send",
        "Submit form",
        "Delete account",
        "Remove",
        "Transfer",
        "Confirm",
        "Оплатить",
        "Купить",
        "Оформить заказ",
        "Подписаться",
        "Отправить",
        "Удалить",
        "Перевести",
        "Подтвердить",
        "ОПЛАТА",
    ] {
        assert!(is_risky_name(name), "{name} should be risky");
    }
}

#[test]
fn ordinary_names_are_not_risky() {
    for name in [
        "Home",
        "Cancel",
        "Search",
        "Email",
        "Logo",
        "Next",
        "Назад",
        "Главная",
        "Каталог",
        "Поиск",
        "",
    ] {
        assert!(!is_risky_name(name), "{name} should not be risky");
    }
}

// --- Chrome launch arguments ---

#[test]
fn chrome_starts_headless_with_the_profile_and_port() {
    let args = chrome_args(Path::new("/home/u/.bandito/workspaces/shared/browser"), 9222, false);
    for flag in [
        "--remote-debugging-port=9222",
        "--remote-debugging-address=127.0.0.1",
        "--user-data-dir=/home/u/.bandito/workspaces/shared/browser",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-dev-shm-usage",
        "--password-store=basic",
        "--window-size=1440,900",
        "--headless=new",
    ] {
        assert!(args.iter().any(|a| a == flag), "missing {flag}: {args:?}");
    }
    assert!(!args.iter().any(|a| a == "--no-sandbox"), "{args:?}");
}

#[test]
fn no_sandbox_only_when_asked() {
    let args = chrome_args(Path::new("/p"), 1, true);
    assert!(args.iter().any(|a| a == "--no-sandbox"));
}

// --- hop-by-hop headers and Location rewriting (preview proxy) ---

#[test]
fn hop_by_hop_headers_are_detected_including_connection_tokens() {
    for name in [
        "connection",
        "keep-alive",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    ] {
        assert!(is_hop_by_hop(name, &[]), "{name}");
    }
    assert!(!is_hop_by_hop("content-type", &[]));
    assert!(is_hop_by_hop("x-private", &["x-private".to_string()]));
}

#[test]
fn location_to_the_target_is_rewritten_under_the_proxy_prefix() {
    assert_eq!(rewrite_location("http://127.0.0.1:3000/x", 3000), "/v1/proxy/3000/x");
    assert_eq!(
        rewrite_location("http://localhost:3000/x?y=1", 3000),
        "/v1/proxy/3000/x?y=1"
    );
    assert_eq!(rewrite_location("http://127.0.0.1:3000", 3000), "/v1/proxy/3000/");
    assert_eq!(
        rewrite_location("http://127.0.0.1:3000?a=1", 3000),
        "/v1/proxy/3000/?a=1"
    );
    assert_eq!(rewrite_location("/login", 3000), "/v1/proxy/3000/login");
    assert_eq!(rewrite_location("https://other.test/x", 3000), "https://other.test/x");
    assert_eq!(
        rewrite_location("http://127.0.0.1:30001/x", 3000),
        "http://127.0.0.1:30001/x"
    );
    assert_eq!(rewrite_location("sibling.html", 3000), "sibling.html");
}

// --- crew MCP tools for the browser ---

#[derive(Default)]
struct BrowserMock {
    calls: Mutex<Vec<(String, Value)>>,
    reply: Mutex<Option<Value>>,
    fail: Option<String>,
}

#[async_trait]
impl CrewBackend for BrowserMock {
    async fn list(&self) -> anyhow::Result<Vec<CrewMember>> {
        Ok(Vec::new())
    }
    async fn send(&self, _to: &str, _message: &str) -> anyhow::Result<()> {
        Ok(())
    }
    async fn history_search(&self, _query: &str, _limit: u32) -> anyhow::Result<String> {
        Ok(String::new())
    }
    async fn history_day(&self, _date: &str) -> anyhow::Result<String> {
        Ok(String::new())
    }
    async fn screen(&self, _method: &str, _params: Value) -> anyhow::Result<Value> {
        anyhow::bail!("no screen in this test")
    }
    async fn browser(&self, method: &str, params: Value) -> anyhow::Result<Value> {
        self.calls.lock().unwrap().push((method.to_string(), params));
        if let Some(e) = &self.fail {
            anyhow::bail!("{e}");
        }
        Ok(self.reply.lock().unwrap().clone().unwrap_or(json!({"text": "ok"})))
    }
}

async fn mcp(backend: &BrowserMock, name: &str, args: Value) -> Value {
    let request =
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": name, "arguments": args}});
    let mut out = Vec::new();
    serve(format!("{request}\n").as_bytes(), &mut out, backend)
        .await
        .unwrap();
    serde_json::from_slice(&out).unwrap()
}

#[tokio::test]
async fn crew_lists_the_browser_tools_after_the_crew_tools() {
    let backend = BrowserMock::default();
    let mut out = Vec::new();
    let req = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"});
    serve(format!("{req}\n").as_bytes(), &mut out, &backend).await.unwrap();
    let reply: Value = serde_json::from_slice(&out).unwrap();
    let names: Vec<&str> = reply["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        [
            "crew_list",
            "crew_send",
            "history_search",
            "history_day",
            "screen_screenshot",
            "screen_click",
            "screen_move",
            "screen_type",
            "screen_key",
            "screen_scroll",
            "screen_launch",
            "browser_open",
            "browser_snapshot",
            "browser_click",
            "browser_type",
            "browser_press",
            "browser_back",
            "browser_screenshot",
            "browser_tabs",
            "browser_switch",
        ]
    );
}

#[tokio::test]
async fn browser_open_sends_the_url_to_the_daemon() {
    let backend = BrowserMock::default();
    let r = mcp(&backend, "browser_open", json!({"url": "https://example.test"})).await;
    assert_eq!(r["result"]["isError"], false);
    assert_eq!(r["result"]["content"][0]["text"], "ok");
    let calls = backend.calls.lock().unwrap();
    assert_eq!(calls[0].0, "browser.agent.open");
    assert_eq!(calls[0].1["url"], "https://example.test");
}

#[tokio::test]
async fn browser_open_without_url_is_a_tool_error() {
    let backend = BrowserMock::default();
    let r = mcp(&backend, "browser_open", json!({})).await;
    assert_eq!(r["result"]["isError"], true);
    assert!(backend.calls.lock().unwrap().is_empty());
}

#[tokio::test]
async fn browser_click_sends_only_the_ref_and_refuses_a_text_ref() {
    let backend = BrowserMock::default();
    let r = mcp(&backend, "browser_click", json!({"ref": 12})).await;
    assert_eq!(r["result"]["isError"], false);
    {
        let calls = backend.calls.lock().unwrap();
        assert_eq!(calls[0].0, "browser.agent.click");
        assert_eq!(calls[0].1, json!({"ref": 12}));
    }
    let r = mcp(&backend, "browser_click", json!({"ref": "12"})).await;
    assert_eq!(r["result"]["isError"], true);
    assert_eq!(backend.calls.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn browser_click_refusal_reaches_the_agent_as_a_tool_error() {
    let backend = BrowserMock {
        fail: Some("The user declined this click.".into()),
        ..Default::default()
    };
    let r = mcp(&backend, "browser_click", json!({"ref": 12})).await;
    assert_eq!(r["result"]["isError"], true);
    assert_eq!(r["result"]["content"][0]["text"], "The user declined this click.");
    assert!(r.get("error").is_none());
}

#[tokio::test]
async fn browser_type_press_back_snapshot_tabs_and_switch_map_to_daemon_methods() {
    let backend = BrowserMock::default();
    mcp(
        &backend,
        "browser_type",
        json!({"ref": 8, "text": "a@b.c", "submit": true}),
    )
    .await;
    mcp(&backend, "browser_press", json!({"key": "Enter"})).await;
    mcp(&backend, "browser_back", json!({})).await;
    mcp(&backend, "browser_snapshot", json!({})).await;
    mcp(&backend, "browser_tabs", json!({})).await;
    let r = mcp(&backend, "browser_switch", json!({"index": 1})).await;
    assert_eq!(r["result"]["isError"], false);
    let r = mcp(&backend, "browser_switch", json!({"index": -1})).await;
    assert_eq!(r["result"]["isError"], true);
    let calls = backend.calls.lock().unwrap();
    let methods: Vec<&str> = calls.iter().map(|c| c.0.as_str()).collect();
    assert_eq!(
        methods,
        [
            "browser.agent.type",
            "browser.agent.press",
            "browser.agent.back",
            "browser.agent.snapshot",
            "browser.agent.tabs",
            "browser.agent.switch",
        ]
    );
    assert_eq!(calls[0].1["submit"], true);
    assert_eq!(calls[0].1["text"], "a@b.c");
    assert_eq!(calls[1].1["key"], "Enter");
    assert_eq!(calls[5].1["index"], 1);
}

#[tokio::test]
async fn browser_screenshot_is_an_image_block() {
    let backend = BrowserMock {
        reply: Mutex::new(Some(json!({"png_base64": "iVBORw0KGgo="}))),
        ..Default::default()
    };
    let r = mcp(&backend, "browser_screenshot", json!({})).await;
    assert_eq!(r["result"]["isError"], false);
    assert_eq!(r["result"]["content"][0]["type"], "image");
    assert_eq!(r["result"]["content"][0]["mimeType"], "image/png");
    assert_eq!(r["result"]["content"][0]["data"], "iVBORw0KGgo=");
}

#[tokio::test]
async fn browser_backend_error_is_a_tool_error_with_its_message() {
    let backend = BrowserMock {
        fail: Some("The user is using the browser. Wait or ask them to hand it back.".into()),
        ..Default::default()
    };
    let r = mcp(&backend, "browser_snapshot", json!({})).await;
    assert_eq!(r["result"]["isError"], true);
    assert_eq!(
        r["result"]["content"][0]["text"],
        "The user is using the browser. Wait or ask them to hand it back."
    );
}

// --- errors the RPC layer maps (the real-Chrome flow is in src/browser.rs, ignored by default) ---

#[test]
fn browser_errors_have_stable_reasons() {
    // Every error the RPC layer maps must exist as a variant; this keeps the names in one place.
    let _ = [
        BrowserError::MissingComponent,
        BrowserError::Unsupported,
        BrowserError::NotRunning,
        BrowserError::UserControls,
        BrowserError::Declined,
        BrowserError::InvalidWorkspace,
        BrowserError::UnsupportedUrl,
    ];
}
