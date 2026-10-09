//! Terminal methods (`term.*`) and the output stream of one connection.
//! Wire format and semantics: docs/ARCHITECTURE.md#terminals.

use super::{
    App, INVALID_PARAMS, Id, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, TERM_ERROR, UNAUTHORIZED,
};
use super::{check_cwd, ok, params};
use crate::terminal::{OpenSpec, TermError, TermEvent};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as B64;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use tokio::sync::{broadcast, mpsc};

/// Largest decoded `term.input` payload, in bytes.
const MAX_INPUT: usize = 64 * 1024;

#[derive(Deserialize)]
struct OpenParams {
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    command: Option<Vec<String>>,
    #[serde(default)]
    title: Option<String>,
    cols: u16,
    rows: u16,
    #[serde(default)]
    env: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct InputParams {
    id: String,
    data: String,
}

#[derive(Deserialize)]
struct ResizeParams {
    id: String,
    cols: u16,
    rows: u16,
}

#[derive(Deserialize)]
struct RenameParams {
    id: String,
    title: String,
}

#[derive(Deserialize)]
struct AttachParams {
    id: String,
    #[serde(default)]
    from: Option<u64>,
}

/// `term.list`, `term.open`, `term.input`, `term.resize`, `term.rename`, `term.close`.
/// Called from `rpc::dispatch`, which has already refused anonymous peers.
pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "term.list" => ok(app.terminals.list()),
        "term.open" => {
            let p: OpenParams = params(p)?;
            if p.command.as_ref().is_some_and(Vec::is_empty) {
                return Err(RpcError::new(INVALID_PARAMS, "command is empty"));
            }
            let spec = OpenSpec {
                cwd: resolve_cwd(p.cwd.as_deref())?,
                command: p.command,
                title: p.title,
                cols: p.cols,
                rows: p.rows,
                env: p.env.into_iter().collect(),
            };
            ok(app.terminals.open(spec).map_err(term_error)?)
        }
        "term.input" => {
            let p: InputParams = params(p)?;
            let data = B64
                .decode(&p.data)
                .map_err(|_| RpcError::new(INVALID_PARAMS, "data is not valid base64"))?;
            if data.len() > MAX_INPUT {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("input is larger than {MAX_INPUT} bytes"),
                ));
            }
            app.terminals.input(&p.id, &data).await.map_err(term_error)?;
            ok(json!({}))
        }
        "term.resize" => {
            let p: ResizeParams = params(p)?;
            app.terminals.resize(&p.id, p.cols, p.rows).map_err(term_error)?;
            ok(app.terminals.info(&p.id).map_err(term_error)?)
        }
        "term.rename" => {
            let p: RenameParams = params(p)?;
            if p.title.trim().is_empty() {
                return Err(RpcError::new(INVALID_PARAMS, "title is empty"));
            }
            app.terminals.rename(&p.id, &p.title).map_err(term_error)?;
            ok(app.terminals.info(&p.id).map_err(term_error)?)
        }
        "term.close" => {
            let Id { id } = params(p)?;
            app.terminals.close(&id).map_err(term_error)?;
            ok(json!({}))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// The user's home folder for `None` and `~`, `~/…` inside it. Anything else must be an absolute
/// path to an existing folder.
fn resolve_cwd(cwd: Option<&str>) -> Result<PathBuf, RpcError> {
    let home = dirs::home_dir().ok_or_else(|| RpcError::new(SERVER_ERROR, "no home directory on the server"))?;
    let path = match cwd {
        None | Some("~") => home,
        Some(c) => match c.strip_prefix("~/") {
            Some(rest) => home.join(rest),
            None => PathBuf::from(c),
        },
    };
    check_cwd(&path.to_string_lossy())?;
    Ok(path)
}

/// Terminal errors keep their short code in the message, e.g. `not_found: terminal not found: …`.
fn term_error(e: anyhow::Error) -> RpcError {
    if let Some(t) = e.downcast_ref::<TermError>() {
        return RpcError::new(TERM_ERROR, format!("{}: {t}", t.code()));
    }
    RpcError::from(e)
}

/// What one connection receives from the terminal manager: the terminals it has attached and,
/// for each, the offset of the next output it expects. The receiver exists only while
/// something is attached. A connection that goes away detaches everything.
#[derive(Default)]
pub struct Stream {
    events: Option<broadcast::Receiver<TermEvent>>,
    attached: HashMap<String, u64>,
}

/// What to send for one output event, given the next offset the connection expects.
#[derive(Debug, PartialEq, Eq)]
pub enum Forward<'a> {
    /// Every byte was sent before.
    Skip,
    /// Bytes that continue the stream, starting at the expected offset.
    Send(&'a [u8]),
    /// Output was lost before `data`: `lost` bytes are missing.
    Gap { lost: u64, data: &'a [u8] },
}

/// Decides which part of an output event a connection still needs. `next` is the offset the
/// connection expects next and moves past the bytes returned.
pub fn forward<'a>(next: &mut u64, offset: u64, data: &'a [u8]) -> Forward<'a> {
    // Empty data has nothing to send. A gap is reported with the bytes that reveal it.
    if data.is_empty() {
        return Forward::Skip;
    }
    let end = offset + data.len() as u64;
    if end <= *next {
        return Forward::Skip;
    }
    let expected = *next;
    *next = end;
    if offset < expected {
        Forward::Send(&data[(expected - offset) as usize..])
    } else if offset == expected {
        Forward::Send(data)
    } else {
        Forward::Gap {
            lost: offset - expected,
            data,
        }
    }
}

