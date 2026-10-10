//! Unix socket transports: newline-delimited JSON-RPC, the same methods as WebSocket.
//! `bandito.sock` is the owner's CLI: it refuses any process that runs under the daemon.
//! `agent.sock` is for the crew servers of agents: its first request must be `daemon.hello`
//! with the agent's session token. See docs/ARCHITECTURE.md#trust-model.

use super::{App, Peer, RpcError, UNAUTHORIZED, response, serve};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::future::Future;
use std::os::fd::{AsRawFd, RawFd};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader, Lines};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;

/// Refusal for a process under the daemon: agents, their shells, and the apps the daemon starts.
const AGENTS_USE_AGENT_SOCK: &str = "agents use agent.sock: bandito.sock is for the owner's CLI";
/// Refusal when the process on the other end cannot be identified.
const UNKNOWN_CALLER: &str = "cannot tell which process is calling bandito.sock; agents use agent.sock";
/// Refusal when an `agent.sock` connection does not open with a valid `daemon.hello`.
const NEEDS_TOKEN: &str = "agent.sock needs daemon.hello with agent_token first";

/// Binds a socket (replacing a stale one), mode 0600. It is created under umask 0077, so no
/// moment exists where it is more open than that.
pub fn bind(path: &Path) -> anyhow::Result<UnixListener> {
    if path.exists() {
        // A live daemon would answer; a dead one leaves the file behind.
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            anyhow::bail!("another bandito daemon is already running ({})", path.display());
        }
        std::fs::remove_file(path)?;
    }
    // SAFETY: umask only changes the file-creation mask of this process, and the old one is put back at once.
    let previous = unsafe { libc::umask(0o077) };
    let bound = UnixListener::bind(path);
    unsafe { libc::umask(previous) };
    let listener = bound?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// Serves `bandito.sock`: the owner's CLI.
pub async fn run(app: Arc<App>, listener: UnixListener) {
    accept_loop(app, listener, handle).await;
}

/// Serves `agent.sock`: the crew servers of agents.
pub async fn run_agents(app: Arc<App>, listener: UnixListener) {
    accept_loop(app, listener, handle_agent).await;
}

async fn accept_loop<F, Fut>(app: Arc<App>, listener: UnixListener, conn: F)
where
    F: Fn(Arc<App>, UnixStream) -> Fut + Copy + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(conn(app.clone(), stream));
            }
            Err(e) => {
                tracing::warn!("unix accept: {e}");
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        }
    }
}

/// One connection on `bandito.sock`, as the owner.
async fn handle(app: Arc<App>, stream: UnixStream) {
    let fd = stream.as_raw_fd();
    let (read, mut write) = stream.into_split();
    if let Err(reason) = owner_check(fd) {
        refuse(&mut write, Value::Null, reason).await;
        return;
    }
    pump(app, Peer::Local, None, BufReader::new(read).lines(), write).await;
}

/// One connection on `agent.sock`. The first request must be `daemon.hello` with a live session token;
/// anything else is refused, and the connection closes.
async fn handle_agent(app: Arc<App>, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let mut lines = BufReader::new(read).lines();
    let first = loop {
        match lines.next_line().await {
            Ok(Some(line)) if line.trim().is_empty() => continue,
            Ok(Some(line)) => break line,
            _ => return,
        }
    };
    match agent_of_hello(&app, &first) {
        Ok(agent) => pump(app, Peer::Agent(agent), Some(first), lines, write).await,
        Err((id, reason)) => refuse(&mut write, id, reason).await,
    }
}

/// The agent a first `agent.sock` request names by its token. On refusal: the request's id and the reason.
fn agent_of_hello(app: &App, line: &str) -> Result<String, (Value, &'static str)> {
    let request: Value = serde_json::from_str(line).unwrap_or(Value::Null);
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    if request.get("method").and_then(Value::as_str) != Some("daemon.hello") {
        return Err((id, NEEDS_TOKEN));
    }
    let Some(token) = request.pointer("/params/agent_token").and_then(Value::as_str) else {
        return Err((id, NEEDS_TOKEN));
    };
    app.sup
        .agent_tokens()
        .agent_for(token)
        .ok_or((id, "the agent token is unknown or its session has ended"))
}

