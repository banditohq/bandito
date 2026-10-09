//! Chrome DevTools Protocol client for the agent's browser tools: one WebSocket per
//! operation, commands answered by id, events queued while a command waits.
//! See docs/ARCHITECTURE.md#browser.

use anyhow::{Context, Result, anyhow, bail};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::VecDeque;
use std::time::Duration;
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};

/// Longest a navigation may take to fire its load event.
pub const LOAD_TIMEOUT: Duration = Duration::from_secs(30);
/// Most element lines in one snapshot.
pub const SNAPSHOT_MAX_LINES: usize = 600;
/// Longest a name or value is shown in a snapshot line, in characters.
const TEXT_LIMIT: usize = 120;
/// Events kept while a command waits for its answer.
const EVENT_QUEUE_LIMIT: usize = 1000;
/// Widest screenshot the agent gets; wider pages are scaled down to this.
const SCREENSHOT_MAX_WIDTH: f64 = 1280.0;
/// Accessibility roles that get a snapshot line.
const SNAPSHOT_ROLES: [&str; 11] = [
    "link",
    "button",
    "textbox",
    "searchbox",
    "combobox",
    "checkbox",
    "radio",
    "menuitem",
    "tab",
    "heading",
    "image",
];

/// One open DevTools WebSocket (a page, or the browser itself).
pub struct Cdp {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    next_id: u64,
    events: VecDeque<Value>,
}

impl Cdp {
    pub async fn connect(url: &str) -> Result<Self> {
        let (ws, _) = connect_async(url)
            .await
            .with_context(|| format!("cannot connect to the browser at {url}"))?;
        Ok(Self {
            ws,
            next_id: 1,
            events: VecDeque::new(),
        })
    }

    /// Send one command and return its `result`. Events that arrive first are kept for [`Cdp::wait_event`].
    pub async fn call(&mut self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id;
        self.next_id += 1;
        let request = json!({ "id": id, "method": method, "params": params });
        self.ws.send(Message::Text(request.to_string().into())).await?;
        loop {
            let msg = self.read().await?;
            if msg.get("id") == Some(&json!(id)) {
                if let Some(err) = msg.get("error") {
                    let text = err.get("message").and_then(Value::as_str).unwrap_or("CDP error");
                    bail!("{method}: {text}");
                }
                return Ok(msg.get("result").cloned().unwrap_or(Value::Null));
            }
            self.keep_event(msg);
        }
    }

    /// The next event called `name`, from the queue or the socket, within `limit`.
    pub async fn wait_event(&mut self, name: &str, limit: Duration) -> Result<Value> {
        if let Some(pos) = self.events.iter().position(|e| is_event(e, name)) {
            return Ok(self.events.remove(pos).unwrap_or(Value::Null));
        }
        let found = tokio::time::timeout(limit, async {
            loop {
                let msg = self.read().await?;
                if is_event(&msg, name) {
                    return Ok::<Value, anyhow::Error>(msg);
                }
                self.keep_event(msg);
            }
        })
        .await;
        match found {
            Ok(event) => event,
            Err(_) => bail!("timed out after {} s waiting for {name}", limit.as_secs()),
        }
    }

    async fn read(&mut self) -> Result<Value> {
        loop {
            match self.ws.next().await {
                Some(Ok(Message::Text(text))) => return Ok(serde_json::from_str(&text)?),
                Some(Ok(Message::Close(_))) | None => bail!("the browser closed the connection"),
                // Pings are answered by the library; binary frames are not used.
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(e.into()),
            }
        }
    }

    fn keep_event(&mut self, msg: Value) {
        if msg.get("method").is_some() {
            if self.events.len() == EVENT_QUEUE_LIMIT {
                self.events.pop_front();
            }
            self.events.push_back(msg);
        }
    }

