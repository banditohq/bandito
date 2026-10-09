//! A child CLI that speaks newline-delimited JSON on stdio: process group, writer task, bounded line reader, stderr tail, kill and exit reporting. Shared by the CLI runtimes.

use super::RuntimeOutput;
use anyhow::{Context, bail};
use serde_json::Value;
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStderr, ChildStdin, ChildStdout, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::timeout;

/// Capacity of the output channel. The pump waits when it is full.
const OUTPUT_CAPACITY: usize = 256;
/// Max bytes of stderr kept for `Exited { stderr_tail }`.
const STDERR_TAIL_LIMIT: usize = 4096;
/// Longest stdout/stderr line kept in memory. Longer lines are dropped whole.
pub(crate) const MAX_LINE_BYTES: usize = 8 * 1024 * 1024;
/// How long the CLI may take to exit after stdin is closed, before it is killed.
const EXIT_GRACE: Duration = Duration::from_secs(5);
/// How long to wait for the child to exit after the kill signal, before the task is aborted.
const KILL_GRACE: Duration = Duration::from_secs(2);
/// How long to wait for stderr to close after the child exited.
const STDERR_GRACE: Duration = Duration::from_secs(2);

/// Frames waiting for the writer task. `None` once the session is shut down.
pub type LineSink = Arc<Mutex<Option<mpsc::UnboundedSender<String>>>>;

/// Decides what each parsed stdout message becomes. Runs on the pump task, in order.
/// The sink lets it answer the CLI (e.g. JSON-RPC replies).
pub type Router = Box<dyn FnMut(&Value, &LineSink) -> Vec<RuntimeOutput> + Send>;

/// A running child that speaks NDJSON on stdio. Writes go through the writer
/// task; the pump task owns the child, routes its stdout and reports its exit.
pub struct JsonProcess {
    /// `None` after shutdown: the writer task then drops stdin (EOF for the CLI).
    sink: LineSink,
    /// Asks the pump to kill the child. Dropping it (process dropped) kills too.
    kill: Option<oneshot::Sender<()>>,
    /// The pump task.
    exited: JoinHandle<()>,
    /// Process group id, for killing the whole tree.
    pgid: Option<u32>,
    label: &'static str,
}

impl JsonProcess {
    /// Spawn `cmd`: sets stdin/stdout/stderr piped, kill_on_drop(true), own process group (unix);
    /// starts the writer, stderr tail and pump tasks. `label` names the CLI in logs and errors.
    pub fn spawn(
        mut cmd: Command,
        label: &'static str,
        router: Router,
    ) -> anyhow::Result<(JsonProcess, mpsc::Receiver<RuntimeOutput>)> {
        let program = cmd.as_std().get_program().to_string_lossy().into_owned();
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        configure_group(&mut cmd);

        let mut child = cmd.spawn().with_context(|| format!("failed to start {program}"))?;
        // Unix: the child leads its own process group, so the whole tree can be killed.
        let pgid = if cfg!(unix) { child.id() } else { None };
        let stdin = piped(child.stdin.take(), "stdin", label)?;
        let stdout = piped(child.stdout.take(), "stdout", label)?;
        let stderr = piped(child.stderr.take(), "stderr", label)?;

        let (line_tx, line_rx) = mpsc::unbounded_channel();
        let sink: LineSink = Arc::new(Mutex::new(Some(line_tx)));
        tokio::spawn(writer_task(stdin, line_rx, label));

        let stderr_tail = Arc::new(Mutex::new(String::new()));
        let stderr_task = spawn_stderr(stderr, Arc::clone(&stderr_tail));
        let (tx, rx) = mpsc::channel(OUTPUT_CAPACITY);
        let (kill_tx, kill_rx) = oneshot::channel();
        let pump = Pump {
            child,
            pgid,
            router,
            sink: Arc::clone(&sink),
            tx,
            kill: kill_rx,
            killed: false,
            stderr: stderr_tail,
            stderr_task,
            label,
        };
        let exited = tokio::spawn(pump.run(stdout));

        let proc = JsonProcess {
            sink,
            kill: Some(kill_tx),
            exited,
            pgid,
            label,
        };
        Ok((proc, rx))
    }

    /// A clone of the sink, for code that answers the CLI outside the router.
    pub fn sink(&self) -> LineSink {
        Arc::clone(&self.sink)
    }

    /// Queue one NDJSON frame for the CLI.
    pub fn send(&self, v: &Value) -> anyhow::Result<()> {
        push_line(&self.sink, self.label, v)
    }

    /// Close stdin, give the CLI `EXIT_GRACE` to exit, then kill its process group.
    pub async fn shutdown(mut self) {
        // Closing the channel ends the writer task, which drops stdin: EOF for the CLI.
        let _ = locked(&self.sink).take();
        if timeout(EXIT_GRACE, &mut self.exited).await.is_ok() {
            return;
        }
        if let Some(kill) = self.kill.take() {
            let _ = kill.send(());
        }
        if timeout(KILL_GRACE, &mut self.exited).await.is_err() {
            if let Some(pgid) = self.pgid {
                kill_group(pgid);
            }
            // Last resort: dropping the task drops the child (kill_on_drop).
            self.exited.abort();
        }
    }
}

