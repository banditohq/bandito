//! Chrome's DevTools protocol over `--remote-debugging-pipe`, and the relay that lets several
//! clients share one browser.
//!
//! Chrome reads commands from fd 3 and writes answers and events to fd 4. Each message is JSON
//! followed by a NUL byte. No port is opened, so no other user on the machine can reach the
//! browser. One task owns both pipes (the relay). Clients get a [`BrowserClient`] (the browser
//! level) or a [`PageClient`] (one tab, as a plain CDP session). See docs/ARCHITECTURE.md#browser.

use crate::cdp::CdpTransport;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::future::Future;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::unix::pipe::{Receiver as PipeReceiver, Sender as PipeSender};
use tokio::sync::{mpsc, oneshot};

/// Most unanswered commands one client may have in flight.
pub const MAX_PENDING: usize = 256;
/// Largest message Chrome may send. A bigger one closes the pipe, as a crash does.
pub const MAX_CHROME_MESSAGE: usize = 64 << 20;
/// Messages queued for one client. A client that falls this far behind is disconnected.
const CLIENT_QUEUE: usize = 1024;
/// Requests queued for the relay task.
const REQUEST_QUEUE: usize = 256;
/// Messages queued between the pipe reader and the relay task.
const FRAME_QUEUE: usize = 64;
/// Bytes read from the pipe at a time.
const READ_CHUNK: usize = 64 << 10;

/// JSON-RPC style codes of the errors the relay answers clients with.
const ERR_INVALID: i64 = -32600;
const ERR_SESSION: i64 = -32001;
const ERR_PENDING: i64 = -32000;
const ERR_NOT_ALLOWED: i64 = -32002;
/// Domains a page client may not use: they address the browser, not one tab.
const BROWSER_DOMAINS: [&str; 4] = ["Target", "Browser", "Storage", "SystemInfo"];

pub type ClientId = u64;
/// A new client's id and the queue its messages arrive on.
/// A new client's id, its message queue, and the bytes of that queue.
type Attached = (ClientId, mpsc::Receiver<String>, Arc<AtomicUsize>);

/// Why a client could not be connected.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum LinkError {
    /// The browser is gone, or its relay has stopped.
    #[error("the browser connection is closed")]
    Closed,
    /// Chrome has no tab with this target id.
    #[error("{0}")]
    NoTarget(String),
}

/// The two pipes between the daemon and Chrome. The child's ends are closed in this process by
/// [`Pipes::into_parent`], after the spawn.
pub struct Pipes {
    /// The daemon's write end: Chrome's fd 3.
    to_chrome: OwnedFd,
    /// The daemon's read end: Chrome's fd 4.
    from_chrome: OwnedFd,
    /// Chrome's read end, moved to fd 3 in the child.
    chrome_reads: OwnedFd,
    /// Chrome's write end, moved to fd 4 in the child.
    chrome_writes: OwnedFd,
}

impl Pipes {
    pub fn new() -> io::Result<Self> {
        let (command_read, command_write) = io::pipe()?;
        let (event_read, event_write) = io::pipe()?;
        Ok(Self {
            to_chrome: command_write.into(),
            from_chrome: event_read.into(),
            chrome_reads: command_read.into(),
            chrome_writes: event_write.into(),
        })
    }

    /// Makes the spawned process see the pipes as fd 3 (commands in) and fd 4 (messages out).
    /// `self` must stay alive until the spawn has returned.
    pub fn install(&self, command: &mut tokio::process::Command) {
        let read = self.chrome_reads.as_raw_fd();
        let write = self.chrome_writes.as_raw_fd();
        // SAFETY: the closure runs in the forked child before exec. It calls only fcntl and dup2,
        // which are async-signal-safe, and allocates nothing. The descriptors are open because
        // `self` outlives the spawn (see the doc comment).
        unsafe { command.pre_exec(move || child_fds(read, write)) };
    }

    /// The daemon's ends as tokio pipes: the sender for commands, the receiver for messages.
    /// Dropping `self` here closes the child's ends in this process.
    pub fn into_parent(self) -> io::Result<(PipeSender, PipeReceiver)> {
        Ok((
            PipeSender::from_owned_fd(self.to_chrome)?,
            PipeReceiver::from_owned_fd(self.from_chrome)?,
        ))
    }
}

/// Runs in the forked child, before exec: puts `read` on fd 3 and `write` on fd 4.
fn child_fds(read: RawFd, write: RawFd) -> io::Result<()> {
    // The sources must not be 3 or 4: the first dup2 would overwrite the other source.
    let read = move_above_targets(read)?;
    let write = move_above_targets(write)?;
    dup_onto(read, 3)?;
    dup_onto(write, 4)?;
    Ok(())
}

fn move_above_targets(fd: RawFd) -> io::Result<RawFd> {
    if fd != 3 && fd != 4 {
        return Ok(fd);
    }
    // SAFETY: F_DUPFD_CLOEXEC only duplicates `fd` to the lowest free number from 10 up.
    let moved = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 10) };
    if moved < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(moved)
    }
}

fn dup_onto(src: RawFd, dst: RawFd) -> io::Result<()> {
    // SAFETY: dup2 only copies a descriptor. `src` is never 3 or 4 here, so it differs from `dst`.
    // dup2 leaves close-on-exec clear on `dst`, so fd 3 and fd 4 survive exec.
    if unsafe { libc::dup2(src, dst) } < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

/// The handle to a running relay. Cheap to clone; every clone talks to the same relay task.
#[derive(Clone)]
pub struct Relay {
    requests: mpsc::Sender<Request>,
    gone: mpsc::UnboundedSender<ClientId>,
}

/// What clients ask the relay task.
enum Request {
    Browser {
        reply: oneshot::Sender<Attached>,
    },
    Page {
        target: String,
        reply: oneshot::Sender<Result<Attached, String>>,
    },
    Send {
        client: ClientId,
        text: String,
    },
}

/// The byte limits of one relay. The defaults are the production values; tests set small ones.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    /// Largest message Chrome may send.
    pub max_message: usize,
    /// Bytes queued for one client before it is disconnected as too slow.
    pub client_queue_bytes: usize,
    /// Bytes of commands waiting for the pipe. A command past this is refused.
    pub write_queue_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_message: MAX_CHROME_MESSAGE,
            client_queue_bytes: 256 << 20,
            write_queue_bytes: 128 << 20,
        }
    }
}

