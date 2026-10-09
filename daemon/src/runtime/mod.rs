//! Runtime adapters: drive an agent CLI (or an API loop) and translate its
//! protocol into [`EventBody`]s and approval requests.

use crate::event::{Decision, EventBody, truncate_output};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

pub use crate::event::Plan;

pub mod claude;
pub mod codex;
pub mod grok;
pub mod process;
pub mod sandbox;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeKind {
    Claude,
    Codex,
    Grok,
    Api,
}

impl RuntimeKind {
    pub fn as_str(self) -> &'static str {
        match self {
            RuntimeKind::Claude => "claude",
            RuntimeKind::Codex => "codex",
            RuntimeKind::Grok => "grok",
            RuntimeKind::Api => "api",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        Some(match s {
            "claude" => RuntimeKind::Claude,
            "codex" => RuntimeKind::Codex,
            "grok" => RuntimeKind::Grok,
            "api" => RuntimeKind::Api,
            _ => return None,
        })
    }
}

/// What `runtimes.status` reports for one runtime.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuntimeStatus {
    pub kind: RuntimeKind,
    pub installed: bool,
    pub version: Option<String>,
    /// `None` when we can't tell without starting a session.
    pub logged_in: Option<bool>,
    pub detail: Option<String>,
}

/// A tool call the CLI wants permission for. `key` is opaque to the daemon
/// and is handed back to [`Session::resolve`].
#[derive(Debug, Clone, PartialEq)]
pub struct ApprovalRequest {
    pub key: String,
    pub call_id: String,
    pub tool: String,
    /// One line for humans, e.g. the shell command.
    pub title: String,
    pub command: Option<String>,
    pub diff: Option<String>,
    /// File paths the call writes to, if known (used by the policy).
    pub paths: Vec<String>,
    pub input: Value,
}

/// Output of a running session.
#[derive(Debug, Clone, PartialEq)]
pub enum RuntimeOutput {
    Event(EventBody),
    Approval(ApprovalRequest),
    /// The CLI withdrew a permission request (e.g. after an interrupt); the approval can no longer be answered.
    ApprovalCancelled {
        key: String,
    },
    /// The CLI's own session/thread id, to store for resume.
    SessionId(String),
    /// Context size the chapter holds after this turn, when the CLI reports it
    /// separately from the turn's total usage (Claude: the last API call of a
    /// multi-step turn). Without it, the turn's usage is the context size.
    ContextSize(u64),
    /// The child process ended; no more output will follow.
    Exited {
        code: Option<i32>,
        stderr_tail: String,
    },
}

/// A path as text for an argument list or a config file. A path that is not valid UTF-8 cannot be
/// given faithfully, so the session that needs it does not start (fail closed).
pub fn path_text(path: &Path) -> anyhow::Result<&str> {
    path.to_str().ok_or_else(|| {
        anyhow::anyhow!(
            "the path {} is not valid UTF-8; the agent session cannot start",
            path.to_string_lossy()
        )
    })
}

#[derive(Debug, Clone, Default)]
pub struct SpawnConfig {
    pub agent_id: String,
    pub cwd: PathBuf,
    pub model: Option<String>,
    pub system_prompt: Option<String>,
    /// Runtime session id to resume.
    pub resume: Option<String>,
    /// Program to run instead of the default (`claude`, `codex`, `grok`).
    /// Tests point this at a fake CLI.
    pub program: Option<PathBuf>,
    /// MCP server to inject (the crew server): program + args.
    pub mcp: Option<(PathBuf, Vec<String>)>,
    /// Extra environment for the child.
    pub env: Vec<(String, String)>,
    /// How hard the model thinks; each runtime maps or rejects it.
    pub effort: Option<crate::store::Effort>,
    /// Folders besides `cwd` the agent may read and write (its home).
    pub extra_dirs: Vec<PathBuf>,
    /// Where the CLI runs (see docs/ARCHITECTURE.md#workspaces). `None` = the server itself.
    pub workspace: Option<crate::workspace::WorkspaceSpec>,
    /// This session's agent token: the CLI gets it as `BANDITO_AGENT_TOKEN`. Its crew server reads
    /// it from a file instead (see docs/ARCHITECTURE.md#trust-model).
    pub agent_token: Option<String>,
    /// Where a Claude MCP config file goes (owner-only, removed with the session). `None`: inline.
    pub agent_mcp_file: Option<PathBuf>,
    /// The sandbox for this session, on macOS (see `sandbox`). `None`: not sandboxed.
    pub sandbox: Option<sandbox::SandboxPolicy>,
}