/// The stdout side of a process. Owns the child, routes lines, and reports
/// `Exited` at the end.
struct Pump {
    child: Child,
    /// Process group id (unix). Kills go to the whole group.
    pgid: Option<u32>,
    router: Router,
    sink: LineSink,
    tx: mpsc::Sender<RuntimeOutput>,
    /// Fires on shutdown. A dropped process closes it too, which also kills.
    kill: oneshot::Receiver<()>,
    killed: bool,
    stderr: Arc<Mutex<String>>,
    stderr_task: JoinHandle<()>,
    label: &'static str,
}

impl Pump {
    fn kill_now(&mut self) {
        self.killed = true;
        kill_tree(&mut self.child, self.pgid);
    }

    async fn run(mut self, stdout: ChildStdout) {
        let mut reader = BufReader::new(stdout);
        loop {
            let read = tokio::select! {
                read = read_capped_line(&mut reader, MAX_LINE_BYTES) => read,
                _ = &mut self.kill, if !self.killed => {
                    self.kill_now();
                    continue;
                }
            };
            let line = match read {
                Ok(Line::Text(text)) => text,
                Ok(Line::TooLong) => {
                    tracing::warn!(
                        "dropped a {} stdout line longer than {MAX_LINE_BYTES} bytes",
                        self.label
                    );
                    continue;
                }
                Ok(Line::Eof) => break,
                Err(e) => {
                    tracing::warn!("{} stdout read failed: {e}", self.label);
                    self.kill_now();
                    break;
                }
            };
            let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                tracing::debug!("skipping non-JSON line from {} stdout", self.label);
                continue;
            };
            for output in (self.router)(&msg, &self.sink) {
                if self.killed {
                    break;
                }
                // Shutdown must not wait behind a full channel.
                let sent = tokio::select! {
                    result = self.tx.send(output) => result.is_ok(),
                    _ = &mut self.kill, if !self.killed => false,
                };
                if !sent {
                    // A kill was requested, or nobody listens any more.
                    self.kill_now();
                    break;
                }
            }
        }

        let status = loop {
            tokio::select! {
                status = self.child.wait() => break status.ok(),
                _ = &mut self.kill, if !self.killed => self.kill_now(),
            }
        };
        if let Some(pgid) = self.pgid {
            // Whatever the CLI left in its group (e.g. background jobs) goes too.
            kill_group(pgid);
        }
        let code = status.and_then(|s| s.code());
        if timeout(STDERR_GRACE, &mut self.stderr_task).await.is_err() {
            self.stderr_task.abort();
        }
        let stderr_tail = locked(&self.stderr).clone();
        tokio::select! {
            _ = self.tx.send(RuntimeOutput::Exited { code, stderr_tail }) => {}
            _ = &mut self.kill, if !self.killed => {}
        }
    }
}

/// Owns the child's stdin. Writes queued frames in order. When the channel
/// closes (shutdown), it drops stdin.
async fn writer_task(mut stdin: ChildStdin, mut lines: mpsc::UnboundedReceiver<String>, label: &'static str) {
    while let Some(line) = lines.recv().await {
        let written = match stdin.write_all(line.as_bytes()).await {
            Ok(()) => stdin.flush().await,
            Err(e) => Err(e),
        };
        if let Err(e) = written {
            tracing::warn!("{label} stdin write failed: {e}");
            break;
        }
    }
}

/// Queue one NDJSON frame for the writer task. Errors when the session is
/// closed or the writer task has stopped.
pub fn push_line(sink: &LineSink, label: &str, v: &Value) -> anyhow::Result<()> {
    let guard = locked(sink);
    let Some(tx) = guard.as_ref() else {
        bail!("{label} session is closed");
    };
    let mut line = v.to_string();
    line.push('\n');
    tx.send(line).map_err(|_| anyhow::anyhow!("{label} session is closed"))
}

/// Collect stderr into a bounded tail shared with the pump.
fn spawn_stderr(stderr: ChildStderr, tail: Arc<Mutex<String>>) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut reader = BufReader::new(stderr);
        loop {
            match read_capped_line(&mut reader, MAX_LINE_BYTES).await {
                Ok(Line::Text(line)) => {
                    let mut shared = locked(&tail);
                    shared.push_str(&line);
                    shared.push('\n');
                    trim_tail(&mut shared);
                }
                Ok(Line::TooLong) => {}
                Ok(Line::Eof) | Err(_) => break,
            }
        }
    })
}