/// Writes one refusal, then the connection is closed by the caller.
async fn refuse<W: AsyncWrite + Unpin>(write: &mut W, id: Value, reason: &str) {
    let line = response(id, Err(RpcError::new(UNAUTHORIZED, reason)));
    let _ = write.write_all(format!("{line}\n").as_bytes()).await;
}

/// Serves one connection as `peer`: request lines in, response lines out, until either side goes away.
/// `first` is a request that was already read, and it is served before the rest.
async fn pump(
    app: Arc<App>,
    peer: Peer,
    first: Option<String>,
    mut lines: Lines<BufReader<OwnedReadHalf>>,
    mut write: OwnedWriteHalf,
) {
    let (in_tx, in_rx) = mpsc::channel::<String>(64);
    let (out_tx, mut out_rx) = mpsc::channel::<String>(256);
    let writer = tokio::spawn(async move {
        while let Some(line) = out_rx.recv().await {
            if write.write_all(line.as_bytes()).await.is_err() || write.write_all(b"\n").await.is_err() {
                break;
            }
        }
    });
    if let Some(first) = first {
        // The channel is empty and has room, so this does not wait.
        let _ = in_tx.send(first).await;
    }
    let reader = tokio::spawn(async move {
        while let Ok(Some(line)) = lines.next_line().await {
            if !line.trim().is_empty() && in_tx.send(line).await.is_err() {
                break;
            }
        }
    });
    serve(app, peer, in_rx, out_tx).await;
    reader.abort();
    let _ = writer.await;
}

/// Lets `bandito.sock` through only to the owner's CLI. Refused: a process under the daemon, and a
/// caller whose process or ancestry cannot be read (fail closed, with a warning).
fn owner_check(fd: RawFd) -> Result<(), &'static str> {
    let Some(pid) = peer_pid(fd) else {
        tracing::warn!("bandito.sock: the caller's pid cannot be read; refusing");
        return Err(UNKNOWN_CALLER);
    };
    match descends_from(pid, std::process::id(), parent_pid) {
        Some(false) => Ok(()),
        Some(true) => Err(AGENTS_USE_AGENT_SOCK),
        None => {
            tracing::warn!(pid, "bandito.sock: the caller's process chain cannot be read; refusing");
            Err(UNKNOWN_CALLER)
        }
    }
}

/// Whether `pid` is `ancestor` or runs under it. `parent_of` gives the parent of a process. `None` when
/// the chain cannot be followed: a parent cannot be read, or the chain loops.
pub fn descends_from(pid: u32, ancestor: u32, parent_of: impl Fn(u32) -> Option<u32>) -> Option<bool> {
    let mut seen = HashSet::new();
    let mut current = pid;
    loop {
        if current == ancestor {
            return Some(true);
        }
        // pid 0 and 1 are the top of every chain.
        if current <= 1 {
            return Some(false);
        }
        if !seen.insert(current) {
            return None;
        }
        current = parent_of(current)?;
    }
}

/// The pid of the process on the other end of a unix socket, when the OS tells it.
#[cfg(target_os = "linux")]
fn peer_pid(fd: RawFd) -> Option<u32> {
    let mut cred = libc::ucred { pid: 0, uid: 0, gid: 0 };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    // SAFETY: `cred` and `len` are valid for the call, and the kernel writes no more than `len` bytes.
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0 && cred.pid > 0).then_some(cred.pid as u32)
}

/// The pid of the process on the other end of a unix socket, when the OS tells it.
#[cfg(target_os = "macos")]
fn peer_pid(fd: RawFd) -> Option<u32> {
    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    // SAFETY: `pid` and `len` are valid for the call, and LOCAL_PEERPID writes one pid_t.
    let rc = unsafe {
        libc::getsockopt(
            fd,
            libc::SOL_LOCAL,
            libc::LOCAL_PEERPID,
            (&mut pid as *mut libc::pid_t).cast(),
            &mut len,
        )
    };
    (rc == 0 && pid > 0).then_some(pid as u32)
}

/// Other systems give no pid here, so the caller is refused (fail closed).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn peer_pid(_fd: RawFd) -> Option<u32> {
    None
}

/// The parent of a process, from the OS. `None` when it cannot be read.
#[cfg(target_os = "linux")]
fn parent_pid(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    parse_stat(&stat).map(|(_, ppid)| ppid)
}