/// A live session with one agent CLI.
#[async_trait]
pub trait Session: Send {
    /// Send a user message. Starts a turn.
    async fn send(&mut self, text: &str) -> anyhow::Result<()>;
    /// Stop the current turn.
    async fn interrupt(&mut self) -> anyhow::Result<()>;
    /// Answer an [`ApprovalRequest`] by its `key`.
    async fn resolve(&mut self, key: &str, decision: Decision) -> anyhow::Result<()>;
    /// Close stdin and wait for the child to exit (kill after a grace period).
    async fn shutdown(self: Box<Self>);
}

pub struct Spawned {
    pub session: Box<dyn Session>,
    pub output: mpsc::Receiver<RuntimeOutput>,
}

/// Copy of a tool input with every string longer than `max_string_bytes` cut
/// (via [`truncate_output`]). Used for event payloads, so a 100 KB `Write`
/// does not end up in the store. The original input still goes back to the CLI.
pub fn clip_input(v: &Value, max_string_bytes: usize) -> Value {
    match v {
        Value::String(s) if s.len() > max_string_bytes => Value::String(truncate_output(s, max_string_bytes)),
        Value::Array(items) => Value::Array(items.iter().map(|x| clip_input(x, max_string_bytes)).collect()),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, x)| (k.clone(), clip_input(x, max_string_bytes)))
                .collect(),
        ),
        _ => v.clone(),
    }
}

#[async_trait]
pub trait Runtime: Send + Sync {
    fn kind(&self) -> RuntimeKind;
    async fn status(&self) -> RuntimeStatus;
    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned>;
    /// Ask the CLI for current rate-limit windows without running a turn.
    /// `Ok(None)` when the runtime can't be asked (the cache then keeps the
    /// last windows a turn reported).
    async fn refresh_usage(&self) -> anyhow::Result<Option<Vec<crate::event::LimitWindow>>> {
        Ok(None)
    }
    /// The account's subscription (`Max ×20`, `Plus`, …), read without starting a turn.
    /// `Ok(None)` when the runtime does not say, or cannot be asked; the stored plan then stays.
    async fn account_plan(&self) -> anyhow::Result<Option<Plan>> {
        Ok(None)
    }
}

/// `text` with its first character upper-cased (`prolite` → `Prolite`). Used for plan names we do not know.
pub(crate) fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

/// What a login probe found: whether the CLI is logged in (`None`: it could not say) and the plan it names, if any.
#[derive(Debug, Clone, PartialEq)]
pub struct LoginCheck {
    pub logged_in: Option<bool>,
    pub plan: Option<Plan>,
}

impl LoginCheck {
    /// The CLI could not say: no login state and no plan.
    pub fn unknown() -> Self {
        Self {
            logged_in: None,
            plan: None,
        }
    }
}

/// A login probe that runs longer than this counts as unknown.
pub const LOGIN_PROBE_TIMEOUT: Duration = Duration::from_secs(5);
/// A login answer is reused for this long before the CLI is asked again.
pub const LOGIN_CACHE_TTL: Duration = Duration::from_secs(60);

/// What a CLI printed and how it ended.
#[derive(Debug, Clone, PartialEq)]
pub struct ProbeOutput {
    /// `None` when the process was ended by a signal.
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

/// Runs `program args` with `env` added to the daemon's environment, stdin closed, and gives up after `timeout`.
/// `None` when it cannot start or does not finish in time; a child still running then is killed.
pub async fn run_probe(
    program: &str,
    args: &[&str],
    env: &[(String, String)],
    timeout: Duration,
) -> Option<ProbeOutput> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args)
        .envs(env.iter().map(|(k, v)| (k, v)))
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true);
    let out = tokio::time::timeout(timeout, cmd.output()).await.ok()?.ok()?;
    Some(ProbeOutput {
        code: out.status.code(),
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&out.stderr).into_owned(),
    })
}

/// The last login answer of one runtime, reused for `ttl`. A caller that comes while a probe is running
/// waits for it, so the CLI is asked once, not once per caller.
pub struct LoginCache {
    ttl: Duration,
    last: tokio::sync::Mutex<Option<(Instant, LoginCheck)>>,
}

impl LoginCache {
    pub fn new(ttl: Duration) -> Self {
        Self {
            ttl,
            last: tokio::sync::Mutex::new(None),
        }
    }

