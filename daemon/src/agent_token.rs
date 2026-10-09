//! Session tokens of agents. Every runtime session gets its own token in `BANDITO_AGENT_TOKEN`,
//! and the agent's crew server presents it on `agent.sock` to say which agent it speaks for.
//! The daemon keeps only the SHA-256 of each token, in memory: a restart invalidates them all,
//! and ending a session revokes its token. See docs/ARCHITECTURE.md#trust-model.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};

/// Every agent token starts with this, so a leaked one is easy to recognise.
pub const PREFIX: &str = "bat_";

type Hash = [u8; 32];

/// The live agent tokens, by hash, and the token of each agent.
#[derive(Default)]
pub struct AgentTokens {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    by_hash: HashMap<Hash, String>,
    by_agent: HashMap<String, Hash>,
}

impl AgentTokens {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// A new token for a session of `agent_id`. The agent's previous token stops working.
    /// The returned guard revokes this token when it is dropped, so it lives as long as the session.
    pub fn issue(self: &Arc<Self>, agent_id: &str) -> (String, SessionToken) {
        let bytes: [u8; 32] = rand::random();
        let token = format!("{PREFIX}{}", URL_SAFE_NO_PAD.encode(bytes));
        let hash = hash_of(&token);
        {
            let mut inner = self.lock();
            if let Some(old) = inner.by_agent.insert(agent_id.to_string(), hash) {
                inner.by_hash.remove(&old);
            }
            inner.by_hash.insert(hash, agent_id.to_string());
        }
        let guard = SessionToken {
            tokens: Arc::clone(self),
            agent_id: agent_id.to_string(),
            hash,
        };
        (token, guard)
    }

    /// The agent a token speaks for, while the token is live.
    pub fn agent_for(&self, token: &str) -> Option<String> {
        self.lock().by_hash.get(&hash_of(token)).cloned()
    }

    fn revoke(&self, agent_id: &str, hash: &Hash) {
        let mut inner = self.lock();
        inner.by_hash.remove(hash);
        if inner.by_agent.get(agent_id) == Some(hash) {
            inner.by_agent.remove(agent_id);
        }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Keeps one agent token live. Dropping it revokes the token.
pub struct SessionToken {
    tokens: Arc<AgentTokens>,
    agent_id: String,
    hash: Hash,
}

impl Drop for SessionToken {
    fn drop(&mut self) {
        self.tokens.revoke(&self.agent_id, &self.hash);
    }
}

fn hash_of(token: &str) -> Hash {
    Sha256::digest(token.as_bytes()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token_names_its_agent_and_has_the_prefix() {
        let tokens = AgentTokens::new();
        let (token, _guard) = tokens.issue("agent-a");
        assert!(token.starts_with(PREFIX));
        // 32 random bytes in unpadded base64url: 43 characters after the prefix.
        assert_eq!(token.len(), PREFIX.len() + 43);
        assert_eq!(tokens.agent_for(&token).as_deref(), Some("agent-a"));
        assert_eq!(tokens.agent_for("bat_guess"), None);
    }

    #[test]
    fn two_agents_get_different_tokens() {
        let tokens = AgentTokens::new();
        let (a, _ga) = tokens.issue("agent-a");
        let (b, _gb) = tokens.issue("agent-b");
        assert_ne!(a, b);
        assert_eq!(tokens.agent_for(&a).as_deref(), Some("agent-a"));
        assert_eq!(tokens.agent_for(&b).as_deref(), Some("agent-b"));
    }

    #[test]
    fn dropping_the_guard_ends_the_token() {
        let tokens = AgentTokens::new();
        let (token, guard) = tokens.issue("agent-a");
        assert!(tokens.agent_for(&token).is_some());
        drop(guard);
        assert_eq!(tokens.agent_for(&token), None);
    }

    #[test]
    fn a_new_session_replaces_the_previous_token() {
        let tokens = AgentTokens::new();
        let (old, old_guard) = tokens.issue("agent-a");
        let (new, _new_guard) = tokens.issue("agent-a");
        assert_eq!(tokens.agent_for(&old), None);
        assert_eq!(tokens.agent_for(&new).as_deref(), Some("agent-a"));
        // The old session ending must not revoke the new token.
        drop(old_guard);
        assert_eq!(tokens.agent_for(&new).as_deref(), Some("agent-a"));
    }
}