/// Keep only the last `STDERR_TAIL_LIMIT` bytes, cut on a char boundary.
fn trim_tail(tail: &mut String) {
    if tail.len() <= STDERR_TAIL_LIMIT {
        return;
    }
    let mut start = tail.len() - STDERR_TAIL_LIMIT;
    while !tail.is_char_boundary(start) {
        start += 1;
    }
    tail.drain(..start);
}

/// One line read by [`read_capped_line`].
#[derive(Debug, PartialEq)]
pub(crate) enum Line {
    /// Stream ended with nothing left to read.
    Eof,
    /// Line without its `\n`. Invalid UTF-8 is replaced, not rejected.
    Text(String),
    /// Longer than the limit. The bytes were discarded up to the newline.
    TooLong,
}

/// Read one `\n`-terminated line. Memory stays bounded by `limit`: a longer
/// line is consumed to its end and reported as [`Line::TooLong`].
pub(crate) async fn read_capped_line<R>(reader: &mut R, limit: usize) -> std::io::Result<Line>
where
    R: AsyncBufRead + Unpin,
{
    let mut buf: Vec<u8> = Vec::new();
    let mut too_long = false;
    let mut read_any = false;
    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            if !read_any {
                return Ok(Line::Eof);
            }
            break;
        }
        read_any = true;
        let newline = chunk.iter().position(|&b| b == b'\n');
        let content_len = newline.unwrap_or(chunk.len());
        if !too_long {
            if buf.len() + content_len > limit {
                too_long = true;
                buf = Vec::new();
            } else {
                buf.extend_from_slice(&chunk[..content_len]);
            }
        }
        let consumed = newline.map_or(chunk.len(), |i| i + 1);
        reader.consume(consumed);
        if newline.is_some() {
            break;
        }
    }
    Ok(if too_long {
        Line::TooLong
    } else {
        Line::Text(String::from_utf8_lossy(&buf).into_owned())
    })
}

/// Start the child in its own process group (unix), so a kill can reach its descendants.
#[cfg(unix)]
fn configure_group(cmd: &mut Command) {
    cmd.process_group(0);
}

#[cfg(not(unix))]
fn configure_group(_cmd: &mut Command) {}

/// SIGKILL to the whole process group.
#[cfg(unix)]
fn kill_group(pgid: u32) {
    // SAFETY: killpg only sends a signal. An unknown group yields ESRCH, which is ignored.
    let _ = unsafe { libc::killpg(pgid as i32, libc::SIGKILL) };
}

#[cfg(not(unix))]
fn kill_group(_pgid: u32) {}

/// Kill the child's whole group, or only the child when no group is known.
fn kill_tree(child: &mut Child, pgid: Option<u32>) {
    match pgid {
        Some(pgid) => kill_group(pgid),
        None => {
            let _ = child.start_kill();
        }
    }
}

/// The child's pipe, or an error if it was not set up as one.
fn piped<T>(pipe: Option<T>, name: &str, label: &str) -> anyhow::Result<T> {
    pipe.ok_or_else(|| anyhow::anyhow!("{label} {name} is not piped"))
}

/// Lock a mutex, ignoring poisoning (the data stays usable).
pub(crate) fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn read_capped_line_replaces_invalid_utf8() {
        let mut r = BufReader::new(&b"ab\xff\n{}\n"[..]);
        assert_eq!(
            read_capped_line(&mut r, 1024).await.expect("io"),
            Line::Text("ab\u{FFFD}".into())
        );
        assert_eq!(
            read_capped_line(&mut r, 1024).await.expect("io"),
            Line::Text("{}".into())
        );
        assert_eq!(read_capped_line(&mut r, 1024).await.expect("io"), Line::Eof);
    }

    #[tokio::test]
    async fn read_capped_line_drops_overlong_line_and_keeps_going() {
        let mut r = BufReader::new(&b"abcdefgh\nxy\n"[..]);
        assert_eq!(read_capped_line(&mut r, 4).await.expect("io"), Line::TooLong);
        assert_eq!(read_capped_line(&mut r, 4).await.expect("io"), Line::Text("xy".into()));
        assert_eq!(read_capped_line(&mut r, 4).await.expect("io"), Line::Eof);
    }

    #[tokio::test]
    async fn read_capped_line_returns_unterminated_tail() {
        let mut r = BufReader::new(&b"tail"[..]);
        assert_eq!(
            read_capped_line(&mut r, 1024).await.expect("io"),
            Line::Text("tail".into())
        );
        assert_eq!(read_capped_line(&mut r, 1024).await.expect("io"), Line::Eof);
    }

    #[test]
    fn trim_tail_keeps_last_bytes_on_char_boundary() {
        // 'я' is 2 bytes and starts at even offsets; the naive cut at 1905 is mid-char.
        let mut s = format!("{}a", "я".repeat(3000));
        trim_tail(&mut s);
        assert_eq!(s.len(), 4095);
        assert!(s.ends_with('a'));
        assert!(s.starts_with('я'));
    }
}