/// State and parent pid from `/proc/<pid>/stat`: fields 3 and 4. The command name sits in parentheses
/// and may hold spaces and parentheses, so the fields are read after the last `)`.
#[cfg(any(target_os = "linux", test))]
fn parse_stat(stat: &str) -> Option<(char, u32)> {
    let mut fields = stat.rsplit_once(')')?.1.split_whitespace();
    let state = fields.next()?.chars().next()?;
    let ppid = fields.next()?.parse().ok()?;
    Some((state, ppid))
}

/// The parent of a process, from the OS. `None` when it cannot be read.
#[cfg(target_os = "macos")]
fn parent_pid(pid: u32) -> Option<u32> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    // SAFETY: `info` is zeroed and exactly `size` bytes, the size PROC_PIDTBSDINFO fills.
    let n = unsafe {
        libc::proc_pidinfo(
            pid as libc::c_int,
            libc::PROC_PIDTBSDINFO,
            0,
            (&mut info as *mut libc::proc_bsdinfo).cast(),
            size,
        )
    };
    if n == size {
        return Some(info.pbi_ppid);
    }
    // EPERM: the process belongs to another user (root's `login` above every Terminal shell, for one).
    // Every process the daemon starts runs as the daemon's own user, so a chain that reaches a process
    // of another user has left the daemon's tree: end it there, as at pid 1. Any other failure (the
    // process is gone) still refuses the caller.
    let permission_denied = std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM);
    permission_denied.then_some(1)
}

/// Other systems: the parent is unknown, so every caller is refused (fail closed).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn parent_pid(_pid: u32) -> Option<u32> {
    None
}

/// On Linux the daemon becomes a child subreaper. A process that double-forks away is then
/// re-parented to the daemon, not to init, and still counts as its descendant.
#[cfg(target_os = "linux")]
pub fn become_subreaper() {
    // SAFETY: PR_SET_CHILD_SUBREAPER only sets a flag on this process.
    let rc = unsafe {
        libc::prctl(
            libc::PR_SET_CHILD_SUBREAPER,
            1 as libc::c_ulong,
            0 as libc::c_ulong,
            0 as libc::c_ulong,
            0 as libc::c_ulong,
        )
    };
    if rc != 0 {
        tracing::warn!(
            "could not become a child subreaper: {}",
            std::io::Error::last_os_error()
        );
    }
}

/// Only Linux has the subreaper flag. Elsewhere a double-forked process is re-parented to init.
#[cfg(not(target_os = "linux"))]
pub fn become_subreaper() {}

/// How often the daemon looks for zombie children (Linux, see [`spawn_zombie_reaper`]).
pub const REAP_INTERVAL: Duration = Duration::from_secs(10);

/// Reaps the zombie children of this process (Linux). Children that double-forked away end up under the
/// daemon (it is a subreaper), and nothing else waits for them. Every `interval` the processes under the
/// daemon are read from `/proc`. A zombie seen in two scans in a row has lived at least one interval, so
/// any child whose owner waits for it (a tokio child is reaped at once) has had its chance. Only then is
/// it reaped, by its pid.
#[cfg(target_os = "linux")]
pub fn spawn_zombie_reaper(interval: Duration) {
    tokio::spawn(reap_zombies(std::process::id(), interval));
}

/// Other systems re-parent orphans to init, which reaps them.
#[cfg(not(target_os = "linux"))]
pub fn spawn_zombie_reaper(_interval: Duration) {}

#[cfg(target_os = "linux")]
async fn reap_zombies(daemon: u32, interval: Duration) {
    let mut tick = tokio::time::interval(interval);
    let mut seen: HashSet<u32> = HashSet::new();
    loop {
        tick.tick().await;
        let zombies: HashSet<u32> = child_states(daemon)
            .into_iter()
            .filter(|(_, state)| *state == 'Z')
            .map(|(pid, _)| pid)
            .collect();
        let mut first_time = HashSet::new();
        for pid in zombies {
            // Its owner waits for it: the exit status is theirs.
            if crate::children::is_registered(pid) {
                continue;
            }
            if seen.contains(&pid) {
                reap_one(pid);
            } else {
                first_time.insert(pid);
            }
        }
        seen = first_time;
    }
}