    /// Navigate and wait for the load event. A same-document navigation (no `loaderId`) has none, so it returns at once.
    pub async fn open(&mut self, url: &str) -> Result<()> {
        self.call("Page.enable", json!({})).await?;
        let nav = self.call("Page.navigate", json!({ "url": url })).await?;
        if let Some(err) = nav.get("errorText").and_then(Value::as_str) {
            bail!("navigation failed: {err}");
        }
        if nav.get("loaderId").is_some_and(|id| !id.is_null()) {
            self.wait_event("Page.loadEventFired", LOAD_TIMEOUT).await?;
        }
        Ok(())
    }

    /// Title, URL and the interactive elements of the page, as text (see [`render_snapshot`]).
    pub async fn snapshot(&mut self) -> Result<String> {
        let evaluated = self
            .call(
                "Runtime.evaluate",
                json!({ "expression": "JSON.stringify([document.title, location.href])", "returnByValue": true }),
            )
            .await?;
        let pair = evaluated["result"]["value"].as_str().unwrap_or("[\"\",\"\"]");
        let (title, url): (String, String) = serde_json::from_str(pair).unwrap_or_default();
        let ax = self.call("Accessibility.getFullAXTree", json!({})).await?;
        let nodes = ax["nodes"].as_array().cloned().unwrap_or_default();
        Ok(render_snapshot(&title, &url, &nodes))
    }

    /// The URL of the page.
    pub async fn url(&mut self) -> Result<String> {
        let evaluated = self
            .call(
                "Runtime.evaluate",
                json!({ "expression": "location.href", "returnByValue": true }),
            )
            .await?;
        Ok(evaluated["result"]["value"].as_str().unwrap_or_default().to_string())
    }

    /// Role, name and value of the element with this ref (its `backendDOMNodeId`).
    pub async fn element(&mut self, node: i64) -> Result<Element> {
        let r = self
            .call(
                "Accessibility.getPartialAXTree",
                json!({ "backendNodeId": node, "fetchRelatives": false }),
            )
            .await
            .with_context(|| format!("no element with ref {node}; take a new snapshot"))?;
        let nodes = r["nodes"].as_array().cloned().unwrap_or_default();
        Ok(element_of(&nodes, node).unwrap_or_default())
    }

    /// Click the centre of the element, after scrolling it into view.
    pub async fn click(&mut self, node: i64) -> Result<()> {
        self.call("DOM.scrollIntoViewIfNeeded", json!({ "backendNodeId": node }))
            .await
            .with_context(|| format!("no element with ref {node}; take a new snapshot"))?;
        let boxed = self
            .call("DOM.getBoxModel", json!({ "backendNodeId": node }))
            .await
            .context("the element has no layout box (hidden?)")?;
        let quad: Vec<f64> = boxed["model"]["content"]
            .as_array()
            .map(|c| c.iter().filter_map(Value::as_f64).collect())
            .unwrap_or_default();
        if quad.len() != 8 {
            bail!("the element has no usable box");
        }
        let x = (quad[0] + quad[2] + quad[4] + quad[6]) / 4.0;
        let y = (quad[1] + quad[3] + quad[5] + quad[7]) / 4.0;
        self.call(
            "Input.dispatchMouseEvent",
            json!({ "type": "mouseMoved", "x": x, "y": y }),
        )
        .await?;
        for kind in ["mousePressed", "mouseReleased"] {
            let params = json!({ "type": kind, "x": x, "y": y, "button": "left", "clickCount": 1 });
            self.call("Input.dispatchMouseEvent", params).await?;
        }
        Ok(())
    }

    /// Focus the element, insert the text, and press Enter when `submit` is set.
    pub async fn type_text(&mut self, node: i64, text: &str, submit: bool) -> Result<()> {
        self.call("DOM.focus", json!({ "backendNodeId": node }))
            .await
            .with_context(|| format!("no element with ref {node}; take a new snapshot"))?;
        if !text.is_empty() {
            self.call("Input.insertText", json!({ "text": text })).await?;
        }
        if submit {
            self.press("Enter").await?;
        }
        Ok(())
    }