    /// The cached answer when it is fresh, else the answer of `probe`, which is then cached.
    pub async fn check<F, Fut>(&self, probe: F) -> LoginCheck
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = LoginCheck>,
    {
        let mut last = self.last.lock().await;
        if let Some((at, answer)) = last.as_ref()
            && at.elapsed() < self.ttl
        {
            return answer.clone();
        }
        let answer = probe().await;
        *last = Some((Instant::now(), answer.clone()));
        answer
    }
}

impl Default for LoginCache {
    fn default() -> Self {
        Self::new(LOGIN_CACHE_TTL)
    }
}

/// `program --version` → first line, or `None` if it can't run.
pub async fn probe_version(program: &str) -> Option<String> {
    let out = tokio::process::Command::new(program)
        .arg("--version")
        .output()
        .await
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .next()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty())
}

#[cfg(all(test, unix))]
mod path_tests {
    use super::*;
    use std::os::unix::ffi::OsStrExt;

    #[test]
    fn a_path_that_is_not_utf8_has_no_text_form() {
        let bad = Path::new(std::ffi::OsStr::from_bytes(b"/tmp/\xff/bandito"));
        let err = path_text(bad).unwrap_err().to_string();
        assert!(err.contains("not valid UTF-8"), "{err}");
        assert_eq!(path_text(Path::new("/tmp/ok")).unwrap(), "/tmp/ok");
    }
}

#[cfg(all(test, unix))]
mod login_probe_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    async fn answer_once(calls: &AtomicUsize, logged_in: bool) -> LoginCheck {
        calls.fetch_add(1, Ordering::SeqCst);
        tokio::time::sleep(Duration::from_millis(30)).await;
        LoginCheck {
            logged_in: Some(logged_in),
            plan: None,
        }
    }

    #[test]
    fn unknown_has_no_login_and_no_plan() {
        assert_eq!(
            LoginCheck::unknown(),
            LoginCheck {
                logged_in: None,
                plan: None
            }
        );
    }

    #[tokio::test]
    async fn run_probe_returns_the_code_and_both_streams() {
        let out = run_probe(
            "/bin/sh",
            &["-c", "echo out; echo err >&2; exit 3"],
            &[],
            Duration::from_secs(5),
        )
        .await
        .expect("the program ran");
        assert_eq!(out.code, Some(3));
        assert_eq!(out.stdout.trim(), "out");
        assert_eq!(out.stderr.trim(), "err");
    }

    #[tokio::test]
    async fn run_probe_passes_the_environment_and_reads_no_stdin() {
        let out = run_probe(
            "/bin/sh",
            &["-c", "echo \"$PROBE_VALUE\"; read line; echo \"stdin:$line\""],
            &[("PROBE_VALUE".into(), "hi".into())],
            Duration::from_secs(5),
        )
        .await
        .expect("the program ran");
        assert_eq!(out.stdout.trim(), "hi\nstdin:");
    }

    #[tokio::test]
    async fn run_probe_is_none_for_a_missing_program() {
        assert!(
            run_probe("/nonexistent/probe", &[], &[], Duration::from_secs(5))
                .await
                .is_none()
        );
    }

    #[tokio::test]
    async fn run_probe_is_none_after_its_timeout() {
        let started = std::time::Instant::now();
        let out = run_probe("/bin/sh", &["-c", "sleep 30"], &[], Duration::from_millis(200)).await;
        assert!(out.is_none());
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[tokio::test]
    async fn login_cache_reuses_an_answer_for_its_ttl() {
        let cache = LoginCache::new(Duration::from_secs(60));
        let calls = AtomicUsize::new(0);
        for _ in 0..3 {
            let got = cache.check(|| answer_once(&calls, true)).await;
            assert_eq!(got.logged_in, Some(true));
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn login_cache_asks_again_after_the_ttl() {
        let cache = LoginCache::new(Duration::from_millis(40));
        let calls = AtomicUsize::new(0);
        cache.check(|| answer_once(&calls, true)).await;
        tokio::time::sleep(Duration::from_millis(80)).await;
        let got = cache.check(|| answer_once(&calls, false)).await;
        assert_eq!(got.logged_in, Some(false));
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn login_cache_runs_one_probe_for_concurrent_callers() {
        let cache = LoginCache::new(Duration::from_secs(60));
        let calls = AtomicUsize::new(0);
        let (a, b, c) = tokio::join!(
            cache.check(|| answer_once(&calls, true)),
            cache.check(|| answer_once(&calls, true)),
            cache.check(|| answer_once(&calls, true)),
        );
        assert_eq!([a.logged_in, b.logged_in, c.logged_in], [Some(true); 3]);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
}