/// Waits for one zombie, without blocking. Its status is dropped: nobody asked for it.
#[cfg(target_os = "linux")]
fn reap_one(pid: u32) {
    let mut status: libc::c_int = 0;
    // SAFETY: waitpid with WNOHANG on one pid writes only to `status`, which lives for the call.
    let rc = unsafe { libc::waitpid(pid as libc::pid_t, &mut status, libc::WNOHANG) };
    if rc == pid as libc::pid_t {
        tracing::debug!(pid, "reaped a zombie child");
    }
}

/// Every process whose parent is `parent`, with its state letter, from `/proc`.
#[cfg(target_os = "linux")]
fn child_states(parent: u32) -> Vec<(u32, char)> {
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    entries
        .filter_map(|entry| {
            let pid: u32 = entry.ok()?.file_name().to_str()?.parse().ok()?;
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let (state, ppid) = parse_stat(&stat)?;
            (ppid == parent).then_some((pid, state))
        })
        .collect()
}

/// Longest a client waits for the daemon to answer one request.
const CALL_TIMEOUT: Duration = Duration::from_secs(30);

/// Client side for the `bandito` CLI: one request, one response.
pub async fn call(path: &Path, method: &str, params: Value) -> anyhow::Result<Value> {
    call_within(path, None, method, params, CALL_TIMEOUT).await
}

/// Client side for the crew server of an agent: says hello with the session token, then makes one request.
pub async fn call_agent(path: &Path, token: &str, method: &str, params: Value) -> anyhow::Result<Value> {
    call_within(path, Some(token), method, params, CALL_TIMEOUT).await
}

/// [`call_agent`] for a call that waits for the human (a form): it may take up to `limit`.
pub async fn call_agent_waiting(
    path: &Path,
    token: &str,
    method: &str,
    params: Value,
    limit: Duration,
) -> anyhow::Result<Value> {
    call_within(path, Some(token), method, params, limit).await
}

async fn call_within(
    path: &Path,
    token: Option<&str>,
    method: &str,
    params: Value,
    limit: Duration,
) -> anyhow::Result<Value> {
    tokio::time::timeout(limit, call_once(path, token, method, params))
        .await
        .map_err(|_| anyhow::anyhow!("the daemon did not answer in {} s", limit.as_secs()))?
}

