//! Run the daemon as a user service: systemd (Linux), launchd (macOS), or a plain background process.
//!
//! Everything that decides *what* gets written or run is a pure function that returns a [`Plan`];
//! [`execute`] is the only part that touches the disk and spawns processes.

use crate::rpc;
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

pub const LABEL: &str = "dev.bandito.daemon";
pub const UNIT_NAME: &str = "bandito.service";
pub const DEFAULT_LISTEN: &str = "127.0.0.1:7878";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Systemd,
    Launchd,
    Background,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Mode::Systemd => "systemd",
            Mode::Launchd => "launchd",
            Mode::Background => "background",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    Linux,
    MacOs,
}

/// Where the service files and the daemon's own files live.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    /// Data directory (`~/.bandito` unless `--home` / `BANDITO_HOME` says otherwise).
    pub data_home: PathBuf,
    pub socket: PathBuf,
    pub pid_file: PathBuf,
    pub log_file: PathBuf,
    pub unit_file: PathBuf,
    pub plist_file: PathBuf,
}

impl Paths {
    pub fn new(data_home: &Path, user_home: &Path) -> Self {
        Paths {
            data_home: data_home.to_path_buf(),
            socket: data_home.join("bandito.sock"),
            pid_file: data_home.join("daemon.pid"),
            log_file: data_home.join("logs").join("daemon.log"),
            unit_file: user_home.join(".config/systemd/user").join(UNIT_NAME),
            plist_file: user_home.join("Library/LaunchAgents").join(format!("{LABEL}.plist")),
        }
    }
}

/// Arguments after the executable: `daemon --listen <listen>`, with `--home <dir>` first
/// when the data directory is not the default one.
pub fn daemon_args(listen: &str, home_override: Option<&Path>) -> Vec<String> {
    let mut args = Vec::new();
    if let Some(home) = home_override {
        args.push("--home".to_string());
        args.push(home.display().to_string());
    }
    args.extend(["daemon".to_string(), "--listen".to_string(), listen.to_string()]);
    args
}

/// One systemd word: `$` and `%` are escaped for systemd, and the word is quoted when it
/// has spaces, quotes or backslashes.
pub fn systemd_word(s: &str) -> String {
    let escaped = s.replace('%', "%%").replace('$', "$$");
    if escaped.is_empty() || escaped.contains([' ', '\t', '"', '\\', '\'']) {
        format!("\"{}\"", escaped.replace('\\', "\\\\").replace('"', "\\\""))
    } else {
        escaped
    }
}

/// The user unit file. `args` are passed through [`systemd_word`] one by one.
pub fn systemd_unit(exe: &Path, args: &[String], path_env: &str) -> String {
    let mut exec = systemd_word(&exe.display().to_string());
    for a in args {
        exec.push(' ');
        exec.push_str(&systemd_word(a));
    }
    format!(
        "[Unit]\n\
         Description=Bandito daemon\n\
         After=network-online.target\n\
         [Service]\n\
         ExecStart={exec}\n\
         Restart=on-failure\n\
         RestartSec=3\n\
         Environment={env}\n\
         [Install]\n\
         WantedBy=default.target\n",
        env = systemd_word(&format!("PATH={path_env}")),
    )
}

/// Escape the five XML special characters for use in element text.
pub fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

/// The launchd agent plist.
pub fn launchd_plist(exe: &Path, args: &[String], log: &Path, path_env: &str) -> String {
    let mut program = format!("    <string>{}</string>\n", xml_escape(&exe.display().to_string()));
    for a in args {
        program.push_str(&format!("    <string>{}</string>\n", xml_escape(a)));
    }
    let log = xml_escape(&log.display().to_string());
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\">\n\
         <dict>\n\
         \x20 <key>Label</key>\n\
         \x20 <string>{LABEL}</string>\n\
         \x20 <key>ProgramArguments</key>\n\
         \x20 <array>\n\
         {program}\
         \x20 </array>\n\
         \x20 <key>RunAtLoad</key>\n\
         \x20 <true/>\n\
         \x20 <key>KeepAlive</key>\n\
         \x20 <true/>\n\
         \x20 <key>StandardOutPath</key>\n\
         \x20 <string>{log}</string>\n\
         \x20 <key>StandardErrorPath</key>\n\
         \x20 <string>{log}</string>\n\
         \x20 <key>EnvironmentVariables</key>\n\
         \x20 <dict>\n\
         \x20   <key>PATH</key>\n\
         \x20   <string>{path}</string>\n\
         \x20 </dict>\n\
         </dict>\n\
         </plist>\n",
        path = xml_escape(path_env),
    )
}

