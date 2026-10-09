//! The sandbox for agent CLIs on macOS: `sandbox-exec` with a Seatbelt profile. Every process a sandboxed
//! CLI starts inherits the profile, orphans included (a shell's `(… &)` re-parented to launchd does too).
//! On other systems nothing is applied. See docs/ARCHITECTURE.md#trust-model.

use crate::workspace::resolve;
use anyhow::Result;
use std::path::{Path, PathBuf};
use tokio::process::Command;

/// The launcher that ships with macOS.
#[cfg(target_os = "macos")]
const SANDBOX_EXEC: &str = "/usr/bin/sandbox-exec";

/// What one sandboxed session may touch. The supervisor builds it for each session.
#[derive(Debug, Clone)]
pub struct SandboxPolicy {
    /// The daemon's data folder (`$BANDITO_HOME`). Nothing in it is readable or writable, except the
    /// session's own files. Its sockets are the only way in: `agent.sock` yes, `bandito.sock` no.
    pub home: PathBuf,
    /// The daemon's own binary. It may run (the crew bridge is that binary) but not be overwritten.
    pub exe: Option<PathBuf>,
    /// The session's own files: its token file and its MCP config.
    pub session_files: Vec<PathBuf>,
}

impl SandboxPolicy {
    /// The Seatbelt profile. Paths are resolved first, so the rules name what the kernel will see.
    /// Later rules win over earlier ones, which is why the exceptions come after the denials.
    pub fn profile(&self) -> String {
        let home = resolve(&self.home);
        let mut rules = vec![
            "(version 1)".to_string(),
            "(allow default)".to_string(),
            format!("(deny file-read* file-write* (subpath {}))", quote(&home)),
        ];
        for file in &self.session_files {
            rules.push(format!("(allow file-read* (literal {}))", quote(&resolve(file))));
        }
        // Connecting to a unix socket is a network operation: a denial on the folder does not stop it.
        rules.push(format!(
            "(deny network-outbound (remote unix-socket (path-literal {})))",
            quote(&home.join("bandito.sock"))
        ));
        rules.push(format!(
            "(allow network-outbound (remote unix-socket (path-literal {})))",
            quote(&home.join("agent.sock"))
        ));
        if let Some(exe) = &self.exe {
            rules.push(format!("(deny file-write* (literal {}))", quote(&resolve(exe))));
        }
        rules.join("\n")
    }
}

