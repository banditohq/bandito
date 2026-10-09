//! Persistent terminals: PTY-backed shells and programs that keep running while no
//! client is attached (a tmux-lite). Output goes into a bounded scrollback ring, so a
//! client that reconnects can read what it missed. Unix only.

use crate::store::{new_id, now_ms};
use anyhow::{Context, Result, anyhow, bail};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};
use std::io::{self, ErrorKind};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::ptr;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::io::unix::AsyncFd;
use tokio::sync::{broadcast, oneshot};

/// Largest accepted terminal dimension, in cells.
const MAX_DIM: u16 = 1000;
/// Longest title, in characters.
const MAX_TITLE_CHARS: usize = 80;
/// Bytes read from a PTY per call.
const READ_CHUNK: usize = 64 * 1024;
/// Largest input accepted by one `input` call.
const MAX_INPUT: usize = 64 * 1024;
/// Most bytes read after the child exited, to pick up output still held by the PTY.
const DRAIN_LIMIT: usize = 1024 * 1024;
/// Time between SIGHUP and SIGKILL when a terminal is closed.
const HANGUP_GRACE: Duration = Duration::from_secs(2);
/// Capacity of the broadcast channel for events.
const EVENT_CAPACITY: usize = 1024;

/// Terminal lifecycle state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TermState {
    Running,
    Exited { code: Option<i32>, signal: Option<i32> },
}

/// Public view of one terminal.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TermInfo {
    /// UUID v7.
    pub id: String,
    pub title: String,
    pub cwd: String,
    pub command: Vec<String>,
    pub pid: i32,
    pub cols: u16,
    pub rows: u16,
    /// Unix milliseconds.
    pub created_at: i64,
    pub state: TermState,
    /// Total bytes of output produced so far (not only the retained part).
    pub offset: u64,
}

/// Parameters for [`TerminalManager::open`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenSpec {
    pub cwd: PathBuf,
    /// `None` starts the user's login shell.
    pub command: Option<Vec<String>>,
    /// `None` uses the program name.
    pub title: Option<String>,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub env: Vec<(String, String)>,
}

/// Retained output starting at `start`. `data` ends at the terminal's current offset.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Snapshot {
    pub start: u64,
    pub data: Vec<u8>,
}

/// Events on the manager's broadcast channel. Every terminal's events share one stream.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TermEvent {
    /// `offset` is the position of the first byte of `data` in the terminal's output.
    Output {
        id: String,
        offset: u64,
        data: Vec<u8>,
    },
    Exited {
        id: String,
        code: Option<i32>,
        signal: Option<i32>,
    },
    Closed {
        id: String,
    },
}

/// Resource limits for a manager.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub max_sessions: usize,
    /// Bytes of output kept per terminal.
    pub scrollback: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_sessions: 16,
            scrollback: 512 * 1024,
        }
    }
}

/// Errors callers may want to match on. They travel inside `anyhow::Error`;
/// use `err.downcast_ref::<TermError>()`.
#[derive(Debug, thiserror::Error)]
pub enum TermError {
    #[error("too many terminals")]
    TooMany,
    #[error("terminal not found: {0}")]
    NotFound(String),
    #[error("terminal size must be 1..=1000 columns and rows")]
    InvalidSize,
    #[error("terminal has exited")]
    Exited,
}

impl TermError {
    /// Short machine-readable code for RPC errors.
    pub fn code(&self) -> &'static str {
        match self {
            TermError::TooMany => "too_many",
            TermError::NotFound(_) => "not_found",
            TermError::InvalidSize => "invalid_size",
            TermError::Exited => "exited",
        }
    }
}

/// Owns all terminals of the daemon. Cheap to clone; clones share the same terminals.
#[derive(Clone)]
pub struct TerminalManager {
    shared: Arc<Shared>,
}

struct Shared {
    limits: Limits,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    events: broadcast::Sender<TermEvent>,
}

