//! Server setup: what each feature (screen, browser, agents, containers) needs, whether
//! it is there, and installing what is missing. See docs/ARCHITECTURE.md#setup.
//!
//! Bandito never asks for or accepts a sudo password. Package installs run `sudo -n`; when
//! that fails, the job stops with `needs_password` and the command for the user to run in a
//! terminal of the app.

use crate::store::new_id;
use async_trait::async_trait;
use futures_util::future::join_all;
use serde::Serialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncRead, BufReader};
use tokio::sync::mpsc;

/// Newest bytes of a job's log that are kept.
pub const LOG_LIMIT: usize = 256 * 1024;
/// Newest bytes of a command's output that are kept for probes and the Node index.
const OUTPUT_LIMIT: usize = 64 * 1024;
const PROBE_TIMEOUT: Duration = Duration::from_secs(10);
/// Longest one command of an install may run.
const INSTALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const NODE_MIN_MAJOR: u32 = 18;
const NODE_INDEX: &str = "https://nodejs.org/dist/latest-v22.x/";
/// Google's signing key for its apt repositories. Its fingerprint is checked before it is used.
const CHROME_KEY_URL: &str = "https://dl.google.com/linux/linux_signing_key.pub";
/// Primary key of Google's Linux Package Signing Authority, the key that signs the Chrome repository.
const CHROME_KEY_FINGERPRINT: &str = "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796";
const CHROME_KEYRING_NAME: &str = "google-chrome.gpg";
const CHROME_LIST_NAME: &str = "google-chrome.list";
const CHROME_REPO_LINE: &str = "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main";
/// npm packages that Bandito installs, each with the version it is pinned to. The versions move
/// with a Bandito release, never on their own. The default workspace image uses the same table.
pub const NPM_PINS: &[(&str, &str)] = &[("@anthropic-ai/claude-code", "2.1.295"), ("@openai/codex", "0.162.0")];
const DOCKER_DOCS: &str = "https://docs.docker.com/engine/install/";
const GROK_DOCS: &str = "https://x.ai/cli";
pub const BROWSERS: [&str; 4] = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"];

/// Every component id, in the order status reports them.
pub const COMPONENTS: [&str; 13] = [
    "xvfb",
    "x11vnc",
    "xdotool",
    "xauth",
    "imagemagick",
    "window_manager",
    "fonts",
    "browser",
    "node",
    "claude",
    "codex",
    "grok",
    "docker",
];
/// What the screen feature needs.
const SCREEN_COMPONENTS: [&str; 7] = [
    "xvfb",
    "x11vnc",
    "xdotool",
    "xauth",
    "imagemagick",
    "window_manager",
    "fonts",
];
/// Components whose install goes through the system package manager, so through sudo.
const SUDO_COMPONENTS: [&str; 8] = [
    "xvfb",
    "x11vnc",
    "xdotool",
    "xauth",
    "imagemagick",
    "window_manager",
    "fonts",
    "browser",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Feature {
    Screen,
    Browser,
    Agents,
    Containers,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PackageManager {
    Apt,
    Dnf,
    Pacman,
    Brew,
}

/// How sudo can be used without a password prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Sudo {
    /// `sudo -n true` works.
    Passwordless,
    /// sudo is installed but asks for a password.
    Password,
    /// sudo is not installed.
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Ready {
    Ready,
    Missing,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Distro {
    Ubuntu,
    Debian,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum JobState {
    Running,
    Done,
    Failed,
    NeedsPassword,
}

/// One thing a feature needs on the server.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Component {
    pub id: &'static str,
    pub feature: Feature,
    pub installed: bool,
    pub version: Option<String>,
    /// Bandito has an installer for this server.
    pub installable: bool,
    pub needs_sudo: bool,
    /// What to do by hand, when it is not installed and cannot be installed here.
    pub hint: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AgentFeatures {
    pub claude: Ready,
    pub codex: Ready,
    pub grok: Ready,
}

#[derive(Debug, Clone, Serialize)]
pub struct Features {
    pub screen: Ready,
    pub browser: Ready,
    pub containers: Ready,
    pub agents: AgentFeatures,
}

/// Answer of `setup.status`.
#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub os: &'static str,
    pub arch: &'static str,
    pub package_manager: Option<PackageManager>,
    pub sudo: Sudo,
    pub components: Vec<Component>,
    pub features: Features,
}

/// What the server looks like: OS, CPU, package manager, distribution, and where to look for tools.
#[derive(Debug, Clone)]
pub struct Platform {
    pub os: &'static str,
    pub arch: &'static str,
    pub package_manager: Option<PackageManager>,
    pub distro: Distro,
    /// Where components are looked for (`PATH`).
    pub path: OsString,
    /// Browser app bundles that count as installed, besides the names on `PATH` (macOS: Google Chrome).
    pub browser_apps: Vec<PathBuf>,
    /// Where Bandito installs what it needs without root (`<data dir>/tools`).
    pub tools: PathBuf,
    /// apt's configuration folder, where the Chrome key and sources line go.
    pub apt_etc: PathBuf,
}

impl Platform {
    pub fn detect() -> Self {
        let path = std::env::var_os("PATH").unwrap_or_default();
        let os = std::env::consts::OS;
        Self {
            os,
            arch: std::env::consts::ARCH,
            package_manager: detect_package_manager(os, &path),
            distro: std::fs::read_to_string("/etc/os-release")
                .map(|text| distro_from_os_release(&text))
                .unwrap_or(Distro::Other),
            path,
            browser_apps: if os == "macos" {
                vec![PathBuf::from(crate::browser::MAC_CHROME)]
            } else {
                Vec::new()
            },
            tools: tools_dir(),
            apt_etc: PathBuf::from("/etc/apt"),
        }
    }
}

/// The daemon's data directory: `--home`, else `$BANDITO_HOME`, else `~/.bandito` (see [`crate::home::data_home`]).
pub fn default_home() -> PathBuf {
    crate::home::data_home()
}

/// `<data dir>/tools`: where Bandito puts Node and the agent CLIs.
pub fn tools_dir() -> PathBuf {
    default_home().join("tools")
}

/// Puts `<tools>/bin` first on `PATH`, so tools installed by Bandito win over system ones and
/// reach runtimes and terminals. Call it in `main` before any thread starts.
pub fn prepend_tools_to_path() {
    let mut dirs = vec![tools_dir().join("bin")];
    if let Some(old) = std::env::var_os("PATH") {
        dirs.extend(std::env::split_paths(&old));
    }
    match std::env::join_paths(dirs) {
        // SAFETY: called from `main` before the tokio runtime or any other thread starts, so no
        // other thread reads the environment at the same time.
        Ok(path) => unsafe { std::env::set_var("PATH", path) },
        Err(e) => tracing::warn!("could not add the tools folder to PATH: {e}"),
    }
}

/// The first executable called `name` in `path`.
pub fn which(name: &str, path: &OsStr) -> Option<PathBuf> {
    std::env::split_paths(path)
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable(candidate))
}

/// Whether a browser is installed: one of the app bundles, or one of `BROWSERS` on `PATH`.
fn browser_installed(p: &Platform) -> bool {
    p.browser_apps.iter().any(|app| app.is_file()) || BROWSERS.iter().any(|b| which(b, &p.path).is_some())
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The package manager of an OS, found by the tools in `path`.
pub fn detect_package_manager(os: &str, path: &OsStr) -> Option<PackageManager> {
    let candidates: &[(&str, PackageManager)] = match os {
        "linux" => &[
            ("apt-get", PackageManager::Apt),
            ("dnf", PackageManager::Dnf),
            ("pacman", PackageManager::Pacman),
        ],
        "macos" => &[("brew", PackageManager::Brew)],
        _ => &[],
    };
    candidates
        .iter()
        .find(|(bin, _)| which(bin, path).is_some())
        .map(|(_, pm)| *pm)
}

/// Ubuntu and its derivatives count as Ubuntu.
pub fn distro_from_os_release(text: &str) -> Distro {
    let mut words: Vec<String> = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("ID=").or_else(|| line.strip_prefix("ID_LIKE=")) {
            words.extend(value.trim_matches('"').split_whitespace().map(str::to_lowercase));
        }
    }
    if words.iter().any(|w| w == "ubuntu") {
        Distro::Ubuntu
    } else if words.iter().any(|w| w == "debian") {
        Distro::Debian
    } else {
        Distro::Other
    }
}

/// A program and its arguments, run without a shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: String,
    pub args: Vec<String>,
    /// Added to the environment of the child.
    pub env: Vec<(String, String)>,
}

impl CommandSpec {
    pub fn new<I, S>(program: impl Into<String>, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            program: program.into(),
            args: args.into_iter().map(|a| a.into()).collect(),
            env: Vec::new(),
        }
    }

    fn with_env(mut self, key: &str, value: String) -> Self {
        self.env.push((key.to_string(), value));
        self
    }

    /// The command as a person would type it, with arguments quoted for a shell. Environment
    /// variables are not shown.
    pub fn display(&self) -> String {
        std::iter::once(self.program.as_str())
            .chain(self.args.iter().map(String::as_str))
            .map(shell_word)
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// `word` as a shell reads it: as it is when it has only plain characters, otherwise in single
/// quotes, with each `'` written as `'\''`.
fn shell_word(word: &str) -> String {
    let plain = !word.is_empty()
        && word
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_./:=@%+-".contains(&b));
    if plain {
        word.to_string()
    } else {
        format!("'{}'", word.replace('\'', "'\\''"))
    }
}

/// Result of one command. `output` is its stdout and stderr lines, newest `OUTPUT_LIMIT` bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub success: bool,
    pub code: Option<i32>,
    pub output: String,
}

/// Runs commands. The real one is [`SystemRunner`]; tests use a scripted one.
#[async_trait]
pub trait CommandRunner: Send + Sync {
    /// Runs `spec` with no stdin and waits for it. Each stdout or stderr line goes to `on_line` as
    /// it arrives. Errors when the program cannot start or does not finish within `timeout`; then
    /// it is killed.
    async fn run(
        &self,
        spec: &CommandSpec,
        timeout: Duration,
        on_line: &(dyn Fn(String) + Sync),
    ) -> io::Result<CommandResult>;
}

/// Runs real processes.
pub struct SystemRunner;

#[async_trait]
impl CommandRunner for SystemRunner {
    async fn run(
        &self,
        spec: &CommandSpec,
        timeout: Duration,
        on_line: &(dyn Fn(String) + Sync),
    ) -> io::Result<CommandResult> {
        let mut child = tokio::process::Command::new(&spec.program)
            .args(&spec.args)
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        if let Some(out) = child.stdout.take() {
            tokio::spawn(pump_lines(out, tx.clone()));
        }
        if let Some(err) = child.stderr.take() {
            tokio::spawn(pump_lines(err, tx.clone()));
        }
        drop(tx);
        let work = async {
            let mut output = String::new();
            while let Some(line) = rx.recv().await {
                append_capped(&mut output, &format!("{line}\n"), OUTPUT_LIMIT);
                on_line(line);
            }
            let status = child.wait().await?;
            Ok::<_, io::Error>(CommandResult {
                success: status.success(),
                code: status.code(),
                output,
            })
        };
        match tokio::time::timeout(timeout, work).await {
            Ok(result) => result,
            // The child is killed when `child` is dropped on return.
            Err(_) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                format!("`{}` ran longer than {} s", spec.program, timeout.as_secs()),
            )),
        }
    }
}