/// A path as a Seatbelt string literal: in double quotes, with `\` and `"` escaped.
fn quote(path: &Path) -> String {
    let escaped = path.to_string_lossy().replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// `cmd` run under the policy, when there is one. The working folder, environment and arguments carry
/// over. Elsewhere this changes nothing.
#[cfg(target_os = "macos")]
pub fn wrap(cmd: Command, policy: Option<&SandboxPolicy>) -> Result<Command> {
    let Some(policy) = policy else {
        return Ok(cmd);
    };
    let inner = cmd.as_std();
    let mut wrapped = Command::new(SANDBOX_EXEC);
    wrapped
        .arg("-p")
        .arg(policy.profile())
        .arg("--")
        .arg(inner.get_program())
        .args(inner.get_args());
    for (key, value) in inner.get_envs() {
        match value {
            Some(value) => wrapped.env(key, value),
            None => wrapped.env_remove(key),
        };
    }
    if let Some(dir) = inner.get_current_dir() {
        wrapped.current_dir(dir);
    }
    Ok(wrapped)
}

/// Not macOS: no sandbox, the command is returned as it is.
#[cfg(not(target_os = "macos"))]
pub fn wrap(cmd: Command, _policy: Option<&SandboxPolicy>) -> Result<Command> {
    Ok(cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_are_quoted_for_the_profile() {
        assert_eq!(quote(Path::new("/a b/c")), "\"/a b/c\"");
        assert_eq!(quote(Path::new(r#"/x"y\z"#)), r#""/x\"y\\z""#);
    }

    #[test]
    fn the_profile_denies_the_data_folder_and_allows_only_the_agent_socket() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".bandito");
        std::fs::create_dir_all(home.join("run")).unwrap();
        let token = home.join("run").join("agent-x.token");
        let policy = SandboxPolicy {
            home: home.clone(),
            exe: Some(PathBuf::from("/usr/local/bin/bandito")),
            session_files: vec![token.clone()],
        };
        let profile = policy.profile();
        let home = resolve(&home);
        assert!(profile.contains(&format!(
            "(deny file-read* file-write* (subpath \"{}\"))",
            home.display()
        )));
        assert!(profile.contains(&format!(
            "(allow file-read* (literal \"{}\"))",
            resolve(&token).display()
        )));
        assert!(profile.contains(&format!(
            "(deny network-outbound (remote unix-socket (path-literal \"{}\")))",
            home.join("bandito.sock").display()
        )));
        assert!(profile.contains(&format!(
            "(allow network-outbound (remote unix-socket (path-literal \"{}\")))",
            home.join("agent.sock").display()
        )));
        // Exceptions come after the denial they open.
        let denial = profile.find("(subpath").unwrap();
        let exception = profile.find("(literal").unwrap();
        assert!(exception > denial, "{profile}");
    }

    #[test]
    fn without_a_policy_the_command_is_unchanged() {
        let cmd = Command::new("true");
        let wrapped = wrap(cmd, None).unwrap();
        assert_eq!(wrapped.as_std().get_program(), "true");
    }
}

/// The sandbox on a real macOS process: each probe is this test binary, run under the policy.
#[cfg(all(test, target_os = "macos"))]
mod sandboxed {
    use super::*;
    use std::time::{Duration, Instant};

    /// Not a test of its own. A probe run under a policy: the operation named in the environment is tried
    /// on the path, and the outcome is written to the output file.
    #[test]
    fn sandbox_probe() {
        let (Some(op), Some(path), Some(out)) = (
            std::env::var_os("BANDITO_SANDBOX_PROBE_OP"),
            std::env::var_os("BANDITO_SANDBOX_PROBE_PATH"),
            std::env::var_os("BANDITO_SANDBOX_PROBE_OUT"),
        ) else {
            return;
        };
        let outcome = match op.to_str() {
            Some("connect") => std::os::unix::net::UnixStream::connect(&path).map(|_| ()),
            Some("read") => std::fs::read(&path).map(|_| ()),
            Some("write") => std::fs::write(&path, b"written"),
            _ => Err(std::io::Error::other("unknown probe")),
        };
        let text = match outcome {
            Ok(()) => "ok".to_string(),
            Err(e) => format!("denied: {e}"),
        };
        std::fs::write(out, text).unwrap();
    }

    struct Fixture {
        _dir: tempfile::TempDir,
        home: PathBuf,
        policy: SandboxPolicy,
        project: PathBuf,
        /// Kept alive: the socket files must exist for the probes.
        _sockets: Vec<std::os::unix::net::UnixListener>,
    }

    fn fixture() -> Fixture {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".bandito");
        let run = home.join("run");
        std::fs::create_dir_all(&run).unwrap();
        std::fs::write(home.join("bandito.db"), "SECRET").unwrap();
        std::fs::write(run.join("agent-own.token"), "bat_own").unwrap();
        std::fs::write(run.join("agent-other.token"), "bat_other").unwrap();
        let sockets = vec![
            std::os::unix::net::UnixListener::bind(home.join("bandito.sock")).unwrap(),
            std::os::unix::net::UnixListener::bind(home.join("agent.sock")).unwrap(),
        ];
        let project = dir.path().join("project");
        std::fs::create_dir_all(&project).unwrap();
        let policy = SandboxPolicy {
            home: home.clone(),
            exe: None,
            session_files: vec![run.join("agent-own.token")],
        };
        Fixture {
            _dir: dir,
            home,
            policy,
            project,
            _sockets: sockets,
        }
    }

    /// Runs the probe under `policy` and returns what it wrote: `ok`, or `denied: …`.
    async fn probe(policy: &SandboxPolicy, op: &str, target: &Path, out: &Path) -> String {
        let _ = std::fs::remove_file(out);
        let mut cmd = Command::new(std::env::current_exe().unwrap());
        cmd.args(["--exact", "runtime::sandbox::sandboxed::sandbox_probe"])
            .env("BANDITO_SANDBOX_PROBE_OP", op)
            .env("BANDITO_SANDBOX_PROBE_PATH", target)
            .env("BANDITO_SANDBOX_PROBE_OUT", out);
        wrap(cmd, Some(policy)).unwrap().status().await.unwrap();
        std::fs::read_to_string(out).unwrap_or_else(|_| "no result".into())
    }

    #[tokio::test]
    async fn the_data_folder_cannot_be_read() {
        let f = fixture();
        let mut cmd = Command::new("cat");
        cmd.arg(f.home.join("bandito.db"));
        let status = wrap(cmd, Some(&f.policy)).unwrap().status().await.unwrap();
        assert!(!status.success(), "cat of the database must fail under the sandbox");
    }

    #[tokio::test]
    async fn bandito_sock_cannot_be_connected() {
        let f = fixture();
        let out = f._dir.path().join("out.txt");
        let answer = probe(&f.policy, "connect", &f.home.join("bandito.sock"), &out).await;
        assert!(answer.starts_with("denied"), "{answer}");
    }

    #[tokio::test]
    async fn orphans_inherit_the_sandbox() {
        // A shell starts the probe in the background and exits: the probe is re-parented to launchd.
        let f = fixture();
        let out = f._dir.path().join("orphan.txt");
        let _ = std::fs::remove_file(&out);
        let mut cmd = Command::new("sh");
        cmd.args([
            "-c",
            "\"$0\" --exact runtime::sandbox::sandboxed::sandbox_probe >/dev/null 2>&1 &",
        ])
        .arg(std::env::current_exe().unwrap())
        .env("BANDITO_SANDBOX_PROBE_OP", "connect")
        .env("BANDITO_SANDBOX_PROBE_PATH", f.home.join("bandito.sock"))
        .env("BANDITO_SANDBOX_PROBE_OUT", &out);
        assert!(wrap(cmd, Some(&f.policy)).unwrap().status().await.unwrap().success());
        let deadline = Instant::now() + Duration::from_secs(20);
        while !out.exists() && Instant::now() < deadline {
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        let answer = std::fs::read_to_string(&out).unwrap_or_else(|_| "no result".into());
        assert!(answer.starts_with("denied"), "the orphan got through: {answer}");
    }

    #[tokio::test]
    async fn the_agent_socket_and_the_own_token_work_and_other_tokens_do_not() {
        let f = fixture();
        let out = f._dir.path().join("out.txt");
        let own = f.home.join("run").join("agent-own.token");
        let other = f.home.join("run").join("agent-other.token");
        assert_eq!(
            probe(&f.policy, "connect", &f.home.join("agent.sock"), &out).await,
            "ok"
        );
        assert_eq!(probe(&f.policy, "read", &own, &out).await, "ok");
        assert!(probe(&f.policy, "read", &other, &out).await.starts_with("denied"));
        assert!(
            probe(&f.policy, "read", &f.home.join("bandito.db"), &out)
                .await
                .starts_with("denied")
        );
    }

    #[tokio::test]
    async fn ordinary_work_still_works() {
        let f = fixture();
        let out = f._dir.path().join("out.txt");
        assert_eq!(probe(&f.policy, "write", &f.project.join("note.txt"), &out).await, "ok");
        if std::process::Command::new("git")
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
        {
            assert!(
                std::process::Command::new("git")
                    .arg("init")
                    .arg("-q")
                    .arg(&f.project)
                    .status()
                    .unwrap()
                    .success()
            );
            let mut cmd = Command::new("git");
            cmd.arg("-C").arg(&f.project).arg("status").arg("--short");
            assert!(wrap(cmd, Some(&f.policy)).unwrap().status().await.unwrap().success());
        }
        // Network out: skipped where the machine has no network at all.
        let online = std::process::Command::new("nc")
            .args(["-z", "-w", "5", "1.1.1.1", "443"])
            .status()
            .is_ok_and(|s| s.success());
        if online {
            let mut cmd = Command::new("nc");
            cmd.args(["-z", "-w", "5", "1.1.1.1", "443"]);
            assert!(wrap(cmd, Some(&f.policy)).unwrap().status().await.unwrap().success());
        } else {
            eprintln!("no network here: the outbound check is skipped");
        }
    }

    /// Why Codex is not sandboxed: a nested `sandbox-exec` cannot apply a profile inside a sandbox.
    #[tokio::test]
    async fn a_nested_sandbox_is_refused_inside_the_sandbox() {
        let f = fixture();
        let mut cmd = Command::new(SANDBOX_EXEC);
        cmd.args(["-p", "(version 1)(allow default)", "--", "/usr/bin/true"]);
        let status = wrap(cmd, Some(&f.policy)).unwrap().status().await.unwrap();
        assert!(
            !status.success(),
            "a nested sandbox was accepted: Codex could run sandboxed too"
        );
    }
}