/// One terminal. Created by `open`, removed from the map by `close`.
struct Session {
    id: String,
    /// Session leader and process group id of the child (it calls setsid).
    pid: i32,
    cwd: String,
    command: Vec<String>,
    created_at: i64,
    scrollback: usize,
    /// PTY master, shared by the reader task, `input` and `resize`.
    master: AsyncFd<OwnedFd>,
    events: broadcast::Sender<TermEvent>,
    inner: Mutex<Inner>,
}

struct Inner {
    title: String,
    cols: u16,
    rows: u16,
    state: TermState,
    /// Retained output; `data[0]` is the byte at offset `start`.
    data: VecDeque<u8>,
    start: u64,
    /// Set by `close`: no more output or exit events for this terminal.
    closed: bool,
}

impl TerminalManager {
    pub fn new(limits: Limits) -> Self {
        let (events, _) = broadcast::channel(EVENT_CAPACITY);
        Self {
            shared: Arc::new(Shared {
                limits,
                sessions: Mutex::new(HashMap::new()),
                events,
            }),
        }
    }

    /// Receive events of all terminals. Lagging receivers get `RecvError::Lagged`
    /// and should re-attach to the terminals they show.
    pub fn subscribe(&self) -> broadcast::Receiver<TermEvent> {
        self.shared.events.subscribe()
    }

    /// Start a terminal. Must be called inside a tokio runtime.
    pub fn open(&self, spec: OpenSpec) -> Result<TermInfo> {
        // Held across the spawn, so that concurrent opens cannot exceed `max_sessions`.
        let mut sessions = lock(&self.shared.sessions);
        if sessions.len() >= self.shared.limits.max_sessions {
            return Err(TermError::TooMany.into());
        }
        check_size(spec.cols, spec.rows)?;
        if !spec.cwd.is_dir() {
            bail!("cwd is not a directory: {}", spec.cwd.display());
        }
        let command = spec.command.unwrap_or_else(default_command);
        let Some(program) = command.first() else {
            bail!("command is empty");
        };
        let title = spec
            .title
            .as_deref()
            .and_then(clean_title)
            .unwrap_or_else(|| program_name(program));

        let (master, slave) = open_pty(spec.cols, spec.rows).context("failed to open a pty")?;
        let master = AsyncFd::new(master).context("failed to register the pty")?;
        let mut child = spawn_child(&command, &spec.cwd, &spec.env, &slave)
            .with_context(|| format!("failed to start {program}"))?;
        // Only the child may hold the slave now; EOF on the master means it is gone.
        drop(slave);

        let id = new_id();
        let session = Arc::new(Session {
            id: id.clone(),
            pid: child.id() as i32,
            cwd: spec.cwd.to_string_lossy().into_owned(),
            command,
            created_at: now_ms(),
            scrollback: self.shared.limits.scrollback,
            master,
            events: self.shared.events.clone(),
            inner: Mutex::new(Inner {
                title,
                cols: spec.cols,
                rows: spec.rows,
                state: TermState::Running,
                data: VecDeque::new(),
                start: 0,
                closed: false,
            }),
        });

        // `wait` blocks, so it runs on the blocking pool. The reader learns about the exit here.
        let (exit_tx, exit_rx) = oneshot::channel();
        drop(tokio::task::spawn_blocking(move || {
            let status = child.wait().ok();
            // The receiver is gone only if nobody reads the session any more.
            let _ = exit_tx.send(status);
        }));
        tokio::spawn(pump(Arc::clone(&session), exit_rx));

        let info = session.info();
        sessions.insert(id, session);
        Ok(info)
    }

    /// All terminals, oldest first.
    pub fn list(&self) -> Vec<TermInfo> {
        let sessions: Vec<Arc<Session>> = lock(&self.shared.sessions).values().cloned().collect();
        let mut infos: Vec<TermInfo> = sessions.iter().map(|s| s.info()).collect();
        infos.sort_by(|a, b| a.created_at.cmp(&b.created_at).then_with(|| a.id.cmp(&b.id)));
        infos
    }

    pub fn info(&self, id: &str) -> Result<TermInfo> {
        Ok(self.get(id)?.info())
    }