/// One JSON-RPC notification line.
fn note(method: &str, params: Value) -> String {
    json!({ "jsonrpc": "2.0", "method": method, "params": params }).to_string()
}

/// `term.output` for bytes that start at `offset`.
fn output_note(id: &str, offset: u64, data: &[u8]) -> String {
    note(
        "term.output",
        json!({ "id": id, "offset": offset, "data": B64.encode(data) }),
    )
}

fn gap_note(id: &str, lost: u64) -> String {
    note("term.gap", json!({ "id": id, "lost": lost }))
}

fn closed_note(id: &str) -> String {
    note("term.closed", json!({ "id": id }))
}

/// Sends notifications in order. Fails when the client is gone.
pub async fn send_all(outbox: &mpsc::Sender<String>, lines: Vec<String>) -> Result<(), mpsc::error::SendError<String>> {
    for line in lines {
        outbox.send(line).await?;
    }
    Ok(())
}

impl Stream {
    /// Next event of the terminal manager. Pends forever while nothing is attached.
    pub async fn next_event(&mut self) -> Result<TermEvent, broadcast::error::RecvError> {
        match &mut self.events {
            Some(rx) => rx.recv().await,
            None => std::future::pending().await,
        }
    }

    /// `term.attach {id, from?}`: start streaming a terminal. Answers with its info and a snapshot.
    pub fn attach(&mut self, app: &App, peer: &Peer, p: Value) -> RpcResult {
        ensure_paired(peer)?;
        let AttachParams { id, from } = params(p)?;
        // Subscribe before the snapshot, so nothing between the two is lost. Events already
        // covered by the snapshot are dropped by `forward`.
        if self.events.is_none() {
            self.events = Some(app.terminals.subscribe());
        }
        match app.terminals.attach(&id, from) {
            Ok((info, snap)) => {
                self.attached.insert(id, snap.start + snap.data.len() as u64);
                ok(json!({ "info": info, "start": snap.start, "data": B64.encode(&snap.data) }))
            }
            Err(e) => {
                self.forget_if_idle();
                Err(term_error(e))
            }
        }
    }

    /// `term.detach {id}`: stop streaming a terminal. The terminal keeps running.
    pub fn detach(&mut self, peer: &Peer, p: Value) -> RpcResult {
        ensure_paired(peer)?;
        let Id { id } = params(p)?;
        self.attached.remove(&id);
        self.forget_if_idle();
        ok(json!({}))
    }

    /// Drops the receiver once nothing is attached, so events are not queued for nobody.
    fn forget_if_idle(&mut self) {
        if self.attached.is_empty() {
            self.events = None;
        }
    }

