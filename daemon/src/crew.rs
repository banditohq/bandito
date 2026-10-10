//! Crew MCP server: lets one agent see and message the other agents of its crew.
//!
//! The daemon starts `bandito --home <home> mcp --agent <id>` for every agent.
//! That process speaks MCP (JSON-RPC 2.0, one message per line) on stdio and
//! forwards `crew.list` / `crew.send` to the daemon over its unix socket.
//! Stdout carries the protocol only, so logs must go to stderr.

use crate::forms;
use crate::rpc::unix::{call_agent, call_agent_waiting};
use crate::store::{ALL_CAPABILITIES, Capability};
use anyhow::{Context, Result, bail};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};

/// Version answered when the client asks for none we support.
const PROTOCOL_VERSION: &str = "2025-06-18";
/// Protocol versions this server speaks. A client asking for one gets it back.
const SUPPORTED_PROTOCOL_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];
/// Longest input line we accept. A longer line is refused and skipped without being kept.
const MAX_LINE_BYTES: usize = 1024 * 1024;
const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;

/// JSON-RPC error: code and message.
type Fault = (i64, String);

/// Another agent in the crew, as seen by the agent asking.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
pub struct CrewMember {
    pub name: String,
    pub role: String,
    pub runtime: String,
}

/// What the MCP tools need from the daemon. A trait so the protocol can be tested without a socket.
#[async_trait]
pub trait CrewBackend: Send + Sync {
    async fn list(&self) -> Result<Vec<CrewMember>>;
    async fn send(&self, to: &str, message: &str) -> Result<()>;
    /// Formatted matches from the agent's own past messages, newest first.
    async fn history_search(&self, query: &str, limit: u32) -> Result<String>;
    /// Everything said with the agent on one local day (`YYYY-MM-DD`), formatted.
    async fn history_day(&self, date: &str) -> Result<String>;
    /// A browser tool call: `method` is a `browser.agent.*` method, answered by the daemon.
    async fn browser(&self, method: &str, params: Value) -> Result<Value>;
    /// One `screen.agent.*` RPC method with its parameters. Returns the daemon's result.
    async fn screen(&self, method: &str, params: Value) -> Result<Value>;
    /// Asks the human with a form (`forms.agent.ask`) and waits for the answer. Returns `{action, values?, comment?}`.
    async fn ask_form(&self, form: Value) -> Result<Value> {
        let _ = form;
        bail!("ask_form is not available here")
    }
    /// Puts a reaction on a message (`messages.agent.react`). Returns the daemon's result.
    async fn react(&self, params: Value) -> Result<Value> {
        let _ = params;
        bail!("react is not available here")
    }
    /// One `schedules.agent.*` RPC method with its parameters. Returns the daemon's result.
    async fn schedules(&self, method: &str, params: Value) -> Result<Value>;
}

/// Backend that asks the daemon over `agent.sock`, as the agent whose session token it holds.
/// The daemon takes the agent from the token: the calls carry no agent id.
pub struct DaemonBackend {
    pub sock: PathBuf,
    pub token: String,
}

#[async_trait]
impl CrewBackend for DaemonBackend {
    async fn list(&self) -> Result<Vec<CrewMember>> {
        let v = call_agent(&self.sock, &self.token, "crew.list", json!({})).await?;
        serde_json::from_value(v).context("crew.list: unexpected response")
    }

    async fn send(&self, to: &str, message: &str) -> Result<()> {
        call_agent(
            &self.sock,
            &self.token,
            "crew.send",
            json!({ "to": to, "message": message }),
        )
        .await?;
        Ok(())
    }

    async fn history_search(&self, query: &str, limit: u32) -> Result<String> {
        let v = call_agent(
            &self.sock,
            &self.token,
            "history.search",
            json!({ "query": query, "limit": limit }),
        )
        .await?;
        text_of(v, "history.search")
    }

    async fn history_day(&self, date: &str) -> Result<String> {
        let v = call_agent(&self.sock, &self.token, "history.day", json!({ "date": date })).await?;
        text_of(v, "history.day")
    }

    async fn browser(&self, method: &str, params: Value) -> Result<Value> {
        // A risky click asks the user in the agent's feed, and the call waits for the answer: it may take as long
        // as the approval does. The daemon knows the agent from the token.
        match browser_wait(method) {
            Some(limit) => call_agent_waiting(&self.sock, &self.token, method, params, limit).await,
            None => call_agent(&self.sock, &self.token, method, params).await,
        }
    }

    async fn screen(&self, method: &str, params: Value) -> Result<Value> {
        call_agent(&self.sock, &self.token, method, params).await
    }

    async fn ask_form(&self, form: Value) -> Result<Value> {
        // The answer may take as long as the form waits (see `rpc::chat::FORM_WAIT`), plus a margin.
        let limit = crate::rpc::chat::FORM_WAIT + Duration::from_secs(60);
        call_agent_waiting(
            &self.sock,
            &self.token,
            "forms.agent.ask",
            json!({ "form": form }),
            limit,
        )
        .await
    }

    async fn react(&self, params: Value) -> Result<Value> {
        call_agent(&self.sock, &self.token, "messages.agent.react", params).await
    }

    async fn schedules(&self, method: &str, params: Value) -> Result<Value> {
        call_agent(&self.sock, &self.token, method, params).await
    }
}

/// How long a browser call may wait for the daemon: a click waits for the person's approval (see
/// `browser::approve_click`), with a margin; the other calls keep the plain limit (`None`).
fn browser_wait(method: &str) -> Option<Duration> {
    (method == "browser.agent.click").then(|| crate::browser::CLICK_APPROVAL_LIMIT + Duration::from_secs(60))
}

/// The `text` field of a history reply.
fn text_of(v: Value, method: &str) -> Result<String> {
    v.get("text")
        .and_then(Value::as_str)
        .map(str::to_string)
        .with_context(|| format!("{method}: unexpected response"))
}

/// Serve MCP until the reader reaches EOF. Every request gets one reply line;
/// notifications (no `id`) get none. `on` are the agent's capabilities: only their tools are served.
pub async fn serve<R, W>(mut reader: R, mut writer: W, backend: &dyn CrewBackend, on: &[Capability]) -> Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buf = Vec::new();
    loop {
        match read_line_capped(&mut reader, &mut buf).await? {
            LineRead::Eof => return Ok(()),
            LineRead::TooLong => {
                let reply = error_reply(Value::Null, PARSE_ERROR, "parse error: line is longer than 1 MB");
                write_reply(&mut writer, &reply).await?;
            }
            LineRead::Line => {
                let line = String::from_utf8_lossy(&buf);
                if line.trim().is_empty() {
                    continue;
                }
                if let Some(reply) = handle_line(&line, backend, on).await {
                    write_reply(&mut writer, &reply).await?;
                }
            }
        }
    }
}

enum LineRead {
    /// Input ended before any byte of a new line.
    Eof,
    /// A line is in the buffer, without its newline.
    Line,
    /// The line was over `MAX_LINE_BYTES`; it was skipped up to its newline.
    TooLong,
}

/// Read one line into `buf`. Bytes past `MAX_LINE_BYTES` are dropped as they
/// arrive, so an overlong line never sits in memory.
async fn read_line_capped<R: AsyncBufRead + Unpin>(reader: &mut R, buf: &mut Vec<u8>) -> std::io::Result<LineRead> {
    buf.clear();
    let mut too_long = false;
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            return Ok(match (too_long, buf.is_empty()) {
                (true, _) => LineRead::TooLong,
                (false, true) => LineRead::Eof,
                (false, false) => LineRead::Line,
            });
        }
        let (chunk, finished) = match available.iter().position(|&b| b == b'\n') {
            Some(i) => (&available[..i], true),
            None => (available, false),
        };
        if !too_long {
            if buf.len() + chunk.len() > MAX_LINE_BYTES {
                too_long = true;
                buf.clear();
            } else {
                buf.extend_from_slice(chunk);
            }
        }
        let used = chunk.len() + usize::from(finished);
        reader.consume(used);
        if finished {
            return Ok(if too_long { LineRead::TooLong } else { LineRead::Line });
        }
    }
}