    /// Returns the terminal info and the retained output from `from` (or the oldest byte kept)
    /// to the current offset.
    ///
    /// The stream is shared: call `subscribe()` before `attach()`. The snapshot ends at a chunk
    /// boundary. Keep stream events whose `offset` is at or past `snapshot.start + data.len()`
    /// and drop the earlier ones, which the snapshot already holds. If `from` is past the current
    /// offset, the snapshot is empty and starts at the offset.
    pub fn attach(&self, id: &str, from: Option<u64>) -> Result<(TermInfo, Snapshot)> {
        let session = self.get(id)?;
        let inner = lock(&session.inner);
        let end = inner.offset();
        let start = from.unwrap_or(0).max(inner.start).min(end);
        let skip = (start - inner.start) as usize;
        let data: Vec<u8> = inner.data.range(skip..).copied().collect();
        let info = session.info_locked(&inner);
        Ok((info, Snapshot { start, data }))
    }

    /// Write raw bytes to the terminal. At most 64 KiB per call. Waits while the PTY buffer
    /// is full, i.e. while the program does not read its input.
    pub async fn input(&self, id: &str, data: &[u8]) -> Result<()> {
        if data.len() > MAX_INPUT {
            bail!("input is larger than {MAX_INPUT} bytes");
        }
        let session = self.get(id)?;
        if !session.is_running() {
            return Err(TermError::Exited.into());
        }
        session.write_all(data).await
    }

    /// Change the window size. Only the stored size changes for exited terminals.
    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<()> {
        check_size(cols, rows)?;
        let session = self.get(id)?;
        let mut inner = lock(&session.inner);
        if inner.state == TermState::Running {
            set_winsize(session.master_fd(), cols, rows).context("failed to resize the pty")?;
        }
        inner.cols = cols;
        inner.rows = rows;
        Ok(())
    }

    /// Set the title. Trimmed, cut to 80 characters. Empty is an error.
    pub fn rename(&self, id: &str, title: &str) -> Result<()> {
        let title = clean_title(title).ok_or_else(|| anyhow!("title is empty"))?;
        let session = self.get(id)?;
        lock(&session.inner).title = title;
        Ok(())
    }

    /// Hang up a running terminal (SIGHUP to its group, SIGKILL after 2 s) and remove it.
    /// Does not wait for the process to exit.
    pub fn close(&self, id: &str) -> Result<()> {
        let session = lock(&self.shared.sessions)
            .remove(id)
            .ok_or_else(|| anyhow::Error::from(TermError::NotFound(id.to_owned())))?;
        detach(session);
        Ok(())
    }

    /// Close every terminal, e.g. when the daemon stops.
    pub fn shutdown_all(&self) {
        let sessions: Vec<Arc<Session>> = lock(&self.shared.sessions).drain().map(|(_, s)| s).collect();
        for session in sessions {
            detach(session);
        }
    }

    fn get(&self, id: &str) -> Result<Arc<Session>> {
        lock(&self.shared.sessions)
            .get(id)
            .cloned()
            .ok_or_else(|| anyhow::Error::from(TermError::NotFound(id.to_owned())))
    }
}

impl Session {
    fn info(&self) -> TermInfo {
        let inner = lock(&self.inner);
        self.info_locked(&inner)
    }

    fn info_locked(&self, inner: &Inner) -> TermInfo {
        TermInfo {
            id: self.id.clone(),
            title: inner.title.clone(),
            cwd: self.cwd.clone(),
            command: self.command.clone(),
            pid: self.pid,
            cols: inner.cols,
            rows: inner.rows,
            created_at: self.created_at,
            state: inner.state.clone(),
            offset: inner.offset(),
        }
    }

    fn is_running(&self) -> bool {
        lock(&self.inner).state == TermState::Running
    }

    fn master_fd(&self) -> RawFd {
        self.master.get_ref().as_raw_fd()
    }