async fn pump_lines(pipe: impl AsyncRead + Unpin, tx: mpsc::UnboundedSender<String>) {
    let mut lines = BufReader::new(pipe).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        if tx.send(line).is_err() {
            break;
        }
    }
}

/// Appends `text` to `buf` and drops the oldest bytes so that at most `max` remain.
/// Returns how many bytes were dropped.
fn append_capped(buf: &mut String, text: &str, max: usize) -> u64 {
    buf.push_str(text);
    if buf.len() <= max {
        return 0;
    }
    let mut cut = buf.len() - max;
    while !buf.is_char_boundary(cut) {
        cut += 1;
    }
    buf.drain(..cut);
    cut as u64
}

/// The name of the Node build for this OS and CPU, as in the tarball names. `None` when there is none.
fn node_platform(p: &Platform) -> Option<&'static str> {
    Some(match (p.os, p.arch) {
        ("linux", "x86_64") => "linux-x64",
        ("linux", "aarch64") => "linux-arm64",
        ("macos", "x86_64") => "darwin-x64",
        ("macos", "aarch64") => "darwin-arm64",
        _ => return None,
    })
}

/// `v22.11.0` → true. Anything that is not a Node version, or an older one, is false.
pub fn node_is_supported(version_output: &str) -> bool {
    version_output
        .trim()
        .strip_prefix('v')
        .and_then(|version| version.split('.').next())
        .and_then(|major| major.parse::<u32>().ok())
        .is_some_and(|major| major >= NODE_MIN_MAJOR)
}

/// Finds the Node tarball of `platform` (such as `linux-x64`) in a `SHASUMS256.txt`.
/// Returns the file name and its lowercase sha256.
pub fn pick_node_tarball(shasums: &str, platform: &str) -> Option<(String, String)> {
    let suffix = format!("-{platform}.tar.xz");
    shasums.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let (hash, file) = (parts.next()?, parts.next()?);
        let file = file.trim_start_matches('*');
        (file.starts_with("node-v") && file.ends_with(&suffix)).then(|| (file.to_string(), hash.to_lowercase()))
    })
}

/// `fc-list` output lists the Noto families when they are installed.
pub fn has_noto_font(fc_list_output: &str) -> bool {
    fc_list_output.to_lowercase().contains("noto")
}

/// True when the output of `gpg --show-keys --with-colons` on a keyring lists exactly one primary
/// key (`pub:`), and the `fpr:` line right after it is Google's Chrome signing key. Subkeys do not
/// count, and a keyring with a second key glued on is refused.
pub fn is_chrome_signing_key(show_keys_output: &str) -> bool {
    let lines: Vec<&str> = show_keys_output.lines().collect();
    let pub_lines: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| line.starts_with("pub:"))
        .map(|(at, _)| at)
        .collect();
    let [pub_at] = pub_lines.as_slice() else {
        return false;
    };
    let wanted = normalize_fingerprint(CHROME_KEY_FINGERPRINT);
    lines.get(pub_at + 1).is_some_and(|line| {
        line.starts_with("fpr:")
            && line
                .split(':')
                .skip(1)
                .any(|field| normalize_fingerprint(field) == wanted)
    })
}

fn normalize_fingerprint(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_whitespace())
        .collect::<String>()
        .to_ascii_uppercase()
}

/// One way to install a component on a platform.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Plan {
    /// Node from the official tarball into `<tools>/node`, with links in `<tools>/bin`.
    Node,
    /// System packages for one component.
    Packages {
        id: &'static str,
        names: &'static [&'static str],
    },
    /// Google Chrome from Google's signed apt repository, for Ubuntu on x86_64.
    ChromeRepo,
    /// `npm install -g <package>@<version>` into `<tools>`.
    Npm {
        id: &'static str,
        package: &'static str,
        version: &'static str,
    },
}

fn plan_rank(plan: &Plan) -> u8 {
    match plan {
        Plan::Node => 0,
        Plan::Packages { .. } => 1,
        Plan::ChromeRepo => 2,
        Plan::Npm { .. } => 3,
    }
}

/// The npm plan of a CLI, pinned by `NPM_PINS`. `None` when the package has no pin.
fn npm_plan(id: &'static str, package: &'static str) -> Option<Plan> {
    let version = NPM_PINS.iter().find(|(name, _)| *name == package)?.1;
    Some(Plan::Npm { id, package, version })
}

/// Package names of a component for a package manager.
fn package_names(id: &str, pm: PackageManager) -> Option<&'static [&'static str]> {
    use PackageManager::{Apt, Dnf, Pacman};
    let names: &'static [&'static str] = match (id, pm) {
        ("xvfb", Apt) => &["xvfb"],
        ("xvfb", Dnf) => &["xorg-x11-server-Xvfb"],
        ("xvfb", Pacman) => &["xorg-server-xvfb"],
        ("x11vnc", Apt | Dnf | Pacman) => &["x11vnc"],
        ("xdotool", Apt | Dnf | Pacman) => &["xdotool"],
        ("xauth", Apt) => &["xauth"],
        ("xauth", Dnf) => &["xorg-x11-xauth"],
        ("xauth", Pacman) => &["xorg-xauth"],
        // The `import` and `convert` programs of ImageMagick, for screenshots.
        ("imagemagick", Apt) => &["imagemagick"],
        ("imagemagick", Dnf) => &["ImageMagick"],
        ("imagemagick", Pacman) => &["imagemagick"],
        ("window_manager", Apt | Dnf | Pacman) => &["openbox"],
        ("fonts", Apt) => &["fonts-noto", "fonts-noto-color-emoji"],
        ("fonts", Dnf) => &["google-noto-sans-fonts"],
        ("fonts", Pacman) => &["noto-fonts"],
        ("browser", Apt | Dnf | Pacman) => &["chromium"],
        _ => return None,
    };
    Some(names)
}

/// Package names of a component on this server. Only Linux has packages here.
fn packages_for(id: &str, p: &Platform) -> Option<&'static [&'static str]> {
    if p.os != "linux" {
        return None;
    }
    package_names(id, p.package_manager?)
}

/// How a component is installed on this server, or `None` when Bandito cannot install it here.
fn plan_for(id: &'static str, p: &Platform) -> Option<Plan> {
    match id {
        "node" => node_platform(p).map(|_| Plan::Node),
        "claude" => node_platform(p).and_then(|_| npm_plan("claude", "@anthropic-ai/claude-code")),
        "codex" => node_platform(p).and_then(|_| npm_plan("codex", "@openai/codex")),
        "browser" => {
            if p.os == "linux" && p.package_manager == Some(PackageManager::Apt) && p.distro == Distro::Ubuntu {
                // Ubuntu's chromium-browser is a snap. Google Chrome comes from Google's apt repository instead, on x86_64 only.
                return (p.arch == "x86_64").then_some(Plan::ChromeRepo);
            }
            packages_for(id, p).map(|names| Plan::Packages { id, names })
        }
        _ => packages_for(id, p).map(|names| Plan::Packages { id, names }),
    }
}

/// Why a component cannot be installed here, for the user.
fn unavailable_hint(id: &str, p: &Platform) -> String {
    match id {
        "grok" => GROK_DOCS.into(),
        "docker" => DOCKER_DOCS.into(),
        "browser" => "install Chromium or Google Chrome yourself".into(),
        "node" | "claude" | "codex" => "no built-in installer for this OS and CPU".into(),
        _ if p.os != "linux" => "screen features need Linux".into(),
        _ => "no supported package manager (apt, dnf or pacman)".into(),
    }
}