    /// Press one named key (see [`key_spec`]).
    pub async fn press(&mut self, name: &str) -> Result<()> {
        let spec = key_spec(name).ok_or_else(|| anyhow!("unsupported key: {name}"))?;
        let mut down = json!({
            "type": "keyDown", "key": spec.key, "code": spec.code,
            "windowsVirtualKeyCode": spec.key_code, "nativeVirtualKeyCode": spec.key_code,
        });
        if let Some(text) = spec.text {
            down["text"] = json!(text);
        }
        self.call("Input.dispatchKeyEvent", down).await?;
        let up = json!({
            "type": "keyUp", "key": spec.key, "code": spec.code,
            "windowsVirtualKeyCode": spec.key_code, "nativeVirtualKeyCode": spec.key_code,
        });
        self.call("Input.dispatchKeyEvent", up).await?;
        Ok(())
    }

    /// Go back one history entry. `false` when there is none.
    pub async fn back(&mut self) -> Result<bool> {
        let history = self.call("Page.getNavigationHistory", json!({})).await?;
        let current = history["currentIndex"].as_u64().unwrap_or(0);
        if current == 0 {
            return Ok(false);
        }
        let entry = history["entries"][(current - 1) as usize]["id"].clone();
        self.call("Page.navigateToHistoryEntry", json!({ "entryId": entry }))
            .await?;
        // Best effort: a same-document entry fires no load event, and the snapshot that follows is the real check.
        let _ = self.wait_event("Page.loadEventFired", Duration::from_secs(5)).await;
        Ok(true)
    }

    /// The visible page as a base64 PNG, scaled to at most 1280 px wide.
    pub async fn screenshot(&mut self) -> Result<String> {
        let metrics = self.call("Page.getLayoutMetrics", json!({})).await?;
        let view = &metrics["cssVisualViewport"];
        let width = view["clientWidth"].as_f64().unwrap_or(0.0);
        let mut params = json!({ "format": "png" });
        if width > SCREENSHOT_MAX_WIDTH {
            params["clip"] = json!({
                "x": view["pageX"].as_f64().unwrap_or(0.0),
                "y": view["pageY"].as_f64().unwrap_or(0.0),
                "width": width,
                "height": view["clientHeight"].as_f64().unwrap_or(0.0),
                "scale": SCREENSHOT_MAX_WIDTH / width,
            });
        }
        let shot = self.call("Page.captureScreenshot", params).await?;
        shot["data"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| anyhow!("the browser sent no screenshot"))
    }
}

fn is_event(msg: &Value, name: &str) -> bool {
    msg.get("method").and_then(Value::as_str) == Some(name)
}

/// What an element is, as the accessibility tree names it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Element {
    pub role: String,
    pub name: String,
    pub value: String,
}

/// The element with this ref in an accessibility node list, unless it is ignored.
pub fn element_of(nodes: &[Value], node: i64) -> Option<Element> {
    nodes
        .iter()
        .find(|n| !is_ignored(n) && n.get("backendDOMNodeId").and_then(Value::as_i64) == Some(node))
        .map(|n| Element {
            role: ax_text(n, "role"),
            name: ax_text(n, "name"),
            value: ax_text(n, "value"),
        })
}

/// The snapshot the agent reads: a title and URL line, then one `[ref] role "name" (value)` line per
/// interactive or meaningful node, in page order. Images without a name are left out. At most
/// [`SNAPSHOT_MAX_LINES`] element lines; a final `…` line says when there were more.
pub fn render_snapshot(title: &str, url: &str, nodes: &[Value]) -> String {
    let mut lines = vec![format!("Title: {}", clean(title)), format!("URL: {url}")];
    let mut elements = 0;
    for node in nodes {
        if is_ignored(node) {
            continue;
        }
        let role = ax_text(node, "role");
        if !SNAPSHOT_ROLES.contains(&role.as_str()) {
            continue;
        }
        let Some(id) = node.get("backendDOMNodeId").and_then(Value::as_i64) else {
            continue;
        };
        let name = clean(&ax_text(node, "name"));
        if role == "image" && name.is_empty() {
            continue;
        }
        if elements == SNAPSHOT_MAX_LINES {
            lines.push("… (more elements; scroll and take a new snapshot)".to_string());
            break;
        }
        elements += 1;
        let mut line = format!("[{id}] {role} \"{name}\"");
        let value = clean(&ax_text(node, "value"));
        if !value.is_empty() {
            line.push_str(&format!(" ({value})"));
        }
        lines.push(line);
    }
    lines.join("\n")
}

