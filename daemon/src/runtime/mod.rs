//! Runtime adapters: drive an agent CLI (or an API loop) and translate its
//! protocol into [`EventBody`]s and approval requests.

use crate::event::{Decision, EventBody};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use tokio::sync::mpsc;

pub mod claude;

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
    /// The CLI's own session/thread id, to store for resume.
    SessionId(String),
    /// The child process ended; no more output will follow.
    Exited {
        code: Option<i32>,
        stderr_tail: String,
    },
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

#[async_trait]
pub trait Runtime: Send + Sync {
    fn kind(&self) -> RuntimeKind;
    async fn status(&self) -> RuntimeStatus;
    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned>;
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