impl Relay {
    /// Starts the relay over Chrome's pipes: `from_chrome` carries its answers and events, and
    /// `to_chrome` its commands. Must be called inside the tokio runtime.
    pub fn spawn<R, W>(from_chrome: R, to_chrome: W, max_message: usize) -> Self
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        Self::spawn_with_limits(
            from_chrome,
            to_chrome,
            Limits {
                max_message,
                ..Limits::default()
            },
        )
    }

    /// As [`Relay::spawn`], with the byte limits given.
    pub fn spawn_with_limits<R, W>(from_chrome: R, to_chrome: W, limits: Limits) -> Self
    where
        R: AsyncRead + Unpin + Send + 'static,
        W: AsyncWrite + Unpin + Send + 'static,
    {
        let (requests, request_rx) = mpsc::channel(REQUEST_QUEUE);
        let (gone, gone_rx) = mpsc::unbounded_channel();
        let (frames_tx, frames_rx) = mpsc::channel(FRAME_QUEUE);
        let (writes, writes_rx) = mpsc::unbounded_channel();
        let write_queued = Arc::new(AtomicUsize::new(0));
        tokio::spawn(read_frames(from_chrome, limits.max_message, frames_tx));
        tokio::spawn(write_frames(to_chrome, writes_rx, write_queued.clone()));
        let mux = Mux {
            writes,
            write_queued,
            limits,
            next_id: 1,
            next_client: 1,
            clients: HashMap::new(),
            sessions: HashMap::new(),
            session_targets: HashMap::new(),
            pending: HashMap::new(),
        };
        tokio::spawn(mux.run(request_rx, gone_rx, frames_rx));
        Self { requests, gone }
    }

    /// True once the relay task has stopped: Chrome closed the pipe or sent something invalid.
    pub fn is_closed(&self) -> bool {
        self.requests.is_closed()
    }

    /// A client for the browser level: browser commands and browser events.
    pub async fn browser_client(&self) -> Result<BrowserClient, LinkError> {
        let (reply, attached) = oneshot::channel();
        self.requests
            .send(Request::Browser { reply })
            .await
            .map_err(|_| LinkError::Closed)?;
        let (id, out, queued) = attached.await.map_err(|_| LinkError::Closed)?;
        Ok(BrowserClient {
            link: Link {
                relay: self.clone(),
                id,
                out,
                queued,
            },
        })
    }

    /// A client for one tab. Chrome attaches the tab (flattened) before this returns; the client
    /// then sees the tab's commands and events as a plain CDP session.
    pub async fn page_client(&self, target: &str) -> Result<PageClient, LinkError> {
        let (reply, attached) = oneshot::channel();
        self.requests
            .send(Request::Page {
                target: target.to_string(),
                reply,
            })
            .await
            .map_err(|_| LinkError::Closed)?;
        match attached.await.map_err(|_| LinkError::Closed)? {
            Ok((id, out, queued)) => Ok(PageClient {
                link: Link {
                    relay: self.clone(),
                    id,
                    out,
                    queued,
                },
            }),
            Err(message) => Err(LinkError::NoTarget(message)),
        }
    }
}

/// One client's connection. Dropping it detaches the sessions it owns.
struct Link {
    relay: Relay,
    id: ClientId,
    out: mpsc::Receiver<String>,
    /// Bytes of this client's messages that are queued and not yet read.
    queued: Arc<AtomicUsize>,
}

impl Link {
    async fn send(&mut self, text: String) -> Result<()> {
        self.relay
            .requests
            .send(Request::Send { client: self.id, text })
            .await
            .map_err(|_| anyhow!(LinkError::Closed))
    }

    async fn recv(&mut self) -> Result<String> {
        let text = self.out.recv().await.ok_or_else(|| anyhow!(LinkError::Closed))?;
        self.queued.fetch_sub(text.len(), Ordering::SeqCst);
        Ok(text)
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        // The channel is unbounded and the relay may already be gone: either way nothing to do.
        let _ = self.relay.gone.send(self.id);
    }
}

/// A client on the browser level. Its commands carry no session; it gets browser-level events.
pub struct BrowserClient {
    link: Link,
}

/// A client on one tab. Its commands and events go through the tab's session, and the messages it
/// sees carry no `sessionId`.
pub struct PageClient {
    link: Link,
}

impl CdpTransport for BrowserClient {
    fn send(&mut self, text: String) -> impl Future<Output = Result<()>> + Send {
        self.link.send(text)
    }

    fn recv(&mut self) -> impl Future<Output = Result<String>> + Send {
        self.link.recv()
    }
}

impl CdpTransport for PageClient {
    fn send(&mut self, text: String) -> impl Future<Output = Result<()>> + Send {
        self.link.send(text)
    }

    fn recv(&mut self) -> impl Future<Output = Result<String>> + Send {
        self.link.recv()
    }
}

