//! Session tokens of agents. Every runtime session gets its own token, in `BANDITO_AGENT_TOKEN` for
//! the CLI and in a file under the run folder for its crew server (`bandito mcp --token-file`), so the
//! token never appears in an argument list. The agent's crew server presents it on `agent.sock` to say
//! which agent it speaks for. The daemon keeps only the SHA-256 of each token, in memory: a restart
//! invalidates them all, and ending a session revokes its token and removes its files.
//! See docs/ARCHITECTURE.md#trust-model.

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{DirBuilder, OpenOptions, Permissions};
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};

/// Every agent token starts with this, so a leaked one is easy to recognise.
pub const PREFIX: &str = "bat_";
/// Files of the run folder that belong to sessions: the token, and the Claude MCP config.
const FILE_START: &str = "agent-";
const TOKEN_SUFFIX: &str = ".token";
const CONFIG_SUFFIX: &str = ".mcp.json";
const TEMP_SUFFIX: &str = ".tmp";

type Hash = [u8; 32];

/// The live agent tokens, by hash, and the token of each agent.
#[derive(Default)]
pub struct AgentTokens {
    inner: Mutex<Inner>,
    /// The run folder (`$BANDITO_HOME/run`). `None`: tokens are kept in memory only.
    run_dir: Mutex<Option<PathBuf>>,
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

    /// The daemon's data folder: the parent of the run folder, once one is set.
    pub fn home(&self) -> Option<PathBuf> {
        let run = self.run_dir.lock().unwrap_or_else(|e| e.into_inner()).clone();
        run.and_then(|dir| dir.parent().map(Path::to_path_buf))
    }