    /// Append output, drop the oldest bytes beyond the scrollback, and announce the chunk.
    fn push_output(&self, chunk: &[u8]) {
        let mut inner = lock(&self.inner);
        if inner.closed {
            return;
        }
        let offset = inner.offset();
        inner.data.extend(chunk);
        let excess = inner.data.len().saturating_sub(self.scrollback);
        if excess > 0 {
            inner.data.drain(..excess);
            inner.start += excess as u64;
        }
        let _ = self.events.send(TermEvent::Output {
            id: self.id.clone(),
            offset,
            data: chunk.to_vec(),
        });
    }

    /// Read what the PTY already holds, without waiting. Used once the child has exited.
    fn drain(&self, buf: &mut [u8]) {
        let mut total = 0;
        while total < DRAIN_LIMIT {
            match read_fd(self.master_fd(), buf) {
                Ok(n) if n > 0 => {
                    self.push_output(&buf[..n]);
                    total += n;
                }
                _ => break,
            }
        }
    }

    /// Record the final state and announce it, unless the terminal was closed.
    fn finish(&self, status: Option<ExitStatus>) {
        let mut inner = lock(&self.inner);
        let (code, signal) = status.map_or((None, None), |st| (st.code(), st.signal()));
        inner.state = TermState::Exited { code, signal };
        if !inner.closed {
            let _ = self.events.send(TermEvent::Exited {
                id: self.id.clone(),
                code,
                signal,
            });
        }
    }

    /// Write all of `data` to the PTY, waiting while its buffer is full.
    async fn write_all(&self, mut data: &[u8]) -> Result<()> {
        while !data.is_empty() {
            let mut guard = self.master.writable().await.context("pty is not writable")?;
            match guard.try_io(|fd| write_fd(fd.get_ref().as_raw_fd(), data)) {
                Err(_would_block) => {}
                Ok(Ok(0)) => return Err(io::Error::from(ErrorKind::WriteZero).into()),
                Ok(Ok(n)) => data = &data[n..],
                Ok(Err(e)) if e.kind() == ErrorKind::Interrupted => {}
                // EIO: the child is gone and no slave is left open.
                Ok(Err(e)) if e.raw_os_error() == Some(libc::EIO) => return Err(TermError::Exited.into()),
                Ok(Err(e)) => return Err(e.into()),
            }
        }
        Ok(())
    }
}

impl Inner {
    /// Total bytes of output produced so far.
    fn offset(&self) -> u64 {
        self.start + self.data.len() as u64
    }
}

/// Reads one terminal's output and publishes its exit. Ends when the PTY is closed and the
/// child has exited, then records the final state.
async fn pump(session: Arc<Session>, mut exited: oneshot::Receiver<Option<ExitStatus>>) {
    let mut buf = vec![0u8; READ_CHUNK];
    let status = 'read: {
        loop {
            tokio::select! {
                res = &mut exited => {
                    session.drain(&mut buf);
                    break 'read res.ok().flatten();
                }
                ready = session.master.readable() => {
                    let Ok(mut guard) = ready else { break };
                    match guard.try_io(|fd| read_fd(fd.get_ref().as_raw_fd(), &mut buf)) {
                        Err(_would_block) => {}
                        Ok(Ok(n)) if n > 0 => session.push_output(&buf[..n]),
                        // EOF, or EIO once no process holds the slave open.
                        Ok(Ok(_)) => break,
                        Ok(Err(e)) if e.kind() == ErrorKind::Interrupted => {}
                        Ok(Err(_)) => break,
                    }
                }
            }
        }
        // The PTY is closed, but the child may still run: wait for it.
        exited.await.ok().flatten()
    };
    session.finish(status);
}

/// Mark a session that was removed from the map as closed, announce it, and hang up its group.
fn detach(session: Arc<Session>) {
    let running = {
        let mut inner = lock(&session.inner);
        inner.closed = true;
        let _ = session.events.send(TermEvent::Closed { id: session.id.clone() });
        inner.state == TermState::Running
    };
    if running {
        signal_group(session.pid, libc::SIGHUP);
        kill_after_grace(session);
    }
}