async fn write_reply<W: AsyncWrite + Unpin>(writer: &mut W, reply: &Value) -> Result<()> {
    let mut out = reply.to_string();
    out.push('\n');
    writer.write_all(out.as_bytes()).await?;
    writer.flush().await?;
    Ok(())
}

/// Reply to one incoming line, or `None` when no reply is due.
async fn handle_line(line: &str, backend: &dyn CrewBackend, on: &[Capability]) -> Option<Value> {
    let Ok(msg) = serde_json::from_str::<Value>(line) else {
        return Some(error_reply(Value::Null, PARSE_ERROR, "parse error"));
    };
    let id = msg.get("id")?.clone();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or_default();
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let outcome: Result<Value, Fault> = match method {
        "initialize" => Ok(initialize(&params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({ "tools": tools_list(on) })),
        "tools/call" => call_tool(&params, backend, on).await,
        "" => Err((INVALID_REQUEST, "invalid request: no method".into())),
        other => Err((METHOD_NOT_FOUND, format!("Method not found: {other}"))),
    };
    Some(match outcome {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err((code, message)) => error_reply(id, code, &message),
    })
}

fn error_reply(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

fn initialize(params: &Value) -> Value {
    let version = params
        .get("protocolVersion")
        .and_then(Value::as_str)
        .filter(|v| SUPPORTED_PROTOCOL_VERSIONS.contains(v))
        .unwrap_or(PROTOCOL_VERSION);
    json!({
        "protocolVersion": version,
        "capabilities": { "tools": {} },
        "serverInfo": { "name": "bandito-crew", "version": env!("CARGO_PKG_VERSION") },
        "instructions": "Tools to talk to the other agents in your Bandito crew.",
    })
}

/// The tools served to an agent with these capabilities. A tool of a capability the agent lacks is not listed.
fn tools_list(on: &[Capability]) -> Vec<Value> {
    let mut tools = vec![
        crew_list_tool(),
        crew_send_tool(),
        history_search_tool(),
        history_day_tool(),
        ask_form_tool(),
        react_tool(),
    ];
    tools.extend(screen_tools());
    tools.extend(browser_tool_defs());
    tools.extend(crate::crew_schedule::tool_defs());
    tools.retain(|t| capability_of(t["name"].as_str().unwrap_or_default()).is_none_or(|c| on.contains(&c)));
    tools
}

/// The capability a tool needs; `None` for the tools every agent has (the history tools).
fn capability_of(tool: &str) -> Option<Capability> {
    match tool {
        "crew_list" | "crew_send" => Some(Capability::Team),
        t if BROWSER_TOOLS.contains(&t) => Some(Capability::Browser),
        t if SCREEN_TOOLS.iter().any(|(name, _)| *name == t) => Some(Capability::Screen),
        _ => None,
    }
}

fn crew_list_tool() -> Value {
    json!({
        "name": "crew_list",
        "description": "List the other agents in your Bandito crew: name, role and runtime.",
        "inputSchema": { "type": "object", "properties": {} },
    })
}

fn crew_send_tool() -> Value {
    json!({
        "name": "crew_send",
        "description": "Send a message to another agent in your crew, by name. Use it to hand off work or ask for a review. Their answer arrives later as a new message from them; don't wait for it in this turn.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "to": { "type": "string", "description": "Agent name" },
                "message": { "type": "string", "description": "What you want them to do, with enough context" },
            },
            "required": ["to", "message"],
        },
    })
}

fn history_search_tool() -> Value {
    json!({
        "name": "history_search",
        "description": "Search your past conversations with the user and the crew (older messages are not in your context). Returns matching messages with dates.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": { "type": "string", "description": "Text to look for" },
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 50,
                    "description": "How many matches to return, newest first (default 20)",
                },
            },
            "required": ["query"],
        },
    })
}

fn ask_form_tool() -> Value {
    let field = json!({
        "type": "object",
        "properties": {
            "id": { "type": "string", "description": "Short name of the field, letters, digits, _ or -; unique in the form" },
            "label": { "type": "string", "description": "What the person sees next to the field" },
            "type": {
                "type": "string",
                "enum": ["text", "textarea", "email", "number", "choice", "multichoice", "boolean", "date"],
            },
            "options": { "type": "array", "items": { "type": "string" }, "minItems": 1, "maxItems": 20, "description": "For choice and multichoice" },
            "required": { "type": "boolean", "description": "The person must answer (default false)" },
            "default": { "description": "Filled in before the person answers. A date is YYYY-MM-DD" },
            "placeholder": { "type": "string" },
            "help": { "type": "string", "description": "A hint under the field" },
        },
        "required": ["id", "label", "type"],
    });
    json!({
        "name": "ask_form",
        "description": "Ask the person a form instead of several questions in text. Blocks until they answer (up to 24 hours). Returns JSON: {\"action\": \"submit\" | \"reject\" | \"expired\", \"values\": {field id: answer}} on submit, {\"comment\"} may come with reject. Use kind \"confirm\" before anything that leaves the server (a letter, a post, a payment, a deletion): the fields are then shown as an editable summary.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": { "type": "string", "description": "Short title of the form" },
                "intro": { "type": "string", "description": "A line above the fields" },
                "kind": { "type": "string", "enum": ["question", "confirm"] },
                "fields": { "type": "array", "items": field, "minItems": 1, "maxItems": 20 },
                "submit_label": { "type": "string", "description": "Text of the submit button" },
                "reject_label": { "type": "string", "description": "Text of the reject button" },
            },
            "required": ["title", "kind", "fields"],
        },
    })
}

fn react_tool() -> Value {
    json!({
        "name": "react",
        "description": "Put an emoji reaction on a message of the person (by default the last one they sent) instead of a short reply. For example 👍 means got it, 👀 means looking at it. One reaction per message from you: a new one replaces the old one.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "seq": { "type": "integer", "minimum": 1, "description": "The message to react to; by default the person's last message" },
                "emoji": { "type": "string", "description": "One emoji" },
            },
            "required": ["emoji"],
        },
    })
}

fn history_day_tool() -> Value {
    json!({
        "name": "history_day",
        "description": "Read everything said with you on one day.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": { "type": "string", "description": "Day as YYYY-MM-DD (server local time)" },
            },
            "required": ["date"],
        },
    })
}

async fn call_tool(params: &Value, backend: &dyn CrewBackend, on: &[Capability]) -> Result<Value, Fault> {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
    let args = params.get("arguments").cloned().unwrap_or(Value::Null);
    // A tool of a capability the agent lacks is unknown to it, as if it were never registered.
    if capability_of(name).is_some_and(|c| !on.contains(&c)) {
        return Err((INVALID_PARAMS, format!("Unknown tool: {name}")));
    }
    match name {
        "crew_list" => Ok(tool_result(crew_list(backend).await)),
        "crew_send" => Ok(tool_result(crew_send(&args, backend).await)),
        "history_search" => Ok(tool_result(history_search(&args, backend).await)),
        "history_day" => Ok(tool_result(history_day(&args, backend).await)),
        "ask_form" => Ok(tool_result(ask_form(&args, backend).await)),
        "react" => Ok(tool_result(react(&args, backend).await)),
        name if BROWSER_TOOLS.contains(&name) => Ok(blocks_result(browser_tool(name, &args, backend).await)),
        _ if SCREEN_TOOLS.iter().any(|(tool, _)| *tool == name) => Ok(screen_tool(name, &args, backend).await),
        _ if crate::crew_schedule::SCHEDULE_TOOLS.contains(&name) => {
            Ok(tool_result(crate::crew_schedule::call(name, &args, backend).await))
        }
        _ => Err((INVALID_PARAMS, format!("Unknown tool: {name}"))),
    }
}