/// Reads NUL-terminated JSON messages from Chrome and forwards them to the relay task. Ends on
/// EOF; a message over `max` bytes, or invalid JSON, is sent as an error first.
async fn read_frames<R: AsyncRead + Unpin>(mut from: R, max: usize, frames: mpsc::Sender<Result<Value>>) {
    let mut buf: Vec<u8> = Vec::new();
    // Bytes at the start of `buf` already known to hold no NUL, so that a long message is not
    // scanned again from its beginning after every read.
    let mut scanned = 0;
    let mut chunk = vec![0u8; READ_CHUNK];
    loop {
        let read = match from.read(&mut chunk).await {
            Ok(0) => return,
            Ok(n) => n,
            Err(e) => {
                let _ = frames.send(Err(e.into())).await;
                return;
            }
        };
        buf.extend_from_slice(&chunk[..read]);
        while let Some(at) = buf[scanned..].iter().position(|&b| b == 0).map(|i| scanned + i) {
            if at > max {
                let _ = frames
                    .send(Err(anyhow!("a message from the browser is over {max} bytes")))
                    .await;
                return;
            }
            let parsed = serde_json::from_slice::<Value>(&buf[..at]);
            buf.drain(..=at);
            scanned = 0;
            let message = match parsed {
                Ok(message) => message,
                Err(e) => {
                    let _ = frames.send(Err(e.into())).await;
                    return;
                }
            };
            if frames.send(Ok(message)).await.is_err() {
                return;
            }
        }
        scanned = buf.len();
        if buf.len() > max {
            let _ = frames
                .send(Err(anyhow!("a message from the browser is over {max} bytes")))
                .await;
            return;
        }
    }
}

/// Writes queued commands to Chrome, and gives back their bytes once they are written. Dropping the pipe at
/// the end tells Chrome to exit.
async fn write_frames<W: AsyncWrite + Unpin>(
    mut to: W,
    mut writes: mpsc::UnboundedReceiver<Vec<u8>>,
    queued: Arc<AtomicUsize>,
) {
    while let Some(bytes) = writes.recv().await {
        let len = bytes.len();
        if to.write_all(&bytes).await.is_err() {
            return;
        }
        queued.fetch_sub(len, Ordering::SeqCst);
    }
}

/// Who a client is, as the relay sees it.
#[derive(Debug, Clone)]
enum Kind {
    /// Browser-level commands; receives browser-level events.
    Browser,
    /// One tab. `session` is set once Chrome has attached it.
    Page { session: Option<String> },
}

struct ClientState {
    kind: Kind,
    out: mpsc::Sender<String>,
    /// Commands sent to Chrome whose answers have not come back yet.
    pending: usize,
    /// Bytes of this client's messages in its queue.
    queued: Arc<AtomicUsize>,
}

/// Where a Chrome answer goes, keyed by the relay's own command id.
enum Waiting {
    /// A client's command: the answer goes back with the client's own id. `attach_target` is the tab of an
    /// attach, so the session can be matched to its tab.
    Answer {
        client: ClientId,
        id: Value,
        method: String,
        attach_target: Option<String>,
    },
    /// The attach a page client waits for before it is handed out.
    Attach {
        client: ClientId,
        target: String,
        out: mpsc::Receiver<String>,
        queued: Arc<AtomicUsize>,
        reply: oneshot::Sender<Result<Attached, String>>,
    },
    /// A detach the relay sent for a client that went away. Nobody waits for the answer.
    Ignore,
}

/// The relay task's state. Only this task touches it, so it needs no locks, and it never waits
/// on anything but its own channels: a slow client is disconnected, not waited for.
struct Mux {
    writes: mpsc::UnboundedSender<Vec<u8>>,
    /// Bytes of commands handed to the writer and not yet written.
    write_queued: Arc<AtomicUsize>,
    limits: Limits,
    /// The ids Chrome sees. Only this task assigns them, so a plain counter is enough.
    next_id: u64,
    next_client: ClientId,
    clients: HashMap<ClientId, ClientState>,
    /// Session id → the client that attached it.
    sessions: HashMap<String, ClientId>,
    /// Session id → the tab it is attached to.
    session_targets: HashMap<String, String>,
    pending: HashMap<u64, Waiting>,
}

impl Mux {
    async fn run(
        mut self,
        mut requests: mpsc::Receiver<Request>,
        mut gone: mpsc::UnboundedReceiver<ClientId>,
        mut frames: mpsc::Receiver<Result<Value>>,
    ) {
        loop {
            let step = tokio::select! {
                request = requests.recv() => match request {
                    Some(request) => self.request(request),
                    None => break,
                },
                Some(client) = gone.recv() => self.drop_client(client),
                frame = frames.recv() => match frame {
                    Some(Ok(message)) => self.handle_chrome(message),
                    Some(Err(e)) => Err(e),
                    None => break,
                },
            };
            if let Err(e) = step {
                tracing::warn!("browser relay stopped: {e:#}");
                break;
            }
        }
        // Dropping `self` closes every client's queue, so their recv() fails, and the write side
        // of the pipe, so Chrome sees EOF.
    }

    fn request(&mut self, request: Request) -> Result<()> {
        match request {
            Request::Browser { reply } => {
                let attached = self.add(Kind::Browser);
                // If the caller has gone, its Link drop cleans up.
                let _ = reply.send(attached);
                Ok(())
            }
            Request::Page { target, reply } => {
                let (id, out, queued) = self.add(Kind::Page { session: None });
                let gid = self.next_id();
                let attach = json!({
                    "id": gid,
                    "method": "Target.attachToTarget",
                    "params": { "targetId": target, "flatten": true },
                });
                self.pending.insert(
                    gid,
                    Waiting::Attach {
                        client: id,
                        target,
                        out,
                        queued,
                        reply,
                    },
                );
                self.push(&attach)
            }
            Request::Send { client, text } => self.client_command(client, &text),
        }
    }

    fn add(&mut self, kind: Kind) -> Attached {
        let id = self.next_client;
        self.next_client += 1;
        let (out, rx) = mpsc::channel(CLIENT_QUEUE);
        let queued = Arc::new(AtomicUsize::new(0));
        self.clients.insert(
            id,
            ClientState {
                kind,
                out,
                pending: 0,
                queued: queued.clone(),
            },
        );
        (id, rx, queued)
    }