fn is_ignored(node: &Value) -> bool {
    node.get("ignored").and_then(Value::as_bool).unwrap_or(false)
}

/// The `value` of an accessibility property (`{"type": ..., "value": ...}`), as text.
fn ax_text(node: &Value, field: &str) -> String {
    match node.get(field).and_then(|f| f.get("value")) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

/// Whitespace collapsed to single spaces, quotes made single, cut to [`TEXT_LIMIT`] characters.
fn clean(text: &str) -> String {
    let joined = text.split_whitespace().collect::<Vec<_>>().join(" ").replace('"', "'");
    if joined.chars().count() > TEXT_LIMIT {
        format!("{}…", joined.chars().take(TEXT_LIMIT).collect::<String>())
    } else {
        joined
    }
}

/// A named key for `Input.dispatchKeyEvent`.
#[derive(Debug, PartialEq, Eq)]
pub struct KeySpec {
    pub key: &'static str,
    pub code: &'static str,
    pub key_code: i64,
    /// Text the key types (only keyDown carries it).
    pub text: Option<&'static str>,
}

/// The named keys `browser_press` accepts.
pub fn key_spec(name: &str) -> Option<KeySpec> {
    let (key, code, key_code, text) = match name {
        "Enter" => ("Enter", "Enter", 13, Some("\r")),
        "Tab" => ("Tab", "Tab", 9, None),
        "Escape" => ("Escape", "Escape", 27, None),
        "Backspace" => ("Backspace", "Backspace", 8, None),
        "Delete" => ("Delete", "Delete", 46, None),
        "Space" => (" ", "Space", 32, Some(" ")),
        "ArrowUp" => ("ArrowUp", "ArrowUp", 38, None),
        "ArrowDown" => ("ArrowDown", "ArrowDown", 40, None),
        "ArrowLeft" => ("ArrowLeft", "ArrowLeft", 37, None),
        "ArrowRight" => ("ArrowRight", "ArrowRight", 39, None),
        "Home" => ("Home", "Home", 36, None),
        "End" => ("End", "End", 35, None),
        "PageUp" => ("PageUp", "PageUp", 33, None),
        "PageDown" => ("PageDown", "PageDown", 34, None),
        _ => return None,
    };
    Some(KeySpec {
        key,
        code,
        key_code,
        text,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn named_keys_known_and_unknown() {
        assert_eq!(key_spec("Enter").unwrap().text, Some("\r"));
        assert_eq!(key_spec("Escape").unwrap().key_code, 27);
        assert!(key_spec("Ctrl+A").is_none());
        assert!(key_spec("enter").is_none());
    }

    #[test]
    fn element_of_skips_ignored_and_other_refs() {
        let nodes = vec![
            json!({"ignored": true, "role": {"value": "button"}, "name": {"value": "Hidden"}, "backendDOMNodeId": 4}),
            json!({"ignored": false, "role": {"value": "button"}, "name": {"value": "Pay"}, "backendDOMNodeId": 4}),
        ];
        assert_eq!(
            element_of(&nodes, 4),
            Some(Element {
                role: "button".into(),
                name: "Pay".into(),
                value: String::new(),
            })
        );
        assert_eq!(element_of(&nodes, 9), None);
    }

    #[test]
    fn clean_collapses_whitespace_and_quotes() {
        assert_eq!(clean("  a \n\t b \"c\" "), "a b 'c'");
    }
}