/// MCP tool result with a single text block. `Err` is a tool error (`isError`), not a protocol error.
fn tool_result(outcome: Result<String, String>) -> Value {
    let (text, is_error) = match outcome {
        Ok(text) => (text, false),
        Err(text) => (text, true),
    };
    json!({ "content": [{ "type": "text", "text": text }], "isError": is_error })
}

async fn crew_list(backend: &dyn CrewBackend) -> Result<String, String> {
    let members = backend.list().await.map_err(|e| format!("{e:#}"))?;
    if members.is_empty() {
        return Ok("No other agents in this crew yet.".into());
    }
    let lines: Vec<String> = members
        .iter()
        .map(|m| {
            let role = m.role.trim();
            if role.is_empty() {
                format!("- {} · {}", m.name, m.runtime)
            } else {
                format!("- {} ({role}) · {}", m.name, m.runtime)
            }
        })
        .collect();
    Ok(lines.join("\n"))
}

/// `ask_form`: the form is checked here first, so a mistake comes back as a tool error the agent can fix.
async fn ask_form(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    forms::parse_spec(args)?;
    let answer = backend.ask_form(args.clone()).await.map_err(|e| format!("{e:#}"))?;
    Ok(answer.to_string())
}

async fn react(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let emoji = args
        .get("emoji")
        .and_then(Value::as_str)
        .ok_or("react needs \"emoji\"")?;
    let seq = args.get("seq").filter(|v| !v.is_null());
    if let Some(seq) = seq
        && seq.as_i64().is_none_or(|n| n < 1)
    {
        return Err("seq must be a message number, 1 or more".into());
    }
    let params = json!({ "emoji": emoji, "seq": seq.cloned() });
    backend.react(params).await.map_err(|e| format!("{e:#}"))?;
    Ok(format!("Reacted with {emoji}."))
}

async fn crew_send(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let to = args.get("to").and_then(Value::as_str).filter(|s| !s.trim().is_empty());
    let message = args
        .get("message")
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty());
    let (Some(to), Some(message)) = (to, message) else {
        return Err("crew_send needs \"to\" and \"message\"".into());
    };
    backend.send(to, message).await.map_err(|e| format!("{e:#}"))?;
    Ok(format!(
        "Sent to {to}. Their answer will arrive as a new message from them."
    ))
}

/// The browser tools, in the order `tools/list` gives them. Their daemon methods: `browser.agent.*`.
const BROWSER_TOOLS: [&str; 9] = [
    "browser_open",
    "browser_snapshot",
    "browser_click",
    "browser_type",
    "browser_press",
    "browser_back",
    "browser_screenshot",
    "browser_tabs",
    "browser_switch",
];

fn browser_tool_defs() -> Vec<Value> {
    vec![
        json!({
            "name": "browser_open",
            "description": "Open a web page in the browser on the server, in the current tab (or a new one). Only http, https, data: and about:blank. Take a browser_snapshot after it loads.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "url": { "type": "string", "description": "Absolute URL" },
                    "new_tab": { "type": "boolean", "description": "Open in a new tab (default false)" },
                },
                "required": ["url"],
            },
        }),
        json!({
            "name": "browser_snapshot",
            "description": "Read the current page: title, URL, and its links, buttons, fields, headings and images, each with a [ref]. Take a snapshot before you click or type; refs come from the latest one.",
            "inputSchema": { "type": "object", "properties": {} },
        }),
        json!({
            "name": "browser_click",
            "description": "Click an element by its [ref] from browser_snapshot. A click that pays, buys, sends, submits, deletes, removes, transfers or confirms first asks the user in the app; the tool waits for their answer (up to 10 minutes) and says whether the click went ahead.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ref": { "type": "integer", "minimum": 1, "description": "The [ref] from browser_snapshot" },
                },
                "required": ["ref"],
            },
        }),
        json!({
            "name": "browser_type",
            "description": "Type text into a field by its [ref] from browser_snapshot. With submit, press Enter afterwards.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "ref": { "type": "integer", "minimum": 1, "description": "The [ref] of the field" },
                    "text": { "type": "string" },
                    "submit": { "type": "boolean", "description": "Press Enter after typing (default false)" },
                },
                "required": ["ref", "text"],
            },
        }),
        json!({
            "name": "browser_press",
            "description": "Press one key in the page.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": {
                        "type": "string",
                        "enum": [
                            "Enter", "Tab", "Escape", "Backspace", "Delete", "Space", "ArrowUp", "ArrowDown",
                            "ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown",
                        ],
                    },
                },
                "required": ["key"],
            },
        }),
        json!({
            "name": "browser_back",
            "description": "Go back one page in the current tab.",
            "inputSchema": { "type": "object", "properties": {} },
        }),
        json!({
            "name": "browser_screenshot",
            "description": "A PNG screenshot of the visible part of the current page (at most 1280 px wide).",
            "inputSchema": { "type": "object", "properties": {} },
        }),
        json!({
            "name": "browser_tabs",
            "description": "List the browser's tabs. The one you work in is marked with *.",
            "inputSchema": { "type": "object", "properties": {} },
        }),
        json!({
            "name": "browser_switch",
            "description": "Make the tab with this index (from browser_tabs) the one you work in, and bring it to the front.",
            "inputSchema": {
                "type": "object",
                "properties": { "index": { "type": "integer", "minimum": 0 } },
                "required": ["index"],
            },
        }),
    ]
}

/// Screen tools and the daemon method each one calls. The arguments are passed on as they are.
const SCREEN_TOOLS: [(&str, &str); 7] = [
    ("screen_screenshot", "screen.agent.screenshot"),
    ("screen_click", "screen.agent.click"),
    ("screen_move", "screen.agent.move"),
    ("screen_type", "screen.agent.type"),
    ("screen_key", "screen.agent.key"),
    ("screen_scroll", "screen.agent.scroll"),
    ("screen_launch", "screen.agent.launch"),
];