    /// Notifications for one event from the terminal manager, in the order they must be sent.
    pub fn on_event(&mut self, app: &App, ev: Result<TermEvent, broadcast::error::RecvError>) -> Vec<String> {
        match ev {
            Ok(TermEvent::Output { id, offset, data }) => {
                let Some(next) = self.attached.get_mut(&id) else {
                    return Vec::new();
                };
                let expected = *next;
                match forward(next, offset, &data) {
                    Forward::Skip => Vec::new(),
                    Forward::Send(bytes) => vec![output_note(&id, expected, bytes)],
                    Forward::Gap { lost, data } => vec![gap_note(&id, lost), output_note(&id, offset, data)],
                }
            }
            Ok(TermEvent::Exited { id, code, signal }) => {
                if self.attached.contains_key(&id) {
                    vec![note("term.exit", json!({ "id": id, "code": code, "signal": signal }))]
                } else {
                    Vec::new()
                }
            }
            Ok(TermEvent::Closed { id }) => {
                if self.attached.remove(&id).is_some() {
                    vec![closed_note(&id)]
                } else {
                    Vec::new()
                }
            }
            Err(broadcast::error::RecvError::Lagged(_)) => self.catch_up(app),
            Err(broadcast::error::RecvError::Closed) => {
                self.events = None;
                Vec::new()
            }
        }
    }

    /// After events were lost: read every attached terminal from the place this connection
    /// expects. Output that was already sent is not repeated; a terminal that is gone is closed.
    fn catch_up(&mut self, app: &App) -> Vec<String> {
        let ids: Vec<String> = self.attached.keys().cloned().collect();
        let mut out = Vec::new();
        for id in ids {
            let next = self.attached[&id];
            match app.terminals.attach(&id, Some(next)) {
                Ok((_, snap)) => {
                    if snap.start > next {
                        out.push(gap_note(&id, snap.start - next));
                    }
                    if !snap.data.is_empty() {
                        out.push(output_note(&id, snap.start, &snap.data));
                    }
                    self.attached.insert(id, snap.start + snap.data.len() as u64);
                }
                // `attach` fails only when the terminal is gone.
                Err(_) => {
                    self.attached.remove(&id);
                    out.push(closed_note(&id));
                }
            }
        }
        self.forget_if_idle();
        out
    }
}