    /// Makes `dir` the run folder (mode 0700) and removes the session files a previous daemon left in it.
    pub fn set_run_dir(&self, dir: &Path) -> io::Result<()> {
        // A symlink where the folder should be is removed, and a folder made in its place.
        if std::fs::symlink_metadata(dir).is_ok_and(|m| m.file_type().is_symlink()) {
            std::fs::remove_file(dir)?;
        }
        DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        if !std::fs::symlink_metadata(dir)?.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "the run folder is not a folder",
            ));
        }
        std::fs::set_permissions(dir, Permissions::from_mode(0o700))?;
        for entry in std::fs::read_dir(dir)? {
            let entry = entry?;
            let name = entry.file_name();
            let name = name.to_string_lossy();
            let ours = name.starts_with(FILE_START)
                && [TOKEN_SUFFIX, CONFIG_SUFFIX, TEMP_SUFFIX]
                    .iter()
                    .any(|s| name.ends_with(s));
            if ours {
                let _ = std::fs::remove_file(entry.path());
            }
        }
        *self.run_dir.lock().unwrap_or_else(|e| e.into_inner()) = Some(dir.to_path_buf());
        Ok(())
    }

    /// A new token for a session of `agent_id`. The agent's previous token stops working. With a run
    /// folder, the token is also written to a file there. The returned guard ends the session's token
    /// and removes its files when it is dropped.
    pub fn issue(self: &Arc<Self>, agent_id: &str) -> io::Result<(String, SessionToken)> {
        let bytes: [u8; 32] = rand::random();
        let token = format!("{PREFIX}{}", URL_SAFE_NO_PAD.encode(bytes));
        let hash = hash_of(&token);
        let mut session = SessionToken {
            tokens: Arc::clone(self),
            agent_id: agent_id.to_string(),
            hash,
            token_file: None,
            config_file: None,
        };
        let run_dir = self.run_dir.lock().unwrap_or_else(|e| e.into_inner()).clone();
        if let Some(dir) = run_dir {
            let id: [u8; 8] = rand::random();
            let stem = format!("{FILE_START}{}", hex::encode(id));
            // Written before the token counts, so a failed write leaves nothing live.
            let token_file = dir.join(format!("{stem}{TOKEN_SUFFIX}"));
            write_private(&token_file, &token)?;
            session.token_file = Some(token_file);
            session.config_file = Some(dir.join(format!("{stem}{CONFIG_SUFFIX}")));
        }
        {
            let mut inner = self.lock();
            if let Some(old) = inner.by_agent.insert(agent_id.to_string(), hash) {
                inner.by_hash.remove(&old);
            }
            inner.by_hash.insert(hash, agent_id.to_string());
        }
        Ok((token, session))
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

/// Keeps one session's agent token live, with its files. Dropping it revokes the token and removes the files.
pub struct SessionToken {
    tokens: Arc<AgentTokens>,
    agent_id: String,
    hash: Hash,
    token_file: Option<PathBuf>,
    config_file: Option<PathBuf>,
}

impl SessionToken {
    /// The file that holds this session's token, when there is a run folder.
    pub fn token_file(&self) -> Option<&Path> {
        self.token_file.as_deref()
    }

    /// Where the session's Claude MCP config goes. The file is removed with the session.
    pub fn config_file(&self) -> Option<&Path> {
        self.config_file.as_deref()
    }
}

impl Drop for SessionToken {
    fn drop(&mut self) {
        self.tokens.revoke(&self.agent_id, &self.hash);
        for file in [&self.token_file, &self.config_file].into_iter().flatten() {
            let _ = std::fs::remove_file(file);
        }
    }
}

/// Writes `contents` to `path` as an owner-only file. The file is first made under a random temporary
/// name, with `O_EXCL` and `O_NOFOLLOW` (a symlink planted in the folder is never followed), and then
/// renamed into place, so a reader never sees half of it.
pub fn write_private(path: &Path, contents: &str) -> io::Result<()> {
    let (temp, mut file) = create_temp(path)?;
    let written = file
        .write_all(contents.as_bytes())
        .and_then(|()| file.sync_all())
        .and_then(|()| std::fs::set_permissions(&temp, Permissions::from_mode(0o600)));
    drop(file);
    if let Err(e) = written {
        let _ = std::fs::remove_file(&temp);
        return Err(e);
    }
    std::fs::rename(&temp, path)
}

/// A new file next to `path`, with a random name. A name already taken is not used: another is drawn.
fn create_temp(path: &Path) -> io::Result<(PathBuf, std::fs::File)> {
    for _ in 0..16 {
        let id: [u8; 8] = rand::random();
        let mut name = path.as_os_str().to_owned();
        name.push(format!(".{}{TEMP_SUFFIX}", hex::encode(id)));
        let temp = PathBuf::from(name);
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .custom_flags(libc::O_NOFOLLOW)
            .mode(0o600)
            .open(&temp)
        {
            Ok(file) => return Ok((temp, file)),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(io::Error::new(io::ErrorKind::AlreadyExists, "no free temporary name"))
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
        let (token, _guard) = tokens.issue("agent-a").unwrap();
        assert!(token.starts_with(PREFIX));
        // 32 random bytes in unpadded base64url: 43 characters after the prefix.
        assert_eq!(token.len(), PREFIX.len() + 43);
        assert_eq!(tokens.agent_for(&token).as_deref(), Some("agent-a"));
        assert_eq!(tokens.agent_for("bat_guess"), None);
    }

    #[test]
    fn two_agents_get_different_tokens() {
        let tokens = AgentTokens::new();
        let (a, _ga) = tokens.issue("agent-a").unwrap();
        let (b, _gb) = tokens.issue("agent-b").unwrap();
        assert_ne!(a, b);
        assert_eq!(tokens.agent_for(&a).as_deref(), Some("agent-a"));
        assert_eq!(tokens.agent_for(&b).as_deref(), Some("agent-b"));
    }

    #[test]
    fn dropping_the_guard_ends_the_token() {
        let tokens = AgentTokens::new();
        let (token, guard) = tokens.issue("agent-a").unwrap();
        assert!(tokens.agent_for(&token).is_some());
        drop(guard);
        assert_eq!(tokens.agent_for(&token), None);
    }

    #[test]
    fn a_new_session_replaces_the_previous_token() {
        let tokens = AgentTokens::new();
        let (old, old_guard) = tokens.issue("agent-a").unwrap();
        let (new, _new_guard) = tokens.issue("agent-a").unwrap();
        assert_eq!(tokens.agent_for(&old), None);
        assert_eq!(tokens.agent_for(&new).as_deref(), Some("agent-a"));
        // The old session ending must not revoke the new token.
        drop(old_guard);
        assert_eq!(tokens.agent_for(&new).as_deref(), Some("agent-a"));
    }

    #[test]
    fn the_token_file_is_owner_only_and_goes_with_the_session() {
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path().join("run");
        let tokens = AgentTokens::new();
        tokens.set_run_dir(&run).unwrap();
        assert_eq!(std::fs::metadata(&run).unwrap().permissions().mode() & 0o777, 0o700);
        let (token, guard) = tokens.issue("agent-a").unwrap();
        let file = guard.token_file().unwrap().to_path_buf();
        assert!(file.starts_with(&run));
        assert_eq!(std::fs::read_to_string(&file).unwrap(), token);
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        // The config file is only named here; the runtime writes it, and ending the session removes it.
        let config = guard.config_file().unwrap().to_path_buf();
        write_private(&config, "{}").unwrap();
        assert_eq!(std::fs::metadata(&config).unwrap().permissions().mode() & 0o777, 0o600);
        drop(guard);
        assert!(!file.exists());
        assert!(!config.exists());
    }

    #[test]
    fn starting_clears_what_a_previous_daemon_left() {
        let dir = tempfile::tempdir().unwrap();
        let run = dir.path().join("run");
        std::fs::create_dir_all(&run).unwrap();
        std::fs::write(run.join("agent-old.token"), "bat_old").unwrap();
        std::fs::write(run.join("agent-old.mcp.json"), "{}").unwrap();
        std::fs::write(run.join("agent-old.token.tmp"), "bat_old").unwrap();
        std::fs::write(run.join("keep.txt"), "x").unwrap();
        AgentTokens::new().set_run_dir(&run).unwrap();
        assert!(!run.join("agent-old.token").exists());
        assert!(!run.join("agent-old.mcp.json").exists());
        assert!(!run.join("agent-old.token.tmp").exists());
        assert!(run.join("keep.txt").exists());
    }

    #[test]
    fn without_a_run_folder_the_token_is_only_in_memory() {
        let tokens = AgentTokens::new();
        let (_token, guard) = tokens.issue("agent-a").unwrap();
        assert!(guard.token_file().is_none());
        assert!(guard.config_file().is_none());
    }

    #[test]
    fn a_symlink_planted_as_the_run_folder_is_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim");
        std::fs::create_dir(&victim).unwrap();
        let run = dir.path().join("run");
        std::os::unix::fs::symlink(&victim, &run).unwrap();
        AgentTokens::new().set_run_dir(&run).unwrap();
        assert!(!std::fs::symlink_metadata(&run).unwrap().file_type().is_symlink());
        assert!(run.is_dir());
        assert_eq!(std::fs::metadata(&run).unwrap().permissions().mode() & 0o777, 0o700);
    }

    #[test]
    fn a_file_planted_at_the_target_is_not_followed() {
        let dir = tempfile::tempdir().unwrap();
        let victim = dir.path().join("victim.txt");
        std::fs::write(&victim, "keep").unwrap();
        let target = dir.path().join("agent-x.token");
        std::os::unix::fs::symlink(&victim, &target).unwrap();
        write_private(&target, "bat_new").unwrap();
        // The link is replaced by the new file, and the file it pointed to is untouched.
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "bat_new");
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "keep");
        assert_eq!(std::fs::metadata(&target).unwrap().permissions().mode() & 0o777, 0o600);
    }
}