    fn next_id(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Queues a message for Chrome, without a budget check: used for the relay's own commands, which are few.
    fn push(&self, message: &Value) -> Result<()> {
        let mut bytes = message.to_string().into_bytes();
        bytes.push(0);
        self.write_queued.fetch_add(bytes.len(), Ordering::SeqCst);
        self.writes
            .send(bytes)
            .map_err(|_| anyhow!("the browser pipe is closed"))
    }

    /// A command from a client: the id is replaced by one the relay owns, and the session is set or
    /// checked. A command the browser has no room for is refused, not queued.
    fn client_command(&mut self, client: ClientId, text: &str) -> Result<()> {
        let mut command: Value = match serde_json::from_str::<Value>(text) {
            Ok(command) if command.get("id").is_some() && command.get("method").and_then(Value::as_str).is_some() => {
                command
            }
            _ => return self.refuse(client, Value::Null, ERR_INVALID, "a command needs an id and a method"),
        };
        let Some(state) = self.clients.get(&client) else {
            return Ok(());
        };
        let (kind, pending) = (state.kind.clone(), state.pending);
        let id = command["id"].take();
        if pending >= MAX_PENDING {
            return self.refuse(client, id, ERR_PENDING, "too many pending commands");
        }
        let method = command["method"].as_str().unwrap_or_default().to_owned();
        match kind {
            Kind::Page { session } => {
                if BROWSER_DOMAINS.contains(&method.split('.').next().unwrap_or_default()) {
                    return self.refuse(client, id, ERR_NOT_ALLOWED, "method not allowed for a page client");
                }
                let params = &command["params"];
                if params.get("targetId").is_some() {
                    return self.refuse(
                        client,
                        id,
                        ERR_NOT_ALLOWED,
                        "params.targetId is not allowed for a page client",
                    );
                }
                // The screencast ack names its frame with a number. A session id is a string, and is never allowed.
                let frame_ack = method == "Page.screencastFrameAck" && params["sessionId"].is_number();
                if params.get("sessionId").is_some() && !frame_ack {
                    return self.refuse(
                        client,
                        id,
                        ERR_NOT_ALLOWED,
                        "params.sessionId is not allowed for a page client",
                    );
                }
                match session {
                    Some(sid) => command["sessionId"] = json!(sid),
                    None => return self.refuse(client, id, ERR_SESSION, "the tab is not attached"),
                }
            }
            Kind::Browser => {
                if let Some(sid) = command.get("sessionId").and_then(Value::as_str)
                    && self.sessions.get(sid) != Some(&client)
                {
                    return self.refuse(client, id, ERR_SESSION, "unknown session");
                }
                match method.as_str() {
                    "Target.detachFromTarget" | "Target.sendMessageToTarget" => {
                        if let Some(sid) = command["params"]["sessionId"].as_str()
                            && self.sessions.get(sid) != Some(&client)
                        {
                            return self.refuse(client, id, ERR_SESSION, "unknown session");
                        }
                    }
                    "Target.closeTarget" => {
                        if let Some(target) = command["params"]["targetId"].as_str()
                            && self.attached_to_another(client, target)
                        {
                            return self.refuse(client, id, ERR_SESSION, "the tab is attached to another client");
                        }
                    }
                    _ => {}
                }
            }
        }
        let attach_target = if method == "Target.attachToTarget" {
            command["params"]["targetId"].as_str().map(str::to_owned)
        } else {
            None
        };
        let gid = self.next_id();
        command["id"] = json!(gid);
        let mut bytes = command.to_string().into_bytes();
        bytes.push(0);
        if self.write_queued.load(Ordering::SeqCst) + bytes.len() > self.limits.write_queue_bytes {
            return self.refuse(client, id, ERR_PENDING, "too many bytes waiting for the browser");
        }
        self.pending.insert(
            gid,
            Waiting::Answer {
                client,
                id,
                method,
                attach_target,
            },
        );
        if let Some(state) = self.clients.get_mut(&client) {
            state.pending += 1;
        }
        self.write_queued.fetch_add(bytes.len(), Ordering::SeqCst);
        self.writes
            .send(bytes)
            .map_err(|_| anyhow!("the browser pipe is closed"))
    }

    /// Whether some session on `target` belongs to a client other than `client`.
    fn attached_to_another(&self, client: ClientId, target: &str) -> bool {
        self.session_targets
            .iter()
            .any(|(sid, t)| t == target && self.sessions.get(sid).is_some_and(|owner| *owner != client))
    }

    fn refuse(&mut self, client: ClientId, id: Value, code: i64, message: &str) -> Result<()> {
        self.deliver(
            client,
            json!({ "id": id, "error": { "code": code, "message": message } }),
        )
    }

    fn handle_chrome(&mut self, message: Value) -> Result<()> {
        if let Some(gid) = message.get("id").and_then(Value::as_u64) {
            match self.pending.remove(&gid) {
                Some(Waiting::Answer {
                    client,
                    id,
                    method,
                    attach_target,
                }) => self.answer(client, id, &method, attach_target, message),
                Some(Waiting::Attach {
                    client,
                    target,
                    out,
                    queued,
                    reply,
                }) => self.attached(client, target, out, queued, reply, message),
                Some(Waiting::Ignore) | None => Ok(()),
            }
        } else if message.get("method").is_some() {
            self.event(message)
        } else {
            Ok(())
        }
    }

    fn answer(
        &mut self,
        client: ClientId,
        id: Value,
        method: &str,
        attach_target: Option<String>,
        mut message: Value,
    ) -> Result<()> {
        let Some(state) = self.clients.get_mut(&client) else {
            return Ok(());
        };
        state.pending = state.pending.saturating_sub(1);
        if method == "Target.attachToTarget"
            && let Some(sid) = message["result"]["sessionId"].as_str()
        {
            self.sessions.insert(sid.to_owned(), client);
            if let Some(target) = attach_target {
                self.session_targets.insert(sid.to_owned(), target);
            }
        }
        let session = message.get("sessionId").and_then(Value::as_str).map(str::to_owned);
        if self.hides_session(client, session.as_deref()) {
            strip_session(&mut message);
        }
        message["id"] = id;
        self.deliver(client, message)
    }

    /// Chrome's answer to the attach a page client asked for.
    fn attached(
        &mut self,
        client: ClientId,
        target: String,
        out: mpsc::Receiver<String>,
        queued: Arc<AtomicUsize>,
        reply: oneshot::Sender<Result<Attached, String>>,
        message: Value,
    ) -> Result<()> {
        let session = message["result"]["sessionId"].as_str().map(str::to_owned);
        let Some(sid) = session.filter(|_| message.get("error").is_none()) else {
            self.clients.remove(&client);
            let text = message["error"]["message"]
                .as_str()
                .unwrap_or("the tab could not be attached");
            let _ = reply.send(Err(text.to_owned()));
            return Ok(());
        };
        if let Some(state) = self.clients.get_mut(&client) {
            state.kind = Kind::Page {
                session: Some(sid.clone()),
            };
        }
        self.session_targets.insert(sid.clone(), target);
        self.sessions.insert(sid, client);
        if reply.send(Ok((client, out, queued))).is_err() {
            return self.drop_client(client);
        }
        Ok(())
    }

    /// A browser-level event goes to every browser client. A session event goes to the client
    /// that owns the session.
    fn event(&mut self, message: Value) -> Result<()> {
        if let Some(sid) = message.get("sessionId").and_then(Value::as_str).map(str::to_owned) {
            let Some(&owner) = self.sessions.get(&sid) else {
                return Ok(());
            };
            let mut message = message;
            if self.hides_session(owner, Some(&sid)) {
                strip_session(&mut message);
            }
            return self.deliver(owner, message);
        }
        let method = message["method"].as_str().unwrap_or_default().to_owned();
        if method == "Target.detachedFromTarget"
            && let Some(sid) = message["params"]["sessionId"].as_str().map(str::to_owned)
        {
            // The session is forgotten whoever owns it. A tab client's connection ends with it.
            let owner = self.sessions.remove(&sid);
            self.session_targets.remove(&sid);
            if let Some(owner) = owner
                && matches!(self.clients.get(&owner).map(|c| &c.kind), Some(Kind::Page { .. }))
            {
                self.deliver(owner, message.clone())?;
                self.clients.remove(&owner);
            }
        }
        let browsers: Vec<ClientId> = self
            .clients
            .iter()
            .filter(|(_, c)| matches!(c.kind, Kind::Browser))
            .map(|(id, _)| *id)
            .collect();
        for id in browsers {
            self.deliver(id, message.clone())?;
        }
        Ok(())
    }

    /// True when `client` is a tab client whose own session is `sid`: its messages carry no session.
    fn hides_session(&self, client: ClientId, sid: Option<&str>) -> bool {
        matches!(
            self.clients.get(&client).map(|c| &c.kind),
            Some(Kind::Page { session: Some(own) }) if Some(own.as_str()) == sid
        )
    }

    /// Queues a message for a client. A client whose queue is full (by count or by bytes), or who is gone,
    /// is dropped as too slow.
    fn deliver(&mut self, client: ClientId, message: Value) -> Result<()> {
        let Some(state) = self.clients.get(&client) else {
            return Ok(());
        };
        let text = message.to_string();
        let len = text.len();
        // Counted before the send: the reader may take the message back at once.
        state.queued.fetch_add(len, Ordering::SeqCst);
        let within_budget = state.queued.load(Ordering::SeqCst) <= self.limits.client_queue_bytes;
        if within_budget && state.out.try_send(text).is_ok() {
            return Ok(());
        }
        state.queued.fetch_sub(len, Ordering::SeqCst);
        self.drop_client(client)
    }

    /// Forgets a client, and detaches the sessions it owned.
    fn drop_client(&mut self, client: ClientId) -> Result<()> {
        if self.clients.remove(&client).is_none() {
            return Ok(());
        }
        let owned: Vec<String> = self
            .sessions
            .iter()
            .filter(|(_, owner)| **owner == client)
            .map(|(sid, _)| sid.clone())
            .collect();
        for sid in owned {
            self.sessions.remove(&sid);
            self.session_targets.remove(&sid);
            let gid = self.next_id();
            self.pending.insert(gid, Waiting::Ignore);
            self.push(&json!({
                "id": gid,
                "method": "Target.detachFromTarget",
                "params": { "sessionId": sid },
            }))?;
        }
        Ok(())
    }
}

fn strip_session(message: &mut Value) {
    if let Some(object) = message.as_object_mut() {
        object.remove("sessionId");
    }
}

/// A relay with no Chrome behind it: it stays open until the test ends.
#[cfg(test)]
pub(crate) fn idle_relay() -> Relay {
    let (daemon_end, chrome_end) = tokio::io::duplex(1 << 16);
    let (read, write) = tokio::io::split(daemon_end);
    tokio::spawn(async move {
        let _keep = chrome_end;
        std::future::pending::<()>().await;
    });
    Relay::spawn(read, write, MAX_CHROME_MESSAGE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncBufReadExt, BufReader, DuplexStream};
    use tokio::time::timeout;

    const WAIT: Duration = Duration::from_secs(2);

    /// Stands in for Chrome: reads the commands the relay writes, and writes answers and events.
    struct FakeChrome {
        commands: BufReader<DuplexStream>,
        events: DuplexStream,
    }

    impl FakeChrome {
        /// The next command the relay sent Chrome.
        async fn command(&mut self) -> Value {
            let mut raw = Vec::new();
            timeout(WAIT, self.commands.read_until(0, &mut raw))
                .await
                .expect("no command from the relay")
                .unwrap();
            raw.pop();
            serde_json::from_slice(&raw).unwrap()
        }

        /// Writes one message the way Chrome does: JSON and a NUL byte.
        async fn send(&mut self, message: Value) {
            let mut bytes = message.to_string().into_bytes();
            bytes.push(0);
            self.events.write_all(&bytes).await.unwrap();
        }

        /// Answers the attach the relay sent for a page client.
        async fn attach_answer(&mut self, session: &str) {
            let command = self.command().await;
            assert_eq!(command["method"], "Target.attachToTarget");
            assert_eq!(command["params"]["flatten"], true);
            self.send(json!({ "id": command["id"], "result": { "sessionId": session } }))
                .await;
        }
    }

    fn setup(max_message: usize) -> (Relay, FakeChrome) {
        let (relay_reads, chrome_writes) = tokio::io::duplex(1 << 20);
        let (relay_writes, chrome_reads) = tokio::io::duplex(1 << 20);
        let relay = Relay::spawn(relay_reads, relay_writes, max_message);
        let chrome = FakeChrome {
            commands: BufReader::new(chrome_reads),
            events: chrome_writes,
        };
        (relay, chrome)
    }

    /// A page client for `target`, with Chrome answering the attach as `session`.
    async fn page(relay: &Relay, chrome: &mut FakeChrome, target: &str, session: &str) -> PageClient {
        let (relay, target) = (relay.clone(), target.to_string());
        let attach = tokio::spawn(async move { relay.page_client(&target).await });
        chrome.attach_answer(session).await;
        attach.await.unwrap().expect("attach")
    }

    async fn recv_json(client: &mut impl CdpTransport) -> Value {
        let text = timeout(WAIT, client.recv()).await.expect("no message").expect("closed");
        serde_json::from_str(&text).unwrap()
    }

    /// True when nothing arrives on the client within a short wait.
    async fn quiet(client: &mut impl CdpTransport) -> bool {
        timeout(Duration::from_millis(100), client.recv()).await.is_err()
    }

    #[tokio::test]
    async fn two_browser_clients_with_the_same_ids_get_their_own_answers() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut a = relay.browser_client().await.unwrap();
        let mut b = relay.browser_client().await.unwrap();
        a.send(json!({"id": 1, "method": "Browser.getVersion"}).to_string())
            .await
            .unwrap();
        b.send(json!({"id": 1, "method": "Target.getTargets"}).to_string())
            .await
            .unwrap();
        let first = chrome.command().await;
        let second = chrome.command().await;
        assert_eq!(first["method"], "Browser.getVersion");
        assert_ne!(first["id"], second["id"]);
        chrome.send(json!({"id": first["id"], "result": {"for": "a"}})).await;
        chrome.send(json!({"id": second["id"], "result": {"for": "b"}})).await;
        assert_eq!(recv_json(&mut a).await, json!({"id": 1, "result": {"for": "a"}}));
        assert_eq!(recv_json(&mut b).await, json!({"id": 1, "result": {"for": "b"}}));
    }