/// Only paired apps and the local socket may stream terminals.
fn ensure_paired(peer: &Peer) -> Result<(), RpcError> {
    if matches!(peer, Peer::Anonymous) {
        Err(RpcError::new(
            UNAUTHORIZED,
            "not paired: run `bandito pair` on the server",
        ))
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::time::Instant;

    const WAIT: Duration = Duration::from_secs(5);

    /// Closes the terminals of a test app when the test ends, even on panic, so no shell is left behind.
    struct Cleanup(Arc<App>);

    impl Drop for Cleanup {
        fn drop(&mut self) {
            self.0.terminals.shutdown_all();
        }
    }

    fn test_app() -> (Arc<App>, Cleanup) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let app = App::new(sup, std::env::temp_dir());
        (app.clone(), Cleanup(app))
    }

    /// One simulated connection. `serve` runs on its own task; the test plays the client.
    struct Conn {
        inbox: mpsc::Sender<String>,
        outbox: mpsc::Receiver<String>,
        /// Notifications that arrived while the test waited for something else.
        notes: Vec<Value>,
        next_id: u64,
    }

    fn connect(app: &Arc<App>, peer: Peer) -> Conn {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(256);
        tokio::spawn(crate::rpc::serve(app.clone(), peer, in_rx, out_tx));
        Conn {
            inbox: in_tx,
            outbox: out_rx,
            notes: Vec::new(),
            next_id: 0,
        }
    }

    fn sh_params() -> Value {
        json!({ "command": ["/bin/sh"], "cwd": "/", "cols": 80, "rows": 24 })
    }

    fn decode(p: &Value) -> Vec<u8> {
        B64.decode(p["data"].as_str().unwrap()).unwrap()
    }

    impl Conn {
        async fn recv(&mut self) -> Value {
            let line = tokio::time::timeout(WAIT, self.outbox.recv())
                .await
                .expect("no message within 5 s")
                .expect("connection closed");
            serde_json::from_str(&line).expect("valid JSON")
        }

        /// Sends a request and returns its response object. Notifications that come first are kept.
        async fn request(&mut self, method: &str, params: Value) -> Value {
            self.next_id += 1;
            let id = self.next_id;
            let req = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
            self.inbox.send(req.to_string()).await.expect("connection open");
            loop {
                let msg = self.recv().await;
                if msg["id"] == json!(id) {
                    return msg;
                }
                self.notes.push(msg);
            }
        }

        /// Result of a request that must succeed.
        async fn ok(&mut self, method: &str, params: Value) -> Value {
            let res = self.request(method, params).await;
            assert!(res.get("error").is_none(), "{method} failed: {res}");
            res["result"].clone()
        }

        /// Code and message of a request that must fail.
        async fn fail(&mut self, method: &str, params: Value) -> (i64, String) {
            let res = self.request(method, params).await;
            let e = res
                .get("error")
                .unwrap_or_else(|| panic!("{method} should fail: {res}"));
            (e["code"].as_i64().unwrap(), e["message"].as_str().unwrap().to_owned())
        }

        /// Params of the next notification called `method`.
        async fn note(&mut self, method: &str) -> Value {
            if let Some(i) = self.notes.iter().position(|m| m["method"] == method) {
                return self.notes.remove(i)["params"].clone();
            }
            loop {
                let msg = self.recv().await;
                if msg["method"] == method {
                    return msg["params"].clone();
                }
                self.notes.push(msg);
            }
        }

        /// Reads `term.output` until the received text contains `needle`. Returns the text and the
        /// offset just past the last byte received.
        async fn output_until(&mut self, needle: &str) -> (String, u64) {
            let mut text: Vec<u8> = Vec::new();
            loop {
                let p = self.note("term.output").await;
                let bytes = decode(&p);
                let end = p["offset"].as_u64().unwrap() + bytes.len() as u64;
                text.extend_from_slice(&bytes);
                let so_far = String::from_utf8_lossy(&text).into_owned();
                if so_far.contains(needle) {
                    return (so_far, end);
                }
            }
        }

        /// Collects every message for `dur`, responses and notifications alike.
        async fn quiet_for(&mut self, dur: Duration) -> Vec<Value> {
            let deadline = Instant::now() + dur;
            let mut got = Vec::new();
            loop {
                tokio::select! {
                    line = self.outbox.recv() => got.push(serde_json::from_str(&line.expect("connection closed")).unwrap()),
                    _ = tokio::time::sleep_until(deadline) => return got,
                }
            }
        }

        /// Opens a shell at `/`, attaches to it and returns its id.
        async fn open_attached(&mut self) -> String {
            let id = self.ok("term.open", sh_params()).await["id"]
                .as_str()
                .unwrap()
                .to_owned();
            self.ok("term.attach", json!({ "id": id })).await;
            id
        }

        async fn type_line(&mut self, id: &str, line: &str) {
            let data = B64.encode(line.as_bytes());
            self.ok("term.input", json!({ "id": id, "data": data })).await;
        }
    }

    #[test]
    fn forward_skips_bytes_that_were_sent() {
        let mut next = 10;
        assert_eq!(forward(&mut next, 0, b"abcde"), Forward::Skip);
        assert_eq!(forward(&mut next, 5, b"fghij"), Forward::Skip);
        assert_eq!(next, 10);
    }

    #[test]
    fn forward_sends_only_the_part_past_next() {
        let mut next = 12;
        assert_eq!(forward(&mut next, 10, b"abcdef"), Forward::Send(b"cdef"));
        assert_eq!(next, 16);
    }

    #[test]
    fn forward_sends_all_of_an_event_that_starts_at_next() {
        let mut next = 10;
        assert_eq!(forward(&mut next, 10, b"abc"), Forward::Send(b"abc"));
        assert_eq!(next, 13);
    }

    #[test]
    fn forward_reports_a_gap_and_sends_the_data() {
        let mut next = 10;
        assert_eq!(forward(&mut next, 15, b"xyz"), Forward::Gap { lost: 5, data: b"xyz" });
        assert_eq!(next, 18);
    }

    #[test]
    fn forward_ignores_empty_data() {
        let mut next = 10;
        assert_eq!(forward(&mut next, 10, b""), Forward::Skip);
        assert_eq!(forward(&mut next, 20, b""), Forward::Skip);
        assert_eq!(next, 10);
    }

    #[tokio::test]
    async fn attach_streams_output_and_input_reaches_the_shell() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let id = c.ok("term.open", sh_params()).await["id"].as_str().unwrap().to_owned();

        let attach = c.ok("term.attach", json!({ "id": id })).await;
        assert_eq!(attach["info"]["id"], json!(id));
        assert_eq!(attach["start"], json!(0));
        // Attaching again only replaces the snapshot and the expected offset.
        let again = c.ok("term.attach", json!({ "id": id })).await;
        assert_eq!(again["info"]["id"], json!(id));

        c.type_line(&id, "echo hel\"\"lo\n").await;
        let (text, _) = c.output_until("hello").await;
        assert!(text.contains("hello"));

        c.ok("term.close", json!({ "id": id })).await;
    }

    #[tokio::test]
    async fn detach_stops_the_stream_but_the_terminal_keeps_running() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let id = c.open_attached().await;
        c.type_line(&id, "echo hel\"\"lo\n").await;
        c.output_until("hello").await;

        c.ok("term.detach", json!({ "id": id })).await;
        c.notes.clear();
        let offset_before = c.ok("term.list", json!({})).await[0]["offset"].as_u64().unwrap();
        c.type_line(&id, "echo sec\"\"ond\n").await;
        let quiet = c.quiet_for(Duration::from_millis(300)).await;
        let streamed = quiet.iter().chain(c.notes.iter()).any(|m| m["method"] == "term.output");
        assert!(!streamed, "no output may be streamed after detach: {quiet:?}");

        let info = app.terminals.info(&id).unwrap();
        assert!(
            info.offset > offset_before,
            "the shell must keep running while detached"
        );
        assert_eq!(info.state, crate::terminal::TermState::Running);

        c.ok("term.close", json!({ "id": id })).await;
    }

    #[tokio::test]
    async fn reattach_from_an_old_offset_returns_what_was_missed() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let id = c.open_attached().await;
        c.type_line(&id, "echo hel\"\"lo\n").await;
        // `mark` is what this client has received so far.
        let (_, mark) = c.output_until("hello").await;

        c.ok("term.detach", json!({ "id": id })).await;
        c.type_line(&id, "echo wor\"\"ld\n").await;

        let deadline = Instant::now() + WAIT;
        let data = loop {
            let a = c.ok("term.attach", json!({ "id": id, "from": mark })).await;
            assert_eq!(a["start"], json!(mark));
            let data = decode(&a);
            if String::from_utf8_lossy(&data).contains("world") {
                break data;
            }
            assert!(Instant::now() < deadline, "output while detached never showed up");
            tokio::time::sleep(Duration::from_millis(50)).await;
        };
        assert!(String::from_utf8_lossy(&data).contains("world"));

        c.ok("term.close", json!({ "id": id })).await;
    }

    #[tokio::test]
    async fn close_announces_term_closed_and_removes_the_terminal() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let id = c.open_attached().await;

        c.ok("term.close", json!({ "id": id })).await;
        let p = c.note("term.closed").await;
        assert_eq!(p["id"], json!(id));
        let list = c.ok("term.list", json!({})).await;
        assert!(
            list.as_array().unwrap().is_empty(),
            "closed terminal still listed: {list}"
        );
    }

    #[tokio::test]
    async fn exit_announces_term_exit_with_the_code() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let spec = json!({ "command": ["/bin/sh", "-c", "read x; exit 4"], "cwd": "/", "cols": 80, "rows": 24 });
        let id = c.ok("term.open", spec).await["id"].as_str().unwrap().to_owned();
        c.ok("term.attach", json!({ "id": id })).await;

        // The shell waits for a line, so the exit is certain to come after the attach.
        c.type_line(&id, "x\n").await;
        let p = c.note("term.exit").await;
        assert_eq!(p["id"], json!(id));
        assert_eq!(p["code"], json!(4));
        assert_eq!(p["signal"], Value::Null);

        c.ok("term.close", json!({ "id": id })).await;
    }

    #[tokio::test]
    async fn anonymous_peer_cannot_use_terminals() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Anonymous);
        for (method, params) in [
            ("term.attach", json!({ "id": "x" })),
            ("term.detach", json!({ "id": "x" })),
            ("term.list", json!({})),
            ("term.open", sh_params()),
        ] {
            let (code, _) = c.fail(method, params).await;
            assert_eq!(code, UNAUTHORIZED, "{method}");
        }
        assert!(app.terminals.list().is_empty());
    }

    #[tokio::test]
    async fn unknown_terminal_id_says_not_found() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let calls = [
            ("term.attach", json!({ "id": "nope" })),
            ("term.input", json!({ "id": "nope", "data": "" })),
            ("term.resize", json!({ "id": "nope", "cols": 80, "rows": 24 })),
            ("term.rename", json!({ "id": "nope", "title": "x" })),
            ("term.close", json!({ "id": "nope" })),
        ];
        for (method, params) in calls {
            let (code, message) = c.fail(method, params).await;
            assert_eq!(code, TERM_ERROR, "{method}");
            assert!(message.contains("not_found"), "{method}: {message}");
        }
    }

    #[tokio::test]
    async fn input_over_64_kib_is_invalid_params() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let id = c.open_attached().await;

        let big = B64.encode(vec![b'a'; 64 * 1024 + 1]);
        let (code, message) = c.fail("term.input", json!({ "id": id, "data": big })).await;
        assert_eq!(code, INVALID_PARAMS);
        assert!(message.contains("larger"), "{message}");

        c.ok("term.close", json!({ "id": id })).await;
    }

    #[tokio::test]
    async fn input_that_is_not_base64_is_invalid_params() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        let id = c.open_attached().await;

        let (code, _) = c
            .fail("term.input", json!({ "id": id, "data": "!!! not base64" }))
            .await;
        assert_eq!(code, INVALID_PARAMS);

        c.ok("term.close", json!({ "id": id })).await;
    }

    #[tokio::test]
    async fn detach_of_an_unattached_terminal_is_ok() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);
        assert_eq!(c.ok("term.detach", json!({ "id": "whatever" })).await, json!({}));
    }

    #[tokio::test]
    async fn open_rejects_a_relative_cwd_and_expands_home() {
        let (app, _guard) = test_app();
        let mut c = connect(&app, Peer::Local);

        let mut relative = sh_params();
        relative["cwd"] = json!("relative/dir");
        let (code, _) = c.fail("term.open", relative).await;
        assert_eq!(code, INVALID_PARAMS);

        let mut home = sh_params();
        home["cwd"] = json!("~");
        let info = c.ok("term.open", home).await;
        let expected = dirs::home_dir().unwrap().display().to_string();
        assert_eq!(info["cwd"], json!(expected));
        c.ok("term.close", json!({ "id": info["id"] })).await;
    }

    #[tokio::test]
    async fn lagged_stream_catches_up_from_the_terminal() {
        let (app, _guard) = test_app();
        let spec = OpenSpec {
            cwd: "/".into(),
            command: Some(vec!["/bin/sh".into()]),
            title: None,
            cols: 80,
            rows: 24,
            env: Vec::new(),
        };
        let id = app.terminals.open(spec).unwrap().id;
        app.terminals.input(&id, b"echo hel\"\"lo\n").await.unwrap();

        // Pretend this connection missed events: it expects everything from offset 0.
        let mut stream = Stream::default();
        stream.attached.insert(id.clone(), 0);
        let deadline = Instant::now() + WAIT;
        loop {
            let notes = stream.on_event(&app, Err(broadcast::error::RecvError::Lagged(1)));
            let text: String = notes
                .iter()
                .filter_map(|n| serde_json::from_str::<Value>(n).ok())
                .filter(|v| v["method"] == "term.output")
                .map(|v| String::from_utf8_lossy(&decode(&v["params"])).into_owned())
                .collect();
            if text.contains("hello") {
                break;
            }
            assert!(Instant::now() < deadline, "catch-up never showed the output");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(stream.attached[&id] > 0);
    }
}