fn feature_of(id: &str) -> Feature {
    match id {
        "browser" => Feature::Browser,
        "node" | "claude" | "codex" | "grok" => Feature::Agents,
        "docker" => Feature::Containers,
        _ => Feature::Screen,
    }
}

/// `sudo`, with `-n` (never ask for a password) when `non_interactive`.
fn sudo_command<I, S>(non_interactive: bool, words: I) -> CommandSpec
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args: Vec<String> = Vec::new();
    if non_interactive {
        args.push("-n".into());
    }
    args.extend(words.into_iter().map(|w| w.into()));
    CommandSpec {
        program: "sudo".into(),
        args,
        env: Vec::new(),
    }
}

fn apt_update(non_interactive: bool) -> CommandSpec {
    sudo_command(non_interactive, ["apt-get", "update"])
}

/// Commands that install `pkgs` with the system package manager. With `non_interactive` they run
/// `sudo -n`, which fails rather than ask for a password. The text shown to the user is the same
/// without `-n`.
pub fn package_commands(pm: PackageManager, pkgs: &[&str], non_interactive: bool) -> Vec<CommandSpec> {
    if pkgs.is_empty() {
        return Vec::new();
    }
    match pm {
        PackageManager::Apt => vec![
            apt_update(non_interactive),
            sudo_command(
                non_interactive,
                ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "-y"]
                    .into_iter()
                    .chain(pkgs.iter().copied()),
            ),
        ],
        PackageManager::Dnf => vec![sudo_command(
            non_interactive,
            ["dnf", "install", "-y"].into_iter().chain(pkgs.iter().copied()),
        )],
        PackageManager::Pacman => vec![sudo_command(
            non_interactive,
            ["pacman", "-S", "--needed", "--noconfirm"]
                .into_iter()
                .chain(pkgs.iter().copied()),
        )],
        PackageManager::Brew => Vec::new(),
    }
}

/// The files of Google's Chrome repository. The key is downloaded and checked in `<tools>/downloads`,
/// then the keyring and the sources line are installed where apt reads them (`apt_etc`).
#[derive(Debug, Clone, PartialEq, Eq)]
struct ChromeRepo {
    /// The key as downloaded (ASCII armored).
    key_download: PathBuf,
    /// The key as a keyring, from `gpg --dearmor`.
    keyring: PathBuf,
    /// The sources line, written by Bandito.
    list: PathBuf,
    keyring_target: PathBuf,
    list_target: PathBuf,
}

fn chrome_repo(tools: &Path, apt_etc: &Path) -> ChromeRepo {
    let downloads = tools.join("downloads");
    ChromeRepo {
        key_download: downloads.join("google-linux-signing-key.pub"),
        keyring: downloads.join(CHROME_KEYRING_NAME),
        list: downloads.join(CHROME_LIST_NAME),
        keyring_target: apt_etc.join("keyrings").join(CHROME_KEYRING_NAME),
        list_target: apt_etc.join("sources.list.d").join(CHROME_LIST_NAME),
    }
}

/// The sudo steps of Google Chrome, in order. Unless the key and the sources line are in place
/// (`configured`), they are installed first. Then apt updates from the Chrome list alone, and
/// installs Chrome.
fn chrome_repo_commands(repo: &ChromeRepo, configured: bool, non_interactive: bool) -> Vec<CommandSpec> {
    let keyring = repo.keyring.display().to_string();
    let keyring_target = repo.keyring_target.display().to_string();
    let list = repo.list.display().to_string();
    let list_target = repo.list_target.display().to_string();
    let source_list = format!("Dir::Etc::sourcelist=sources.list.d/{CHROME_LIST_NAME}");
    let mut steps = Vec::new();
    if !configured {
        steps.push(sudo_command(
            non_interactive,
            ["install", "-D", "-m", "0644", keyring.as_str(), keyring_target.as_str()],
        ));
        steps.push(sudo_command(
            non_interactive,
            ["install", "-D", "-m", "0644", list.as_str(), list_target.as_str()],
        ));
    }
    steps.push(sudo_command(
        non_interactive,
        [
            "env",
            "DEBIAN_FRONTEND=noninteractive",
            "apt-get",
            "update",
            "-o",
            source_list.as_str(),
            "-o",
            "Dir::Etc::sourceparts=-",
            "-o",
            "APT::Get::List-Cleanup=0",
        ],
    ));
    steps.push(sudo_command(
        non_interactive,
        [
            "env",
            "DEBIAN_FRONTEND=noninteractive",
            "apt-get",
            "install",
            "-y",
            "google-chrome-stable",
        ],
    ));
    steps
}

/// The package batch of the plans as commands: one update and one install with apt. `gpg` joins
/// the batch when the Chrome key needs it and it is missing.
fn batch_commands(p: &Platform, plans: &[Plan], need_gpg: bool, non_interactive: bool) -> Vec<CommandSpec> {
    let mut names: Vec<&str> = plans
        .iter()
        .flat_map(|plan| match plan {
            Plan::Packages { names, .. } => names.to_vec(),
            _ => Vec::new(),
        })
        .collect();
    if need_gpg {
        names.push("gpg");
    }
    match p.package_manager {
        Some(pm) => package_commands(pm, &names, non_interactive),
        None => Vec::new(),
    }
}

fn npm_install(package: &str, version: &str, tools: &Path) -> CommandSpec {
    let spec = format!("{package}@{version}");
    CommandSpec::new("npm", ["install", "-g", spec.as_str()]).with_env("NPM_CONFIG_PREFIX", tools.display().to_string())
}

/// Whether a component is installed, with its version and a hint when it is not.
fn features(p: &Platform, installed: &dyn Fn(&str) -> bool) -> Features {
    let all = |ids: &[&str]| {
        if ids.iter().all(|id| installed(id)) {
            Ready::Ready
        } else {
            Ready::Missing
        }
    };
    Features {
        screen: if p.os == "linux" {
            all(&SCREEN_COMPONENTS)
        } else {
            Ready::Unsupported
        },
        browser: if p.os == "linux" {
            all(&["browser", "fonts"])
        } else {
            all(&["browser"])
        },
        containers: all(&["docker"]),
        agents: AgentFeatures {
            claude: all(&["claude"]),
            codex: all(&["codex"]),
            grok: all(&["grok"]),
        },
    }
}

/// Result of an install job, before it is written to the job.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Outcome {
    Done,
    Failed {
        component: Option<&'static str>,
        message: String,
    },
    NeedsPassword {
        command: String,
    },
}

/// One install job: its state and log, read by `setup.job`.
pub struct Job {
    id: String,
    inner: Mutex<JobInner>,
}

struct JobInner {
    state: JobState,
    step: String,
    /// Newest `LOG_LIMIT` bytes of the log.
    log: String,
    /// Bytes dropped from the front of the log so far.
    dropped: u64,
    command: Option<String>,
    failed_component: Option<String>,
}

fn append_line(inner: &mut JobInner, line: &str) {
    let dropped = append_capped(&mut inner.log, &format!("{line}\n"), LOG_LIMIT);
    inner.dropped += dropped;
}

impl Job {
    fn new(id: String) -> Arc<Self> {
        Arc::new(Self {
            id,
            inner: Mutex::new(JobInner {
                state: JobState::Running,
                step: "Starting".into(),
                log: String::new(),
                dropped: 0,
                command: None,
                failed_component: None,
            }),
        })
    }

    fn lock(&self) -> MutexGuard<'_, JobInner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn is_running(&self) -> bool {
        self.lock().state == JobState::Running
    }

    pub fn push_log(&self, line: &str) {
        append_line(&mut self.lock(), line);
    }

    fn set_step(&self, step: impl Into<String>) {
        self.lock().step = step.into();
    }

    fn finish(&self, outcome: Outcome) {
        let mut inner = self.lock();
        match outcome {
            Outcome::Done => {
                inner.state = JobState::Done;
                inner.step = "Done".into();
            }
            Outcome::Failed { component, message } => {
                append_line(&mut inner, &format!("failed: {message}"));
                inner.state = JobState::Failed;
                inner.step = message;
                inner.failed_component = component.map(str::to_string);
            }
            Outcome::NeedsPassword { command } => {
                inner.state = JobState::NeedsPassword;
                inner.step =
                    "Needs the sudo password: run the command in a terminal of the app, then install again.".into();
                inner.command = Some(command);
            }
        }
    }

    /// The job as `setup.job` answers it. `from` is a byte offset into the log; bytes older than
    /// the kept log are not there any more, so the answer starts with the oldest kept byte.
    pub fn snapshot(&self, from: u64) -> Value {
        let inner = self.lock();
        let len = inner.log.len();
        let mut start = from.saturating_sub(inner.dropped).min(len as u64) as usize;
        while start < len && !inner.log.is_char_boundary(start) {
            start += 1;
        }
        let mut out = json!({
            "state": inner.state,
            "step": inner.step,
            "log": &inner.log[start..],
            "offset": inner.dropped + len as u64,
        });
        if let Some(command) = &inner.command {
            out["command"] = json!(command);
        }
        if let Some(component) = &inner.failed_component {
            out["failed_component"] = json!(component);
        }
        out
    }
}

/// Why `setup.install` refused to start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallError {
    Empty,
    UnknownComponent(String),
    /// Another install is still running.
    Busy,
}