    #[tokio::test]
    async fn a_page_client_sends_with_its_session_and_gets_plain_answers() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut tab = page(&relay, &mut chrome, "T1", "S1").await;
        tab.send(json!({"id": 5, "method": "Page.enable"}).to_string())
            .await
            .unwrap();
        let command = chrome.command().await;
        assert_eq!(command["sessionId"], "S1");
        assert_eq!(command["method"], "Page.enable");
        chrome
            .send(json!({"id": command["id"], "sessionId": "S1", "result": {}}))
            .await;
        assert_eq!(recv_json(&mut tab).await, json!({"id": 5, "result": {}}));
    }

    #[tokio::test]
    async fn session_events_reach_only_their_owner_and_browser_events_reach_browser_clients() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut first = page(&relay, &mut chrome, "T1", "S1").await;
        let mut second = page(&relay, &mut chrome, "T2", "S2").await;
        let mut browser = relay.browser_client().await.unwrap();

        chrome
            .send(json!({"sessionId": "S1", "method": "Page.frameNavigated", "params": {"n": 1}}))
            .await;
        chrome
            .send(json!({"method": "Target.targetCreated", "params": {"n": 2}}))
            .await;

        assert_eq!(
            recv_json(&mut first).await,
            json!({"method": "Page.frameNavigated", "params": {"n": 1}})
        );
        // The browser client's first message is the browser event: the session event was not sent to it.
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"method": "Target.targetCreated", "params": {"n": 2}})
        );
        assert!(quiet(&mut first).await, "the browser event reached a page client");
        assert!(quiet(&mut second).await, "another tab's client got a session event");
    }

    #[tokio::test]
    async fn dropping_a_page_client_detaches_its_session() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let tab = page(&relay, &mut chrome, "T1", "S1").await;
        drop(tab);
        let command = chrome.command().await;
        assert_eq!(command["method"], "Target.detachFromTarget");
        assert_eq!(command["params"]["sessionId"], "S1");
    }

    #[tokio::test]
    async fn a_closed_tab_gives_its_client_the_event_and_then_ends_the_connection() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut tab = page(&relay, &mut chrome, "T1", "S1").await;
        chrome
            .send(json!({"method": "Target.detachedFromTarget", "params": {"sessionId": "S1", "targetId": "T1"}}))
            .await;
        assert_eq!(recv_json(&mut tab).await["method"], "Target.detachedFromTarget");
        assert!(timeout(WAIT, tab.recv()).await.unwrap().is_err());
    }

    #[tokio::test]
    async fn a_browser_client_cannot_use_a_session_it_does_not_own() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let _tab = page(&relay, &mut chrome, "T1", "S1").await;
        let mut browser = relay.browser_client().await.unwrap();
        browser
            .send(json!({"id": 1, "sessionId": "S1", "method": "Page.enable"}).to_string())
            .await
            .unwrap();
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"id": 1, "error": {"code": -32001, "message": "unknown session"}})
        );
    }

    #[tokio::test]
    async fn a_command_without_an_id_is_refused_with_a_null_id() {
        let (relay, _chrome) = setup(MAX_CHROME_MESSAGE);
        let mut browser = relay.browser_client().await.unwrap();
        browser
            .send(json!({"method": "Browser.getVersion"}).to_string())
            .await
            .unwrap();
        assert_eq!(recv_json(&mut browser).await["id"], Value::Null);
    }

    #[tokio::test]
    async fn a_client_has_at_most_256_unanswered_commands() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut browser = relay.browser_client().await.unwrap();
        for i in 0..MAX_PENDING {
            browser
                .send(json!({"id": i, "method": "Browser.getVersion"}).to_string())
                .await
                .unwrap();
        }
        browser
            .send(json!({"id": "over", "method": "Browser.getVersion"}).to_string())
            .await
            .unwrap();
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"id": "over", "error": {"code": -32000, "message": "too many pending commands"}})
        );
        let mut forwarded = Vec::new();
        for _ in 0..MAX_PENDING {
            forwarded.push(chrome.command().await);
        }
        // One answer frees one slot.
        chrome.send(json!({"id": forwarded[0]["id"], "result": {}})).await;
        assert_eq!(recv_json(&mut browser).await, json!({"id": 0, "result": {}}));
        browser
            .send(json!({"id": "again", "method": "Browser.getVersion"}).to_string())
            .await
            .unwrap();
        assert_eq!(chrome.command().await["method"], "Browser.getVersion");
    }

    #[tokio::test]
    async fn a_message_split_over_many_reads_is_reassembled() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut browser = relay.browser_client().await.unwrap();
        let big = "x".repeat(300_000);
        chrome.send(json!({"method": "Big.event", "params": {"s": big}})).await;
        chrome.send(json!({"method": "Small.event"})).await;
        assert_eq!(
            recv_json(&mut browser).await["params"]["s"].as_str().unwrap().len(),
            300_000
        );
        assert_eq!(recv_json(&mut browser).await["method"], "Small.event");
    }

    #[tokio::test]
    async fn a_message_longer_than_the_limit_closes_the_relay() {
        let (relay, mut chrome) = setup(1024);
        let mut browser = relay.browser_client().await.unwrap();
        // More than the limit, and no NUL: the relay cannot know where the message ends.
        chrome.events.write_all(&vec![b'x'; 2048]).await.unwrap();
        assert!(timeout(WAIT, browser.recv()).await.unwrap().is_err());
        assert!(
            timeout(WAIT, async {
                while !relay.is_closed() {
                    tokio::task::yield_now().await;
                }
            })
            .await
            .is_ok()
        );
    }

    #[tokio::test]
    async fn a_complete_message_longer_than_the_limit_closes_the_relay() {
        let (relay, mut chrome) = setup(1024);
        let mut browser = relay.browser_client().await.unwrap();
        chrome
            .send(json!({"method": "Big", "params": {"s": "y".repeat(2000)}}))
            .await;
        assert!(timeout(WAIT, browser.recv()).await.unwrap().is_err());
    }

    #[tokio::test]
    async fn chrome_exiting_closes_every_client() {
        let (relay, chrome) = setup(MAX_CHROME_MESSAGE);
        let mut browser = relay.browser_client().await.unwrap();
        drop(chrome.events);
        assert!(timeout(WAIT, browser.recv()).await.unwrap().is_err());
        assert!(relay.browser_client().await.is_err());
    }

    #[tokio::test]
    async fn a_client_that_falls_too_far_behind_is_disconnected() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut browser = relay.browser_client().await.unwrap();
        let mut slow = relay.browser_client().await.unwrap();
        // Chrome sends more browser events than the queue holds, and `slow` never reads.
        for n in 0..CLIENT_QUEUE + 10 {
            chrome.send(json!({"method": "Tick", "params": {"n": n}})).await;
            assert_eq!(recv_json(&mut browser).await["params"]["n"], n);
        }
        assert!(
            timeout(WAIT, async { while slow.recv().await.is_ok() {} })
                .await
                .is_ok()
        );
    }

    /// True when nothing reaches Chrome within a short wait.
    async fn nothing_reached(chrome: &mut FakeChrome) -> bool {
        let mut raw = Vec::new();
        timeout(Duration::from_millis(100), chrome.commands.read_until(0, &mut raw))
            .await
            .is_err()
    }

    #[tokio::test]
    async fn a_page_client_cannot_reach_the_browser_domains() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut tab = page(&relay, &mut chrome, "T1", "S1").await;
        for method in [
            "Target.getTargets",
            "Target.attachToTarget",
            "Target.detachFromTarget",
            "Browser.getVersion",
            "Storage.getCookies",
            "SystemInfo.getInfo",
        ] {
            tab.send(json!({"id": 9, "method": method}).to_string()).await.unwrap();
            assert_eq!(
                recv_json(&mut tab).await,
                json!({"id": 9, "error": {"code": -32002, "message": "method not allowed for a page client"}}),
                "{method}"
            );
        }
        assert!(nothing_reached(&mut chrome).await, "a refused command reached Chrome");
    }

    #[tokio::test]
    async fn a_page_client_cannot_name_another_session_or_target_in_params() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut tab = page(&relay, &mut chrome, "T1", "S1").await;
        tab.send(
            json!({"id": 4, "method": "Runtime.evaluate", "params": {"expression": "1", "sessionId": "S2"}})
                .to_string(),
        )
        .await
        .unwrap();
        assert_eq!(recv_json(&mut tab).await["error"]["code"], -32002);
        tab.send(json!({"id": 5, "method": "Runtime.evaluate", "params": {"targetId": "T2"}}).to_string())
            .await
            .unwrap();
        assert_eq!(recv_json(&mut tab).await["error"]["code"], -32002);
        assert!(nothing_reached(&mut chrome).await);

        // The screencast ack names its frame with a number, not a session: it still goes through.
        tab.send(json!({"id": 6, "method": "Page.screencastFrameAck", "params": {"sessionId": 3}}).to_string())
            .await
            .unwrap();
        let command = chrome.command().await;
        assert_eq!(command["method"], "Page.screencastFrameAck");
        assert_eq!(command["sessionId"], "S1");
        assert_eq!(command["params"]["sessionId"], 3);
    }

    #[tokio::test]
    async fn a_browser_client_detaches_and_messages_only_its_own_sessions() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let _tab = page(&relay, &mut chrome, "T1", "S1").await;
        let mut browser = relay.browser_client().await.unwrap();
        for (id, method) in [(1, "Target.detachFromTarget"), (2, "Target.sendMessageToTarget")] {
            browser
                .send(json!({"id": id, "method": method, "params": {"sessionId": "S1", "message": "{}"}}).to_string())
                .await
                .unwrap();
            assert_eq!(
                recv_json(&mut browser).await,
                json!({"id": id, "error": {"code": -32001, "message": "unknown session"}}),
                "{method}"
            );
        }
        assert!(
            nothing_reached(&mut chrome).await,
            "another client's session was addressed"
        );

        // Its own session works.
        browser
            .send(
                json!({"id": 3, "method": "Target.attachToTarget", "params": {"targetId": "T9", "flatten": true}})
                    .to_string(),
            )
            .await
            .unwrap();
        let attach = chrome.command().await;
        chrome
            .send(json!({"id": attach["id"], "result": {"sessionId": "S9"}}))
            .await;
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"id": 3, "result": {"sessionId": "S9"}})
        );
        browser
            .send(json!({"id": 4, "method": "Target.detachFromTarget", "params": {"sessionId": "S9"}}).to_string())
            .await
            .unwrap();
        assert_eq!(chrome.command().await["method"], "Target.detachFromTarget");
    }

    #[tokio::test]
    async fn a_browser_client_cannot_close_a_tab_another_client_has_attached() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let _tab = page(&relay, &mut chrome, "T1", "S1").await;
        let mut browser = relay.browser_client().await.unwrap();
        browser
            .send(json!({"id": 1, "method": "Target.closeTarget", "params": {"targetId": "T1"}}).to_string())
            .await
            .unwrap();
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"id": 1, "error": {"code": -32001, "message": "the tab is attached to another client"}})
        );
        assert!(nothing_reached(&mut chrome).await);

        // A tab nobody has attached may be closed.
        browser
            .send(json!({"id": 2, "method": "Target.closeTarget", "params": {"targetId": "T2"}}).to_string())
            .await
            .unwrap();
        assert_eq!(chrome.command().await["params"]["targetId"], "T2");
    }

    #[tokio::test]
    async fn a_session_is_forgotten_when_its_target_detaches_whoever_owns_it() {
        let (relay, mut chrome) = setup(MAX_CHROME_MESSAGE);
        let mut browser = relay.browser_client().await.unwrap();
        browser
            .send(
                json!({"id": 1, "method": "Target.attachToTarget", "params": {"targetId": "T9", "flatten": true}})
                    .to_string(),
            )
            .await
            .unwrap();
        let attach = chrome.command().await;
        chrome
            .send(json!({"id": attach["id"], "result": {"sessionId": "S9"}}))
            .await;
        assert_eq!(recv_json(&mut browser).await["id"], 1);

        chrome
            .send(json!({"method": "Target.detachedFromTarget", "params": {"sessionId": "S9", "targetId": "T9"}}))
            .await;
        assert_eq!(recv_json(&mut browser).await["method"], "Target.detachedFromTarget");

        browser
            .send(json!({"id": 2, "sessionId": "S9", "method": "Page.enable"}).to_string())
            .await
            .unwrap();
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"id": 2, "error": {"code": -32001, "message": "unknown session"}})
        );
    }

    #[tokio::test]
    async fn a_client_whose_queued_bytes_pass_its_budget_is_disconnected_as_slow() {
        let limits = Limits {
            client_queue_bytes: 1000,
            ..Limits::default()
        };
        let (relay_reads, chrome_writes) = tokio::io::duplex(1 << 20);
        let (relay_writes, chrome_reads) = tokio::io::duplex(1 << 20);
        let relay = Relay::spawn_with_limits(relay_reads, relay_writes, limits);
        let mut chrome = FakeChrome {
            commands: BufReader::new(chrome_reads),
            events: chrome_writes,
        };
        let mut browser = relay.browser_client().await.unwrap();
        // Three events of about 400 bytes, none read yet: the third passes the 1000-byte budget.
        for n in 0..3 {
            chrome
                .send(json!({"method": "Big", "params": {"n": n, "s": "x".repeat(380)}}))
                .await;
        }
        assert_eq!(recv_json(&mut browser).await["params"]["n"], 0);
        assert_eq!(recv_json(&mut browser).await["params"]["n"], 1);
        assert!(
            timeout(WAIT, browser.recv()).await.unwrap().is_err(),
            "the slow client was kept"
        );
    }

    #[tokio::test]
    async fn commands_past_the_write_budget_are_refused_not_queued() {
        let limits = Limits {
            write_queue_bytes: 1000,
            ..Limits::default()
        };
        // A pipe that holds 128 bytes and is not read: the first command stays in flight.
        let (relay_reads, _chrome_writes) = tokio::io::duplex(1 << 20);
        let (relay_writes, chrome_reads) = tokio::io::duplex(128);
        let relay = Relay::spawn_with_limits(relay_reads, relay_writes, limits);
        let mut chrome = FakeChrome {
            commands: BufReader::new(chrome_reads),
            events: tokio::io::duplex(1 << 20).1,
        };
        let mut browser = relay.browser_client().await.unwrap();
        for id in 0..3 {
            browser
                .send(json!({"id": id, "method": "Browser.getVersion", "params": {"pad": "x".repeat(380)}}).to_string())
                .await
                .unwrap();
        }
        assert_eq!(
            recv_json(&mut browser).await,
            json!({"id": 2, "error": {"code": -32000, "message": "too many bytes waiting for the browser"}})
        );
        assert!(!relay.is_closed(), "a refused command closed the relay");
        // The first command is still on its way.
        let mut raw = Vec::new();
        timeout(WAIT, chrome.commands.read_until(0, &mut raw))
            .await
            .unwrap()
            .unwrap();
        assert!(!raw.is_empty());
    }
}
