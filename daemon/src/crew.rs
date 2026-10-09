//! Crew MCP server: lets one agent see and message the other agents of its crew.
//!
//! The daemon starts `bandito --home <home> mcp --agent <id>` for every agent.
//! That process speaks MCP (JSON-RPC 2.0, one message per line) on stdio and
//! forwards `crew.list` / `crew.send` to the daemon over its unix socket.
//! Stdout carries the protocol only, so logs must go to stderr.

use crate::rpc::unix::call;
use anyhow::{Context, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::PathBuf;
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
}

/// Backend that asks the daemon over its unix socket.
pub struct DaemonBackend {
    pub sock: PathBuf,
    pub agent_id: String,
}

#[async_trait]
impl CrewBackend for DaemonBackend {
    async fn list(&self) -> Result<Vec<CrewMember>> {
        let v = call(&self.sock, "crew.list", json!({ "agent_id": self.agent_id })).await?;
        serde_json::from_value(v).context("crew.list: unexpected response")
    }

    async fn send(&self, to: &str, message: &str) -> Result<()> {
        call(
            &self.sock,
            "crew.send",
            json!({ "from": self.agent_id, "to": to, "message": message }),
        )
        .await?;
        Ok(())
    }

    async fn history_search(&self, query: &str, limit: u32) -> Result<String> {
        let v = call(
            &self.sock,
            "history.search",
            json!({ "agent_id": self.agent_id, "query": query, "limit": limit }),
        )
        .await?;
        text_of(v, "history.search")
    }

    async fn history_day(&self, date: &str) -> Result<String> {
        let v = call(
            &self.sock,
            "history.day",
            json!({ "agent_id": self.agent_id, "date": date }),
        )
        .await?;
        text_of(v, "history.day")
    }
}

/// The `text` field of a history reply.
fn text_of(v: Value, method: &str) -> Result<String> {
    v.get("text")
        .and_then(Value::as_str)
        .map(str::to_string)
        .with_context(|| format!("{method}: unexpected response"))
}

/// Serve MCP until the reader reaches EOF. Every request gets one reply line;
/// notifications (no `id`) get none.
pub async fn serve<R, W>(mut reader: R, mut writer: W, backend: &dyn CrewBackend) -> Result<()>
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
                if let Some(reply) = handle_line(&line, backend).await {
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
async fn handle_line(line: &str, backend: &dyn CrewBackend) -> Option<Value> {
    let Ok(msg) = serde_json::from_str::<Value>(line) else {
        return Some(error_reply(Value::Null, PARSE_ERROR, "parse error"));
    };
    let id = msg.get("id")?.clone();
    let method = msg.get("method").and_then(Value::as_str).unwrap_or_default();
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let outcome: Result<Value, Fault> = match method {
        "initialize" => Ok(initialize(&params)),
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({
            "tools": [crew_list_tool(), crew_send_tool(), history_search_tool(), history_day_tool()]
        })),
        "tools/call" => call_tool(&params, backend).await,
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

async fn call_tool(params: &Value, backend: &dyn CrewBackend) -> Result<Value, Fault> {
    let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
    let args = params.get("arguments").cloned().unwrap_or(Value::Null);
    match name {
        "crew_list" => Ok(tool_result(crew_list(backend).await)),
        "crew_send" => Ok(tool_result(crew_send(&args, backend).await)),
        "history_search" => Ok(tool_result(history_search(&args, backend).await)),
        "history_day" => Ok(tool_result(history_day(&args, backend).await)),
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

/// Run the crew MCP server for one agent on stdin/stdout.
pub async fn serve_stdio(sock: PathBuf, agent_id: String) -> Result<()> {
    let backend = DaemonBackend { sock, agent_id };
    serve(BufReader::new(tokio::io::stdin()), tokio::io::stdout(), &backend).await
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
    }

    fn member(name: &str, role: &str, runtime: &str) -> CrewMember {
        CrewMember {
            name: name.into(),
            role: role.into(),
            runtime: runtime.into(),
        }
    }

    /// Feed raw input through `serve` and parse every reply line.
    async fn replies(input: &str, backend: &MockBackend) -> Vec<Value> {
        let mut out = Vec::new();
        serve(input.as_bytes(), &mut out, backend).await.unwrap();
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
    async fn tools_list_has_all_four_tools() {
        let backend = MockBackend::default();
        let r = reply(json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }), &backend).await;
        let tools = r["result"]["tools"].as_array().unwrap();
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["crew_list", "crew_send", "history_search", "history_day"]);
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
}
