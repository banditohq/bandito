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
    /// The user's home folder. Its login and background-task files cannot be written, so nothing can
    /// make the user's shell or launchd run a command later.
    pub user_home: PathBuf,
    /// The daemon's own binary. It may run (the crew bridge is that binary) but not be overwritten.
    pub exe: Option<PathBuf>,
    /// The session's own files: its token file and its MCP config.
    pub session_files: Vec<PathBuf>,
}

/// Programs that start things outside the sandbox: `open` hands a file to Launch Services, `osascript`
/// sends Apple events, `launchctl` and the scheduler programs load jobs that run later.
const BLOCKED_PROGRAMS: &[&str] = &[
    "/usr/bin/open",
    "/usr/bin/osascript",
    "/bin/launchctl",
    "/usr/bin/lsappinfo",
    "/usr/bin/crontab",
    "/usr/bin/at",
    "/usr/bin/batch",
    "/usr/sbin/cron",
];

/// Login and background-task files of the user, relative to the home folder. Writing one of them would
/// run a command in a later shell or at login, outside any session.
const LOGIN_FILES: &[&str] = &[
    ".zshrc",
    ".zprofile",
    ".zshenv",
    ".zlogin",
    ".bashrc",
    ".bash_profile",
    ".profile",
    ".ssh/rc",
    ".ssh/authorized_keys",
];
const LOGIN_FOLDERS: &[&str] = &[
    ".config/fish",
    "Library/LaunchAgents",
    "Library/Application Support/com.apple.backgroundtaskmanagementagent",
];