/// SIGKILL the group after `HANGUP_GRACE`, unless the terminal has exited by then.
/// A plain thread: it must not depend on the runtime, which may be shutting down.
fn kill_after_grace(session: Arc<Session>) {
    let spawned = std::thread::Builder::new()
        .name("terminal-hangup".into())
        .spawn(move || {
            std::thread::sleep(HANGUP_GRACE);
            if session.is_running() {
                signal_group(session.pid, libc::SIGKILL);
            }
        });
    if let Err(e) = spawned {
        tracing::warn!("failed to start the terminal kill timer: {e}");
    }
}

/// Start `command` with the PTY slave as stdio and as controlling terminal, in a new session.
fn spawn_child(command: &[String], cwd: &Path, env: &[(String, String)], slave: &OwnedFd) -> io::Result<Child> {
    let mut cmd = Command::new(&command[0]);
    cmd.args(&command[1..])
        .current_dir(cwd)
        .env("TERM", "xterm-256color")
        .env("COLORTERM", "truecolor")
        .env("BANDITO_TERM", "1")
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::from(slave.try_clone()?))
        .stdout(Stdio::from(slave.try_clone()?))
        .stderr(Stdio::from(slave.try_clone()?));
    // SAFETY: the hook runs in the forked child before exec and calls only setsid and ioctl,
    // which are async-signal-safe. Fd 0 already is the slave: std dup2s stdio before hooks run.
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() < 0 {
                return Err(io::Error::last_os_error());
            }
            if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    cmd.spawn()
}

/// Open a PTY pair of the given size. Both ends are close-on-exec; the master is non-blocking.
fn open_pty(cols: u16, rows: u16) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut winsize = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    // SAFETY: both out-pointers are valid; the name and termios arguments are optional and null.
    // libc declares these parameters as `*mut` on macOS and `*const` on glibc; `&mut` fits both.
    let rc = unsafe { libc::openpty(&mut master, &mut slave, ptr::null_mut(), ptr::null_mut(), &mut winsize) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: openpty returned two new descriptors that no other owner holds.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    set_cloexec(master.as_raw_fd())?;
    set_cloexec(slave.as_raw_fd())?;
    set_nonblocking(master.as_raw_fd())?;
    Ok((master, slave))
}

fn set_cloexec(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl with F_SETFD only changes the descriptor flags of an fd we own.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    // SAFETY: fcntl with F_GETFL / F_SETFL only reads and updates the status flags of an fd we own.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return Err(io::Error::last_os_error());
        }
    }
    Ok(())
}

fn set_winsize(fd: RawFd, cols: u16, rows: u16) -> io::Result<()> {
    let ws = libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    // SAFETY: TIOCSWINSZ reads one winsize struct, which lives for the whole call, from an fd we own.
    if unsafe { libc::ioctl(fd, libc::TIOCSWINSZ, &ws as *const libc::winsize) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn read_fd(fd: RawFd, buf: &mut [u8]) -> io::Result<usize> {
    // SAFETY: buf is a valid writable slice of buf.len() bytes; fd is an open PTY master we own.
    let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
    usize::try_from(n).map_err(|_| io::Error::last_os_error())
}

fn write_fd(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    // SAFETY: buf is a valid readable slice of buf.len() bytes; fd is an open PTY master we own.
    let n = unsafe { libc::write(fd, buf.as_ptr().cast(), buf.len()) };
    usize::try_from(n).map_err(|_| io::Error::last_os_error())
}

/// Send `sig` to the process group led by `pid`. Errors are ignored: the group may be gone.
fn signal_group(pid: i32, sig: libc::c_int) {
    // SAFETY: killpg only sends a signal; an unknown group yields ESRCH, which is ignored.
    let _ = unsafe { libc::killpg(pid, sig) };
}

fn check_size(cols: u16, rows: u16) -> Result<(), TermError> {
    if (1..=MAX_DIM).contains(&cols) && (1..=MAX_DIM).contains(&rows) {
        Ok(())
    } else {
        Err(TermError::InvalidSize)
    }
}

/// Trimmed title cut to 80 characters, or `None` if nothing is left.
fn clean_title(title: &str) -> Option<String> {
    let trimmed = title.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.chars().take(MAX_TITLE_CHARS).collect())
    }
}