/// What the installer needs to know about this machine and this request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallSpec {
    /// Canonical path of the running binary.
    pub exe: PathBuf,
    /// `host:port`, as given to `--listen`.
    pub listen: String,
    /// Data directory to pass to the daemon, only when it is not the default one.
    pub home_override: Option<PathBuf>,
    pub path_env: String,
    pub user: String,
    pub uid: u32,
}

/// Facts that need a probe on the real machine (kept out of the pure planner).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Probe {
    /// `systemctl --user` reaches a user manager.
    pub systemd_user: bool,
    /// The `setsid` binary exists.
    pub setsid: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OnError {
    /// Stop the install with an error.
    Fail,
    /// Ignore the failure silently.
    Ignore,
    /// Keep going and show this warning.
    Warn(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    MakeDir(PathBuf),
    WriteFile {
        path: PathBuf,
        contents: String,
    },
    Remove(PathBuf),
    Run {
        argv: Vec<String>,
        on_error: OnError,
    },
    /// Start a detached daemon, append its output to `log`, write its pid to `pid_file`.
    Spawn {
        argv: Vec<String>,
        log: PathBuf,
        pid_file: PathBuf,
    },
    /// Send SIGTERM to the pid stored in this file (no-op if the file or process is gone).
    StopPid(PathBuf),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Plan {
    pub mode: Option<Mode>,
    pub actions: Vec<Action>,
    pub warnings: Vec<String>,
}

/// Which service files exist right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Presence {
    pub unit: bool,
    pub plist: bool,
    pub pid_file: bool,
}

fn run(argv: &[&str], on_error: OnError) -> Action {
    Action::Run {
        argv: argv.iter().map(|s| s.to_string()).collect(),
        on_error,
    }
}

fn launchd_domain(uid: u32) -> String {
    format!("gui/{uid}")
}

pub fn install_plan(spec: &InstallSpec, paths: &Paths, os: Os, probe: &Probe) -> Plan {
    let args = daemon_args(&spec.listen, spec.home_override.as_deref());
    let logs_dir = paths.data_home.join("logs");
    match os {
        Os::Linux if probe.systemd_user => Plan {
            mode: Some(Mode::Systemd),
            actions: vec![
                Action::WriteFile {
                    path: paths.unit_file.clone(),
                    contents: systemd_unit(&spec.exe, &args, &spec.path_env),
                },
                run(&["systemctl", "--user", "daemon-reload"], OnError::Fail),
                // Picks up a new binary when the service is already running; no-op otherwise.
                run(&["systemctl", "--user", "try-restart", UNIT_NAME], OnError::Ignore),
                run(&["systemctl", "--user", "enable", "--now", UNIT_NAME], OnError::Fail),
                run(
                    &["loginctl", "enable-linger", &spec.user],
                    OnError::Warn(format!(
                        "could not enable lingering, so the daemon stops at logout. Run: sudo loginctl enable-linger {}",
                        spec.user
                    )),
                ),
            ],
            warnings: Vec::new(),
        },
        Os::Linux => {
            let mut argv = Vec::new();
            let mut warnings = vec![
                "no systemd: the daemon will not survive a reboot. Enable systemd in WSL: add [boot] systemd=true to /etc/wsl.conf and restart WSL.".to_string(),
            ];
            if probe.setsid {
                argv.push("setsid".to_string());
            } else {
                warnings.push("setsid not found: the daemon may stop when the SSH session closes.".to_string());
            }
            argv.push(spec.exe.display().to_string());
            argv.extend(args);
            Plan {
                mode: Some(Mode::Background),
                actions: vec![
                    Action::MakeDir(logs_dir),
                    Action::Spawn {
                        argv,
                        log: paths.log_file.clone(),
                        pid_file: paths.pid_file.clone(),
                    },
                ],
                warnings,
            }
        }
        Os::MacOs => {
            let domain = launchd_domain(spec.uid);
            Plan {
                mode: Some(Mode::Launchd),
                actions: vec![
                    Action::MakeDir(logs_dir),
                    Action::WriteFile {
                        path: paths.plist_file.clone(),
                        contents: launchd_plist(&spec.exe, &args, &paths.log_file, &spec.path_env),
                    },
                    run(&["launchctl", "bootout", &format!("{domain}/{LABEL}")], OnError::Ignore),
                    run(
                        &[
                            "launchctl",
                            "bootstrap",
                            &domain,
                            &paths.plist_file.display().to_string(),
                        ],
                        OnError::Fail,
                    ),
                ],
                warnings: Vec::new(),
            }
        }
    }
}

pub fn uninstall_plan(paths: &Paths, present: &Presence, uid: u32) -> Plan {
    let mut actions = Vec::new();
    let mut mode = None;
    if present.unit {
        mode = Some(Mode::Systemd);
        actions.push(run(
            &["systemctl", "--user", "disable", "--now", UNIT_NAME],
            OnError::Ignore,
        ));
        actions.push(Action::Remove(paths.unit_file.clone()));
        actions.push(run(&["systemctl", "--user", "daemon-reload"], OnError::Ignore));
    }
    if present.plist {
        mode.get_or_insert(Mode::Launchd);
        actions.push(run(
            &["launchctl", "bootout", &format!("{}/{LABEL}", launchd_domain(uid))],
            OnError::Ignore,
        ));
        actions.push(Action::Remove(paths.plist_file.clone()));
    }
    if present.pid_file {
        mode.get_or_insert(Mode::Background);
        actions.push(Action::StopPid(paths.pid_file.clone()));
        actions.push(Action::Remove(paths.pid_file.clone()));
    }
    Plan {
        mode,
        actions,
        warnings: Vec::new(),
    }
}

/// Quote an argument for display only, so a path with spaces reads clearly.
fn display_arg(s: &str) -> String {
    if s.is_empty() || s.contains(char::is_whitespace) {
        format!("'{}'", s.replace('\'', "'\\''"))
    } else {
        s.to_string()
    }
}

fn display_argv(argv: &[String]) -> String {
    argv.iter().map(|a| display_arg(a)).collect::<Vec<_>>().join(" ")
}

/// Human-readable list of what the plan would write and run (for `--dry-run`).
pub fn describe(plan: &Plan) -> String {
    let mut out = String::new();
    if let Some(mode) = plan.mode {
        out.push_str(&format!("mode: {}\n", mode.as_str()));
    }
    for action in &plan.actions {
        let line = match action {
            Action::MakeDir(p) => format!("mkdir -p {}", p.display()),
            Action::WriteFile { path, contents } => format!("write {}:\n{contents}", path.display()),
            Action::Remove(p) => format!("remove {}", p.display()),
            Action::Run { argv, on_error } => {
                let suffix = match on_error {
                    OnError::Fail => "",
                    OnError::Ignore => " (failure ignored)",
                    OnError::Warn(_) => " (failure shown as a warning)",
                };
                format!("run: {}{suffix}", display_argv(argv))
            }
            Action::Spawn { argv, log, pid_file } => format!(
                "start detached: {} (log {}, pid {})",
                display_argv(argv),
                log.display(),
                pid_file.display()
            ),
            Action::StopPid(p) => format!("stop the process whose pid is in {}", p.display()),
        };
        out.push_str(&line);
        out.push('\n');
    }
    for w in &plan.warnings {
        out.push_str(&format!("warning: {w}\n"));
    }
    out
}

/// A pid number from a file or from `systemctl show -p MainPID`. Zero or junk means "no process".
pub fn parse_main_pid(s: &str) -> Option<u32> {
    s.trim().parse::<u32>().ok().filter(|pid| signal_pid(*pid).is_some())
}

/// A pid that `kill(2)` may signal for a bandito daemon: it must fit `pid_t`, and 0, 1 and negative
/// values (process groups, init) are refused.
pub fn signal_pid(pid: u32) -> Option<libc::pid_t> {
    i32::try_from(pid).ok().filter(|p| *p > 1)
}

/// The `"PID" = 123;` line from `launchctl list <label>`.
pub fn parse_launchctl_pid(s: &str) -> Option<u32> {
    s.lines().find_map(|line| {
        let value = line.trim().strip_prefix("\"PID\" = ")?;
        value
            .trim_end_matches(';')
            .trim()
            .parse::<u32>()
            .ok()
            .filter(|pid| signal_pid(*pid).is_some())
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub installed: bool,
    pub mode: Option<Mode>,
    pub running: bool,
    pub pid: Option<u32>,
}

pub fn status_json(s: &Status) -> Value {
    let mut v = json!({
        "installed": s.installed,
        "mode": s.mode.map(Mode::as_str),
        "running": s.running,
    });
    if let Some(pid) = s.pid {
        v["pid"] = json!(pid);
    }
    v
}

pub fn install_json(ok: bool, mode: Mode, listen: &str, socket: &Path, warnings: &[String]) -> Value {
    json!({
        "ok": ok,
        "mode": mode.as_str(),
        "listen": listen,
        "socket": socket.display().to_string(),
        "warnings": warnings,
    })
}

impl Os {
    pub fn current() -> Os {
        if cfg!(target_os = "macos") {
            Os::MacOs
        } else {
            Os::Linux
        }
    }
}

/// Whether a command ran and exited with status 0. Missing binaries count as failure.
fn succeeds(argv: &[&str]) -> bool {
    Command::new(argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// Trimmed stdout of a command, or None when it fails.
fn stdout_of(argv: &[&str]) -> Option<String> {
    let out = Command::new(argv[0])
        .args(&argv[1..])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// The user name and uid this process runs as.
pub fn current_user() -> Result<(String, u32)> {
    let name = stdout_of(&["id", "-un"]).context("cannot read the user name (id -un)")?;
    let uid = stdout_of(&["id", "-u"])
        .and_then(|s| s.parse::<u32>().ok())
        .context("cannot read the user id (id -u)")?;
    Ok((name, uid))
}

/// What this machine supports. Only Linux needs probing.
pub fn probe(os: Os) -> Probe {
    match os {
        Os::MacOs => Probe {
            systemd_user: false,
            setsid: false,
        },
        Os::Linux => Probe {
            systemd_user: succeeds(&["systemctl", "--user", "show-environment"]),
            setsid: succeeds(&["setsid", "--version"]),
        },
    }
}

/// The `daemon.info` result when a daemon answers on the socket within 2 s.
pub async fn probe_daemon(socket: &Path) -> Option<Value> {
    tokio::time::timeout(
        Duration::from_secs(2),
        rpc::unix::call(socket, "daemon.info", json!({})),
    )
    .await
    .ok()?
    .ok()
}

/// Poll `daemon.info` until it answers or `limit` passes.
async fn wait_ready(socket: &Path, limit: Duration) -> Option<Value> {
    let deadline = Instant::now() + limit;
    loop {
        if let Some(info) = probe_daemon(socket).await {
            return Some(info);
        }
        if Instant::now() >= deadline {
            return None;
        }
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
}

/// Send SIGTERM to the pid in `path`, but only if that process is a bandito (a stale pid file
/// must not kill an unrelated process).
fn stop_pid_file(path: &Path) -> Result<()> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Ok(());
    };
    let Some(pid) = parse_main_pid(&text) else {
        return Ok(());
    };
    let pid_arg = pid.to_string();
    let is_bandito = stdout_of(&["ps", "-o", "comm=", "-p", &pid_arg]).is_some_and(|c| c.contains("bandito"));
    if let (true, Some(raw)) = (is_bandito, signal_pid(pid)) {
        // SAFETY: plain kill(2) on a pid that was just checked to be a bandito process and fits pid_t.
        unsafe {
            libc::kill(raw, libc::SIGTERM);
        }
    }
    Ok(())
}

/// Run every action of a plan in order. Returns the warnings to show.
pub fn execute(plan: &Plan) -> Result<Vec<String>> {
    let mut warnings = plan.warnings.clone();
    for action in &plan.actions {
        match action {
            Action::MakeDir(dir) => {
                std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
            }
            Action::WriteFile { path, contents } => {
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
                }
                std::fs::write(path, contents).with_context(|| format!("write {}", path.display()))?;
            }
            Action::Remove(path) => match std::fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e).with_context(|| format!("remove {}", path.display())),
            },
            Action::Run { argv, on_error } => {
                let outcome = Command::new(&argv[0]).args(&argv[1..]).stdin(Stdio::null()).output();
                let failure = match outcome {
                    Ok(out) if out.status.success() => None,
                    Ok(out) => Some(String::from_utf8_lossy(&out.stderr).trim().to_string()),
                    Err(e) => Some(e.to_string()),
                };
                if let Some(detail) = failure {
                    match on_error {
                        OnError::Fail => bail!("`{}` failed: {detail}", display_argv(argv)),
                        OnError::Ignore => {}
                        OnError::Warn(msg) => warnings.push(msg.clone()),
                    }
                }
            }
            Action::Spawn { argv, log, pid_file } => {
                if let Some(dir) = log.parent() {
                    std::fs::create_dir_all(dir).with_context(|| format!("create {}", dir.display()))?;
                }
                let out = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(log)
                    .with_context(|| format!("open {}", log.display()))?;
                let err = out.try_clone().context("duplicate log handle")?;
                let child = Command::new(&argv[0])
                    .args(&argv[1..])
                    .stdin(Stdio::null())
                    .stdout(out)
                    .stderr(err)
                    .spawn()
                    .with_context(|| format!("start `{}`", display_argv(argv)))?;
                // Dropping the child does not stop it; it keeps running after this command exits.
                std::fs::write(pid_file, format!("{}\n", child.id()))
                    .with_context(|| format!("write {}", pid_file.display()))?;
            }
            Action::StopPid(path) => stop_pid_file(path)?,
        }
    }
    Ok(warnings)
}

/// Result of `bandito service install`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallOutcome {
    pub ok: bool,
    pub mode: Mode,
    pub warnings: Vec<String>,
}

/// Install the service, start it, and wait up to 10 s for the daemon to answer.
pub async fn install(paths: &Paths, spec: &InstallSpec, os: Os, probe: &Probe) -> Result<InstallOutcome> {
    let mut plan = install_plan(spec, paths, os, probe);
    let mode = plan.mode.context("no service mode for this platform")?;
    let mut extra_warnings = Vec::new();
    if mode == Mode::Background && probe_daemon(&paths.socket).await.is_some() {
        // Starting a second daemon would fail on the socket; keep the running one.
        plan.actions.retain(|a| !matches!(a, Action::Spawn { .. }));
        extra_warnings.push("a daemon already answers on the socket; it was not restarted".to_string());
    }
    let mut warnings = execute(&plan)?;
    warnings.extend(extra_warnings);
    let ready = wait_ready(&paths.socket, Duration::from_secs(10)).await.is_some();
    if !ready {
        warnings.push(format!(
            "the daemon did not answer on {} within 10 s; see {}",
            paths.socket.display(),
            paths.log_file.display()
        ));
    }
    Ok(InstallOutcome {
        ok: ready,
        mode,
        warnings,
    })
}

/// Current state of the service, for `bandito service status`.
/// How the service is installed, from the files: a unit, then a plist, then a pid file.
pub fn installed_mode(paths: &Paths) -> Option<Mode> {
    if paths.unit_file.exists() {
        Some(Mode::Systemd)
    } else if paths.plist_file.exists() {
        Some(Mode::Launchd)
    } else if paths.pid_file.exists() {
        Some(Mode::Background)
    } else {
        None
    }
}

pub async fn status(paths: &Paths) -> Status {
    let mode = installed_mode(paths);
    let running = probe_daemon(&paths.socket).await.is_some();
    let pid = if !running {
        None
    } else {
        match mode {
            Some(Mode::Systemd) => stdout_of(&["systemctl", "--user", "show", "-p", "MainPID", "--value", UNIT_NAME])
                .and_then(|s| parse_main_pid(&s)),
            Some(Mode::Launchd) => stdout_of(&["launchctl", "list", LABEL]).and_then(|s| parse_launchctl_pid(&s)),
            Some(Mode::Background) => std::fs::read_to_string(&paths.pid_file)
                .ok()
                .and_then(|s| parse_main_pid(&s)),
            None => None,
        }
    };
    Status {
        installed: mode.is_some(),
        mode,
        running,
        pid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exe() -> PathBuf {
        PathBuf::from("/opt/bandito dir/bin/bandito")
    }

    fn home_paths() -> Paths {
        Paths::new(Path::new("/home/u/.bandito"), Path::new("/home/u"))
    }

    fn spec(home_override: Option<&str>) -> InstallSpec {
        InstallSpec {
            exe: PathBuf::from("/home/u/.local/bin/bandito"),
            listen: "127.0.0.1:7878".into(),
            home_override: home_override.map(PathBuf::from),
            path_env: "/usr/bin:/bin".into(),
            user: "u".into(),
            uid: 1000,
        }
    }

    fn has_run(plan: &Plan, argv: &[&str]) -> bool {
        plan.actions
            .iter()
            .any(|a| matches!(a, Action::Run { argv: got, .. } if got == argv))
    }

    #[test]
    fn daemon_args_default_and_with_home_override() {
        assert_eq!(
            daemon_args("127.0.0.1:7878", None),
            ["daemon", "--listen", "127.0.0.1:7878"]
        );
        assert_eq!(
            daemon_args("0.0.0.0:7879", Some(Path::new("/srv/bd"))),
            ["--home", "/srv/bd", "daemon", "--listen", "0.0.0.0:7879"]
        );
    }

    #[test]
    fn systemd_word_quotes_spaces_and_escapes_specifiers() {
        assert_eq!(systemd_word("/usr/bin/bandito"), "/usr/bin/bandito");
        assert_eq!(systemd_word("/opt/my apps/bandito"), "\"/opt/my apps/bandito\"");
        assert_eq!(systemd_word("/a/%h/b"), "/a/%%h/b");
        assert_eq!(systemd_word("/a/$HOME"), "/a/$$HOME");
        assert_eq!(systemd_word("/x\"y"), "\"/x\\\"y\"");
        assert_eq!(systemd_word("PATH=/a b:/c"), "\"PATH=/a b:/c\"");
        assert_eq!(systemd_word(""), "\"\"");
    }

    #[test]
    fn systemd_unit_matches_the_documented_text() {
        let unit = systemd_unit(
            Path::new("/home/u/.local/bin/bandito"),
            &daemon_args("127.0.0.1:7878", None),
            "/usr/bin:/bin",
        );
        assert_eq!(
            unit,
            "[Unit]\n\
             Description=Bandito daemon\n\
             After=network-online.target\n\
             [Service]\n\
             ExecStart=/home/u/.local/bin/bandito daemon --listen 127.0.0.1:7878\n\
             Restart=on-failure\n\
             RestartSec=3\n\
             Environment=PATH=/usr/bin:/bin\n\
             [Install]\n\
             WantedBy=default.target\n"
        );
    }

    #[test]
    fn systemd_unit_quotes_paths_with_spaces() {
        let args = daemon_args("127.0.0.1:7878", Some(Path::new("/srv/my home")));
        let unit = systemd_unit(&exe(), &args, "/opt/x y/bin:/bin");
        assert!(
            unit.contains(
                "ExecStart=\"/opt/bandito dir/bin/bandito\" --home \"/srv/my home\" daemon --listen 127.0.0.1:7878\n"
            ),
            "{unit}"
        );
        assert!(unit.contains("Environment=\"PATH=/opt/x y/bin:/bin\"\n"), "{unit}");
    }

    #[test]
    fn xml_escape_covers_ampersand_and_angle_brackets() {
        assert_eq!(xml_escape("a&b<c>d"), "a&amp;b&lt;c&gt;d");
        assert_eq!(xml_escape("\"q\" 'a'"), "&quot;q&quot; &apos;a&apos;");
        assert_eq!(xml_escape("/plain/path"), "/plain/path");
    }

    #[test]
    fn launchd_plist_escapes_paths_and_keeps_argument_order() {
        let plist = launchd_plist(
            Path::new("/Users/Ann & Co/<bin>/bandito"),
            &daemon_args("127.0.0.1:7878", None),
            Path::new("/Users/Ann & Co/.bandito/logs/daemon.log"),
            "/opt/homebrew/bin:/usr/bin",
        );
        assert!(
            plist.contains("<string>/Users/Ann &amp; Co/&lt;bin&gt;/bandito</string>"),
            "{plist}"
        );
        assert!(
            plist.contains("<string>/Users/Ann &amp; Co/.bandito/logs/daemon.log</string>"),
            "{plist}"
        );
        assert!(plist.contains("<string>dev.bandito.daemon</string>"), "{plist}");
        assert!(plist.contains("<key>RunAtLoad</key>"), "{plist}");
        assert!(plist.contains("<key>KeepAlive</key>"), "{plist}");
        assert_eq!(plist.matches("<true/>").count(), 2, "{plist}");
        assert!(plist.contains("<key>StandardOutPath</key>"), "{plist}");
        assert!(plist.contains("<key>StandardErrorPath</key>"), "{plist}");
        assert!(plist.contains("<string>/opt/homebrew/bin:/usr/bin</string>"), "{plist}");
        assert!(!plist.contains("Ann & Co"), "raw ampersand leaked: {plist}");

        let exe_at = plist.find("<string>/Users/Ann &amp;").unwrap();
        let daemon_at = plist.find("<string>daemon</string>").unwrap();
        let listen_flag_at = plist.find("<string>--listen</string>").unwrap();
        let listen_at = plist.find("<string>127.0.0.1:7878</string>").unwrap();
        assert!(exe_at < daemon_at && daemon_at < listen_flag_at && listen_flag_at < listen_at);
    }

    #[test]
    fn linux_with_systemd_writes_the_unit_and_enables_it() {
        let plan = install_plan(
            &spec(None),
            &home_paths(),
            Os::Linux,
            &Probe {
                systemd_user: true,
                setsid: true,
            },
        );
        assert_eq!(plan.mode, Some(Mode::Systemd));
        assert!(plan.actions.iter().any(|a| matches!(
            a,
            Action::WriteFile { path, .. } if path == Path::new("/home/u/.config/systemd/user/bandito.service")
        )));
        assert!(has_run(&plan, &["systemctl", "--user", "daemon-reload"]));
        assert!(has_run(
            &plan,
            &["systemctl", "--user", "enable", "--now", "bandito.service"]
        ));
        assert!(has_run(&plan, &["loginctl", "enable-linger", "u"]));
        assert!(plan.warnings.is_empty());
        assert!(!plan.actions.iter().any(|a| matches!(a, Action::Spawn { .. })));
    }

    #[test]
    fn linux_without_systemd_falls_back_to_background_with_warning() {
        let plan = install_plan(
            &spec(None),
            &home_paths(),
            Os::Linux,
            &Probe {
                systemd_user: false,
                setsid: true,
            },
        );
        assert_eq!(plan.mode, Some(Mode::Background));
        assert!(plan.actions.iter().any(|a| matches!(
            a,
            Action::Spawn { argv, log, pid_file }
                if argv == &["setsid", "/home/u/.local/bin/bandito", "daemon", "--listen", "127.0.0.1:7878"]
                    && log == Path::new("/home/u/.bandito/logs/daemon.log")
                    && pid_file == Path::new("/home/u/.bandito/daemon.pid")
        )));
        assert!(!plan.actions.iter().any(|a| matches!(a, Action::WriteFile { .. })));
        assert!(
            plan.warnings
                .iter()
                .any(|w| w.contains("systemd=true") && w.contains("/etc/wsl.conf"))
        );
    }

    #[test]
    fn background_without_setsid_spawns_the_binary_directly() {
        let plan = install_plan(
            &spec(None),
            &home_paths(),
            Os::Linux,
            &Probe {
                systemd_user: false,
                setsid: false,
            },
        );
        assert!(plan.actions.iter().any(|a| matches!(
            a,
            Action::Spawn { argv, .. } if argv[0] == "/home/u/.local/bin/bandito"
        )));
    }

    #[test]
    fn macos_writes_the_plist_and_bootstraps_it_in_the_gui_domain() {
        let paths = Paths::new(Path::new("/Users/u/.bandito"), Path::new("/Users/u"));
        let plan = install_plan(
            &spec(None),
            &paths,
            Os::MacOs,
            &Probe {
                systemd_user: false,
                setsid: false,
            },
        );
        assert_eq!(plan.mode, Some(Mode::Launchd));
        assert!(plan.actions.iter().any(|a| matches!(
            a,
            Action::WriteFile { path, contents }
                if path == Path::new("/Users/u/Library/LaunchAgents/dev.bandito.daemon.plist")
                    && contents.contains("<string>dev.bandito.daemon</string>")
        )));
        assert!(has_run(&plan, &["launchctl", "bootout", "gui/1000/dev.bandito.daemon"]));
        assert!(has_run(
            &plan,
            &[
                "launchctl",
                "bootstrap",
                "gui/1000",
                "/Users/u/Library/LaunchAgents/dev.bandito.daemon.plist"
            ]
        ));
        let bootout_ignored = plan.actions.iter().any(
            |a| matches!(a, Action::Run { argv, on_error: OnError::Ignore } if argv.contains(&"bootout".to_string())),
        );
        assert!(bootout_ignored);
    }

    #[test]
    fn home_override_reaches_the_unit_and_the_plist() {
        let plan = install_plan(
            &spec(Some("/srv/bd")),
            &home_paths(),
            Os::Linux,
            &Probe {
                systemd_user: true,
                setsid: true,
            },
        );
        let unit = plan
            .actions
            .iter()
            .find_map(|a| match a {
                Action::WriteFile { contents, .. } => Some(contents.clone()),
                _ => None,
            })
            .expect("unit written");
        assert!(
            unit.contains("ExecStart=/home/u/.local/bin/bandito --home /srv/bd daemon --listen 127.0.0.1:7878\n"),
            "{unit}"
        );
    }

    #[test]
    fn uninstall_removes_service_files_and_leaves_data_alone() {
        let plan = uninstall_plan(
            &home_paths(),
            &Presence {
                unit: true,
                plist: false,
                pid_file: false,
            },
            1000,
        );
        assert!(plan.actions.contains(&Action::Remove(PathBuf::from(
            "/home/u/.config/systemd/user/bandito.service"
        ))));
        assert!(has_run(
            &plan,
            &["systemctl", "--user", "disable", "--now", "bandito.service"]
        ));
        for a in &plan.actions {
            let touches_data = match a {
                Action::Remove(p) | Action::MakeDir(p) | Action::StopPid(p) => p.starts_with("/home/u/.bandito"),
                Action::WriteFile { path, .. } => path.starts_with("/home/u/.bandito"),
                _ => false,
            };
            assert!(!touches_data, "uninstall touches data: {a:?}");
        }
    }

    #[test]
    fn uninstall_with_nothing_installed_plans_nothing() {
        let plan = uninstall_plan(
            &home_paths(),
            &Presence {
                unit: false,
                plist: false,
                pid_file: false,
            },
            1000,
        );
        assert!(plan.actions.is_empty());
    }

    #[test]
    fn describe_lists_every_file_and_command() {
        let paths = Paths::new(Path::new("/Users/u/.bandito"), Path::new("/Users/u"));
        let plan = install_plan(
            &spec(None),
            &paths,
            Os::MacOs,
            &Probe {
                systemd_user: false,
                setsid: false,
            },
        );
        let text = describe(&plan);
        assert!(
            text.contains("/Users/u/Library/LaunchAgents/dev.bandito.daemon.plist"),
            "{text}"
        );
        assert!(text.contains("launchctl bootstrap gui/1000"), "{text}");
    }

    #[test]
    fn parses_main_pid_from_systemctl_output() {
        assert_eq!(parse_main_pid("4242\n"), Some(4242));
        assert_eq!(parse_main_pid("0\n"), None);
        // Pids that kill(2) cannot take: init, group wide values, and numbers past pid_t.
        assert_eq!(parse_main_pid("1\n"), None);
        assert_eq!(parse_main_pid("4294967295\n"), None);
        assert_eq!(parse_main_pid("2147483648\n"), None);
        assert_eq!(parse_main_pid("2147483647\n"), Some(2147483647));
        assert_eq!(parse_launchctl_pid("\t\"PID\" = 4294967295;\n"), None);
        assert_eq!(signal_pid(1), None);
        assert_eq!(signal_pid(4294967295), None);
        assert_eq!(signal_pid(42), Some(42));
        assert_eq!(parse_main_pid(""), None);
        assert_eq!(parse_main_pid("junk"), None);
    }

    #[test]
    fn parses_pid_from_launchctl_list_output() {
        let out =
            "{\n\t\"LimitLoadToSessionType\" = \"Aqua\";\n\t\"PID\" = 977;\n\t\"Label\" = \"dev.bandito.daemon\";\n};";
        assert_eq!(parse_launchctl_pid(out), Some(977));
        assert_eq!(parse_launchctl_pid("{ \"Label\" = \"x\"; };"), None);
    }

    #[test]
    fn status_json_has_the_documented_shape() {
        let running = status_json(&Status {
            installed: true,
            mode: Some(Mode::Launchd),
            running: true,
            pid: Some(977),
        });
        assert_eq!(
            running,
            json!({"installed": true, "mode": "launchd", "running": true, "pid": 977})
        );
        let absent = status_json(&Status {
            installed: false,
            mode: None,
            running: false,
            pid: None,
        });
        assert_eq!(absent, json!({"installed": false, "mode": null, "running": false}));
    }

    #[test]
    fn install_json_has_the_documented_shape() {
        let v = install_json(true, Mode::Systemd, "127.0.0.1:7878", Path::new("/h/bandito.sock"), &[]);
        assert_eq!(
            v,
            json!({"ok": true, "mode": "systemd", "listen": "127.0.0.1:7878", "socket": "/h/bandito.sock", "warnings": []})
        );
    }

    fn temp_dir() -> tempfile::TempDir {
        tempfile::tempdir().expect("temp dir")
    }

    #[test]
    fn execute_writes_files_and_follows_error_policies() {
        let dir = temp_dir();
        let file = dir.path().join("nested/dir/unit.txt");
        let plan = Plan {
            mode: None,
            actions: vec![
                Action::WriteFile {
                    path: file.clone(),
                    contents: "hello".into(),
                },
                run(&["false"], OnError::Ignore),
                run(&["false"], OnError::Warn("step was optional".into())),
            ],
            warnings: vec!["static".into()],
        };
        let warnings = execute(&plan).expect("plan runs");
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "hello");
        assert_eq!(warnings, ["static", "step was optional"]);
    }

    #[test]
    fn execute_stops_at_a_failing_required_step() {
        let plan = Plan {
            mode: None,
            actions: vec![run(&["false"], OnError::Fail)],
            warnings: Vec::new(),
        };
        let err = execute(&plan).unwrap_err();
        assert!(err.to_string().contains("`false` failed"), "{err}");
    }

    #[test]
    fn spawn_writes_the_pid_and_appends_the_log() {
        let dir = temp_dir();
        let log = dir.path().join("logs/daemon.log");
        let pid_file = dir.path().join("daemon.pid");
        let plan = Plan {
            mode: Some(Mode::Background),
            actions: vec![Action::Spawn {
                argv: vec!["sh".into(), "-c".into(), "echo started".into()],
                log: log.clone(),
                pid_file: pid_file.clone(),
            }],
            warnings: Vec::new(),
        };
        execute(&plan).expect("spawn works");
        assert!(parse_main_pid(&std::fs::read_to_string(&pid_file).unwrap()).is_some());
        let deadline = Instant::now() + Duration::from_secs(5);
        while !std::fs::read_to_string(&log).unwrap_or_default().contains("started") {
            assert!(Instant::now() < deadline, "log never received the output");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn stop_pid_leaves_a_process_that_is_not_bandito_alone() {
        let dir = temp_dir();
        let pid_file = dir.path().join("daemon.pid");
        let mut child = Command::new("sleep").arg("30").spawn().expect("sleep starts");
        std::fs::write(&pid_file, format!("{}\n", child.id())).unwrap();
        let plan = Plan {
            mode: Some(Mode::Background),
            actions: vec![Action::StopPid(pid_file)],
            warnings: Vec::new(),
        };
        execute(&plan).expect("stop step runs");
        std::thread::sleep(Duration::from_millis(200));
        assert!(child.try_wait().unwrap().is_none(), "a non-bandito process was stopped");
        child.kill().ok();
        child.wait().ok();
    }
}
