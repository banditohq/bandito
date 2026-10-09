//! Codex adapter. Implemented in a later step; see tests/codex_runtime.rs for the contract.

use super::{Runtime, RuntimeKind, RuntimeStatus, SpawnConfig, Spawned};
use async_trait::async_trait;

pub struct CodexRuntime {
    program: String,
}

impl CodexRuntime {
    pub fn new() -> Self {
        Self::with_program("codex")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
        }
    }
}

impl Default for CodexRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Runtime for CodexRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Codex
    }

    async fn status(&self) -> RuntimeStatus {
        let _ = &self.program;
        todo!()
    }

    async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned> {
        let _ = cfg;
        todo!()
    }
}