/// Status and installs of this server's components.
pub struct Setup {
    platform: Platform,
    runner: Arc<dyn CommandRunner>,
    /// The most recent job. A new install may start only when it is not running.
    current: Mutex<Option<Arc<Job>>>,
}

impl Setup {
    pub fn new(platform: Platform, runner: Arc<dyn CommandRunner>) -> Arc<Self> {
        Arc::new(Self {
            platform,
            runner,
            current: Mutex::new(None),
        })
    }

    /// The setup of this machine, with real commands.
    pub fn system() -> Arc<Self> {
        Self::new(Platform::detect(), Arc::new(SystemRunner))
    }

    /// Starts an install job in the background and returns its id. One job at a time.
    pub fn start_install(self: &Arc<Self>, ids: &[String]) -> Result<String, InstallError> {
        if ids.is_empty() {
            return Err(InstallError::Empty);
        }
        let mut wanted: Vec<&'static str> = Vec::new();
        for id in ids {
            let known = COMPONENTS
                .iter()
                .copied()
                .find(|c| *c == id.as_str())
                .ok_or_else(|| InstallError::UnknownComponent(id.clone()))?;
            if !wanted.contains(&known) {
                wanted.push(known);
            }
        }
        let job = {
            let mut current = self.current.lock().unwrap_or_else(|e| e.into_inner());
            if current.as_ref().is_some_and(|job| job.is_running()) {
                return Err(InstallError::Busy);
            }
            let job = Job::new(new_id());
            *current = Some(job.clone());
            job
        };
        let id = job.id.clone();
        let setup = self.clone();
        tokio::spawn(async move {
            let outcome = setup.install(&job, &wanted).await;
            job.finish(outcome);
        });
        Ok(id)
    }

    /// The job with this id, if it is the most recent one.
    pub fn job(&self, id: &str, from: u64) -> Option<Value> {
        let current = self.current.lock().unwrap_or_else(|e| e.into_inner());
        current
            .as_ref()
            .filter(|job| job.id == id)
            .map(|job| job.snapshot(from))
    }

    pub async fn status(&self) -> Status {
        let sudo = self.sudo_state().await;
        let components = join_all(COMPONENTS.iter().map(|id| self.probe(id))).await;
        let installed = |id: &str| components.iter().any(|c| c.id == id && c.installed);
        let features = features(&self.platform, &installed);
        Status {
            os: self.platform.os,
            arch: self.platform.arch,
            package_manager: self.platform.package_manager,
            sudo,
            components,
            features,
        }
    }

    /// Checks one component.
    pub async fn probe(&self, id: &'static str) -> Component {
        let p = &self.platform;
        let (installed, version, hint) = match id {
            "fonts" => (self.fonts_installed().await, None, None),
            // The same lookup the browser feature starts Chrome with, so the status matches what runs.
            "browser" => (browser_installed(p), None, None),
            "docker" => self.docker_probe().await,
            "node" => {
                let (_, version) = self.binary("node", true).await;
                (version.as_deref().is_some_and(node_is_supported), version, None)
            }
            "claude" | "codex" | "grok" => {
                let (installed, version) = self.binary(id, true).await;
                (installed, version, None)
            }
            _ => {
                let name = match id {
                    "xvfb" => "Xvfb",
                    "window_manager" => "openbox",
                    "imagemagick" => "import",
                    other => other,
                };
                (self.binary(name, false).await.0, None, None)
            }
        };
        let installable = plan_for(id, p).is_some();
        let hint = hint.or_else(|| (!installable && !installed).then(|| unavailable_hint(id, p)));
        Component {
            id,
            feature: feature_of(id),
            installed,
            version,
            installable,
            needs_sudo: SUDO_COMPONENTS.contains(&id),
            hint,
        }
    }

    /// Whether sudo works without a password. Never gives it one.
    pub async fn sudo_state(&self) -> Sudo {
        if which("sudo", &self.platform.path).is_none() {
            return Sudo::None;
        }
        match self
            .runner
            .run(
                &CommandSpec::new("sudo", ["-n", "true"]),
                PROBE_TIMEOUT,
                &|_: String| {},
            )
            .await
        {
            Ok(r) if r.success => Sudo::Passwordless,
            _ => Sudo::Password,
        }
    }

    /// Found on the path, and answers `--version` when `versioned`.
    async fn binary(&self, name: &str, versioned: bool) -> (bool, Option<String>) {
        let Some(path) = which(name, &self.platform.path) else {
            return (false, None);
        };
        if !versioned {
            return (true, None);
        }
        let version = self.version_of(&path).await;
        (version.is_some(), version)
    }

    async fn version_of(&self, path: &Path) -> Option<String> {
        let spec = CommandSpec::new(path.display().to_string(), ["--version"]);
        let r = self.runner.run(&spec, PROBE_TIMEOUT, &|_: String| {}).await.ok()?;
        if !r.success {
            return None;
        }
        r.output
            .lines()
            .map(str::trim)
            .find(|l| !l.is_empty())
            .map(str::to_string)
    }

    async fn fonts_installed(&self) -> bool {
        let Some(fc_list) = which("fc-list", &self.platform.path) else {
            return false;
        };
        let spec = CommandSpec::new(fc_list.display().to_string(), Vec::<String>::new());
        match self.runner.run(&spec, PROBE_TIMEOUT, &|_: String| {}).await {
            Ok(r) => r.success && has_noto_font(&r.output),
            Err(_) => false,
        }
    }

    /// `docker info` must succeed. A permission error gets the group hint, anything else the docs.
    async fn docker_probe(&self) -> (bool, Option<String>, Option<String>) {
        let Some(docker) = which("docker", &self.platform.path) else {
            return (false, None, Some(DOCKER_DOCS.into()));
        };
        let spec = CommandSpec::new(docker.display().to_string(), ["info"]);
        match self.runner.run(&spec, PROBE_TIMEOUT, &|_: String| {}).await {
            Ok(r) if r.success => (true, None, None),
            Ok(r) if r.output.to_lowercase().contains("permission denied") => {
                (false, None, Some("sudo usermod -aG docker $USER".into()))
            }
            _ => (false, None, Some(DOCKER_DOCS.into())),
        }
    }