impl SandboxPolicy {
    /// The Seatbelt profile. Paths are resolved first, so the rules name what the kernel will see.
    /// Later rules win over earlier ones, which is why the exceptions come after the denials. A path
    /// that is not valid UTF-8 has no profile text: the session is refused rather than given a wrong rule.
    pub fn profile(&self) -> Result<String> {
        let home = resolve(&self.home);
        let user = resolve(&self.user_home);
        let mut rules = vec![
            "(version 1)".to_string(),
            "(allow default)".to_string(),
            format!("(deny file-read* file-write* (subpath {}))", quote(&home)?),
        ];
        for file in &self.session_files {
            rules.push(format!("(allow file-read* (literal {}))", quote(&resolve(file))?));
        }
        // Connecting to a unix socket is a network operation: a denial on the folder does not stop it.
        rules.push(format!(
            "(deny network-outbound (remote unix-socket (path-literal {})))",
            quote(&home.join("bandito.sock"))?
        ));
        rules.push(format!(
            "(allow network-outbound (remote unix-socket (path-literal {})))",
            quote(&home.join("agent.sock"))?
        ));
        if let Some(exe) = &self.exe {
            rules.push(format!("(deny file-write* (literal {}))", quote(&resolve(exe))?));
        }
        // Start-outside-the-sandbox channels: programs, Launch Services, Apple events.
        let programs: Vec<String> = BLOCKED_PROGRAMS
            .iter()
            .map(|p| quote(Path::new(p)).map(|q| format!("(literal {q})")))
            .collect::<Result<_>>()?;
        rules.push(format!("(deny process-exec {})", programs.join(" ")));
        rules.push(r#"(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))"#.to_string());
        rules.push("(deny appleevent-send)".to_string());
        // Login and background-task files of the user: writing them would run something later.
        let mut writes: Vec<String> = Vec::new();
        for folder in LOGIN_FOLDERS {
            writes.push(format!("(subpath {})", quote(&user.join(folder))?));
        }
        for file in LOGIN_FILES {
            writes.push(format!("(literal {})", quote(&user.join(file))?));
        }
        rules.push(format!("(deny file-write* {})", writes.join(" ")));
        Ok(rules.join("\n"))
    }
}

/// A path as a Seatbelt string literal: in double quotes, with `\` and `"` escaped. A path that is not
/// valid UTF-8 is an error: it cannot be written into a profile faithfully.
fn quote(path: &Path) -> Result<String> {
    let text = path.to_str().ok_or_else(|| {
        anyhow::anyhow!(
            "the path {} is not valid UTF-8; the agent session cannot start",
            path.to_string_lossy()
        )
    })?;
    let escaped = text.replace('\\', "\\\\").replace('"', "\\\"");
    Ok(format!("\"{escaped}\""))
}

/// Whether sessions are sandboxed by `wrap` here. Codex needs to know, to turn its own sandbox off.
pub fn applies(policy: Option<&SandboxPolicy>) -> bool {
    cfg!(target_os = "macos") && policy.is_some()
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
        .arg(policy.profile()?)
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
        assert_eq!(quote(Path::new("/a b/c")).unwrap(), "\"/a b/c\"");
        assert_eq!(quote(Path::new(r#"/x"y\z"#)).unwrap(), r#""/x\"y\\z""#);
    }

    #[test]
    fn a_path_that_is_not_utf8_refuses_the_session() {
        use std::os::unix::ffi::OsStrExt;
        let bad = Path::new(std::ffi::OsStr::from_bytes(b"/tmp/\xff/bandito"));
        let err = quote(bad).unwrap_err().to_string();
        assert!(err.contains("not valid UTF-8"), "{err}");
        let policy = SandboxPolicy {
            home: bad.to_path_buf(),
            user_home: PathBuf::from("/Users/someone"),
            exe: None,
            session_files: Vec::new(),
        };
        assert!(policy.profile().is_err());
    }

    #[test]
    fn the_profile_denies_the_data_folder_and_allows_only_the_agent_socket() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join(".bandito");
        std::fs::create_dir_all(home.join("run")).unwrap();
        let token = home.join("run").join("agent-x.token");
        let policy = SandboxPolicy {
            home: home.clone(),
            user_home: dir.path().join("userhome"),
            exe: Some(PathBuf::from("/usr/local/bin/bandito")),
            session_files: vec![token.clone()],
        };
        let profile = policy.profile().unwrap();
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
        // The channels that start things outside the sandbox are closed.
        assert!(profile.contains("(deny process-exec (literal \"/usr/bin/open\")"));
        assert!(profile.contains("(deny appleevent-send)"));
        assert!(profile.contains("com.apple.coreservices.launchservicesd"));
        assert!(profile.contains("Library/LaunchAgents"));
        assert!(profile.contains(".zshrc"));
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
        user_home: PathBuf,
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
        let user_home = dir.path().join("userhome");
        std::fs::create_dir_all(user_home.join("Library").join("LaunchAgents")).unwrap();
        let policy = SandboxPolicy {
            home: home.clone(),
            user_home: user_home.clone(),
            exe: None,
            session_files: vec![run.join("agent-own.token")],
        };
        Fixture {
            _dir: dir,
            home,
            user_home,
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

    /// Runs a program under the policy: whether it succeeded, and its output.
    async fn run_under(policy: &SandboxPolicy, program: &str, args: &[&str]) -> (bool, String) {
        let mut cmd = Command::new(program);
        cmd.args(args);
        let out = wrap(cmd, Some(policy)).unwrap().output().await.unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        (out.status.success(), text)
    }

    /// `open` would hand a file to Launch Services, which starts it outside the sandbox. The exec is refused.
    #[tokio::test]
    async fn open_cannot_start_anything() {
        let f = fixture();
        let (ok, text) = run_under(&f.policy, "/usr/bin/open", &["/nonexistent-bandito-probe"]).await;
        assert!(!ok && text.contains("Operation not permitted"), "{text}");
    }

    #[tokio::test]
    async fn launchctl_cannot_load_jobs() {
        let f = fixture();
        let (ok, text) = run_under(&f.policy, "/bin/launchctl", &["list"]).await;
        assert!(!ok && text.contains("Operation not permitted"), "{text}");
    }

    /// A small program that sends Apple events itself, so that `osascript` is not needed to test the rule.
    /// It asks Finder for nothing but its name: no window opens.
    const APPLE_EVENT_PROBE: &str = r#"
#include <CoreServices/CoreServices.h>
#include <stdio.h>
int main(void) {
    OSType sig = 'MACS';
    AEAddressDesc target;
    if (AECreateDesc(typeApplSignature, &sig, sizeof(sig), &target) != noErr) return 2;
    AppleEvent ev;
    if (AECreateAppleEvent('core', 'getd', &target, kAutoGenerateReturnID, kAnyTransactionID, &ev) != noErr) return 3;
    AppleEvent reply;
    OSErr e = AESendMessage(&ev, &reply, kAEWaitReply | kAENeverInteract, kAEDefaultTimeout);
    printf("send result %d\n", (int)e);
    return e == noErr ? 0 : 1;
}
"#;

    /// The Apple event rule: the probe can send an event on its own (the control), and under the profile it
    /// cannot. Skipped where the probe cannot be built or the machine refuses Apple events even unsandboxed.
    #[tokio::test]
    async fn apple_events_cannot_be_sent() {
        let f = fixture();
        let source = f._dir.path().join("ae.c");
        let probe_bin = f._dir.path().join("ae-probe");
        std::fs::write(&source, APPLE_EVENT_PROBE).unwrap();
        let built = std::process::Command::new("/usr/bin/clang")
            .arg("-framework")
            .arg("CoreServices")
            .arg("-o")
            .arg(&probe_bin)
            .arg(&source)
            .status();
        if !built.is_ok_and(|s| s.success()) {
            eprintln!("cannot build the Apple event probe here: skipped");
            return;
        }
        let control = std::process::Command::new(&probe_bin).status().unwrap();
        if !control.success() {
            eprintln!("this machine refuses Apple events even without a sandbox: skipped");
            return;
        }
        let (ok, text) = run_under(&f.policy, probe_bin.to_str().unwrap(), &[]).await;
        assert!(!ok, "an Apple event got through under the sandbox: {text}");
        assert!(
            text.contains("send result") && !text.contains("send result 0"),
            "{text}"
        );
    }

    #[tokio::test]
    async fn login_and_background_files_cannot_be_written() {
        let f = fixture();
        let out = f._dir.path().join("out.txt");
        for target in [
            f.user_home.join(".zshrc"),
            f.user_home
                .join("Library")
                .join("LaunchAgents")
                .join("com.bandito.probe.plist"),
        ] {
            let answer = probe(&f.policy, "write", &target, &out).await;
            assert!(answer.starts_with("denied"), "{}: {answer}", target.display());
        }
        // Other files of the user's home stay writable: the rule is targeted.
        let answer = probe(&f.policy, "write", &f.user_home.join(".gitconfig"), &out).await;
        assert_eq!(answer, "ok");
    }

    #[tokio::test]
    async fn node_and_curl_still_run() {
        let f = fixture();
        if std::process::Command::new("node")
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
        {
            let (ok, text) = run_under(&f.policy, "node", &["-e", "process.exit(0)"]).await;
            assert!(ok, "{text}");
        } else {
            eprintln!("node is not installed here: skipped");
        }
        if std::process::Command::new("curl")
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
        {
            let (ok, text) = run_under(&f.policy, "curl", &["--version"]).await;
            assert!(ok, "{text}");
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