fn screen_tools() -> Vec<Value> {
    let point = |what: &str| {
        json!({
            "type": "integer",
            "minimum": 0,
            "description": format!("{what} in screen pixels, from the top left corner"),
        })
    };
    vec![
        json!({
            "name": "screen_screenshot",
            "description": "Take a screenshot of the server's screen, the desktop the user can also see over VNC. Starts the screen if it is not running. Returns the image, with the screen's original width and height and the scale of the image. Multiply coordinates you read from the image by 1/scale to get screen pixels for screen_click, screen_move and screen_scroll.",
            "inputSchema": { "type": "object", "properties": {} },
        }),
        json!({
            "name": "screen_click",
            "description": "Click at x, y in screen pixels (not the pixels of the screenshot; see screen_screenshot for the scale). Starts the screen if needed. Refused while the user controls the screen.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "x": point("X"),
                    "y": point("Y"),
                    "button": { "type": "string", "enum": ["left", "right", "middle"], "description": "Mouse button, left by default" },
                    "double": { "type": "boolean", "description": "Double click, false by default" },
                },
                "required": ["x", "y"],
            },
        }),
        json!({
            "name": "screen_move",
            "description": "Move the mouse pointer to x, y in screen pixels (not the pixels of the screenshot). Refused while the user controls the screen.",
            "inputSchema": {
                "type": "object",
                "properties": { "x": point("X"), "y": point("Y") },
                "required": ["x", "y"],
            },
        }),
        json!({
            "name": "screen_type",
            "description": "Type text into the window that has focus, as if typed on a keyboard. Refused while the user controls the screen.",
            "inputSchema": {
                "type": "object",
                "properties": { "text": { "type": "string", "description": "Text to type" } },
                "required": ["text"],
            },
        }),
        json!({
            "name": "screen_key",
            "description": "Press a key or a shortcut, for example Return, Tab, Escape, ctrl+l or alt+F4. Refused while the user controls the screen.",
            "inputSchema": {
                "type": "object",
                "properties": { "keys": { "type": "string", "description": "Key or shortcut, joined with +" } },
                "required": ["keys"],
            },
        }),
        json!({
            "name": "screen_scroll",
            "description": "Scroll with the mouse wheel at the pointer position, which can be set with screen_move (in screen pixels). Refused while the user controls the screen.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "direction": { "type": "string", "enum": ["up", "down", "left", "right"] },
                    "amount": { "type": "integer", "minimum": 1, "maximum": 20, "description": "Wheel notches, 3 by default" },
                },
                "required": ["direction"],
            },
        }),
        json!({
            "name": "screen_launch",
            "description": "Start a program on the server's screen, for example firefox. It runs detached: the call returns at once and does not wait for the program. Starts the screen if needed. Refused while the user controls the screen.",
            "inputSchema": {
                "type": "object",
                "properties": { "command": { "type": "string", "description": "Shell command line to run" } },
                "required": ["command"],
            },
        }),
    ]
}

/// Runs one browser tool: its daemon method and arguments, then the reply as MCP content blocks.
async fn browser_tool(name: &str, args: &Value, backend: &dyn CrewBackend) -> Result<Vec<Value>, String> {
    let (method, params) = browser_call(name, args)?;
    let reply = backend.browser(method, params).await.map_err(|e| format!("{e:#}"))?;
    if name == "browser_screenshot" {
        let data = reply["png_base64"]
            .as_str()
            .ok_or_else(|| format!("{name}: unexpected response"))?;
        return Ok(vec![json!({ "type": "image", "data": data, "mimeType": "image/png" })]);
    }
    let text = reply["text"]
        .as_str()
        .ok_or_else(|| format!("{name}: unexpected response"))?;
    Ok(vec![text_block(text)])
}

/// The daemon method and parameters for a browser tool; bad arguments are an error for the agent.
fn browser_call(name: &str, args: &Value) -> Result<(&'static str, Value), String> {
    let text = |key: &str| args.get(key).and_then(Value::as_str);
    let node = |key: &str| {
        args.get(key)
            .and_then(Value::as_i64)
            .filter(|n| *n >= 1)
            .ok_or_else(|| format!("{name} needs \"{key}\": a ref from browser_snapshot"))
    };
    let flag = |key: &str| args.get(key).and_then(Value::as_bool).unwrap_or(false);
    match name {
        "browser_open" => {
            let url = text("url")
                .map(str::trim)
                .filter(|u| !u.is_empty())
                .ok_or_else(|| "browser_open needs \"url\"".to_string())?;
            Ok(("browser.agent.open", json!({ "url": url, "new_tab": flag("new_tab") })))
        }
        "browser_snapshot" => Ok(("browser.agent.snapshot", json!({}))),
        "browser_click" => Ok(("browser.agent.click", json!({ "ref": node("ref")? }))),
        "browser_type" => {
            let typed = text("text").ok_or_else(|| "browser_type needs \"text\"".to_string())?;
            Ok((
                "browser.agent.type",
                json!({ "ref": node("ref")?, "text": typed, "submit": flag("submit") }),
            ))
        }
        "browser_press" => {
            let key = text("key")
                .filter(|k| !k.is_empty())
                .ok_or_else(|| "browser_press needs \"key\"".to_string())?;
            Ok(("browser.agent.press", json!({ "key": key })))
        }
        "browser_back" => Ok(("browser.agent.back", json!({}))),
        "browser_screenshot" => Ok(("browser.agent.screenshot", json!({}))),
        "browser_tabs" => Ok(("browser.agent.tabs", json!({}))),
        "browser_switch" => {
            let index = args
                .get("index")
                .and_then(Value::as_u64)
                .ok_or_else(|| "browser_switch needs \"index\": a whole number from browser_tabs".to_string())?;
            Ok(("browser.agent.switch", json!({ "index": index })))
        }
        other => Err(format!("Unknown tool: {other}")),
    }
}

fn text_block(text: &str) -> Value {
    json!({ "type": "text", "text": text })
}

/// MCP result from content blocks. `Err` is a tool error (`isError`) with its message as the block.
fn blocks_result(outcome: Result<Vec<Value>, String>) -> Value {
    match outcome {
        Ok(content) => json!({ "content": content, "isError": false }),
        Err(text) => json!({ "content": [text_block(&text)], "isError": true }),
    }
}

/// Runs one screen tool through the daemon. The screenshot comes back as an image block.
async fn screen_tool(tool: &str, args: &Value, backend: &dyn CrewBackend) -> Value {
    let Some((_, method)) = SCREEN_TOOLS.iter().find(|(name, _)| *name == tool) else {
        return tool_result(Err(format!("Unknown tool: {tool}")));
    };
    let reply = match backend.screen(method, args.clone()).await {
        Ok(reply) => reply,
        Err(e) => return tool_result(Err(format!("{e:#}"))),
    };
    if tool != "screen_screenshot" {
        return tool_result(Ok("Done.".into()));
    }
    let png = reply.get("png_base64").and_then(Value::as_str);
    let size = json!({
        "width": reply.get("width").cloned().unwrap_or(Value::Null),
        "height": reply.get("height").cloned().unwrap_or(Value::Null),
        "scale": reply.get("scale").cloned().unwrap_or(Value::Null),
    });
    match png {
        Some(data) => json!({
            "content": [
                { "type": "text", "text": size.to_string() },
                { "type": "image", "data": data, "mimeType": "image/png" },
            ],
            "isError": false,
        }),
        None => tool_result(Err("screen_screenshot: the daemon sent no image".into())),
    }
}

/// Matches returned when `history_search` gets no `limit`.
const HISTORY_SEARCH_DEFAULT_LIMIT: u32 = 20;
const HISTORY_SEARCH_MAX_LIMIT: u32 = 50;

async fn history_search(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let query = args
        .get("query")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let Some(query) = query else {
        return Err("history_search needs \"query\"".into());
    };
    let limit = match args.get("limit") {
        None | Some(Value::Null) => HISTORY_SEARCH_DEFAULT_LIMIT,
        Some(v) => v
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .filter(|n| (1..=HISTORY_SEARCH_MAX_LIMIT).contains(n))
            .ok_or_else(|| "history_search: \"limit\" must be an integer from 1 to 50".to_string())?,
    };
    backend.history_search(query, limit).await.map_err(|e| format!("{e:#}"))
}

async fn history_day(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let date = args
        .get("date")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let Some(date) = date else {
        return Err("history_day needs \"date\" as YYYY-MM-DD".into());
    };
    backend.history_day(date).await.map_err(|e| format!("{e:#}"))
}

/// Run the crew MCP server on stdin/stdout, for the agent whose session token it is given: from
/// `token_file` when one is named (the daemon's way), else from `BANDITO_AGENT_TOKEN`.
pub async fn serve_stdio(sock: PathBuf, token_file: Option<PathBuf>, capabilities: Option<String>) -> Result<()> {
    let from_file = match &token_file {
        Some(path) => Some(
            std::fs::read_to_string(path).with_context(|| format!("read the agent token file {}", path.display()))?,
        ),
        None => None,
    };
    let token = token_from(from_file.as_deref(), std::env::var("BANDITO_AGENT_TOKEN").ok())?;
    let on = parse_capabilities(capabilities.as_deref())?;
    let backend = DaemonBackend { sock, token };
    serve(BufReader::new(tokio::io::stdin()), tokio::io::stdout(), &backend, &on).await
}

