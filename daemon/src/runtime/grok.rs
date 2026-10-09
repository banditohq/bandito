//! Grok adapter. Implemented in a later step; see tests/grok_runtime.rs for the contract.

use super::{Runtime, RuntimeKind, RuntimeStatus, SpawnConfig, Spawned};
use async_trait::async_trait;

pub struct GrokRuntime {
    program: String,
}

impl GrokRuntime {
    pub fn new() -> Self {
        Self::with_program("grok")
    }

    pub fn with_program(program: &str) -> Self {
        Self {
            program: program.to_string(),
        }
    }
}

impl Default for GrokRuntime {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Runtime for GrokRuntime {
    fn kind(&self) -> RuntimeKind {
        RuntimeKind::Grok
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
