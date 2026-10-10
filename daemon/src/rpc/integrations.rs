//! `integrations.*` JSON-RPC methods: the owner's MCP servers for the agents, the template catalog, and a test
//! that starts a server and lists its tools. Owner and apps only. See docs/ARCHITECTURE.md#integrations.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::integrations::{self, Pair, Server, Transport};
use crate::store::{Integration, IntegrationPatch, NewIntegration};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::os::unix::process::CommandExt;
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

pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    let store = &app.sup.hub().store;
    match method {
        "integrations.list" => ok(store.integration_list()?),
        "integrations.catalog" => ok(serde_json::from_str::<Value>(CATALOG_JSON)
            .map_err(|e| RpcError::new(SERVER_ERROR, format!("catalog: {e}")))?),
        "integrations.add" => {
            let n: NewIntegration = params(p)?;
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
            ok(json!({ "deleted": store.integration_delete(&id)? }))
        }
        "integrations.test" => {
            let Id { id } = params(p)?;
            let cur = store
                .integration_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no integration {id}")))?;
            let secrets: HashMap<String, String> = store.secrets_all()?.into_iter().collect();
            let servers = integrations::resolve(&[&cur], &secrets);
            let Some(server) = servers.into_iter().next() else {
                return ok(json!({ "ok": false, "tools": [], "error": "a secret it names is not set" }));
            };
            match probe(&server, TEST_TIMEOUT).await {
                Ok(tools) => ok(json!({ "ok": true, "tools": tools })),
                Err(e) => ok(json!({ "ok": false, "tools": [], "error": format!("{e:#}") })),
            }
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
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
    let row = Integration {
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
    };
    check_definition(&row)
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
    match &server.transport {
        Transport::Stdio { command, args, env } => probe_stdio(command, args, env, limit).await,
        Transport::Http { url, headers } => probe_http(url, headers, limit).await,
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

/// Reads a child's stderr in the background, keeping its last bytes.
fn collect_stderr<R>(mut stderr: R) -> std::sync::Arc<std::sync::Mutex<Vec<u8>>>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
{
    let buf = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = std::sync::Arc::clone(&buf);
    tokio::spawn(async move {
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
    buf
}

/// The last characters of the collected stderr, with every secret value replaced by its `••••NAME`.
fn stderr_tail(buf: &std::sync::Mutex<Vec<u8>>, secrets: &[(String, String)]) -> String {
    let raw = String::from_utf8_lossy(&buf.lock().unwrap_or_else(|e| e.into_inner())).into_owned();
    let redacted = crate::redact::Redactor::new(secrets.iter().cloned())
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

/// The secret values of an environment or a header, by name: what the redaction must hide.
fn secret_pairs(pairs: &[Pair]) -> Vec<(String, String)> {
    pairs
        .iter()
        .filter(|p| p.secret)
        .map(|p| (p.key.clone(), p.value.clone()))
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
    let stderr = collect_stderr(child.stderr.take().ok_or_else(|| anyhow::anyhow!("no stderr"))?);
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
        Ok(Err(e)) => anyhow::bail!("{}", with_stderr(format!("{e:#}"), stderr_tail(&stderr, &secrets))),
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
async fn probe_http(url: &str, headers: &[Pair], limit: Duration) -> anyhow::Result<Vec<String>> {
    let exchange = async {
        let init = http_post(url, headers, &initialize_request(), None).await?;
        let session = init.session.clone();
        http_post(
            url,
            headers,
            &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
            session.as_deref(),
        )
        .await?;
        let listed = http_post(url, headers, &list_request(), session.as_deref()).await?;
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

async fn http_post(url: &str, headers: &[Pair], msg: &Value, session: Option<&str>) -> anyhow::Result<HttpReply> {
    let mut config = String::new();
    config.push_str(&format!("url = {}\n", json!(url)));
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
    cmd.args(["--config", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    cmd.as_std_mut().process_group(0);
    let mut child = cmd.spawn().map_err(|e| anyhow::anyhow!("cannot run curl: {e}"))?;
    // Killed with the group when this call ends, however it ends.
    let _group = Group(child.id().unwrap_or(0) as i32);
    let stderr = collect_stderr(child.stderr.take().ok_or_else(|| anyhow::anyhow!("no stderr"))?);
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(config.as_bytes()).await?;
    }
    let out = child.wait_with_output().await?;
    let raw = String::from_utf8_lossy(&out.stdout).into_owned();
    if !out.status.success() {
        // The headers are in the config, not in curl's own messages; the tail is redacted with the secrets anyway.
        let secrets = secret_pairs(headers);
        let tail = stderr_tail(&stderr, &secrets);
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
        anyhow::bail!("the server answered with HTTP {}", parsed.status);
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
    fn the_catalog_parses_and_has_the_verified_entries() {
        let cat: Vec<Value> = serde_json::from_str(CATALOG_JSON).unwrap();
        let ids: Vec<&str> = cat.iter().filter_map(|e| e["id"].as_str()).collect();
        assert_eq!(
            ids,
            ["composio", "github", "linear", "playwright", "filesystem", "fetch"]
        );
        for entry in &cat {
            assert!(entry["docs_url"].as_str().is_some_and(|u| u.starts_with("https://")));
            match entry["kind"].as_str() {
                Some("stdio") => assert!(entry["command"].is_string(), "{entry}"),
                Some("http") => assert!(entry["url"].is_string() || entry["url_hint"].is_string(), "{entry}"),
                other => panic!("kind {other:?}"),
            }
        }
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
        for method in ["integrations.list", "integrations.add", "integrations.test"] {
            let err = super::super::dispatch(&app, &agent, method, json!({}))
                .await
                .unwrap_err();
            assert_eq!(err.code, super::super::UNAUTHORIZED, "{method}");
        }
        let catalog = owner(&app, "integrations.catalog", json!({})).await.unwrap();
        assert_eq!(catalog.as_array().map(Vec::len), Some(6));
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
}