/// The `--capabilities` list of `bandito mcp`: comma-separated names. Missing means all of them; empty means none.
fn parse_capabilities(list: Option<&str>) -> Result<Vec<Capability>> {
    let Some(list) = list else {
        return Ok(ALL_CAPABILITIES.to_vec());
    };
    list.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| Capability::parse(s).ok_or_else(|| anyhow::anyhow!("unknown capability {s}")))
        .collect()
}

/// The session token: the token file's contents when a file is named, else `BANDITO_AGENT_TOKEN`.
/// Blank values count as missing.
fn token_from(file: Option<&str>, env: Option<String>) -> Result<String> {
    if let Some(text) = file {
        let token = text.trim();
        anyhow::ensure!(!token.is_empty(), "the agent token file is empty");
        return Ok(token.to_string());
    }
    env.filter(|t| !t.trim().is_empty()).map(|t| t.trim().to_string()).context(
        "no agent token: the Bandito crew server only runs inside an agent session (BANDITO_AGENT_TOKEN is not set)",
    )
}

#[cfg(test)]
mod token_tests {
    use super::*;

    #[test]
    fn the_token_file_wins_and_the_environment_is_the_fallback() {
        assert_eq!(
            token_from(Some("  bat_file \n"), Some("bat_env".into())).unwrap(),
            "bat_file"
        );
        assert_eq!(token_from(None, Some("bat_env".into())).unwrap(), "bat_env");
    }

    #[test]
    fn a_missing_or_blank_token_is_an_error() {
        let missing = token_from(None, None).unwrap_err().to_string();
        assert!(missing.contains("BANDITO_AGENT_TOKEN is not set"), "{missing}");
        assert!(token_from(None, Some(String::new())).is_err());
        assert!(token_from(Some("  \n"), Some("bat_env".into())).is_err());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    #[derive(Default)]
    struct MockBackend {
        members: Vec<CrewMember>,
        sent: Mutex<Vec<(String, String)>>,
        /// (query, limit) of every history_search call.
        searches: Mutex<Vec<(String, u32)>>,
        /// Date of every history_day call.
        days: Mutex<Vec<String>>,
        /// Method and parameters of every screen call.
        screen_calls: Mutex<Vec<(String, Value)>>,
        /// What screen calls answer; `{}` when unset.
        screen_reply: Option<Value>,
        /// Every form the agent asked, and every reaction it put (as sent to the daemon).
        forms: Mutex<Vec<Value>>,
        reactions: Mutex<Vec<Value>>,
        /// Method and parameters of every schedules call.
        schedule_calls: Mutex<Vec<(String, Value)>>,
        /// What schedules calls answer; `{}` when unset.
        schedule_reply: Option<Value>,
        /// When set, every backend call fails with this message.
        fail: Option<String>,
    }

    #[async_trait]
    impl CrewBackend for MockBackend {
        async fn list(&self) -> Result<Vec<CrewMember>> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            Ok(self.members.clone())
        }

        async fn send(&self, to: &str, message: &str) -> Result<()> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.sent.lock().unwrap().push((to.to_string(), message.to_string()));
            Ok(())
        }