async fn call_once(path: &Path, token: Option<&str>, method: &str, params: Value) -> anyhow::Result<Value> {
    let stream = UnixStream::connect(path)
        .await
        .map_err(|e| anyhow::anyhow!("cannot reach the daemon at {} ({e}). Is it running?", path.display()))?;
    let (read, mut write) = stream.into_split();
    let mut out = String::new();
    if let Some(token) = token {
        let hello = json!({ "jsonrpc": "2.0", "id": 0, "method": "daemon.hello", "params": { "agent_token": token } });
        out.push_str(&format!("{hello}\n"));
    }
    let req = json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    out.push_str(&format!("{req}\n"));
    write.write_all(out.as_bytes()).await?;
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        let v: Value = serde_json::from_str(&line)?;
        let id = v.get("id").cloned().unwrap_or(Value::Null);
        if id == json!(1) {
            if let Some(err) = v.get("error") {
                anyhow::bail!("{}", err["message"].as_str().unwrap_or("daemon error"));
            }
            return Ok(v["result"].clone());
        }
        // A refused connection, or a hello that was not accepted: both carry an error and no reply to 1.
        if let Some(err) = v.get("error") {
            anyhow::bail!("{}", err["message"].as_str().unwrap_or("daemon error"));
        }
    }
    anyhow::bail!("the daemon closed the connection")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use tokio::io::AsyncReadExt as _;

    fn test_app(dir: &Path) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, dir.join("agents"))
    }

    #[tokio::test]
    async fn call_gives_up_when_the_daemon_stays_silent() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("silent.sock");
        let listener = tokio::net::UnixListener::bind(&sock).unwrap();
        // Accept the connection and never answer.
        let server = tokio::spawn(async move {
            let _conn = listener.accept().await;
            tokio::time::sleep(Duration::from_secs(60)).await;
        });
        let err = call_within(&sock, None, "daemon.info", json!({}), Duration::from_millis(100))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("the daemon did not answer in"), "{err}");
        server.abort();
    }

    #[tokio::test]
    async fn sockets_are_created_owner_only() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("bandito.sock");
        let _listener = bind(&sock).unwrap();
        let mode = std::fs::metadata(&sock).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn descends_from_follows_the_chain_up_to_init() {
        // 50 -> 40 -> 30 -> 1, and the daemon is 40.
        let parent = |pid: u32| match pid {
            50 => Some(40),
            40 => Some(30),
            30 => Some(1),
            _ => None,
        };
        assert_eq!(descends_from(50, 40, parent), Some(true));
        assert_eq!(descends_from(40, 40, parent), Some(true));
        assert_eq!(descends_from(50, 99, parent), Some(false));
        assert_eq!(descends_from(1, 40, parent), Some(false));
    }

    #[test]
    fn descends_from_refuses_to_guess_when_the_chain_breaks_or_loops() {
        // A parent that cannot be read.
        let broken = |pid: u32| if pid == 50 { Some(40) } else { None };
        assert_eq!(descends_from(50, 99, broken), None);
        // 10 -> 11 -> 10: a loop.
        let looping = |pid: u32| Some(if pid == 10 { 11 } else { 10 });
        assert_eq!(descends_from(10, 99, looping), None);
    }

    #[test]
    fn stat_gives_state_and_parent_even_when_the_name_has_brackets() {
        assert_eq!(parse_stat("1234 (node) S 42 1234 1234 0 -1"), Some(('S', 42)));
        assert_eq!(parse_stat("1234 (my (weird) name) Z 7 1 1 0 -1"), Some(('Z', 7)));
        assert_eq!(parse_stat("garbage"), None);
    }

    /// Not a test of its own. The reaper test below runs it in a child process, which plays the daemon.
    #[cfg(target_os = "linux")]
    #[test]
    fn reaper_probe() {
        let Some(out) = std::env::var_os("BANDITO_TEST_REAPER_OUT") else {
            return;
        };
        // This process plays the daemon: a child subreaper, with the reaper running.
        become_subreaper();
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let verdict = runtime.block_on(async {
            let me = std::process::id();
            // The shell starts a sleep in the background and exits. The sleep is re-parented to this process.
            let status = std::process::Command::new("sh")
                .args(["-c", "(sleep 0.1 &)"])
                .status()
                .unwrap();
            assert!(status.success());
            // Once the sleep has exited it is a zombie of this process, and nothing has reaped it yet.
            let mut zombies = Vec::new();
            for _ in 0..50 {
                tokio::time::sleep(Duration::from_millis(20)).await;
                zombies = child_states(me).into_iter().filter(|(_, s)| *s == 'Z').collect();
                if !zombies.is_empty() {
                    break;
                }
            }
            if zombies.is_empty() {
                return "no zombie appeared".to_string();
            }
            // Now the reaper starts: within a few scans it must take the zombie.
            spawn_zombie_reaper(Duration::from_millis(50));
            for _ in 0..200 {
                tokio::time::sleep(Duration::from_millis(25)).await;
                if child_states(me).iter().all(|(_, s)| *s != 'Z') {
                    return "reaped".to_string();
                }
            }
            "zombie remains".to_string()
        });
        std::fs::write(out, verdict).unwrap();
    }

    /// A process that double-forks leaves a zombie under the daemon, and the daemon reaps it.
    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn a_double_forked_child_does_not_stay_a_zombie() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("reaper.out");
        let status = std::process::Command::new(probe_exe())
            .args(["--exact", "rpc::unix::tests::reaper_probe"])
            .env("BANDITO_TEST_REAPER_OUT", &out)
            .status()
            .unwrap();
        assert!(status.success());
        assert_eq!(std::fs::read_to_string(&out).unwrap(), "reaped");
    }

    fn probe_exe() -> PathBuf {
        std::env::current_exe().unwrap()
    }

    /// Not a test of its own. The probe processes of the two tests below run this one, with the socket and
    /// an output file in the environment. Without them it does nothing.
    #[test]
    fn ancestor_probe_client() {
        let (Some(sock), Some(out)) = (
            std::env::var_os("BANDITO_TEST_PROBE_SOCK"),
            std::env::var_os("BANDITO_TEST_PROBE_OUT"),
        ) else {
            return;
        };
        use std::io::{BufRead, BufReader, Write};
        let mut stream = std::os::unix::net::UnixStream::connect(sock).expect("connect");
        stream.set_read_timeout(Some(Duration::from_secs(10))).expect("timeout");
        stream
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"daemon.info\",\"params\":{}}\n")
            .expect("write");
        let mut line = String::new();
        let _ = BufReader::new(&stream).read_line(&mut line);
        std::fs::write(out, line).expect("write output");
    }

    #[tokio::test]
    async fn a_child_of_the_daemon_is_refused_on_bandito_sock() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("bandito.sock");
        let listener = bind(&sock).unwrap();
        let out = dir.path().join("probe.out");
        let mut child = std::process::Command::new(probe_exe())
            .args(["--exact", "rpc::unix::tests::ancestor_probe_client"])
            .env("BANDITO_TEST_PROBE_SOCK", &sock)
            .env("BANDITO_TEST_PROBE_OUT", &out)
            .spawn()
            .unwrap();
        let (stream, _) = listener.accept().await.unwrap();
        // The probe is a child of this process, which plays the daemon: it is refused and the connection closes.
        handle(test_app(dir.path()), stream).await;
        assert!(child.wait().unwrap().success());
        let reply = std::fs::read_to_string(&out).unwrap();
        assert!(reply.contains("agents use agent.sock"), "{reply}");
        assert!(reply.contains("-32001"), "{reply}");
    }

    #[tokio::test]
    async fn a_process_outside_the_daemon_gets_through_bandito_sock() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("bandito.sock");
        let listener = bind(&sock).unwrap();
        let out = dir.path().join("probe.out");
        // The probe is started in the background by a shell that exits at once, so the probe is
        // re-parented away from this process before it connects.
        let mut shell = std::process::Command::new("sh")
            .args([
                "-c",
                "\"$0\" --exact rpc::unix::tests::ancestor_probe_client >/dev/null 2>&1 &",
            ])
            .arg(probe_exe())
            .env("BANDITO_TEST_PROBE_SOCK", &sock)
            .env("BANDITO_TEST_PROBE_OUT", &out)
            .spawn()
            .unwrap();
        assert!(shell.wait().unwrap().success());
        let (stream, _) = listener.accept().await.unwrap();
        handle(test_app(dir.path()), stream).await;
        let reply = std::fs::read_to_string(&out).unwrap();
        assert!(reply.contains("\"version\""), "{reply}");
    }

    /// Sends `requests` on one `agent.sock` connection and returns every reply, until the server closes it.
    async fn talk_agent(app: Arc<App>, requests: &[Value]) -> Vec<Value> {
        let (client, server) = UnixStream::pair().unwrap();
        tokio::spawn(handle_agent(app, server));
        let (read, mut write) = client.into_split();
        for request in requests {
            let _ = write.write_all(format!("{request}\n").as_bytes()).await;
        }
        // Half-close: the server ends the connection once it has answered everything.
        let _ = write.shutdown().await;
        let mut lines = BufReader::new(read).lines();
        let mut replies = Vec::new();
        while let Ok(Some(line)) = lines.next_line().await {
            replies.push(serde_json::from_str(&line).unwrap());
        }
        replies
    }

    fn hello(id: i64, token: &str) -> Value {
        json!({ "jsonrpc": "2.0", "id": id, "method": "daemon.hello", "params": { "agent_token": token } })
    }

    fn request(id: i64, method: &str, params: Value) -> Value {
        json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params })
    }

    #[tokio::test]
    async fn agent_sock_needs_a_valid_hello_first() {
        let dir = tempfile::tempdir().unwrap();
        let app = test_app(dir.path());
        let (token, _guard) = app.sup.agent_tokens().issue("agent-a").unwrap();

        // No hello: refused and closed.
        let replies = talk_agent(app.clone(), &[request(1, "crew.list", json!({}))]).await;
        assert_eq!(replies.len(), 1, "{replies:?}");
        assert_eq!(replies[0]["error"]["code"], json!(UNAUTHORIZED));
        assert!(
            replies[0]["error"]["message"]
                .as_str()
                .unwrap()
                .contains("daemon.hello")
        );

        // A token that is not live: refused and closed.
        let replies = talk_agent(
            app.clone(),
            &[hello(1, "bat_not_a_token"), request(2, "crew.list", json!({}))],
        )
        .await;
        assert_eq!(replies.len(), 1, "{replies:?}");
        assert_eq!(replies[0]["error"]["code"], json!(UNAUTHORIZED));

        // A live token: hello is answered, then calls go through.
        let replies = talk_agent(app.clone(), &[hello(1, &token), request(2, "crew.list", json!({}))]).await;
        assert_eq!(replies.len(), 2, "{replies:?}");
        assert_eq!(replies[0]["result"]["authenticated"], json!(true));
        assert_eq!(replies[1]["result"], json!([]));
    }

    #[tokio::test]
    async fn agent_sock_refuses_what_agents_may_not_call() {
        let dir = tempfile::tempdir().unwrap();
        let app = test_app(dir.path());
        let (token, _guard) = app.sup.agent_tokens().issue("agent-a").unwrap();
        let forbidden = [
            ("events.subscribe", json!({ "after": 0 })),
            ("pair.create", json!({})),
            ("rules.set", json!({ "pattern": "x", "action": "allow" })),
            ("approvals.resolve", json!({ "approval_id": "a", "decision": "allow" })),
            ("agents.update", json!({ "id": "a" })),
            ("commands.install", json!({ "scope": "user" })),
            ("secrets.list", json!({})),
        ];
        for (method, params) in forbidden {
            let replies = talk_agent(app.clone(), &[hello(1, &token), request(2, method, params)]).await;
            assert_eq!(
                replies[1]["error"]["code"],
                json!(UNAUTHORIZED),
                "{method}: {replies:?}"
            );
        }
    }

    #[tokio::test]
    async fn an_agent_cannot_act_as_another_agent() {
        let dir = tempfile::tempdir().unwrap();
        let app = test_app(dir.path());
        let (token, _guard) = app.sup.agent_tokens().issue("agent-a").unwrap();
        let replies = talk_agent(
            app.clone(),
            &[
                hello(1, &token),
                request(2, "crew.list", json!({ "agent_id": "agent-b" })),
                request(3, "history.day", json!({ "agent_id": "agent-b", "date": "2026-10-01" })),
                request(4, "crew.send", json!({ "from": "agent-b", "to": "x", "message": "hi" })),
            ],
        )
        .await;
        for reply in &replies[1..] {
            assert_eq!(reply["error"]["code"], json!(UNAUTHORIZED), "{replies:?}");
        }
    }

    #[tokio::test]
    async fn a_session_that_ended_loses_its_token() {
        let dir = tempfile::tempdir().unwrap();
        let app = test_app(dir.path());
        let (token, guard) = app.sup.agent_tokens().issue("agent-a").unwrap();
        drop(guard);
        let replies = talk_agent(app.clone(), &[hello(1, &token)]).await;
        assert_eq!(replies[0]["error"]["code"], json!(UNAUTHORIZED), "{replies:?}");
    }

    #[tokio::test]
    async fn call_agent_reaches_agent_sock_with_its_token() {
        let dir = tempfile::tempdir().unwrap();
        let sock = dir.path().join("agent.sock");
        let listener = bind(&sock).unwrap();
        let mode = std::fs::metadata(&sock).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let app = test_app(dir.path());
        let (token, _guard) = app.sup.agent_tokens().issue("agent-a").unwrap();
        tokio::spawn(run_agents(app.clone(), listener));
        let listed = call_agent(&sock, &token, "crew.list", json!({})).await.unwrap();
        assert_eq!(listed, json!([]));
        let err = call_agent(&sock, "bat_wrong", "crew.list", json!({}))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("unknown"), "{err}");
    }

    #[tokio::test]
    async fn bandito_sock_refuses_a_socket_pair_held_by_this_process() {
        // Over a socket pair the caller is this test process, which is the daemon here: refused.
        let dir = tempfile::tempdir().unwrap();
        let app = test_app(dir.path());
        let (client, server) = UnixStream::pair().unwrap();
        tokio::spawn(handle(app, server));
        let mut reply = String::new();
        let mut client = client;
        client.read_to_string(&mut reply).await.unwrap();
        assert!(reply.contains("agents use agent.sock"), "{reply}");
    }
}