    async fn first_missing(&self, ids: &[&'static str]) -> Option<&'static str> {
        for id in ids {
            if !self.probe(id).await.installed {
                return Some(id);
            }
        }
        None
    }

    async fn failed(&self, missing: &[&'static str], message: String) -> Outcome {
        Outcome::Failed {
            component: self.first_missing(missing).await,
            message,
        }
    }

    /// The whole install of the requested components, in order: Node, then system packages (one
    /// batch, sudo), then Google Chrome, then npm packages. Nothing runs when sudo would need a
    /// password.
    async fn install(&self, job: &Job, requested: &[&'static str]) -> Outcome {
        let mut missing: Vec<&'static str> = Vec::new();
        for &id in requested {
            if !self.probe(id).await.installed {
                missing.push(id);
            }
        }
        if missing.is_empty() {
            job.push_log("Everything requested is installed already.");
            return Outcome::Done;
        }
        // claude and codex are npm packages that run on node: node comes with them when missing.
        if missing.iter().any(|id| matches!(*id, "claude" | "codex"))
            && !missing.contains(&"node")
            && !self.probe("node").await.installed
        {
            job.push_log("claude and codex run on node: node is added to the install.");
            missing.insert(0, "node");
        }
        let mut plans: Vec<(&'static str, Plan)> = Vec::new();
        for &id in &missing {
            match plan_for(id, &self.platform) {
                Some(plan) => plans.push((id, plan)),
                None => {
                    return Outcome::Failed {
                        component: Some(id),
                        message: format!(
                            "{id} cannot be installed on this server: {}",
                            unavailable_hint(id, &self.platform)
                        ),
                    };
                }
            }
        }
        plans.sort_by_key(|(_, plan)| plan_rank(plan));
        let all_plans: Vec<Plan> = plans.iter().map(|(_, plan)| plan.clone()).collect();
        let chrome = all_plans.contains(&Plan::ChromeRepo);
        // The Chrome key is checked with gpg. When gpg is missing, it joins the package batch.
        let need_gpg = chrome && which("gpg", &self.platform.path).is_none();
        let repo = chrome_repo(&self.platform.tools, &self.platform.apt_etc);

        if all_plans
            .iter()
            .any(|plan| matches!(plan, Plan::Packages { .. } | Plan::ChromeRepo))
        {
            match self.sudo_state().await {
                Sudo::Passwordless => {}
                Sudo::Password => {
                    let mut commands = batch_commands(&self.platform, &all_plans, need_gpg, false);
                    // The key is checked now, before the user is asked to run the commands, so that
                    // their Chrome steps name files that exist. The check needs gpg: without it, the
                    // commands are the package batch only, and the Chrome steps come on the next run.
                    if chrome && !need_gpg {
                        match self.prepare_chrome_repo(job, &repo).await {
                            Ok(configured) => commands.extend(chrome_repo_commands(&repo, configured, false)),
                            Err(message) => return self.failed(&missing, message).await,
                        }
                    }
                    let command = commands
                        .iter()
                        .map(CommandSpec::display)
                        .collect::<Vec<_>>()
                        .join(" && ");
                    return Outcome::NeedsPassword { command };
                }
                Sudo::None => {
                    return Outcome::Failed {
                        component: None,
                        message: "sudo is not installed, so system packages cannot be installed".into(),
                    };
                }
            }
        }

        if plans.iter().any(|(_, plan)| *plan == Plan::Node) {
            job.set_step("Installing node");
            if let Err(message) = self.install_node(job).await {
                return self.failed(&missing, message).await;
            }
        }
        let batch = batch_commands(&self.platform, &all_plans, need_gpg, true);
        if !batch.is_empty() {
            job.set_step("Installing system packages");
            for spec in &batch {
                if let Err(message) = self.run_step(job, spec, INSTALL_TIMEOUT).await {
                    return self.failed(&missing, message).await;
                }
            }
        }
        if chrome {
            job.set_step("Installing Google Chrome");
            let configured = match self.prepare_chrome_repo(job, &repo).await {
                Ok(configured) => configured,
                Err(message) => return self.failed(&missing, message).await,
            };
            for spec in chrome_repo_commands(&repo, configured, true) {
                if let Err(message) = self.run_step(job, &spec, INSTALL_TIMEOUT).await {
                    return self.failed(&missing, message).await;
                }
            }
        }
        for (id, plan) in &plans {
            if let Plan::Npm { package, version, .. } = plan {
                job.set_step(format!("Installing {id}"));
                if let Err(e) = std::fs::create_dir_all(&self.platform.tools) {
                    return self
                        .failed(&missing, format!("create {}: {e}", self.platform.tools.display()))
                        .await;
                }
                let spec = npm_install(package, version, &self.platform.tools);
                if let Err(message) = self.run_step(job, &spec, INSTALL_TIMEOUT).await {
                    return self.failed(&missing, message).await;
                }
            }
        }
        for &id in &missing {
            if !self.probe(id).await.installed {
                return Outcome::Failed {
                    component: Some(id),
                    message: format!("{id} is still not found after the install"),
                };
            }
        }
        Outcome::Done
    }

    /// `gpg --show-keys --with-colons FILE`: its output. Errors when gpg cannot read the file.
    async fn show_keys(&self, file: &Path) -> Result<String, String> {
        let file = file.display().to_string();
        let spec = CommandSpec::new("gpg", ["--show-keys", "--with-colons", file.as_str()]);
        match self.runner.run(&spec, PROBE_TIMEOUT, &|_: String| {}).await {
            Ok(r) if r.success => Ok(r.output),
            Ok(_) => Err(format!("gpg could not read {file}")),
            Err(e) => Err(format!("gpg could not run: {e}")),
        }
    }

    /// Whether the Chrome key and the sources line are in place already, with the right key.
    /// Changes nothing.
    async fn chrome_repo_configured(&self, repo: &ChromeRepo) -> bool {
        let list_ok = std::fs::read_to_string(&repo.list_target).is_ok_and(|text| text.trim_end() == CHROME_REPO_LINE);
        if !list_ok || !repo.keyring_target.is_file() {
            return false;
        }
        self.show_keys(&repo.keyring_target)
            .await
            .is_ok_and(|listing| is_chrome_signing_key(&listing))
    }

    /// Gets Google's key and turns it into a keyring in `<tools>/downloads`. The keyring is checked
    /// before anything is installed: it must hold exactly the Chrome signing key as its primary key.
    /// Then the sources line is written next to it. Returns `true` when the repository was configured
    /// already, and then writes nothing. A keyring that fails the check is deleted and the job stops.
    async fn prepare_chrome_repo(&self, job: &Job, repo: &ChromeRepo) -> Result<bool, String> {
        if self.chrome_repo_configured(repo).await {
            job.push_log("The Google Chrome key and repository are in place already.");
            return Ok(true);
        }
        let downloads = self.platform.tools.join("downloads");
        std::fs::create_dir_all(&downloads).map_err(|e| format!("create {}: {e}", downloads.display()))?;
        job.set_step("Checking the Google Chrome signing key");
        let key_arg = repo.key_download.display().to_string();
        self.run_step(
            job,
            &CommandSpec::new(
                "curl",
                [
                    "--proto",
                    "=https",
                    "--tlsv1.2",
                    "-fsSL",
                    "-o",
                    key_arg.as_str(),
                    CHROME_KEY_URL,
                ],
            ),
            INSTALL_TIMEOUT,
        )
        .await?;
        let keyring_arg = repo.keyring.display().to_string();
        self.run_step(
            job,
            &CommandSpec::new(
                "gpg",
                [
                    "--batch",
                    "--yes",
                    "--dearmor",
                    "-o",
                    keyring_arg.as_str(),
                    key_arg.as_str(),
                ],
            ),
            PROBE_TIMEOUT,
        )
        .await?;
        // The keyring is checked, not the download: this is the file that apt will trust.
        let checked = match self.show_keys(&repo.keyring).await {
            Ok(listing) if is_chrome_signing_key(&listing) => Ok(()),
            Ok(_) => {
                job.push_log(&format!(
                    "expected one primary key, with the fingerprint {CHROME_KEY_FINGERPRINT}"
                ));
                Err("Google signing key fingerprint mismatch".to_string())
            }
            Err(message) => Err(message),
        };
        if let Err(message) = checked {
            let _ = std::fs::remove_file(&repo.keyring);
            let _ = std::fs::remove_file(&repo.key_download);
            return Err(message);
        }
        std::fs::write(&repo.list, format!("{CHROME_REPO_LINE}\n"))
            .map_err(|e| format!("write {}: {e}", repo.list.display()))?;
        Ok(false)
    }

    /// Runs one command and logs its output to the job.
    async fn run_step(&self, job: &Job, spec: &CommandSpec, timeout: Duration) -> Result<(), String> {
        job.push_log(&format!("$ {}", spec.display()));
        match self
            .runner
            .run(spec, timeout, &|line: String| job.push_log(&line))
            .await
        {
            Ok(r) if r.success => Ok(()),
            Ok(r) => Err(format!(
                "`{}` failed (exit code {})",
                spec.display(),
                r.code.map_or("none".to_string(), |c| c.to_string())
            )),
            Err(e) => Err(format!("`{}` could not run: {e}", spec.display())),
        }
    }

    async fn fetch(&self, url: &str) -> Result<String, String> {
        let spec = CommandSpec::new("curl", ["-fsSL", url]);
        match self.runner.run(&spec, INSTALL_TIMEOUT, &|_: String| {}).await {
            Ok(r) if r.success => Ok(r.output),
            Ok(_) => Err(format!("could not fetch {url}")),
            Err(e) => Err(format!("could not fetch {url}: {e}")),
        }
    }

    /// Official Node 22 tarball into `<tools>/node`, checked against its sha256, then linked as
    /// `node`, `npm` and `npx` in `<tools>/bin`. No root needed.
    async fn install_node(&self, job: &Job) -> Result<(), String> {
        let platform = node_platform(&self.platform).ok_or("no Node build for this OS and CPU")?;
        let shasums = self.fetch(&format!("{NODE_INDEX}SHASUMS256.txt")).await?;
        let (file, expected) = pick_node_tarball(&shasums, platform)
            .ok_or_else(|| format!("no Node tarball for {platform} in SHASUMS256.txt"))?;
        let tools = &self.platform.tools;
        let downloads = tools.join("downloads");
        std::fs::create_dir_all(&downloads).map_err(|e| format!("create {}: {e}", downloads.display()))?;
        let tarball = downloads.join(&file);
        let tarball_arg = tarball.display().to_string();
        let url = format!("{NODE_INDEX}{file}");
        self.run_step(
            job,
            &CommandSpec::new("curl", ["-fsSL", "-o", tarball_arg.as_str(), url.as_str()]),
            INSTALL_TIMEOUT,
        )
        .await?;
        let bytes = std::fs::read(&tarball).map_err(|e| format!("read {}: {e}", tarball.display()))?;
        if hex::encode(Sha256::digest(&bytes)) != expected {
            let _ = std::fs::remove_file(&tarball);
            return Err(format!("sha256 of {file} does not match SHASUMS256.txt"));
        }
        drop(bytes);
        let staging = tools.join("node.new");
        let _ = std::fs::remove_dir_all(&staging);
        std::fs::create_dir_all(&staging).map_err(|e| format!("create {}: {e}", staging.display()))?;
        let staging_arg = staging.display().to_string();
        self.run_step(
            job,
            &CommandSpec::new(
                "tar",
                [
                    "-xJf",
                    tarball_arg.as_str(),
                    "-C",
                    staging_arg.as_str(),
                    "--strip-components=1",
                ],
            ),
            INSTALL_TIMEOUT,
        )
        .await?;
        let _ = std::fs::remove_file(&tarball);
        let node_dir = tools.join("node");
        let _ = std::fs::remove_dir_all(&node_dir);
        std::fs::rename(&staging, &node_dir).map_err(|e| format!("install node: {e}"))?;
        let bin = tools.join("bin");
        std::fs::create_dir_all(&bin).map_err(|e| format!("create {}: {e}", bin.display()))?;
        for name in ["node", "npm", "npx"] {
            let link = bin.join(name);
            let _ = std::fs::remove_file(&link);
            std::os::unix::fs::symlink(Path::new("../node/bin").join(name), &link)
                .map_err(|e| format!("link {}: {e}", link.display()))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use tokio::sync::Notify;

    /// What the mock runner answers for one command.
    #[derive(Clone)]
    enum Reply {
        Exit {
            success: bool,
            output: String,
        },
        /// Waits until the notify is signalled, then succeeds.
        Gate(Arc<Notify>),
    }

    /// Answers by `<program file name> <args>`. Commands without a reply fail to start, as a
    /// missing program does. Records every command it is asked for.
    #[derive(Default)]
    struct MockRunner {
        replies: Mutex<HashMap<String, Reply>>,
        calls: Mutex<Vec<String>>,
    }

    impl MockRunner {
        fn on(&self, key: &str, reply: Reply) {
            self.replies.lock().unwrap().insert(key.to_string(), reply);
        }

        fn calls(&self) -> Vec<String> {
            self.calls.lock().unwrap().clone()
        }
    }

    fn key_of(spec: &CommandSpec) -> String {
        let name = Path::new(&spec.program)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        std::iter::once(name)
            .chain(spec.args.iter().cloned())
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[async_trait]
    impl CommandRunner for MockRunner {
        async fn run(
            &self,
            spec: &CommandSpec,
            _timeout: Duration,
            on_line: &(dyn Fn(String) + Sync),
        ) -> io::Result<CommandResult> {
            let key = key_of(spec);
            self.calls.lock().unwrap().push(key.clone());
            let reply = self.replies.lock().unwrap().get(&key).cloned();
            match reply {
                None => Err(io::Error::new(io::ErrorKind::NotFound, format!("no mock for `{key}`"))),
                Some(Reply::Exit { success, output }) => {
                    for line in output.lines() {
                        on_line(line.to_string());
                    }
                    Ok(CommandResult {
                        success,
                        code: Some(if success { 0 } else { 1 }),
                        output,
                    })
                }
                Some(Reply::Gate(notify)) => {
                    notify.notified().await;
                    Ok(CommandResult {
                        success: true,
                        code: Some(0),
                        output: String::new(),
                    })
                }
            }
        }
    }

    fn stub(dir: &Path, name: &str) {
        use std::os::unix::fs::PermissionsExt;
        let path = dir.join(name);
        std::fs::write(&path, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn ok_reply(output: &str) -> Reply {
        Reply::Exit {
            success: true,
            output: output.into(),
        }
    }

    fn platform(dir: &Path, pm: Option<PackageManager>, distro: Distro) -> Platform {
        Platform {
            os: "linux",
            arch: "x86_64",
            package_manager: pm,
            distro,
            path: dir.as_os_str().to_owned(),
            browser_apps: Vec::new(),
            tools: dir.join("tools"),
            apt_etc: dir.join("apt"),
        }
    }

    #[test]
    fn browser_is_installed_as_an_app_bundle_or_on_path() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Google Chrome");
        std::fs::write(&app, b"").unwrap();
        let mut p = platform(dir.path(), None, Distro::Other);
        assert!(!browser_installed(&p), "nothing installed yet");
        p.browser_apps = vec![dir.path().join("missing.app")];
        assert!(!browser_installed(&p), "a missing bundle does not count");
        p.browser_apps = vec![app];
        assert!(browser_installed(&p), "an installed bundle counts");
    }

    fn setup_with(platform: Platform, mock: &Arc<MockRunner>) -> Arc<Setup> {
        Setup::new(platform, mock.clone())
    }

    async fn wait_done(setup: &Setup, job_id: &str) -> Value {
        for _ in 0..1000 {
            let snap = setup.job(job_id, 0).unwrap();
            if snap["state"] != "running" {
                return snap;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("job {job_id} still running");
    }

    fn texts(specs: &[CommandSpec]) -> Vec<String> {
        specs.iter().map(CommandSpec::display).collect()
    }

    #[test]
    fn package_manager_comes_from_the_path() {
        let dir = tempfile::tempdir().unwrap();
        stub(dir.path(), "dnf");
        let path = dir.path().as_os_str();
        assert_eq!(detect_package_manager("linux", path), Some(PackageManager::Dnf));
        stub(dir.path(), "apt-get");
        assert_eq!(detect_package_manager("linux", path), Some(PackageManager::Apt));

        let mac = tempfile::tempdir().unwrap();
        stub(mac.path(), "brew");
        assert_eq!(
            detect_package_manager("macos", mac.path().as_os_str()),
            Some(PackageManager::Brew)
        );
        assert_eq!(detect_package_manager("linux", mac.path().as_os_str()), None);
    }

    #[test]
    fn distro_is_read_from_os_release() {
        assert_eq!(
            distro_from_os_release("NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=debian\n"),
            Distro::Ubuntu
        );
        assert_eq!(distro_from_os_release("ID=debian\n"), Distro::Debian);
        assert_eq!(distro_from_os_release("ID=fedora\n"), Distro::Other);
        assert_eq!(
            distro_from_os_release("ID=linuxmint\nID_LIKE=\"ubuntu debian\"\n"),
            Distro::Ubuntu
        );
    }

    #[test]
    fn package_commands_for_apt_dnf_pacman() {
        assert_eq!(
            texts(&package_commands(PackageManager::Apt, &["xvfb", "x11vnc"], true)),
            vec![
                "sudo -n apt-get update",
                "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y xvfb x11vnc",
            ]
        );
        assert_eq!(
            texts(&package_commands(PackageManager::Dnf, &["xorg-x11-server-Xvfb"], false)),
            vec!["sudo dnf install -y xorg-x11-server-Xvfb"]
        );
        assert_eq!(
            texts(&package_commands(PackageManager::Pacman, &["xorg-server-xvfb"], true)),
            vec!["sudo -n pacman -S --needed --noconfirm xorg-server-xvfb"]
        );
        assert!(package_commands(PackageManager::Brew, &["x"], true).is_empty());
        assert!(package_commands(PackageManager::Apt, &[], true).is_empty());
    }

    #[test]
    fn plans_follow_distribution_and_cpu() {
        let dir = tempfile::tempdir().unwrap();
        let debian = platform(dir.path(), Some(PackageManager::Apt), Distro::Debian);
        assert_eq!(
            plan_for("browser", &debian),
            Some(Plan::Packages {
                id: "browser",
                names: &["chromium"]
            })
        );
        let ubuntu = platform(dir.path(), Some(PackageManager::Apt), Distro::Ubuntu);
        assert_eq!(plan_for("browser", &ubuntu), Some(Plan::ChromeRepo));
        let ubuntu_arm = Platform {
            arch: "aarch64",
            ..ubuntu.clone()
        };
        assert_eq!(plan_for("browser", &ubuntu_arm), None);
        assert_eq!(plan_for("grok", &ubuntu), None);
        assert_eq!(plan_for("docker", &ubuntu), None);
        let mac = Platform {
            os: "macos",
            package_manager: Some(PackageManager::Brew),
            ..ubuntu
        };
        assert_eq!(plan_for("xvfb", &mac), None);
        assert_eq!(
            plan_for("node", &mac),
            Some(Plan::Node),
            "the Node tarball exists for macOS too"
        );
    }

    /// The Chrome repository as the sudo steps name it, for `/x/tools` and `/etc/apt`.
    fn chrome_repo_at_etc() -> ChromeRepo {
        chrome_repo(Path::new("/x/tools"), Path::new("/etc/apt"))
    }

    #[test]
    fn chrome_steps_install_the_key_and_list_then_update_only_chrome_and_install() {
        let shown = texts(&chrome_repo_commands(&chrome_repo_at_etc(), false, true));
        assert_eq!(
            shown,
            [
                "sudo -n install -D -m 0644 /x/tools/downloads/google-chrome.gpg /etc/apt/keyrings/google-chrome.gpg",
                "sudo -n install -D -m 0644 /x/tools/downloads/google-chrome.list /etc/apt/sources.list.d/google-chrome.list",
                "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -o Dir::Etc::sourcelist=sources.list.d/google-chrome.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0",
                "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable",
            ]
        );
    }

    #[test]
    fn chrome_steps_skip_the_key_when_the_repository_is_configured() {
        let shown = texts(&chrome_repo_commands(&chrome_repo_at_etc(), true, false));
        assert_eq!(
            shown,
            [
                "sudo env DEBIAN_FRONTEND=noninteractive apt-get update -o Dir::Etc::sourcelist=sources.list.d/google-chrome.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0",
                "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable",
            ]
        );
    }

    #[test]
    fn chrome_repo_line_is_signed_by_the_keyring_apt_reads() {
        assert_eq!(
            CHROME_REPO_LINE,
            "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main"
        );
        assert_eq!(
            chrome_repo_at_etc().keyring_target,
            Path::new("/etc/apt/keyrings/google-chrome.gpg")
        );
        assert_eq!(
            chrome_repo_at_etc().list_target,
            Path::new("/etc/apt/sources.list.d/google-chrome.list")
        );
    }

    /// `gpg --show-keys --with-colons` of Google's key: the primary key, one subkey.
    const CHROME_KEY_LISTING: &str = "\
tru::1:1700000000:0:3:1:5
pub:-:4096:1:7721F63BD38B4796:1234567890:::-:::scESC::::::23::0:
fpr:::::::::EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796:
uid:-::::1234567890::ABCDEF::Google Inc. (Linux Packages Signing Authority) <linux-packages-keymaster@google.com>::::::::::0:
sub:-:4096:1:A1B2C3D4E5F60718:1234567890::::::e::::::23:
fpr:::::::::1111222233334444555566667777888899990000:
";

    /// Another key, glued after or before Chrome's in a keyring.
    const FOREIGN_KEY_LISTING: &str = "\
pub:-:4096:1:0123456789ABCDEF:1234567890:::-:::scESC::::::23::0:
fpr:::::::::00112233445566778899AABBCCDDEEFF00112233:
uid:-::::1234567890::ABCDEF::Someone <someone@example.com>::::::::::0:
";

    #[test]
    fn keyring_with_one_primary_key_is_accepted_when_it_is_the_chrome_signing_key() {
        assert!(is_chrome_signing_key(CHROME_KEY_LISTING));
        // Lower case, and spaces between the groups of the fingerprint.
        let loose = CHROME_KEY_LISTING.replace(
            "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796",
            "eb4c 1bfd 4f04 2f6d ddcc ec91 7721 f63b d38b 4796",
        );
        assert!(is_chrome_signing_key(&loose));
    }

    #[test]
    fn keyring_with_two_primary_keys_is_refused() {
        let chrome_then_other = format!("{CHROME_KEY_LISTING}{FOREIGN_KEY_LISTING}");
        assert!(!is_chrome_signing_key(&chrome_then_other));
        let other_then_chrome = format!("{FOREIGN_KEY_LISTING}{CHROME_KEY_LISTING}");
        assert!(!is_chrome_signing_key(&other_then_chrome));
    }

    #[test]
    fn chrome_fingerprint_on_a_subkey_alone_is_refused() {
        // The primary key is someone else's. Chrome's fingerprint is only on a subkey.
        let subkey_only = CHROME_KEY_LISTING
            .replace(
                "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796",
                "0000000000000000000000000000000000000000",
            )
            .replace(
                "1111222233334444555566667777888899990000",
                "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796",
            );
        assert!(!is_chrome_signing_key(&subkey_only));
    }

    #[test]
    fn primary_fingerprint_must_come_right_after_the_pub_line() {
        let moved = "\
pub:-:4096:1:7721F63BD38B4796:1234567890:::-:::scESC::::::23::0:
uid:-::::1234567890::ABCDEF::Google Inc.::::::::::0:
fpr:::::::::EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796:
";
        assert!(!is_chrome_signing_key(moved));
    }

    #[test]
    fn keyring_without_a_key_is_refused() {
        assert!(!is_chrome_signing_key(""));
        assert!(!is_chrome_signing_key("tru::1:1700000000:0:3:1:5\n"));
        assert!(!is_chrome_signing_key("pub:-:4096:1:7721F63BD38B4796:::\n"));
    }

    #[test]
    fn displayed_commands_quote_arguments_outside_the_plain_alphabet() {
        // Plain words, paths, `=`, `:`, `@`, `%`, `+` show as they are.
        let plain = CommandSpec::new("sudo", ["install", "-m", "0644", "/tmp/a/b.gpg", "a=b:c/d@e%f+g"]);
        assert_eq!(plain.display(), "sudo install -m 0644 /tmp/a/b.gpg a=b:c/d@e%f+g");
        // A space, a quote and an empty argument are quoted; `'` becomes `'\''`.
        let rough = CommandSpec::new("sudo", ["install", "/tmp/my dir/it's.gpg", ""]);
        assert_eq!(rough.display(), "sudo install '/tmp/my dir/it'\\''s.gpg' ''");
        assert_eq!(
            CommandSpec::new("/opt/my tools/npm", ["install"]).display(),
            "'/opt/my tools/npm' install"
        );
    }

    #[test]
    fn npm_packages_are_pinned_to_exact_versions() {
        assert_eq!(NPM_PINS.len(), 2);
        for (package, version) in NPM_PINS {
            let parts: Vec<&str> = version.split('.').collect();
            assert_eq!(parts.len(), 3, "{package} is pinned to {version}");
            assert!(
                parts
                    .iter()
                    .all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit())),
                "{package} is pinned to {version}"
            );
        }
        let dir = tempfile::tempdir().unwrap();
        let claude = plan_for("claude", &platform(dir.path(), None, Distro::Other));
        assert_eq!(
            claude,
            Some(Plan::Npm {
                id: "claude",
                package: "@anthropic-ai/claude-code",
                version: "2.1.295",
            })
        );
        let spec = npm_install("@openai/codex", "0.162.0", Path::new("/x/tools"));
        assert_eq!(
            texts(std::slice::from_ref(&spec)),
            ["npm install -g @openai/codex@0.162.0"]
        );
        assert_eq!(spec.env, [("NPM_CONFIG_PREFIX".to_string(), "/x/tools".to_string())]);
    }

    #[test]
    fn xauth_and_imagemagick_are_screen_components_installed_with_system_packages() {
        for id in ["xauth", "imagemagick"] {
            assert!(COMPONENTS.contains(&id), "{id}");
            assert!(SCREEN_COMPONENTS.contains(&id), "{id}");
            assert!(SUDO_COMPONENTS.contains(&id), "{id}");
        }
        assert_eq!(package_names("xauth", PackageManager::Apt), Some(&["xauth"][..]));
        assert_eq!(
            package_names("xauth", PackageManager::Dnf),
            Some(&["xorg-x11-xauth"][..])
        );
        assert_eq!(
            package_names("xauth", PackageManager::Pacman),
            Some(&["xorg-xauth"][..])
        );
        assert_eq!(
            package_names("imagemagick", PackageManager::Apt),
            Some(&["imagemagick"][..])
        );
        assert_eq!(
            package_names("imagemagick", PackageManager::Dnf),
            Some(&["ImageMagick"][..])
        );
        assert_eq!(
            package_names("imagemagick", PackageManager::Pacman),
            Some(&["imagemagick"][..])
        );
    }

    #[tokio::test]
    async fn screen_is_missing_until_import_is_on_the_path() {
        let dir = tempfile::tempdir().unwrap();
        for name in ["Xvfb", "x11vnc", "xdotool", "xauth", "openbox", "fc-list"] {
            stub(dir.path(), name);
        }
        let mock = Arc::new(MockRunner::default());
        mock.on("fc-list", ok_reply("Noto Sans:style=Regular\n"));
        let setup = setup_with(platform(dir.path(), Some(PackageManager::Apt), Distro::Debian), &mock);
        assert_eq!(setup.status().await.features.screen, Ready::Missing);
        assert!(!setup.probe("imagemagick").await.installed);
        stub(dir.path(), "import");
        let status = setup.status().await;
        assert!(status.components.iter().any(|c| c.id == "imagemagick" && c.installed));
        assert_eq!(status.features.screen, Ready::Ready);
    }

    /// Installs the Chrome repository with a scripted runner. `key_listing` is what gpg prints for the
    /// downloaded key. Returns the job snapshot and the commands the runner was asked for, and waits
    /// for the apt install to be asked for before it lets it finish (`finish_chrome` then runs).
    async fn run_chrome_install(
        key_listing: &str,
        finish_chrome: Option<Arc<Notify>>,
    ) -> (Value, Vec<String>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        stub(&root, "gpg");
        stub(&root, "sudo");
        let tools = root.join("tools");
        let repo = chrome_repo(&tools, &root.join("apt"));
        let mock = Arc::new(MockRunner::default());
        let key = repo.key_download.display().to_string();
        let keyring = repo.keyring.display().to_string();
        let list = repo.list.display().to_string();
        let keyring_target = repo.keyring_target.display().to_string();
        let list_target = repo.list_target.display().to_string();
        mock.on("sudo -n true", ok_reply(""));
        mock.on(
            &format!("curl --proto =https --tlsv1.2 -fsSL -o {key} {CHROME_KEY_URL}"),
            ok_reply(""),
        );
        mock.on(&format!("gpg --batch --yes --dearmor -o {keyring} {key}"), ok_reply(""));
        // The check reads the keyring that would be installed, not the downloaded file.
        mock.on(
            &format!("gpg --show-keys --with-colons {keyring}"),
            ok_reply(key_listing),
        );
        mock.on(
            &format!("sudo -n install -D -m 0644 {keyring} {keyring_target}"),
            ok_reply(""),
        );
        mock.on(
            &format!("sudo -n install -D -m 0644 {list} {list_target}"),
            ok_reply(""),
        );
        mock.on(
            "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -o Dir::Etc::sourcelist=sources.list.d/google-chrome.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0",
            ok_reply(""),
        );
        let install = "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable";
        match &finish_chrome {
            Some(gate) => mock.on(install, Reply::Gate(gate.clone())),
            None => mock.on(install, ok_reply("")),
        }
        let mut p = platform(&root, Some(PackageManager::Apt), Distro::Ubuntu);
        p.tools = tools;
        p.apt_etc = root.join("apt");
        let setup = setup_with(p, &mock);
        let id = setup.start_install(&["browser".to_string()]).unwrap();
        if let Some(gate) = finish_chrome {
            // Chrome is "installed" once the apt install has run: a stub on the path, as dpkg would leave it.
            for _ in 0..1000 {
                if mock.calls().iter().any(|c| c == install) {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            stub(&root, "google-chrome-stable");
            gate.notify_one();
        }
        let snap = wait_done(&setup, &id).await;
        (snap, mock.calls(), dir)
    }

    #[tokio::test]
    async fn chrome_key_with_another_fingerprint_stops_before_anything_is_installed() {
        let forged = CHROME_KEY_LISTING.replace(
            "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796",
            "0000000000000000000000000000000000000000",
        );
        let (snap, calls, dir) = run_chrome_install(&forged, None).await;
        let root = dir.path();
        assert_eq!(snap["state"], "failed", "{snap:?}");
        assert_eq!(snap["step"], "Google signing key fingerprint mismatch");
        assert_eq!(snap["failed_component"], "browser");
        let check = calls
            .iter()
            .position(|c| c.starts_with("gpg --show-keys"))
            .expect("the keyring is checked");
        assert_eq!(calls.len(), check + 1, "nothing may run after a bad key: {calls:?}");
        assert!(!root.join("apt").exists(), "no keyring or list may be written");
    }

    #[tokio::test]
    async fn chrome_key_with_the_right_fingerprint_is_installed_in_order() {
        let gate = Arc::new(Notify::new());
        let (snap, calls, dir) = run_chrome_install(CHROME_KEY_LISTING, Some(gate)).await;
        let root = dir.path();
        assert_eq!(snap["state"], "done", "{snap:?}");
        let repo = chrome_repo(&root.join("tools"), &root.join("apt"));
        let key = repo.key_download.display().to_string();
        let keyring = repo.keyring.display().to_string();
        let list = repo.list.display().to_string();
        assert_eq!(
            calls,
            [
                "sudo -n true".to_string(),
                format!("curl --proto =https --tlsv1.2 -fsSL -o {key} {CHROME_KEY_URL}"),
                format!("gpg --batch --yes --dearmor -o {keyring} {key}"),
                format!("gpg --show-keys --with-colons {keyring}"),
                format!(
                    "sudo -n install -D -m 0644 {keyring} {}",
                    repo.keyring_target.display()
                ),
                format!("sudo -n install -D -m 0644 {list} {}", repo.list_target.display()),
                "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get update -o Dir::Etc::sourcelist=sources.list.d/google-chrome.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0".to_string(),
                "sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y google-chrome-stable".to_string(),
            ]
        );
        assert_eq!(std::fs::read_to_string(&list).unwrap(), format!("{CHROME_REPO_LINE}\n"));
    }

    #[test]
    fn node_version_must_be_18_or_newer() {
        assert!(node_is_supported("v22.11.0\n"));
        assert!(node_is_supported("v18.0.0"));
        assert!(!node_is_supported("v16.20.2"));
        assert!(!node_is_supported(""));
        assert!(!node_is_supported("node: not found"));
    }

    #[test]
    fn node_tarball_is_picked_by_platform() {
        let shasums = "\
aaa111  node-v22.11.0-linux-arm64.tar.gz
bbb222  node-v22.11.0-linux-arm64.tar.xz
ccc333  node-v22.11.0-linux-x64.tar.xz
ddd444  node-v22.11.0-darwin-arm64.tar.xz
eee555  node-v22.11.0-headers.tar.xz
fff666  node-v22.11.0.pkg
";
        assert_eq!(
            pick_node_tarball(shasums, "linux-arm64"),
            Some(("node-v22.11.0-linux-arm64.tar.xz".into(), "bbb222".into()))
        );
        assert_eq!(
            pick_node_tarball(shasums, "linux-x64"),
            Some(("node-v22.11.0-linux-x64.tar.xz".into(), "ccc333".into()))
        );
        assert_eq!(pick_node_tarball(shasums, "linux-x86"), None);
    }

    #[test]
    fn noto_fonts_are_found_in_fc_list_output() {
        assert!(has_noto_font("DejaVu Sans:style=Book\nNoto Sans:style=Regular\n"));
        assert!(!has_noto_font("DejaVu Sans:style=Book\n"));
    }

    #[tokio::test]
    async fn status_finds_components_on_the_injected_path() {
        let dir = tempfile::tempdir().unwrap();
        stub(dir.path(), "Xvfb");
        let mock = Arc::new(MockRunner::default());
        let setup = setup_with(platform(dir.path(), Some(PackageManager::Apt), Distro::Debian), &mock);
        let status = setup.status().await;
        let by_id = |id: &str| status.components.iter().find(|c| c.id == id).unwrap().clone();
        assert!(by_id("xvfb").installed);
        assert!(by_id("xvfb").installable);
        assert!(!by_id("x11vnc").installed);
        assert!(by_id("x11vnc").needs_sudo);
        assert!(!by_id("grok").installable);
        assert_eq!(by_id("grok").hint.as_deref(), Some(GROK_DOCS));
        assert_eq!(status.features.screen, Ready::Missing);
        assert_eq!(status.features.agents.claude, Ready::Missing);
        assert_eq!(status.sudo, Sudo::None, "no sudo on the injected path");
    }

    #[tokio::test]
    async fn node_counts_only_from_version_18() {
        let dir = tempfile::tempdir().unwrap();
        stub(dir.path(), "node");
        let mock = Arc::new(MockRunner::default());
        mock.on("node --version", ok_reply("v16.20.2\n"));
        let old = setup_with(platform(dir.path(), None, Distro::Other), &mock)
            .probe("node")
            .await;
        assert!(!old.installed);
        assert_eq!(old.version.as_deref(), Some("v16.20.2"));

        mock.on("node --version", ok_reply("v22.11.0\n"));
        let new = setup_with(platform(dir.path(), None, Distro::Other), &mock)
            .probe("node")
            .await;
        assert!(new.installed);
        assert_eq!(new.version.as_deref(), Some("v22.11.0"));
        assert_eq!(new.feature, Feature::Agents);
    }

    #[tokio::test]
    async fn installed_components_finish_without_any_command() {
        let dir = tempfile::tempdir().unwrap();
        stub(dir.path(), "Xvfb");
        let mock = Arc::new(MockRunner::default());
        let setup = setup_with(platform(dir.path(), Some(PackageManager::Apt), Distro::Debian), &mock);
        let id = setup.start_install(&["xvfb".to_string()]).unwrap();
        let snap = wait_done(&setup, &id).await;
        assert_eq!(snap["state"], "done");
        assert_eq!(snap["step"], "Done");
        assert!(mock.calls().is_empty(), "{:?}", mock.calls());
    }

    #[tokio::test]
    async fn sudo_that_needs_a_password_stops_the_job_with_the_command() {
        let dir = tempfile::tempdir().unwrap();
        stub(dir.path(), "sudo");
        let mock = Arc::new(MockRunner::default());
        mock.on(
            "sudo -n true",
            Reply::Exit {
                success: false,
                output: "sudo: a password is required".into(),
            },
        );
        let setup = setup_with(platform(dir.path(), Some(PackageManager::Apt), Distro::Debian), &mock);
        let id = setup.start_install(&["xdotool".to_string()]).unwrap();
        let snap = wait_done(&setup, &id).await;
        assert_eq!(snap["state"], "needs_password");
        assert_eq!(
            snap["command"],
            "sudo apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y xdotool"
        );
        assert!(
            mock.calls().iter().all(|c| !c.contains("apt-get")),
            "nothing may run without sudo: {:?}",
            mock.calls()
        );
    }

    #[tokio::test]
    async fn second_install_while_one_runs_is_busy_and_a_failed_step_names_its_component() {
        let dir = tempfile::tempdir().unwrap();
        stub(dir.path(), "sudo");
        let gate = Arc::new(Notify::new());
        let mock = Arc::new(MockRunner::default());
        mock.on("sudo -n true", ok_reply(""));
        mock.on("sudo -n apt-get update", Reply::Gate(gate.clone()));
        // The install itself is not scripted, so it fails to start.
        let setup = setup_with(platform(dir.path(), Some(PackageManager::Apt), Distro::Debian), &mock);
        let id = setup.start_install(&["xdotool".to_string()]).unwrap();
        for _ in 0..1000 {
            if mock.calls().iter().any(|c| c == "sudo -n apt-get update") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(setup.start_install(&["x11vnc".to_string()]), Err(InstallError::Busy));
        gate.notify_one();
        let snap = wait_done(&setup, &id).await;
        assert_eq!(snap["state"], "failed");
        assert_eq!(snap["failed_component"], "xdotool");
        assert!(setup.job("no-such-job", 0).is_none());
    }

    #[tokio::test]
    async fn unknown_or_empty_component_lists_are_refused() {
        let dir = tempfile::tempdir().unwrap();
        let setup = setup_with(
            platform(dir.path(), None, Distro::Other),
            &Arc::new(MockRunner::default()),
        );
        assert_eq!(setup.start_install(&[]), Err(InstallError::Empty));
        assert_eq!(
            setup.start_install(&["vim".to_string()]),
            Err(InstallError::UnknownComponent("vim".into()))
        );
    }

    #[test]
    fn job_log_is_read_from_an_offset_and_capped() {
        let job = Job::new("job".into());
        job.push_log("one");
        job.push_log("two");
        let all = job.snapshot(0);
        assert_eq!(all["log"], "one\ntwo\n");
        assert_eq!(all["offset"], 8);
        assert_eq!(job.snapshot(4)["log"], "two\n");
        assert_eq!(job.snapshot(100)["log"], "");
        assert_eq!(job.snapshot(100)["offset"], 8);

        let line = "x".repeat(1000);
        for _ in 0..400 {
            job.push_log(&line);
        }
        let snap = job.snapshot(0);
        let kept = snap["log"].as_str().unwrap();
        assert!(kept.len() <= LOG_LIMIT, "{}", kept.len());
        let offset = snap["offset"].as_u64().unwrap();
        assert_eq!(offset, 8 + 400 * 1001);
        assert!(offset > kept.len() as u64, "older bytes were dropped");
        // A reader that asks from before the kept part gets what is kept, from its start.
        assert_eq!(job.snapshot(0)["log"], snap["log"]);
    }

    #[tokio::test]
    async fn real_status_runs_on_this_machine() {
        // Read only: lists what this machine has. Nothing is installed.
        let status = Setup::system().status().await;
        assert_eq!(status.components.len(), COMPONENTS.len());
        #[cfg(target_os = "macos")]
        assert_eq!(status.features.screen, Ready::Unsupported);
    }
}