/// The program's base name, used as the default title.
fn program_name(program: &str) -> String {
    Path::new(program)
        .file_name()
        .map_or_else(|| program.to_owned(), |name| name.to_string_lossy().into_owned())
}

/// The user's shell as a login shell: `$SHELL`, else `/bin/bash`, else `/bin/sh`.
fn default_command() -> Vec<String> {
    let shell = match std::env::var("SHELL") {
        Ok(shell) if !shell.is_empty() => shell,
        _ if Path::new("/bin/bash").exists() => "/bin/bash".to_owned(),
        _ => "/bin/sh".to_owned(),
    };
    vec![shell, "-l".to_owned()]
}

/// Lock a mutex. Poisoning means a bug elsewhere; the terminal state is not recoverable.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().expect("terminal state lock poisoned")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    const WAIT: Duration = Duration::from_secs(5);

    /// Closes all terminals of a test manager when the test ends, even on panic,
    /// so no shell is left behind.
    struct Cleanup(TerminalManager);

    impl Drop for Cleanup {
        fn drop(&mut self) {
            self.0.shutdown_all();
        }
    }

    fn manager() -> TerminalManager {
        TerminalManager::new(Limits::default())
    }

    fn sh_spec(cols: u16, rows: u16) -> OpenSpec {
        OpenSpec {
            cwd: std::env::temp_dir(),
            command: Some(vec!["/bin/sh".into()]),
            title: None,
            cols,
            rows,
            env: Vec::new(),
        }
    }

    fn cmd_spec(args: &[&str]) -> OpenSpec {
        OpenSpec {
            command: Some(args.iter().map(|a| a.to_string()).collect()),
            ..sh_spec(80, 24)
        }
    }

    fn term_err(err: &anyhow::Error) -> &TermError {
        err.downcast_ref::<TermError>().expect("error should be a TermError")
    }

    /// Waits until `needle` shows up in the output of terminal `id`. Output that was already
    /// read by an earlier wait is not searched again, so use needles in order.
    async fn wait_output(rx: &mut broadcast::Receiver<TermEvent>, id: &str, needle: &str) {
        let mut seen: Vec<u8> = Vec::new();
        let found = tokio::time::timeout(WAIT, async {
            loop {
                match rx.recv().await {
                    Ok(TermEvent::Output { id: got, data, .. }) if got == id => {
                        seen.extend_from_slice(&data);
                        if String::from_utf8_lossy(&seen).contains(needle) {
                            return;
                        }
                    }
                    Ok(_) => {}
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => panic!("event channel closed"),
                }
            }
        })
        .await;
        if found.is_err() {
            panic!(
                "timed out waiting for {needle:?}; output was {:?}",
                String::from_utf8_lossy(&seen)
            );
        }
    }

    /// Waits for the first event of terminal `id` that matches `pred`.
    async fn next_event(
        rx: &mut broadcast::Receiver<TermEvent>,
        id: &str,
        pred: impl Fn(&TermEvent) -> bool,
    ) -> TermEvent {
        tokio::time::timeout(WAIT, async {
            loop {
                match rx.recv().await {
                    Ok(ev) => {
                        let mine = match &ev {
                            TermEvent::Output { id: got, .. }
                            | TermEvent::Exited { id: got, .. }
                            | TermEvent::Closed { id: got } => got == id,
                        };
                        if mine && pred(&ev) {
                            return ev;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => panic!("event channel closed"),
                }
            }
        })
        .await
        .expect("timed out waiting for terminal event")
    }

    fn process_alive(pid: i32) -> bool {
        // SAFETY: signal 0 only checks that the process exists.
        let rc = unsafe { libc::kill(pid, 0) };
        rc == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
    }

    #[tokio::test]
    async fn shell_runs_input_and_streams_output() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        mgr.input(&info.id, b"echo hel\"\"lo\n").await.expect("input");
        wait_output(&mut rx, &info.id, "hello").await;
    }

    #[tokio::test]
    async fn shell_evaluates_arithmetic() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        // The echo of the typed line contains "<%s>", not "<5>", so the needle proves execution.
        mgr.input(&info.id, b"printf '<%s>\\n' $((2+3))\n")
            .await
            .expect("input");
        wait_output(&mut rx, &info.id, "<5>").await;
    }

    #[tokio::test]
    async fn resize_is_visible_to_the_program() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        mgr.resize(&info.id, 100, 40).expect("resize");
        mgr.input(&info.id, b"stty size\n").await.expect("input");
        wait_output(&mut rx, &info.id, "40 100").await;
    }

    #[tokio::test]
    async fn initial_size_is_applied() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(120, 30)).expect("open");
        assert_eq!((info.cols, info.rows), (120, 30));
        mgr.input(&info.id, b"stty size\n").await.expect("input");
        wait_output(&mut rx, &info.id, "30 120").await;
    }

    #[tokio::test]
    async fn env_has_terminal_variables() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        mgr.input(&info.id, b"echo $BANDITO_TERM-$TERM\n").await.expect("input");
        wait_output(&mut rx, &info.id, "1-xterm-256color").await;
    }

    #[tokio::test]
    async fn starts_in_cwd() {
        let dir = tempfile::tempdir().expect("tempdir");
        let canonical = dir.path().canonicalize().expect("canonicalize");
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr
            .open(OpenSpec {
                cwd: dir.path().to_path_buf(),
                ..sh_spec(80, 24)
            })
            .expect("open");
        mgr.input(&info.id, b"pwd\n").await.expect("input");
        wait_output(&mut rx, &info.id, &canonical.display().to_string()).await;
    }

    #[tokio::test]
    async fn attach_returns_output_from_offset() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        mgr.input(&info.id, b"printf '<%s>\\n' $((2+3))\n")
            .await
            .expect("input");
        wait_output(&mut rx, &info.id, "<5>").await;

        let (attached, snap) = mgr.attach(&info.id, None).expect("attach");
        assert_eq!(snap.start, 0);
        assert!(String::from_utf8_lossy(&snap.data).contains("<5>"));
        let mid = attached.offset;
        assert_eq!(snap.start + snap.data.len() as u64, mid);

        mgr.input(&info.id, b"printf '<%s>\\n' $((3+3))\n")
            .await
            .expect("input");
        wait_output(&mut rx, &info.id, "<6>").await;

        let (_, from_mid) = mgr.attach(&info.id, Some(mid)).expect("attach");
        assert_eq!(from_mid.start, mid);
        let text = String::from_utf8_lossy(&from_mid.data);
        assert!(text.contains("<6>"), "missing new output: {text:?}");
        assert!(!text.contains("<5>"), "old output leaked: {text:?}");

        let (_, past) = mgr.attach(&info.id, Some(mid + 1_000_000)).expect("attach");
        assert!(past.data.is_empty());
        assert_eq!(past.start, mgr.info(&info.id).expect("info").offset);
    }

    #[tokio::test]
    async fn scrollback_is_bounded() {
        let mgr = TerminalManager::new(Limits {
            max_sessions: 16,
            scrollback: 1024,
        });
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        mgr.input(&info.id, b"yes x | head -c 10000; echo DONE$((1+1))\n")
            .await
            .expect("input");
        wait_output(&mut rx, &info.id, "DONE2").await;

        let (_, snap) = mgr.attach(&info.id, None).expect("attach");
        assert!(snap.data.len() <= 1024, "retained {} bytes", snap.data.len());
        assert!(snap.start > 0, "old output should have been dropped");
        assert!(mgr.info(&info.id).expect("info").offset >= 10_000);
    }

    #[tokio::test]
    async fn exit_is_reported_and_terminal_stays_listed() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(cmd_spec(&["/bin/sh", "-c", "exit 3"])).expect("open");
        let ev = next_event(&mut rx, &info.id, |ev| matches!(ev, TermEvent::Exited { .. })).await;
        assert_eq!(
            ev,
            TermEvent::Exited {
                id: info.id.clone(),
                code: Some(3),
                signal: None
            }
        );

        let now = mgr.info(&info.id).expect("info");
        assert_eq!(
            now.state,
            TermState::Exited {
                code: Some(3),
                signal: None
            }
        );
        assert!(mgr.list().iter().any(|t| t.id == info.id));

        let err = mgr.input(&info.id, b"x").await.expect_err("input after exit");
        assert!(matches!(term_err(&err), TermError::Exited));
    }

    #[tokio::test]
    async fn close_kills_the_process_group() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let mut rx = mgr.subscribe();
        let info = mgr.open(cmd_spec(&["/bin/sh", "-c", "sleep 100"])).expect("open");
        assert_eq!(info.state, TermState::Running);
        mgr.close(&info.id).expect("close");

        next_event(&mut rx, &info.id, |ev| matches!(ev, TermEvent::Closed { .. })).await;
        assert!(!mgr.list().iter().any(|t| t.id == info.id));
        assert!(mgr.info(&info.id).is_err());

        let deadline = Instant::now() + Duration::from_secs(3);
        while process_alive(info.pid) {
            assert!(Instant::now() < deadline, "process {} is still alive", info.pid);
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    #[tokio::test]
    async fn too_many_sessions_is_refused() {
        let mgr = TerminalManager::new(Limits {
            max_sessions: 1,
            scrollback: 1024,
        });
        let _guard = Cleanup(mgr.clone());
        mgr.open(sh_spec(80, 24)).expect("first open");
        let err = mgr.open(sh_spec(80, 24)).expect_err("second open");
        assert!(matches!(term_err(&err), TermError::TooMany));
        assert_eq!(term_err(&err).code(), "too_many");
    }

    #[tokio::test]
    async fn invalid_size_is_refused() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let err = mgr.open(sh_spec(0, 24)).expect_err("cols=0");
        assert!(matches!(term_err(&err), TermError::InvalidSize));
        let err = mgr.open(sh_spec(80, 1001)).expect_err("rows=1001");
        assert!(matches!(term_err(&err), TermError::InvalidSize));

        let info = mgr.open(sh_spec(80, 24)).expect("open");
        let err = mgr.resize(&info.id, 0, 24).expect_err("resize cols=0");
        assert!(matches!(term_err(&err), TermError::InvalidSize));
    }

    #[tokio::test]
    async fn unknown_id_is_not_found() {
        let mgr = manager();
        let err = mgr.attach("missing", None).expect_err("attach");
        assert!(matches!(term_err(&err), TermError::NotFound(id) if id == "missing"));
        let err = mgr.close("missing").expect_err("close");
        assert_eq!(term_err(&err).code(), "not_found");
        let err = mgr.input("missing", b"x").await.expect_err("input");
        assert!(matches!(term_err(&err), TermError::NotFound(_)));
    }

    #[tokio::test]
    async fn rename_trims_and_rejects_empty() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        mgr.rename(&info.id, &"t".repeat(100)).expect("rename");
        assert_eq!(mgr.info(&info.id).expect("info").title.chars().count(), 80);
        assert!(mgr.rename(&info.id, "   ").is_err());
        assert!(mgr.rename(&info.id, "").is_err());
        assert_eq!(mgr.info(&info.id).expect("info").title.chars().count(), 80);
    }

    #[tokio::test]
    async fn default_title_is_program_name() {
        let mgr = manager();
        let _guard = Cleanup(mgr.clone());
        let info = mgr.open(sh_spec(80, 24)).expect("open");
        assert_eq!(info.title, "sh");
        let titled = mgr
            .open(OpenSpec {
                title: Some("build".into()),
                ..sh_spec(80, 24)
            })
            .expect("open");
        assert_eq!(titled.title, "build");
    }
}
