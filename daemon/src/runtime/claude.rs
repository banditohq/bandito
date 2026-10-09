//! Claude Code adapter: drives the official `claude` CLI in print mode with
//! stream-json on both sides and answers permission prompts as the host.
//! Protocol notes and a real transcript: `tests/fixtures/claude/`.

use super::{ApprovalRequest, Runtime, RuntimeKind, RuntimeOutput, RuntimeStatus, Session, SpawnConfig, Spawned};
use crate::event::{Decision, EventBody};
use async_trait::async_trait;
use serde_json::Value;

/// Message sent back to Claude when the human (or policy) says no.
pub const DENY_MESSAGE: &str = "Denied by the user in Bandito";

pub struct ClaudeRuntime {
    program: String,
}

impl ClaudeRuntime {
    pub fn new() -> Self {
        Self::with_program("claude")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
        }
    }
}

impl Default for ClaudeRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Runtime for ClaudeRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Claude
    }

    async fn status(&self) -> RuntimeStatus {
        todo!()
    }

    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned> {
        let _ = cfg;
        todo!()
    }
}

/// One-line human title for a tool call.
pub fn tool_title(tool: &str, input: &Value) -> String {
    let _ = (tool, input);
    todo!()
}

/// Map one stdout line (already parsed) to outputs. Pure, so it is unit-testable.
/// `control_request{can_use_tool}` is NOT handled here (it needs session state).
pub fn map_message(msg: &Value) -> Vec<RuntimeOutput> {
    let _ = (msg, EventBody::Error { message: String::new() });
    todo!()
}

/// Build the approval request for a `can_use_tool` control request.
pub fn approval_from_control(msg: &Value) -> Option<ApprovalRequest> {
    let _ = msg;
    todo!()
}

#[allow(dead_code)]
struct ClaudeSession;

#[async_trait]
impl Session for ClaudeSession {
    async fn send(&mut self, text: &str) -> anyhow::Result<()> {
        let _ = text;
        todo!()
    }
    async fn interrupt(&mut self) -> anyhow::Result<()> {
        todo!()
    }
    async fn resolve(&mut self, key: &str, decision: Decision) -> anyhow::Result<()> {
        let _ = (key, decision);
        todo!()
    }
    async fn shutdown(self: Box<Self>) {
        todo!()
    }
}