        async fn history_search(&self, query: &str, limit: u32) -> Result<String> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.searches.lock().unwrap().push((query.to_string(), limit));
            Ok(format!("searched {query} ({limit})"))
        }

        async fn history_day(&self, date: &str) -> Result<String> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.days.lock().unwrap().push(date.to_string());
            Ok(format!("day {date}"))
        }

        async fn browser(&self, _method: &str, _params: Value) -> Result<Value> {
            anyhow::bail!("no browser in this test")
        }

        async fn ask_form(&self, form: Value) -> Result<Value> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.forms.lock().unwrap().push(form);
            Ok(json!({ "action": "submit", "values": { "name": "Ann" } }))
        }

        async fn react(&self, params: Value) -> Result<Value> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.reactions.lock().unwrap().push(params);
            Ok(json!({}))
        }

        async fn screen(&self, method: &str, params: Value) -> Result<Value> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.screen_calls.lock().unwrap().push((method.to_string(), params));
            Ok(self.screen_reply.clone().unwrap_or_else(|| json!({})))
        }

        async fn schedules(&self, method: &str, params: Value) -> Result<Value> {
            if let Some(e) = &self.fail {
                anyhow::bail!("{e}");
            }
            self.schedule_calls.lock().unwrap().push((method.to_string(), params));
            Ok(self.schedule_reply.clone().unwrap_or_else(|| json!({})))
        }
    }

    fn member(name: &str, role: &str, runtime: &str) -> CrewMember {
        CrewMember {
            name: name.into(),
            role: role.into(),
            runtime: runtime.into(),
        }
    }

    /// Feed raw input through `serve` and parse every reply line. The agent has every capability.
    async fn replies(input: &str, backend: &MockBackend) -> Vec<Value> {
        replies_with(input, backend, &ALL_CAPABILITIES).await
    }

    async fn replies_with(input: &str, backend: &MockBackend, on: &[Capability]) -> Vec<Value> {
        let mut out = Vec::new();
        serve(input.as_bytes(), &mut out, backend, on).await.unwrap();
        String::from_utf8(out)
            .unwrap()
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    /// Send one request and expect exactly one reply.
    async fn reply(request: Value, backend: &MockBackend) -> Value {
        let mut all = replies(&format!("{request}\n"), backend).await;
        assert_eq!(all.len(), 1, "expected exactly one reply");
        all.remove(0)
    }

    #[test]
    fn only_a_browser_click_gets_the_long_wait() {
        // The approval of a risky click can take up to 10 minutes; the other calls keep the plain limit.
        let wait = browser_wait("browser.agent.click").expect("a click waits");
        assert!(wait >= crate::browser::CLICK_APPROVAL_LIMIT);
        assert_eq!(browser_wait("browser.agent.snapshot"), None);
        assert_eq!(browser_wait("browser.agent.open"), None);
    }

    #[tokio::test]
    async fn a_long_wait_outlasts_a_short_one() {
        // A daemon that answers after 300 ms: a 100 ms limit gives up, a longer one gets the answer.
        // A short path: a unix socket path is limited to about 104 bytes.
        let sock = PathBuf::from(format!("/tmp/bcrew-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&sock);
        let listener = tokio::net::UnixListener::bind(&sock).unwrap();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (read, mut write) = stream.into_split();
                    let mut lines = tokio::io::BufReader::new(read).lines();
                    let _ = lines.next_line().await;
                    let _ = lines.next_line().await;
                    tokio::time::sleep(Duration::from_millis(300)).await;
                    let _ = write
                        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n")
                        .await;
                });
            }
        });
        let short = crate::rpc::unix::call_agent_waiting(
            &sock,
            "token",
            "browser.agent.click",
            json!({ "ref": 1 }),
            Duration::from_millis(100),
        )
        .await;
        assert!(short.is_err(), "the short limit ends the wait");
        let long = crate::rpc::unix::call_agent_waiting(
            &sock,
            "token",
            "browser.agent.click",
            json!({ "ref": 1 }),
            Duration::from_secs(5),
        )
        .await
        .unwrap();
        assert_eq!(long["ok"], true);
        let _ = std::fs::remove_file(&sock);
    }

    fn tool_call(name: &str, arguments: Value) -> Value {
        json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": { "name": name, "arguments": arguments } })
    }

    fn tool_text(reply: &Value) -> &str {
        reply["result"]["content"][0]["text"].as_str().unwrap()
    }

    #[tokio::test]
    async fn initialize_answers_with_a_version_we_support() {
        let backend = MockBackend::default();
        for asked in ["2025-06-18", "2025-03-26", "2024-11-05"] {
            let r = reply(
                json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": asked } }),
                &backend,
            )
            .await;
            assert_eq!(r["id"], 1);
            assert_eq!(r["result"]["protocolVersion"], asked);
        }
        let r = reply(json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize" }), &backend).await;
        assert_eq!(r["result"]["capabilities"], json!({ "tools": {} }));
        assert_eq!(r["result"]["serverInfo"]["name"], "bandito-crew");
        assert_eq!(r["result"]["serverInfo"]["version"], env!("CARGO_PKG_VERSION"));
        assert!(r["result"]["instructions"].as_str().unwrap().contains("Bandito crew"));
    }

    #[tokio::test]
    async fn initialize_falls_back_to_our_newest_version() {
        let backend = MockBackend::default();
        let r = reply(json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize" }), &backend).await;
        assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
        for params in [
            json!({ "protocolVersion": 5 }),
            json!({ "protocolVersion": "2099-01-01" }),
        ] {
            let r = reply(
                json!({ "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": params }),
                &backend,
            )
            .await;
            assert_eq!(r["result"]["protocolVersion"], "2025-06-18");
        }
    }

    #[tokio::test]
    async fn overlong_line_is_refused_and_the_next_line_is_served() {
        let backend = MockBackend::default();
        let long = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"pad\":\"{}\"}}",
            "a".repeat(MAX_LINE_BYTES)
        );
        let input = format!("{long}\n{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}}\n");
        let all = replies(&input, &backend).await;
        assert_eq!(all.len(), 2);
        assert_eq!(all[0]["id"], Value::Null);
        assert_eq!(all[0]["error"]["code"], PARSE_ERROR);
        assert_eq!(all[1]["id"], 2);
        assert_eq!(all[1]["result"], json!({}));
    }

    #[tokio::test]
    async fn notifications_get_no_reply() {
        let backend = MockBackend::default();
        let input = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n";
        assert!(replies(input, &backend).await.is_empty());
    }

    #[tokio::test]
    async fn blank_lines_are_skipped() {
        let backend = MockBackend::default();
        let input = "\n   \n{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n\n";
        let all = replies(input, &backend).await;
        assert_eq!(all.len(), 1);
        assert_eq!(all[0]["result"], json!({}));
    }

    #[tokio::test]
    async fn ping_returns_an_empty_result() {
        let backend = MockBackend::default();
        let r = reply(json!({ "jsonrpc": "2.0", "id": "p", "method": "ping" }), &backend).await;
        assert_eq!(r["id"], "p");
        assert_eq!(r["result"], json!({}));
    }

    #[tokio::test]
    async fn tools_list_has_the_crew_history_and_screen_tools() {
        let backend = MockBackend::default();
        let r = reply(json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }), &backend).await;
        let tools = r["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "crew_list",
                "crew_send",
                "history_search",
                "history_day",
                "ask_form",
                "react",
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
                "schedule_list",
                "schedule_create",
                "schedule_delete",
                "schedule_pause",
            ]
        );
        assert_eq!(tools[0]["inputSchema"], json!({ "type": "object", "properties": {} }));
        assert_eq!(tools[1]["inputSchema"]["required"], json!(["to", "message"]));
        assert_eq!(tools[1]["inputSchema"]["properties"]["to"]["type"], "string");
        assert_eq!(tools[2]["inputSchema"]["required"], json!(["query"]));
        assert_eq!(tools[2]["inputSchema"]["properties"]["query"]["type"], "string");
        assert_eq!(tools[2]["inputSchema"]["properties"]["limit"]["type"], "integer");
        assert_eq!(tools[3]["inputSchema"]["required"], json!(["date"]));
        assert_eq!(tools[3]["inputSchema"]["properties"]["date"]["type"], "string");
        assert_eq!(
            tools[2]["description"],
            "Search your past conversations with the user and the crew (older messages are not in your context). Returns matching messages with dates."
        );
        assert_eq!(tools[3]["description"], "Read everything said with you on one day.");
    }

    #[tokio::test]
    async fn history_search_passes_query_and_default_limit() {
        let backend = MockBackend::default();
        let r = reply(tool_call("history_search", json!({ "query": " deploy " })), &backend).await;
        assert_eq!(r["result"]["isError"], false);
        assert_eq!(tool_text(&r), "searched deploy (20)");
        assert_eq!(*backend.searches.lock().unwrap(), vec![("deploy".to_string(), 20)]);
    }

    #[tokio::test]
    async fn history_search_takes_a_limit_from_1_to_50() {
        let backend = MockBackend::default();
        let r = reply(
            tool_call("history_search", json!({ "query": "deploy", "limit": 50 })),
            &backend,
        )
        .await;
        assert_eq!(r["result"]["isError"], false);
        assert_eq!(tool_text(&r), "searched deploy (50)");
        let r = reply(
            tool_call("history_search", json!({ "query": "deploy", "limit": 1 })),
            &backend,
        )
        .await;
        assert_eq!(tool_text(&r), "searched deploy (1)");
    }

    #[tokio::test]
    async fn history_search_bad_arguments_are_tool_errors() {
        let backend = MockBackend::default();
        for args in [
            json!({}),
            json!({ "query": "   " }),
            json!({ "query": "x", "limit": 0 }),
            json!({ "query": "x", "limit": 51 }),
            json!({ "query": "x", "limit": "5" }),
            json!({ "query": "x", "limit": 2.5 }),
        ] {
            let r = reply(tool_call("history_search", args.clone()), &backend).await;
            assert_eq!(r["result"]["isError"], true, "{args}");
            assert!(r.get("error").is_none(), "{args}");
        }
        assert!(backend.searches.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn history_day_passes_the_date() {
        let backend = MockBackend::default();
        let r = reply(tool_call("history_day", json!({ "date": "2026-10-01" })), &backend).await;
        assert_eq!(r["result"]["isError"], false);
        assert_eq!(tool_text(&r), "day 2026-10-01");
        assert_eq!(*backend.days.lock().unwrap(), vec!["2026-10-01".to_string()]);

        let r = reply(tool_call("history_day", json!({})), &backend).await;
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(backend.days.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn history_backend_error_is_a_tool_error() {
        let backend = MockBackend {
            fail: Some("cannot reach the daemon".into()),
            ..Default::default()
        };
        let r = reply(tool_call("history_search", json!({ "query": "x" })), &backend).await;
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(tool_text(&r), "cannot reach the daemon");
        let r = reply(tool_call("history_day", json!({ "date": "2026-10-01" })), &backend).await;
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(tool_text(&r), "cannot reach the daemon");
    }

    #[tokio::test]
    async fn crew_list_with_nobody_else_says_so() {
        let backend = MockBackend::default();
        let r = reply(tool_call("crew_list", json!({})), &backend).await;
        assert_eq!(tool_text(&r), "No other agents in this crew yet.");
        assert_eq!(r["result"]["isError"], false);
    }

    #[tokio::test]
    async fn crew_list_shows_one_line_per_agent() {
        let backend = MockBackend {
            members: vec![member("Scout", "reviewer", "claude"), member("Rook", "", "codex")],
            ..Default::default()
        };
        let r = reply(tool_call("crew_list", json!({})), &backend).await;
        assert_eq!(tool_text(&r), "- Scout (reviewer) · claude\n- Rook · codex");
        assert_eq!(r["result"]["isError"], false);
    }

    #[tokio::test]
    async fn crew_list_backend_error_is_a_tool_error() {
        let backend = MockBackend {
            fail: Some("cannot reach the daemon".into()),
            ..Default::default()
        };
        let r = reply(tool_call("crew_list", json!({})), &backend).await;
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(tool_text(&r), "cannot reach the daemon");
    }

    #[tokio::test]
    async fn crew_send_delivers_to_and_message() {
        let backend = MockBackend::default();
        let r = reply(
            tool_call(
                "crew_send",
                json!({ "to": "Scout", "message": "please review the diff" }),
            ),
            &backend,
        )
        .await;
        assert_eq!(r["result"]["isError"], false);
        assert_eq!(
            tool_text(&r),
            "Sent to Scout. Their answer will arrive as a new message from them."
        );
        assert_eq!(
            *backend.sent.lock().unwrap(),
            vec![("Scout".to_string(), "please review the diff".to_string())]
        );
    }

    #[tokio::test]
    async fn crew_send_without_arguments_is_a_tool_error() {
        let backend = MockBackend::default();
        for args in [
            json!({}),
            json!({ "to": "Scout" }),
            json!({ "to": " ", "message": "hi" }),
        ] {
            let r = reply(tool_call("crew_send", args), &backend).await;
            assert_eq!(r["result"]["isError"], true);
            assert_eq!(tool_text(&r), "crew_send needs \"to\" and \"message\"");
        }
        assert!(backend.sent.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn crew_send_backend_error_is_a_tool_error() {
        let backend = MockBackend {
            fail: Some("no agent named 'Nobody' in this crew".into()),
            ..Default::default()
        };
        let r = reply(
            tool_call("crew_send", json!({ "to": "Nobody", "message": "hi" })),
            &backend,
        )
        .await;
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(tool_text(&r), "no agent named 'Nobody' in this crew");
        assert!(r.get("error").is_none());
    }

    #[tokio::test]
    async fn screen_tools_describe_their_inputs() {
        let backend = MockBackend::default();
        let r = reply(json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }), &backend).await;
        let tools = r["result"]["tools"].as_array().unwrap();
        let tool = |name: &str| tools.iter().find(|t| t["name"] == name).unwrap().clone();

        assert_eq!(tool("screen_screenshot")["inputSchema"]["properties"], json!({}));
        let click = tool("screen_click");
        assert_eq!(click["inputSchema"]["required"], json!(["x", "y"]));
        assert_eq!(
            click["inputSchema"]["properties"]["button"]["enum"],
            json!(["left", "right", "middle"])
        );
        assert_eq!(click["inputSchema"]["properties"]["double"]["type"], "boolean");
        assert_eq!(tool("screen_move")["inputSchema"]["required"], json!(["x", "y"]));
        assert_eq!(tool("screen_type")["inputSchema"]["required"], json!(["text"]));
        assert_eq!(tool("screen_key")["inputSchema"]["required"], json!(["keys"]));
        let scroll = tool("screen_scroll");
        assert_eq!(scroll["inputSchema"]["required"], json!(["direction"]));
        assert_eq!(
            scroll["inputSchema"]["properties"]["direction"]["enum"],
            json!(["up", "down", "left", "right"])
        );
        assert_eq!(scroll["inputSchema"]["properties"]["amount"]["minimum"], 1);
        assert_eq!(scroll["inputSchema"]["properties"]["amount"]["maximum"], 20);
        assert_eq!(tool("screen_launch")["inputSchema"]["required"], json!(["command"]));
        for name in ["screen_click", "screen_move", "screen_scroll"] {
            assert!(
                tool(name)["description"].as_str().unwrap().contains("pixel"),
                "{name} should say that coordinates are screen pixels"
            );
        }
    }

    fn a_form() -> Value {
        json!({
            "title": "Who are you?",
            "kind": "question",
            "fields": [{ "id": "name", "label": "Name", "type": "text", "required": true }],
        })
    }

    #[tokio::test]
    async fn ask_form_sends_a_checked_form_and_returns_the_answer() {
        let backend = MockBackend::default();
        let r = reply(tool_call("ask_form", a_form()), &backend).await;
        assert_eq!(r["result"]["isError"], false, "{r}");
        let text = tool_text(&r);
        let answer: Value = serde_json::from_str(text).unwrap();
        assert_eq!(answer, json!({ "action": "submit", "values": { "name": "Ann" } }));
        assert_eq!(*backend.forms.lock().unwrap(), vec![a_form()]);
    }

    #[tokio::test]
    async fn ask_form_with_a_bad_spec_is_a_tool_error_and_reaches_no_one() {
        let backend = MockBackend::default();
        let bad = json!({
            "title": "Pick",
            "kind": "question",
            "fields": [{ "id": "c", "label": "C", "type": "choice" }],
        });
        let r = reply(tool_call("ask_form", bad), &backend).await;
        assert_eq!(r["result"]["isError"], true, "{r}");
        assert_eq!(tool_text(&r), "field \"c\" needs 1 to 20 options, got 0");
        assert!(backend.forms.lock().unwrap().is_empty());
        let r = reply(tool_call("ask_form", json!({ "title": "x" })), &backend).await;
        assert_eq!(r["result"]["isError"], true, "{r}");
    }

    #[tokio::test]
    async fn ask_form_failure_from_the_daemon_is_a_tool_error() {
        let backend = MockBackend {
            fail: Some("daemon is down".into()),
            ..Default::default()
        };
        let r = reply(tool_call("ask_form", a_form()), &backend).await;
        assert_eq!(r["result"]["isError"], true, "{r}");
        assert!(tool_text(&r).contains("daemon is down"));
    }

    #[tokio::test]
    async fn react_forwards_the_emoji_and_the_message_or_the_default() {
        let backend = MockBackend::default();
        let r = reply(tool_call("react", json!({ "emoji": "👍" })), &backend).await;
        assert_eq!(r["result"]["isError"], false, "{r}");
        assert_eq!(tool_text(&r), "Reacted with 👍.");
        let r = reply(tool_call("react", json!({ "seq": 12, "emoji": "👀" })), &backend).await;
        assert_eq!(r["result"]["isError"], false, "{r}");
        assert_eq!(
            *backend.reactions.lock().unwrap(),
            vec![
                json!({ "emoji": "👍", "seq": null }),
                json!({ "emoji": "👀", "seq": 12 })
            ]
        );
    }

    #[tokio::test]
    async fn react_needs_an_emoji_and_a_message_number() {
        let backend = MockBackend::default();
        let r = reply(tool_call("react", json!({ "seq": 3 })), &backend).await;
        assert_eq!(r["result"]["isError"], true, "{r}");
        assert_eq!(tool_text(&r), "react needs \"emoji\"");
        let r = reply(tool_call("react", json!({ "seq": 0, "emoji": "👍" })), &backend).await;
        assert_eq!(r["result"]["isError"], true, "{r}");
        assert!(backend.reactions.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn screen_click_is_forwarded_to_the_daemon() {
        let backend = MockBackend::default();
        let r = reply(
            tool_call("screen_click", json!({ "x": 10, "y": 20, "button": "right" })),
            &backend,
        )
        .await;
        assert_eq!(r["result"]["isError"], false, "{r}");
        assert_eq!(
            *backend.screen_calls.lock().unwrap(),
            vec![(
                "screen.agent.click".to_string(),
                json!({ "x": 10, "y": 20, "button": "right" })
            )]
        );
    }

    #[tokio::test]
    async fn screen_tools_forward_to_their_daemon_method() {
        let backend = MockBackend::default();
        for (tool, method, args) in [
            ("screen_move", "screen.agent.move", json!({ "x": 1, "y": 2 })),
            ("screen_type", "screen.agent.type", json!({ "text": "hi" })),
            ("screen_key", "screen.agent.key", json!({ "keys": "ctrl+l" })),
            (
                "screen_scroll",
                "screen.agent.scroll",
                json!({ "direction": "down", "amount": 4 }),
            ),
            ("screen_launch", "screen.agent.launch", json!({ "command": "firefox" })),
        ] {
            let r = reply(tool_call(tool, args.clone()), &backend).await;
            assert_eq!(r["result"]["isError"], false, "{tool}: {r}");
            assert_eq!(tool_text(&r), "Done.", "{tool}");
            let calls = backend.screen_calls.lock().unwrap();
            assert_eq!(calls.last().unwrap(), &(method.to_string(), args), "{tool}");
        }
    }

    #[tokio::test]
    async fn screen_screenshot_returns_the_size_and_the_image() {
        let backend = MockBackend {
            screen_reply: Some(json!({
                "width": 1600,
                "height": 1000,
                "scale": 0.8,
                "png_base64": "iVBORw0KGgo=",
            })),
            ..Default::default()
        };
        let r = reply(tool_call("screen_screenshot", json!({})), &backend).await;
        assert_eq!(r["result"]["isError"], false, "{r}");
        let content = r["result"]["content"].as_array().unwrap();
        assert_eq!(content.len(), 2, "{r}");
        assert_eq!(content[0]["type"], "text");
        let size: Value = serde_json::from_str(content[0]["text"].as_str().unwrap()).unwrap();
        assert_eq!(size, json!({ "width": 1600, "height": 1000, "scale": 0.8 }));
        assert_eq!(
            content[1],
            json!({ "type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png" })
        );
        assert_eq!(backend.screen_calls.lock().unwrap()[0].0, "screen.agent.screenshot");
    }

    #[tokio::test]
    async fn screen_refusal_from_the_daemon_is_a_tool_error() {
        let backend = MockBackend {
            fail: Some("The user is controlling the screen. Wait or ask them to hand it back.".into()),
            ..Default::default()
        };
        let r = reply(tool_call("screen_type", json!({ "text": "hi" })), &backend).await;
        assert_eq!(r["result"]["isError"], true);
        assert_eq!(
            tool_text(&r),
            "The user is controlling the screen. Wait or ask them to hand it back."
        );
        assert!(r.get("error").is_none());
    }

    #[tokio::test]
    async fn unknown_tool_is_an_invalid_params_error() {
        let backend = MockBackend::default();
        let r = reply(tool_call("crew_fly", json!({})), &backend).await;
        assert_eq!(r["error"]["code"], -32602);
        assert_eq!(r["error"]["message"], "Unknown tool: crew_fly");
    }

    #[tokio::test]
    async fn unknown_method_is_method_not_found() {
        let backend = MockBackend::default();
        let r = reply(
            json!({ "jsonrpc": "2.0", "id": 9, "method": "resources/list" }),
            &backend,
        )
        .await;
        assert_eq!(r["id"], 9);
        assert_eq!(r["error"]["code"], -32601);
        assert_eq!(r["error"]["message"], "Method not found: resources/list");
    }

    #[tokio::test]
    async fn request_without_method_is_invalid() {
        let backend = MockBackend::default();
        let r = reply(json!({ "jsonrpc": "2.0", "id": 4 }), &backend).await;
        assert_eq!(r["error"]["code"], -32600);
    }

    #[tokio::test]
    async fn invalid_json_is_a_parse_error_with_null_id() {
        let backend = MockBackend::default();
        let all = replies("not json\n", &backend).await;
        assert_eq!(all.len(), 1);
        assert_eq!(all[0]["id"], Value::Null);
        assert_eq!(all[0]["error"]["code"], -32700);
        assert_eq!(all[0]["error"]["message"], "parse error");
    }

    #[tokio::test]
    async fn one_reply_per_request_in_order() {
        let backend = MockBackend::default();
        let input = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n\
                     {\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n\
                     {\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}\n";
        let all = replies(input, &backend).await;
        let ids: Vec<&Value> = all.iter().map(|r| &r["id"]).collect();
        assert_eq!(ids, [&json!(1), &json!(2)]);
    }

    /// The tool names an agent with these capabilities gets from `tools/list`.
    async fn listed(on: &[Capability]) -> Vec<String> {
        let backend = MockBackend::default();
        let request = json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" });
        let r = replies_with(&format!("{request}\n"), &backend, on).await.remove(0);
        r["result"]["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect()
    }

    #[tokio::test]
    async fn each_capability_switches_its_own_tools() {
        let all = listed(&ALL_CAPABILITIES).await;
        assert!(all.iter().any(|n| n == "crew_send") && all.iter().any(|n| n == "browser_open"));
        assert!(all.iter().any(|n| n == "screen_click"));

        let no_browser = listed(&[
            Capability::Terminal,
            Capability::Files,
            Capability::Team,
            Capability::Screen,
        ])
        .await;
        assert!(!no_browser.iter().any(|n| n.starts_with("browser_")));
        assert!(no_browser.iter().any(|n| n == "screen_click") && no_browser.iter().any(|n| n == "crew_list"));

        let no_team = listed(&[Capability::Browser, Capability::Screen]).await;
        assert!(!no_team.iter().any(|n| n.starts_with("crew_")));
        assert!(no_team.iter().any(|n| n == "browser_open"));

        let no_screen = listed(&[Capability::Browser, Capability::Team]).await;
        assert!(!no_screen.iter().any(|n| n.starts_with("screen_")));

        // The shell and the files are not MCP tools: they change the settings, not this list. The history,
        // form, reaction and schedule tools need no capability.
        assert_eq!(
            listed(&[Capability::Terminal, Capability::Files]).await,
            [
                "history_search",
                "history_day",
                "ask_form",
                "react",
                "schedule_list",
                "schedule_create",
                "schedule_delete",
                "schedule_pause"
            ]
        );
        assert_eq!(
            listed(&[]).await,
            [
                "history_search",
                "history_day",
                "ask_form",
                "react",
                "schedule_list",
                "schedule_create",
                "schedule_delete",
                "schedule_pause"
            ]
        );
    }

    #[tokio::test]
    async fn a_tool_of_a_missing_capability_is_unknown_and_never_reaches_the_daemon() {
        let backend = MockBackend::default();
        let browser = format!(
            "{}\n",
            tool_call("browser_open", json!({ "url": "https://example.com" }))
        );
        let r = replies_with(&browser, &backend, &[Capability::Team]).await.remove(0);
        assert_eq!(r["error"]["code"], json!(INVALID_PARAMS));
        assert!(
            r["error"]["message"]
                .as_str()
                .unwrap()
                .contains("Unknown tool: browser_open")
        );

        let send = format!(
            "{}\n",
            tool_call("crew_send", json!({ "to": "Scout", "message": "hi" }))
        );
        let r = replies_with(&send, &backend, &[Capability::Browser]).await.remove(0);
        assert_eq!(r["error"]["code"], json!(INVALID_PARAMS));
        assert!(backend.sent.lock().unwrap().is_empty());

        // The history tools need no capability.
        let history = format!("{}\n", tool_call("history_search", json!({ "query": "x" })));
        let r = replies_with(&history, &backend, &[]).await.remove(0);
        assert_eq!(r["result"]["isError"], json!(false));
    }

    #[test]
    fn the_capabilities_flag_names_the_granted_ones() {
        assert_eq!(parse_capabilities(None).unwrap(), ALL_CAPABILITIES.to_vec());
        assert!(parse_capabilities(Some("")).unwrap().is_empty());
        assert_eq!(
            parse_capabilities(Some("browser, team")).unwrap(),
            [Capability::Browser, Capability::Team]
        );
        let err = parse_capabilities(Some("browser,shell")).unwrap_err().to_string();
        assert!(err.contains("unknown capability shell"), "{err}");
    }
}
