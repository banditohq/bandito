//! Server screen: a virtual desktop (Xvfb with openbox, watched by x11vnc) that the app
//! shows over VNC through `/v1/tunnel`, and that agents drive through the `screen.agent.*`
//! RPC methods (the `screen_*` MCP tools). Linux only; other systems answer `Unsupported`.
//! See docs/ARCHITECTURE.md#screen.

#[cfg(target_os = "linux")]
use crate::children::TrackedChild;
#[cfg(target_os = "linux")]
use crate::store::now_ms;
use serde::Serialize;
use serde_json::Value;
#[cfg(target_os = "linux")]
use serde_json::json;
#[cfg(target_os = "linux")]
use std::collections::HashMap;
use std::fmt;
#[cfg(target_os = "linux")]
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
#[cfg(target_os = "linux")]
use std::os::unix::process::CommandExt;
#[cfg(any(target_os = "linux", test))]
use std::path::Path;
use std::path::PathBuf;
#[cfg(target_os = "linux")]
use std::process::Stdio;
use std::sync::Arc;
#[cfg(target_os = "linux")]
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
#[cfg(target_os = "linux")]
use std::sync::{Mutex as StdMutex, MutexGuard, PoisonError};
use std::time::Duration;
#[cfg(target_os = "linux")]
use std::time::Instant;
#[cfg(target_os = "linux")]
use tokio::process::Command;
#[cfg(target_os = "linux")]
use tokio::task::JoinHandle;

/// Workspace used when a call does not name one.
pub const DEFAULT_WORKSPACE: &str = "shared";
pub const DEFAULT_WIDTH: u32 = 1600;
pub const DEFAULT_HEIGHT: u32 = 1000;
/// Screenshots wider than this are scaled down. Coordinates stay in screen pixels.
pub const SCREENSHOT_MAX_WIDTH: u32 = 1280;
/// A screen with no VNC client and no agent call for this long is stopped.
pub const IDLE_STOP_MS: i64 = 30 * 60 * 1000;
/// How often the idle check runs.
pub const IDLE_CHECK_INTERVAL: Duration = Duration::from_secs(60);
/// RFB (VNC) uses only the first 8 characters of a password, so the whole password is 8.
pub const PASSWORD_LEN: usize = 8;
pub const MAX_WORKSPACE_LEN: usize = 32;
/// Scroll notches when `amount` is not given, and the largest accepted amount.
pub const DEFAULT_SCROLL: u32 = 3;
pub const MAX_SCROLL: u32 = 20;

#[cfg(any(target_os = "linux", test))]
const FIRST_DISPLAY: u32 = 90;
#[cfg(any(target_os = "linux", test))]
const LAST_DISPLAY: u32 = 199;
/// File name of a screen's X authority, inside its folder.
#[cfg(target_os = "linux")]
const XAUTH_FILE: &str = "Xauthority";
#[cfg(target_os = "linux")]
const MIN_SIZE: (u32, u32) = (320, 240);
#[cfg(target_os = "linux")]
const MAX_SIZE: (u32, u32) = (7680, 4320);
/// How long a process may take to show its socket or port.
#[cfg(target_os = "linux")]
const START_TIMEOUT: Duration = Duration::from_secs(5);
/// Time between SIGTERM and SIGKILL.
#[cfg(target_os = "linux")]
const GRACE: Duration = Duration::from_secs(2);
/// Longest one screenshot or input tool may take.
#[cfg(target_os = "linux")]
const ACTION_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(target_os = "linux")]
const POLL: Duration = Duration::from_millis(50);

/// Who drives the screen right now. `None` in `ScreenStatus` means nobody.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Controller {
    Agent,
    User,
}

/// What `screen.status` and `screen.start` return.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ScreenStatus {
    pub running: bool,
    /// X display number: the screen is `:<display>`.
    pub display: Option<u32>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub vnc_port: Option<u16>,
    pub vnc_password: Option<String>,
    /// Unix milliseconds.
    pub started_at: Option<i64>,
    pub controller: Option<Controller>,
    /// Milliseconds since the last agent call. Zero while a VNC client is connected.
    pub idle_ms: Option<i64>,
}

/// Why a screen call failed. `reason()` gives the stable code used in RPC errors.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ScreenError {
    /// Not Linux, so there is no Xvfb or x11vnc.
    Unsupported,
    /// A program the screen needs is not installed on the server.
    MissingComponent(&'static str),
    StartFailed(String),
    /// The user holds the controls, so agent tools are refused.
    UserControls,
    /// `screen.control` on a screen that is not running.
    NotRunning,
    /// A screenshot or input tool ran and failed.
    ActionFailed(String),
    InvalidArgs(String),
}

impl ScreenError {
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Unsupported => "unsupported",
            Self::MissingComponent(_) => "missing_component",
            Self::StartFailed(_) => "start_failed",
            Self::UserControls => "user_controls",
            Self::NotRunning => "not_running",
            Self::ActionFailed(_) => "action_failed",
            Self::InvalidArgs(_) => "invalid_args",
        }
    }
}

impl fmt::Display for ScreenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported => write!(f, "the server screen needs Linux (Xvfb and x11vnc)"),
            Self::MissingComponent(c) => write!(f, "missing component: {c} (install it on the server)"),
            Self::StartFailed(why) => write!(f, "cannot start the screen: {why}"),
            Self::UserControls => write!(
                f,
                "The user is controlling the screen. Wait or ask them to hand it back."
            ),
            Self::NotRunning => write!(f, "the screen is not running"),
            Self::ActionFailed(why) => write!(f, "action failed: {why}"),
            Self::InvalidArgs(why) => write!(f, "{why}"),
        }
    }
}

impl std::error::Error for ScreenError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    Left,
    Middle,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
}

/// One agent tool call, already checked by the RPC layer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentAction {
    Screenshot,
    Click {
        x: u32,
        y: u32,
        button: Button,
        double: bool,
    },
    Move {
        x: u32,
        y: u32,
    },
    Type {
        text: String,
    },
    Key {
        keys: String,
    },
    Scroll {
        direction: Direction,
        amount: u32,
    },
    /// Starts a program on the screen, detached. Not waited for.
    Launch {
        command: String,
    },
}

/// Owns the screens of this server, one per workspace.
pub struct ScreenManager {
    /// Holds `<workspace>/passwd`, the VNC password file of each screen.
    #[cfg_attr(not(target_os = "linux"), allow(dead_code))]
    state_dir: PathBuf,
    #[cfg(target_os = "linux")]
    sessions: tokio::sync::Mutex<HashMap<String, Session>>,
}

/// Running processes of one screen.
#[cfg(target_os = "linux")]
struct Session {
    display: u32,
    width: u32,
    height: u32,
    vnc_port: u16,
    vnc_password: String,
    /// `Xauthority` of this screen: the cookie Xvfb accepts. Removed when the screen stops.
    xauth: PathBuf,
    started_at: i64,
    controller: Option<Controller>,
    /// Unix milliseconds of the last agent call.
    last_agent_ms: i64,
    xvfb: TrackedChild,
    openbox: Option<TrackedChild>,
    vnc: VncTask,
    /// Process group ids of programs started with `Launch` that are still running.
    launched: Arc<StdMutex<Vec<i32>>>,
}

/// The x11vnc process and its watcher. The watcher restarts x11vnc once if it dies.
#[cfg(target_os = "linux")]
struct VncTask {
    /// Process group id of the running x11vnc, or 0 when none runs.
    pgid: Arc<AtomicI32>,
    stopping: Arc<AtomicBool>,
    handle: JoinHandle<()>,
}

impl ScreenManager {
    /// `state_dir` holds `<workspace>/passwd`, the VNC password files (mode 0600).
    pub fn new(state_dir: PathBuf) -> Self {
        Self {
            state_dir,
            #[cfg(target_os = "linux")]
            sessions: tokio::sync::Mutex::new(HashMap::new()),
        }
    }
}

#[cfg(target_os = "linux")]
impl ScreenStatus {
    fn stopped() -> Self {
        Self {
            running: false,
            display: None,
            width: None,
            height: None,
            vnc_port: None,
            vnc_password: None,
            started_at: None,
            controller: None,
            idle_ms: None,
        }
    }
}

#[cfg(target_os = "linux")]
impl ScreenManager {
    /// Start the screen of `workspace` if it is not running, and return its status.
    pub async fn start(&self, workspace: &str, width: u32, height: u32) -> Result<ScreenStatus, ScreenError> {
        validate_workspace(workspace)?;
        let mut sessions = self.sessions.lock().await;
        start_locked(&mut sessions, &self.state_dir, workspace, width, height).await?;
        sessions
            .get(workspace)
            .map(|s| s.status(now_ms()))
            .ok_or(ScreenError::NotRunning)
    }

    /// Status of `workspace`. A screen that was never started reports `running: false`.
    pub async fn status(&self, workspace: &str) -> Result<ScreenStatus, ScreenError> {
        validate_workspace(workspace)?;
        let sessions = self.sessions.lock().await;
        Ok(match sessions.get(workspace) {
            Some(s) => s.status(now_ms()),
            None => ScreenStatus::stopped(),
        })
    }

    /// Stop the screen of `workspace` and every program started on it. Stopping a stopped screen is fine.
    pub async fn stop(&self, workspace: &str) -> Result<(), ScreenError> {
        validate_workspace(workspace)?;
        let removed = self.sessions.lock().await.remove(workspace);
        if let Some(session) = removed {
            shutdown_session(session).await;
        }
        Ok(())
    }

    /// Set who drives the screen. `None` means nobody.
    pub async fn control(&self, workspace: &str, holder: Option<Controller>) -> Result<ScreenStatus, ScreenError> {
        validate_workspace(workspace)?;
        let mut sessions = self.sessions.lock().await;
        let session = sessions.get_mut(workspace).ok_or(ScreenError::NotRunning)?;
        session.controller = holder;
        Ok(session.status(now_ms()))
    }

    /// Environment that puts a program on this screen (`DISPLAY=:N`, `XAUTHORITY`). Empty if it is not running.
    pub async fn env_for(&self, workspace: &str) -> Vec<(String, String)> {
        let sessions = self.sessions.lock().await;
        sessions
            .get(workspace)
            .map(|s| display_env(s.display, &s.xauth))
            .unwrap_or_default()
    }

    /// Run one agent tool call. Starts the screen if needed, refuses while the user holds the
    /// controls, and marks agent activity. Screenshots return `{width, height, scale, png_base64}`.
    pub async fn agent_action(&self, workspace: &str, action: AgentAction) -> Result<Value, ScreenError> {
        validate_workspace(workspace)?;
        let mut sessions = self.sessions.lock().await;
        start_locked(&mut sessions, &self.state_dir, workspace, DEFAULT_WIDTH, DEFAULT_HEIGHT).await?;
        let session = sessions.get_mut(workspace).ok_or(ScreenError::NotRunning)?;
        agent_gate(session.controller)?;
        session.last_agent_ms = now_ms();
        let (display, width, height) = (session.display, session.width, session.height);
        let env = display_env(display, &session.xauth);
        match action {
            AgentAction::Screenshot => {
                let png = screenshot(display, &env).await?;
                let (image_width, _) =
                    png_size(&png).ok_or_else(|| ScreenError::ActionFailed("screenshot is not a PNG".into()))?;
                let scale = (f64::from(image_width) / f64::from(width) * 1000.0).round() / 1000.0;
                let png_base64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &png);
                Ok(json!({ "width": width, "height": height, "scale": scale, "png_base64": png_base64 }))
            }
            AgentAction::Click { x, y, button, double } => {
                check_point(x, y, width, height)?;
                run_capture(&click_argv(x, y, button, double), &env, None, "xdotool").await?;
                Ok(json!({}))
            }
            AgentAction::Move { x, y } => {
                check_point(x, y, width, height)?;
                run_capture(&move_argv(x, y), &env, None, "xdotool").await?;
                Ok(json!({}))
            }
            AgentAction::Type { text } => {
                run_capture(&type_argv(&text), &env, None, "xdotool").await?;
                Ok(json!({}))
            }
            AgentAction::Key { keys } => {
                run_capture(&key_argv(&keys), &env, None, "xdotool").await?;
                Ok(json!({}))
            }
            AgentAction::Scroll { direction, amount } => {
                run_capture(&scroll_argv(direction, amount), &env, None, "xdotool").await?;
                Ok(json!({}))
            }
            AgentAction::Launch { command } => {
                launch_program(session, &command)?;
                Ok(json!({}))
            }
        }
    }

    /// Stop every screen. Called when the daemon shuts down.
    pub async fn shutdown_all(&self) {
        let all: Vec<Session> = self.sessions.lock().await.drain().map(|(_, s)| s).collect();
        for session in all {
            shutdown_session(session).await;
        }
    }

    /// Start the background task that stops idle screens. Call once, from `main`.
    pub fn spawn_idle_reaper(self: &Arc<Self>) {
        let manager = Arc::clone(self);
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(IDLE_CHECK_INTERVAL);
            // The first tick is immediate; the first check comes one interval later.
            tick.tick().await;
            loop {
                tick.tick().await;
                manager.stop_idle().await;
            }
        });
    }

    /// Stop the screens with no VNC client and no agent call for `IDLE_STOP_MS`.
    async fn stop_idle(&self) {
        let now = now_ms();
        let idle: Vec<Session> = {
            let mut sessions = self.sessions.lock().await;
            let names: Vec<String> = sessions
                .iter()
                .filter(|(_, s)| should_auto_stop(vnc_clients(s.vnc_port), now - s.last_agent_ms))
                .map(|(name, _)| name.clone())
                .collect();
            names.iter().filter_map(|name| sessions.remove(name)).collect()
        };
        for session in idle {
            tracing::info!(display = session.display, "stopping an idle server screen");
            shutdown_session(session).await;
        }
    }

    /// Test only: process ids of the screen's processes, including x11vnc's group.
    #[cfg(test)]
    async fn pids_for_test(&self, workspace: &str) -> Vec<i32> {
        let sessions = self.sessions.lock().await;
        let Some(s) = sessions.get(workspace) else {
            return Vec::new();
        };
        let mut pids: Vec<i32> = Vec::new();
        pids.extend(s.xvfb.id().map(|p| p as i32));
        pids.extend(s.openbox.as_ref().and_then(|o| o.id()).map(|p| p as i32));
        let group = s.vnc.pgid.load(Ordering::SeqCst);
        if group > 0 {
            pids.push(group);
        }
        pids
    }
}

#[cfg(not(target_os = "linux"))]
impl ScreenManager {
    pub async fn start(&self, workspace: &str, width: u32, height: u32) -> Result<ScreenStatus, ScreenError> {
        let _ = (workspace, width, height);
        Err(ScreenError::Unsupported)
    }

    pub async fn status(&self, workspace: &str) -> Result<ScreenStatus, ScreenError> {
        let _ = workspace;
        Err(ScreenError::Unsupported)
    }

    pub async fn stop(&self, workspace: &str) -> Result<(), ScreenError> {
        let _ = workspace;
        Err(ScreenError::Unsupported)
    }

    pub async fn control(&self, workspace: &str, holder: Option<Controller>) -> Result<ScreenStatus, ScreenError> {
        let _ = (workspace, holder);
        Err(ScreenError::Unsupported)
    }

    pub async fn env_for(&self, workspace: &str) -> Vec<(String, String)> {
        let _ = workspace;
        Vec::new()
    }

    pub async fn agent_action(&self, workspace: &str, action: AgentAction) -> Result<Value, ScreenError> {
        let _ = (workspace, action);
        Err(ScreenError::Unsupported)
    }

    pub async fn shutdown_all(&self) {}

    pub fn spawn_idle_reaper(self: &Arc<Self>) {}
}

// Pure helpers. Linux code uses them, and the tests run them on every system.

/// Builds a `Vec<String>` argv from values that implement `Display`.
#[cfg(any(target_os = "linux", test))]
macro_rules! argv {
    ($($x:expr),* $(,)?) => {
        vec![$(($x).to_string()),*]
    };
}

/// First X display number from 90 up that is not in `busy`, below 200.
#[cfg(any(target_os = "linux", test))]
pub fn pick_display(busy: &[u32]) -> Option<u32> {
    (FIRST_DISPLAY..=LAST_DISPLAY).find(|n| !busy.contains(n))
}

/// `Xvfb :N -screen 0 WxHx24 -nolisten tcp -dpi 96 -auth FILE`, program name first.
#[cfg(any(target_os = "linux", test))]
pub fn xvfb_argv(display: u32, width: u32, height: u32, xauthority: &Path) -> Vec<String> {
    argv![
        "Xvfb",
        format!(":{display}"),
        "-screen",
        "0",
        format!("{width}x{height}x24"),
        "-nolisten",
        "tcp",
        "-dpi",
        "96",
        "-auth",
        xauthority.display(),
    ]
}

/// `x11vnc -display :N -rfbport P -localhost -rfbauth FILE -forever -shared -noxdamage -quiet -auth FILE`.
#[cfg(any(target_os = "linux", test))]
pub fn x11vnc_argv(display: u32, port: u16, passwd_file: &Path, xauthority: &Path) -> Vec<String> {
    argv![
        "x11vnc",
        "-display",
        format!(":{display}"),
        "-rfbport",
        port,
        "-localhost",
        "-rfbauth",
        passwd_file.display(),
        "-forever",
        "-shared",
        "-noxdamage",
        "-quiet",
        "-auth",
        xauthority.display(),
    ]
}

/// `xauth -f FILE source -`: runs the xauth commands read from stdin. The cookie travels on stdin
/// (see [`xauth_source_input`]), so it never shows in the argument list of a process.
#[cfg(any(target_os = "linux", test))]
pub fn xauth_source_argv(file: &Path) -> Vec<String> {
    argv!["xauth", "-f", file.display(), "source", "-"]
}

/// The stdin of [`xauth_source_argv`]: one line, `add :N MIT-MAGIC-COOKIE-1 HEX`.
#[cfg(any(target_os = "linux", test))]
pub fn xauth_source_input(display: u32, cookie_hex: &str) -> Vec<u8> {
    format!("add :{display} MIT-MAGIC-COOKIE-1 {cookie_hex}\n").into_bytes()
}

/// Environment that puts a program on the screen of `display`: `DISPLAY` and the screen's `XAUTHORITY`.
#[cfg(any(target_os = "linux", test))]
pub fn display_env(display: u32, xauthority: &Path) -> Vec<(String, String)> {
    vec![
        ("DISPLAY".to_string(), format!(":{display}")),
        ("XAUTHORITY".to_string(), xauthority.display().to_string()),
    ]
}

/// 16 random bytes from the system RNG, as 32 hex digits: the MIT-MAGIC-COOKIE-1 of a screen.
#[cfg(any(target_os = "linux", test))]
pub fn random_cookie_hex() -> String {
    let mut bytes = [0u8; 16];
    for b in &mut bytes {
        *b = rand::random();
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// `x11vnc -storepasswd PASSWORD FILE`.
#[cfg(any(target_os = "linux", test))]
pub fn storepasswd_argv(password: &str, passwd_file: &Path) -> Vec<String> {
    argv!["x11vnc", "-storepasswd", password, passwd_file.display()]
}

/// `import -window root -display :N png:-`, the screenshot tool.
#[cfg(any(target_os = "linux", test))]
pub fn import_argv(display: u32) -> Vec<String> {
    argv!["import", "-window", "root", "-display", format!(":{display}"), "png:-"]
}

/// `xwd -root -display :N`, used only when `import` is missing. Its output goes to `resize_argv("xwd")`.
#[cfg(any(target_os = "linux", test))]
pub fn xwd_argv(display: u32) -> Vec<String> {
    argv!["xwd", "-root", "-display", format!(":{display}")]
}

/// `convert <format>:- -resize 1280x> png:-`: scales a screenshot down, never up.
#[cfg(any(target_os = "linux", test))]
pub fn resize_argv(input_format: &str) -> Vec<String> {
    argv![
        "convert",
        format!("{input_format}:-"),
        "-resize",
        format!("{SCREENSHOT_MAX_WIDTH}x>"),
        "png:-"
    ]
}

/// `xdotool mousemove X Y click [--repeat 2] B`.
#[cfg(any(target_os = "linux", test))]
pub fn click_argv(x: u32, y: u32, button: Button, double: bool) -> Vec<String> {
    let button_number = match button {
        Button::Left => 1,
        Button::Middle => 2,
        Button::Right => 3,
    };
    let mut argv = argv!["xdotool", "mousemove", x, y, "click"];
    if double {
        argv.extend(argv!["--repeat", 2]);
    }
    argv.push(button_number.to_string());
    argv
}

/// `xdotool mousemove X Y`.
#[cfg(any(target_os = "linux", test))]
pub fn move_argv(x: u32, y: u32) -> Vec<String> {
    argv!["xdotool", "mousemove", x, y]
}

/// `xdotool type --delay 12 -- TEXT`.
#[cfg(any(target_os = "linux", test))]
pub fn type_argv(text: &str) -> Vec<String> {
    argv!["xdotool", "type", "--delay", 12, "--", text]
}

/// `xdotool key -- KEYS`, for example `ctrl+l`.
#[cfg(any(target_os = "linux", test))]
pub fn key_argv(keys: &str) -> Vec<String> {
    argv!["xdotool", "key", "--", keys]
}

/// `xdotool click --repeat N B`, with B 4 up, 5 down, 6 left, 7 right.
#[cfg(any(target_os = "linux", test))]
pub fn scroll_argv(direction: Direction, amount: u32) -> Vec<String> {
    let button = match direction {
        Direction::Up => 4,
        Direction::Down => 5,
        Direction::Left => 6,
        Direction::Right => 7,
    };
    argv!["xdotool", "click", "--repeat", amount, button]
}

/// `(local port, state)` of each socket row in a `/proc/net/tcp` text. Header lines are skipped.
#[cfg(any(target_os = "linux", test))]
fn tcp_rows(table: &str) -> impl Iterator<Item = (u16, &str)> + '_ {
    table.lines().filter_map(|line| {
        let mut fields = line.split_whitespace();
        let _slot = fields.next()?;
        let local = fields.next()?;
        let _remote = fields.next()?;
        let state = fields.next()?;
        let (_, port_hex) = local.rsplit_once(':')?;
        Some((u16::from_str_radix(port_hex, 16).ok()?, state))
    })
}

/// Number of ESTABLISHED connections whose local port is `port`, in a `/proc/net/tcp` (or tcp6) text.
#[cfg(any(target_os = "linux", test))]
pub fn count_established(table: &str, port: u16) -> usize {
    tcp_rows(table)
        .filter(|(p, state)| *p == port && *state == "01")
        .count()
}

/// True if a LISTEN socket has local port `port` in a `/proc/net/tcp` (or tcp6) text.
#[cfg(any(target_os = "linux", test))]
pub fn is_listening(table: &str, port: u16) -> bool {
    tcp_rows(table).any(|(p, state)| p == port && state == "0A")
}

/// Printable ASCII from `!` to `~`, without `"` and `\` (so a password needs no escaping): 92 characters.
#[cfg(any(target_os = "linux", test))]
const PASSWORD_ALPHABET: [u8; 92] = {
    let mut out = [0u8; 92];
    let mut n = 0;
    let mut c = b'!';
    while c <= b'~' {
        if c != b'"' && c != b'\\' {
            out[n] = c;
            n += 1;
        }
        c += 1;
    }
    assert!(n == 92, "the password alphabet has 92 characters");
    out
};

/// The character for a random byte, or `None` when the byte must be drawn again. Bytes from 184 up
/// are refused: 184 is the largest multiple of 92 below 256, so every character gets exactly two bytes.
#[cfg(any(target_os = "linux", test))]
pub fn password_char(byte: u8) -> Option<char> {
    let n = PASSWORD_ALPHABET.len();
    let limit = 256 - 256 % n;
    (usize::from(byte) < limit).then(|| char::from(PASSWORD_ALPHABET[usize::from(byte) % n]))
}

/// `PASSWORD_LEN` characters from `PASSWORD_ALPHABET`, from the system RNG.
#[cfg(any(target_os = "linux", test))]
pub fn generate_password() -> String {
    let mut out = String::with_capacity(PASSWORD_LEN);
    while out.len() < PASSWORD_LEN {
        let byte: u8 = rand::random();
        if let Some(c) = password_char(byte) {
            out.push(c);
        }
    }
    out
}

/// Agent calls are refused while the user holds the controls.
#[cfg(any(target_os = "linux", test))]
pub fn agent_gate(controller: Option<Controller>) -> Result<(), ScreenError> {
    match controller {
        Some(Controller::User) => Err(ScreenError::UserControls),
        _ => Ok(()),
    }
}

/// Width and height from the IHDR chunk of a PNG, or `None` if the bytes are not a PNG.
#[cfg(any(target_os = "linux", test))]
pub fn png_size(bytes: &[u8]) -> Option<(u32, u32)> {
    const SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
    if bytes.len() < 24 || &bytes[..8] != SIGNATURE || bytes[12..16] != *b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    Some((width, height))
}

/// Workspace names become folder names: 1 to 32 characters from `[A-Za-z0-9_-]`.
pub fn validate_workspace(workspace: &str) -> Result<(), ScreenError> {
    let valid = !workspace.is_empty()
        && workspace.len() <= MAX_WORKSPACE_LEN
        && workspace
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-');
    if valid {
        Ok(())
    } else {
        Err(ScreenError::InvalidArgs(format!(
            "workspace must be 1 to {MAX_WORKSPACE_LEN} letters, digits, '-' or '_'"
        )))
    }
}

/// True when the idle check should stop a screen: no VNC client and idle for `IDLE_STOP_MS` or more.
#[cfg(any(target_os = "linux", test))]
pub fn should_auto_stop(clients: usize, idle_ms: i64) -> bool {
    clients == 0 && idle_ms >= IDLE_STOP_MS
}

// Linux: process handling. Every program of a screen runs in its own process group.

#[cfg(target_os = "linux")]
impl Session {
    fn status(&self, now: i64) -> ScreenStatus {
        let idle_ms = if vnc_clients(self.vnc_port) > 0 {
            0
        } else {
            (now - self.last_agent_ms).max(0)
        };
        ScreenStatus {
            running: true,
            display: Some(self.display),
            width: Some(self.width),
            height: Some(self.height),
            vnc_port: Some(self.vnc_port),
            vnc_password: Some(self.vnc_password.clone()),
            started_at: Some(self.started_at),
            controller: self.controller,
            idle_ms: Some(idle_ms),
        }
    }
}

#[cfg(target_os = "linux")]
fn lock_std<T>(m: &StdMutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

#[cfg(target_os = "linux")]
fn start_failed(e: ScreenError) -> ScreenError {
    match e {
        ScreenError::ActionFailed(why) => ScreenError::StartFailed(why),
        other => other,
    }
}

#[cfg(target_os = "linux")]
async fn start_locked(
    sessions: &mut HashMap<String, Session>,
    state_dir: &Path,
    workspace: &str,
    width: u32,
    height: u32,
) -> Result<(), ScreenError> {
    if sessions.contains_key(workspace) {
        return Ok(());
    }
    if width < MIN_SIZE.0 || height < MIN_SIZE.1 || width > MAX_SIZE.0 || height > MAX_SIZE.1 {
        return Err(ScreenError::InvalidArgs(format!(
            "screen size must be from {}x{} to {}x{}",
            MIN_SIZE.0, MIN_SIZE.1, MAX_SIZE.0, MAX_SIZE.1
        )));
    }
    let display = pick_display(&busy_displays())
        .ok_or_else(|| ScreenError::StartFailed("no free X display from :90 to :199".into()))?;
    let session = launch(&state_dir.join(workspace), display, width, height).await?;
    sessions.insert(workspace.to_string(), session);
    Ok(())
}

/// Writes the screen's `Xauthority`, then starts Xvfb, openbox and x11vnc. On failure, what already
/// started is stopped again and the authority file is removed.
#[cfg(target_os = "linux")]
async fn launch(dir: &Path, display: u32, width: u32, height: u32) -> Result<Session, ScreenError> {
    let xauth = write_xauthority(dir, display).await?;
    match start_processes(dir, display, width, height, &xauth).await {
        Ok(session) => Ok(session),
        Err(e) => {
            let _ = std::fs::remove_file(&xauth);
            Err(e)
        }
    }
}

/// Creates the folder of a screen, mode 0700. A folder that exists is set to 0700 as well.
#[cfg(target_os = "linux")]
fn create_screen_dir(dir: &Path) -> Result<(), ScreenError> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| ScreenError::StartFailed(format!("cannot create {}: {e}", dir.display())))?;
    // A folder that existed already keeps its old mode, so the mode is set again.
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| ScreenError::StartFailed(format!("cannot protect {}: {e}", dir.display())))
}

/// Writes `<dir>/Xauthority` with a new cookie for `:display`, mode 0600. A file left by a crashed
/// screen is replaced. Missing `xauth` gives `MissingComponent("xauth")`.
#[cfg(target_os = "linux")]
async fn write_xauthority(dir: &Path, display: u32) -> Result<PathBuf, ScreenError> {
    create_screen_dir(dir)?;
    let path = dir.join(XAUTH_FILE);
    let _ = std::fs::remove_file(&path);
    let cookie = random_cookie_hex();
    let written = async {
        run_capture_private(
            &xauth_source_argv(&path),
            &[],
            Some(xauth_source_input(display, &cookie)),
            "xauth",
        )
        .await
        .map_err(start_failed)?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| ScreenError::StartFailed(format!("cannot protect the X authority file: {e}")))
    }
    .await;
    match written {
        Ok(()) => Ok(path),
        Err(e) => {
            let _ = std::fs::remove_file(&path);
            Err(e)
        }
    }
}

/// Starts the processes of a screen whose `Xauthority` is written.
#[cfg(target_os = "linux")]
async fn start_processes(
    dir: &Path,
    display: u32,
    width: u32,
    height: u32,
    xauth: &Path,
) -> Result<Session, ScreenError> {
    let mut xvfb = spawn_group(&xvfb_argv(display, width, height, xauth), &[], "xvfb")?;
    if let Err(e) = wait_for_socket(&mut xvfb, display).await {
        terminate_child(xvfb).await;
        return Err(e);
    }
    let openbox = spawn_openbox(display, xauth);
    let vnc = match start_vnc(dir, display, xauth).await {
        Ok(vnc) => vnc,
        Err(e) => {
            terminate_child(xvfb).await;
            if let Some(child) = openbox {
                terminate_child(child).await;
            }
            return Err(e);
        }
    };
    Ok(Session {
        display,
        width,
        height,
        vnc_port: vnc.port,
        vnc_password: vnc.password,
        xauth: xauth.to_path_buf(),
        started_at: now_ms(),
        controller: None,
        last_agent_ms: now_ms(),
        xvfb,
        openbox,
        vnc: vnc.task,
        launched: Arc::new(StdMutex::new(Vec::new())),
    })
}

/// A running x11vnc with its port and password.
#[cfg(target_os = "linux")]
struct Vnc {
    task: VncTask,
    port: u16,
    password: String,
}

/// Writes a new password file, then starts x11vnc on a free localhost port, authorized by `xauth`.
#[cfg(target_os = "linux")]
async fn start_vnc(dir: &Path, display: u32, xauth: &Path) -> Result<Vnc, ScreenError> {
    let passwd = dir.join("passwd");
    let password = generate_password();
    run_capture_private(&storepasswd_argv(&password, &passwd), &[], None, "x11vnc")
        .await
        .map_err(start_failed)?;
    std::fs::set_permissions(&passwd, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| ScreenError::StartFailed(format!("cannot protect the password file: {e}")))?;

    let port = free_port()?;
    let child = spawn_group(
        &x11vnc_argv(display, port, &passwd, xauth),
        &display_env(display, xauth),
        "x11vnc",
    )?;
    let task = spawn_vnc_watcher(display, port, passwd, xauth.to_path_buf(), child);
    let listening = wait_until(START_TIMEOUT, || vnc_listening(port) || task.handle.is_finished()).await;
    if !listening || !vnc_listening(port) {
        stop_vnc(task).await;
        return Err(ScreenError::StartFailed(format!(
            "x11vnc did not listen on port {port} within 5 s"
        )));
    }
    Ok(Vnc { task, port, password })
}

/// Owns x11vnc: restarts it once if it exits on its own, and reaps it.
#[cfg(target_os = "linux")]
fn spawn_vnc_watcher(x_display: u32, port: u16, passwd: PathBuf, xauth: PathBuf, mut child: TrackedChild) -> VncTask {
    let pgid = Arc::new(AtomicI32::new(child.id().map_or(0, |p| p as i32)));
    let stopping = Arc::new(AtomicBool::new(false));
    let watch_pgid = Arc::clone(&pgid);
    let watch_stopping = Arc::clone(&stopping);
    let handle = tokio::spawn(async move {
        let mut restarted = false;
        loop {
            let _ = child.wait().await;
            child.release();
            watch_pgid.store(0, Ordering::SeqCst);
            if watch_stopping.load(Ordering::SeqCst) {
                return;
            }
            if restarted {
                tracing::warn!(
                    x_display = x_display,
                    "x11vnc exited again; the screen has no VNC until it is restarted"
                );
                return;
            }
            restarted = true;
            tracing::warn!(x_display = x_display, "x11vnc exited; restarting it once");
            let env = display_env(x_display, &xauth);
            match spawn_group(&x11vnc_argv(x_display, port, &passwd, &xauth), &env, "x11vnc") {
                Ok(next) => {
                    watch_pgid.store(next.id().map_or(0, |p| p as i32), Ordering::SeqCst);
                    child = next;
                }
                Err(e) => {
                    tracing::warn!(x_display = x_display, "cannot restart x11vnc: {e}");
                    return;
                }
            }
        }
    });
    VncTask { pgid, stopping, handle }
}

#[cfg(target_os = "linux")]
async fn stop_vnc(task: VncTask) {
    task.stopping.store(true, Ordering::SeqCst);
    signal_group(task.pgid.load(Ordering::SeqCst), libc::SIGTERM);
    let mut handle = task.handle;
    if tokio::time::timeout(GRACE, &mut handle).await.is_err() {
        signal_group(task.pgid.load(Ordering::SeqCst), libc::SIGKILL);
        let _ = handle.await;
    }
}

/// Waits until Xvfb has opened its socket. Fails early if Xvfb exits.
#[cfg(target_os = "linux")]
async fn wait_for_socket(child: &mut TrackedChild, display: u32) -> Result<(), ScreenError> {
    let socket = PathBuf::from(format!("/tmp/.X11-unix/X{display}"));
    if wait_until(START_TIMEOUT, || socket.exists()).await {
        return Ok(());
    }
    let exited = matches!(child.try_wait(), Ok(Some(_)));
    Err(ScreenError::StartFailed(if exited {
        format!("Xvfb exited while starting :{display}")
    } else {
        format!("Xvfb did not open :{display} within 5 s")
    }))
}

/// openbox is optional: without it the screen works, but windows have no frames.
#[cfg(target_os = "linux")]
fn spawn_openbox(display: u32, xauth: &Path) -> Option<TrackedChild> {
    match spawn_group(&["openbox".to_string()], &display_env(display, xauth), "openbox") {
        Ok(child) => Some(child),
        Err(e) => {
            tracing::warn!("openbox is not available ({e}); the screen runs without a window manager");
            None
        }
    }
}

/// Polls `ready` every 50 ms until it is true or `limit` has passed.
#[cfg(target_os = "linux")]
async fn wait_until(limit: Duration, mut ready: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    loop {
        if ready() {
            return true;
        }
        if Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(POLL).await;
    }
}

/// Spawns a program in its own process group, with no stdio. `Missing` if the program is not installed.
#[cfg(target_os = "linux")]
fn spawn_group(
    argv: &[String],
    env: &[(String, String)],
    component: &'static str,
) -> Result<TrackedChild, ScreenError> {
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..])
        .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    cmd.as_std_mut().process_group(0);
    let child = cmd.spawn().map_err(|e| spawn_error(&e, component))?;
    Ok(TrackedChild::new(child))
}

#[cfg(target_os = "linux")]
fn spawn_error(e: &std::io::Error, component: &'static str) -> ScreenError {
    if e.kind() == std::io::ErrorKind::NotFound {
        ScreenError::MissingComponent(component)
    } else {
        ScreenError::StartFailed(format!("{component}: {e}"))
    }
}

/// Runs a short-lived program to the end and returns its stdout. `input` is written to its stdin.
#[cfg(target_os = "linux")]
async fn run_capture(
    argv: &[String],
    env: &[(String, String)],
    input: Option<Vec<u8>>,
    component: &'static str,
) -> Result<Vec<u8>, ScreenError> {
    run_capture_with(argv, env, input, component, false).await
}

/// `run_capture` with umask 077: whatever the program creates is owner-only from the start.
#[cfg(target_os = "linux")]
async fn run_capture_private(
    argv: &[String],
    env: &[(String, String)],
    input: Option<Vec<u8>>,
    component: &'static str,
) -> Result<Vec<u8>, ScreenError> {
    run_capture_with(argv, env, input, component, true).await
}

#[cfg(target_os = "linux")]
async fn run_capture_with(
    argv: &[String],
    env: &[(String, String)],
    input: Option<Vec<u8>>,
    component: &'static str,
    private: bool,
) -> Result<Vec<u8>, ScreenError> {
    use tokio::io::AsyncWriteExt;
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..])
        .envs(env.iter().map(|(k, v)| (k.as_str(), v.as_str())))
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    if private {
        // SAFETY: the closure only calls umask, which is async-signal-safe, so it is sound in the
        // child between fork and exec.
        unsafe {
            cmd.as_std_mut().pre_exec(|| {
                libc::umask(0o077);
                Ok(())
            });
        }
    }
    let mut child = cmd.spawn().map_err(|e| spawn_error(&e, component))?;
    if let (Some(data), Some(mut stdin)) = (input, child.stdin.take()) {
        // A write error means the program quit early. Its exit status says why.
        let _ = stdin.write_all(&data).await;
    }
    let out = tokio::time::timeout(ACTION_TIMEOUT, child.wait_with_output())
        .await
        .map_err(|_| ScreenError::ActionFailed(format!("{} timed out", argv[0])))?
        .map_err(|e| ScreenError::ActionFailed(format!("{}: {e}", argv[0])))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(ScreenError::ActionFailed(format!("{}: {}", argv[0], stderr.trim())));
    }
    Ok(out.stdout)
}

/// One PNG of the whole screen, scaled down to `SCREENSHOT_MAX_WIDTH`. `env` puts the capture on the screen.
#[cfg(target_os = "linux")]
async fn screenshot(display: u32, env: &[(String, String)]) -> Result<Vec<u8>, ScreenError> {
    match run_capture(&import_argv(display), env, None, "imagemagick").await {
        Ok(png) => run_capture(&resize_argv("png"), &[], Some(png), "imagemagick").await,
        // Without `import` (ImageMagick), fall back to `xwd`; `convert` then reads its output.
        Err(ScreenError::MissingComponent(_)) => {
            let raw = run_capture(&xwd_argv(display), env, None, "imagemagick").await?;
            run_capture(&resize_argv("xwd"), &[], Some(raw), "imagemagick").await
        }
        Err(e) => Err(e),
    }
}

#[cfg(target_os = "linux")]
fn check_point(x: u32, y: u32, width: u32, height: u32) -> Result<(), ScreenError> {
    if x >= width || y >= height {
        return Err(ScreenError::InvalidArgs(format!(
            "x and y must be inside the {width}x{height} screen"
        )));
    }
    Ok(())
}

/// Starts `command` with `sh -c` on the screen, detached. The group is killed when the screen stops.
#[cfg(target_os = "linux")]
fn launch_program(session: &Session, command: &str) -> Result<(), ScreenError> {
    let mut child = spawn_group(
        &["sh".to_string(), "-c".to_string(), command.to_string()],
        &display_env(session.display, &session.xauth),
        "sh",
    )?;
    let pgid = child.id().map_or(0, |p| p as i32);
    lock_std(&session.launched).push(pgid);
    let launched = Arc::clone(&session.launched);
    tokio::spawn(async move {
        let _ = child.wait().await;
        child.release();
        lock_std(&launched).retain(|&p| p != pgid);
    });
    Ok(())
}

/// Stops a screen: its VNC first, then the window manager, Xvfb and the programs on it. Then the
/// screen's `Xauthority` is removed, since its cookie no longer opens anything.
#[cfg(target_os = "linux")]
async fn shutdown_session(session: Session) {
    let Session {
        xvfb,
        openbox,
        vnc,
        launched,
        xauth,
        ..
    } = session;
    stop_vnc(vnc).await;
    if let Some(child) = openbox {
        terminate_child(child).await;
    }
    terminate_child(xvfb).await;
    stop_launched(&launched).await;
    let _ = std::fs::remove_file(&xauth);
}

/// SIGTERM to a child's group, SIGKILL after `GRACE` if it is still there. Reaps the child.
#[cfg(target_os = "linux")]
async fn terminate_child(mut child: TrackedChild) {
    let pgid = child.id().map_or(0, |p| p as i32);
    signal_group(pgid, libc::SIGTERM);
    if tokio::time::timeout(GRACE, child.wait()).await.is_err() {
        signal_group(pgid, libc::SIGKILL);
        let _ = child.wait().await;
    }
    child.release();
}

#[cfg(target_os = "linux")]
async fn stop_launched(launched: &StdMutex<Vec<i32>>) {
    let groups = lock_std(launched).clone();
    for &pgid in &groups {
        signal_group(pgid, libc::SIGTERM);
    }
    let deadline = Instant::now() + GRACE;
    while Instant::now() < deadline && !lock_std(launched).is_empty() {
        tokio::time::sleep(POLL).await;
    }
    for pgid in lock_std(launched).clone() {
        signal_group(pgid, libc::SIGKILL);
    }
}

/// Send `sig` to the process group `pgid`. Ignored when the group is gone or `pgid` is not positive.
#[cfg(target_os = "linux")]
fn signal_group(pgid: i32, sig: libc::c_int) {
    if pgid <= 0 {
        return;
    }
    // SAFETY: killpg only sends a signal; an unknown group yields ESRCH, which is ignored.
    let _ = unsafe { libc::killpg(pgid, sig) };
}

/// A free TCP port on 127.0.0.1. The port is only probed: another process may take it before x11vnc does.
#[cfg(target_os = "linux")]
fn free_port() -> Result<u16, ScreenError> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| ScreenError::StartFailed(format!("no free localhost port: {e}")))?;
    listener
        .local_addr()
        .map(|addr| addr.port())
        .map_err(|e| ScreenError::StartFailed(format!("no free localhost port: {e}")))
}

/// Both tables of `/proc/net/tcp` and `/proc/net/tcp6`, joined, so one parse covers IPv4 and IPv6.
#[cfg(target_os = "linux")]
fn tcp_tables() -> String {
    let tcp = std::fs::read_to_string("/proc/net/tcp").unwrap_or_default();
    let tcp6 = std::fs::read_to_string("/proc/net/tcp6").unwrap_or_default();
    format!("{tcp}\n{tcp6}")
}

#[cfg(target_os = "linux")]
fn vnc_listening(port: u16) -> bool {
    is_listening(&tcp_tables(), port)
}

#[cfg(target_os = "linux")]
fn vnc_clients(port: u16) -> usize {
    count_established(&tcp_tables(), port)
}

/// Display numbers in use: sockets in `/tmp/.X11-unix` and `/tmp/.X<n>-lock` files.
#[cfg(target_os = "linux")]
fn busy_displays() -> Vec<u32> {
    let mut busy = Vec::new();
    if let Ok(entries) = std::fs::read_dir("/tmp/.X11-unix") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let number = name
                .to_str()
                .and_then(|n| n.strip_prefix('X'))
                .and_then(|n| n.parse::<u32>().ok());
            busy.extend(number);
        }
    }
    if let Ok(entries) = std::fs::read_dir("/tmp") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let number = name
                .to_str()
                .and_then(|n| n.strip_prefix(".X"))
                .and_then(|n| n.strip_suffix("-lock"))
                .and_then(|n| n.parse::<u32>().ok());
            busy.extend(number);
        }
    }
    busy
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    // Pure helpers.

    #[test]
    fn display_is_the_first_free_number_from_90() {
        assert_eq!(pick_display(&[]), Some(90));
        assert_eq!(pick_display(&[90, 91, 93]), Some(92));
        assert_eq!(pick_display(&[5, 89]), Some(90));
        assert_eq!(pick_display(&[90]), Some(91));
    }

    #[test]
    fn no_display_when_all_of_90_to_199_are_busy() {
        let busy: Vec<u32> = (90..200).collect();
        assert_eq!(pick_display(&busy), None);
        let almost: Vec<u32> = (90..199).collect();
        assert_eq!(pick_display(&almost), Some(199));
    }

    const AUTH: &str = "/home/u/.bandito/screens/shared/Xauthority";

    #[test]
    fn xvfb_argv_matches_the_documented_command_and_checks_cookies() {
        assert_eq!(
            xvfb_argv(90, 1600, 1000, Path::new(AUTH)),
            [
                "Xvfb",
                ":90",
                "-screen",
                "0",
                "1600x1000x24",
                "-nolisten",
                "tcp",
                "-dpi",
                "96",
                "-auth",
                AUTH,
            ]
        );
    }

    #[test]
    fn x11vnc_argv_listens_on_localhost_with_the_password_file_and_the_cookie() {
        assert_eq!(
            x11vnc_argv(
                91,
                5901,
                Path::new("/home/u/.bandito/screens/shared/passwd"),
                Path::new(AUTH)
            ),
            [
                "x11vnc",
                "-display",
                ":91",
                "-rfbport",
                "5901",
                "-localhost",
                "-rfbauth",
                "/home/u/.bandito/screens/shared/passwd",
                "-forever",
                "-shared",
                "-noxdamage",
                "-quiet",
                "-auth",
                AUTH,
            ]
        );
    }

    #[test]
    fn xauth_reads_the_cookie_from_stdin_not_from_its_arguments() {
        let cookie = "00112233445566778899aabbccddeeff";
        let argv = xauth_source_argv(Path::new(AUTH));
        assert_eq!(argv, ["xauth", "-f", AUTH, "source", "-"]);
        assert!(argv.iter().all(|arg| !arg.contains(cookie)), "{argv:?}");
        assert_eq!(
            xauth_source_input(90, cookie),
            format!("add :90 MIT-MAGIC-COOKIE-1 {cookie}\n").into_bytes()
        );
    }

    #[test]
    fn programs_on_the_screen_get_display_and_xauthority() {
        assert_eq!(
            display_env(90, Path::new(AUTH)),
            [
                ("DISPLAY".to_string(), ":90".to_string()),
                ("XAUTHORITY".to_string(), AUTH.to_string()),
            ]
        );
    }

    #[test]
    fn screen_cookie_is_16_random_bytes_as_hex() {
        let a = random_cookie_hex();
        assert_eq!(a.len(), 32, "{a}");
        assert!(
            a.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()),
            "{a}"
        );
        assert_ne!(a, random_cookie_hex());
    }

    // Linux: what the screen's helper programs run with, and the folder they write into.

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn helper_programs_run_with_umask_077() {
        let argv = vec!["sh".to_string(), "-c".to_string(), "umask".to_string()];
        let out = run_capture_private(&argv, &[], None, "sh").await.unwrap();
        assert_eq!(String::from_utf8_lossy(&out).trim(), "0077");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn screen_folder_is_owner_only_even_when_it_existed() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let screen = dir.path().join("shared");
        std::fs::create_dir(&screen).unwrap();
        std::fs::set_permissions(&screen, std::fs::Permissions::from_mode(0o755)).unwrap();
        create_screen_dir(&screen).unwrap();
        let mode = std::fs::metadata(&screen).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700);
    }

    #[test]
    fn storepasswd_argv_writes_the_password_to_the_file() {
        assert_eq!(
            storepasswd_argv("abc123", Path::new("/tmp/passwd")),
            ["x11vnc", "-storepasswd", "abc123", "/tmp/passwd"]
        );
    }

    #[test]
    fn screenshot_argv_import_then_resize_then_xwd_fallback() {
        assert_eq!(
            import_argv(90),
            ["import", "-window", "root", "-display", ":90", "png:-"]
        );
        assert_eq!(xwd_argv(90), ["xwd", "-root", "-display", ":90"]);
        assert_eq!(resize_argv("png"), ["convert", "png:-", "-resize", "1280x>", "png:-"]);
        assert_eq!(resize_argv("xwd")[1], "xwd:-");
        assert_eq!(format!("{}x>", SCREENSHOT_MAX_WIDTH), "1280x>");
    }

    #[test]
    fn click_argv_maps_buttons_and_double_clicks() {
        assert_eq!(
            click_argv(10, 20, Button::Left, false),
            ["xdotool", "mousemove", "10", "20", "click", "1"]
        );
        assert_eq!(
            click_argv(10, 20, Button::Middle, false),
            ["xdotool", "mousemove", "10", "20", "click", "2"]
        );
        assert_eq!(
            click_argv(10, 20, Button::Right, true),
            ["xdotool", "mousemove", "10", "20", "click", "--repeat", "2", "3"]
        );
    }

    #[test]
    fn move_type_and_key_argv() {
        assert_eq!(move_argv(5, 6), ["xdotool", "mousemove", "5", "6"]);
        assert_eq!(
            type_argv("hi there"),
            ["xdotool", "type", "--delay", "12", "--", "hi there"]
        );
        assert_eq!(key_argv("ctrl+l"), ["xdotool", "key", "--", "ctrl+l"]);
    }

    #[test]
    fn scroll_argv_uses_wheel_buttons() {
        assert_eq!(
            scroll_argv(Direction::Up, 3),
            ["xdotool", "click", "--repeat", "3", "4"]
        );
        assert_eq!(
            scroll_argv(Direction::Down, 1),
            ["xdotool", "click", "--repeat", "1", "5"]
        );
        assert_eq!(
            scroll_argv(Direction::Left, 2),
            ["xdotool", "click", "--repeat", "2", "6"]
        );
        assert_eq!(
            scroll_argv(Direction::Right, 20),
            ["xdotool", "click", "--repeat", "20", "7"]
        );
    }

    /// A `/proc/net/tcp` excerpt: header, a listener on 5900 (0x170C), two clients of 5900,
    /// the tunnel's own client socket (local 40000, remote 5900), and an unrelated 8080 connection.
    const TCP_SAMPLE: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:170C 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1001 1 0000000000000000 100 0 0 10 0
   1: 0100007F:170C 0100007F:9C42 01 00000000:00000000 00:00000000 00000000     0        0 1002 1 0000000000000000 20 0 0 10 -1
   2: 0100007F:9C40 0100007F:170C 01 00000000:00000000 00:00000000 00000000     0        0 1003 1 0000000000000000 20 0 0 10 -1
   3: 0100007F:170C 0100007F:9C44 01 00000000:00000000 00:00000000 00000000     0        0 1004 1 0000000000000000 20 0 0 10 -1
   4: 0100007F:1F90 0100007F:9C46 01 00000000:00000000 00:00000000 00000000     0        0 1005 1 0000000000000000 20 0 0 10 -1
   5: 0100007F:170C 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1006 1 0000000000000000 100 0 0 10 0
";

    #[test]
    fn established_clients_are_counted_on_the_vnc_port_only() {
        assert_eq!(count_established(TCP_SAMPLE, 5900), 2);
        assert_eq!(count_established(TCP_SAMPLE, 8080), 1);
        assert_eq!(count_established(TCP_SAMPLE, 40000), 1);
        assert_eq!(count_established(TCP_SAMPLE, 9999), 0);
        assert_eq!(count_established("", 5900), 0);
    }

    #[test]
    fn listener_is_detected_by_its_port_and_state() {
        assert!(is_listening(TCP_SAMPLE, 5900));
        assert!(!is_listening(TCP_SAMPLE, 40000));
        assert!(!is_listening(TCP_SAMPLE, 8080));
        assert!(!is_listening("", 5900));
    }

    #[test]
    fn password_is_8_printable_characters_without_quote_or_backslash() {
        assert_eq!(PASSWORD_LEN, 8, "RFB uses only the first 8 characters");
        let p = generate_password();
        assert_eq!(p.chars().count(), PASSWORD_LEN);
        assert!(p.bytes().all(|b| PASSWORD_ALPHABET.contains(&b)), "{p}");
        assert!(
            p.bytes().all(|b| (0x21..=0x7E).contains(&b) && b != b'"' && b != b'\\'),
            "{p}"
        );
    }

    #[test]
    fn password_alphabet_is_printable_ascii_minus_quote_and_backslash() {
        assert_eq!(PASSWORD_ALPHABET.len(), 92);
        assert_eq!(PASSWORD_ALPHABET.first(), Some(&b'!'));
        assert_eq!(PASSWORD_ALPHABET.last(), Some(&b'~'));
        assert!(!PASSWORD_ALPHABET.contains(&b'"'));
        assert!(!PASSWORD_ALPHABET.contains(&b'\\'));
        let mut sorted = PASSWORD_ALPHABET.to_vec();
        sorted.dedup();
        assert_eq!(sorted.len(), 92, "no repeated characters");
    }

    #[test]
    fn password_bytes_are_drawn_again_above_184_so_no_character_is_favored() {
        // 184 = 2 * 92: bytes 0..184 give every character exactly two values.
        assert_eq!(password_char(0), Some('!'));
        assert_eq!(
            password_char(183),
            password_char(91),
            "183 = 91 + 92 gives the same character"
        );
        assert_eq!(password_char(184), None);
        assert_eq!(password_char(255), None);
        for c in PASSWORD_ALPHABET {
            let hits = (0..=255u8).filter(|&b| password_char(b) == Some(char::from(c))).count();
            assert_eq!(hits, 2, "{}", char::from(c));
        }
    }

    #[test]
    fn a_thousand_passwords_do_not_repeat() {
        let all: std::collections::HashSet<String> = (0..1000).map(|_| generate_password()).collect();
        assert_eq!(all.len(), 1000);
    }

    #[test]
    fn user_control_blocks_agent_tools() {
        assert_eq!(agent_gate(None), Ok(()));
        assert_eq!(agent_gate(Some(Controller::Agent)), Ok(()));
        let err = agent_gate(Some(Controller::User)).unwrap_err();
        assert_eq!(err, ScreenError::UserControls);
        assert_eq!(
            err.to_string(),
            "The user is controlling the screen. Wait or ask them to hand it back."
        );
    }

    #[test]
    fn png_size_reads_the_ihdr_chunk() {
        fn png_header(width: u32, height: u32) -> Vec<u8> {
            let mut v = b"\x89PNG\r\n\x1a\n".to_vec();
            v.extend_from_slice(&13u32.to_be_bytes());
            v.extend_from_slice(b"IHDR");
            v.extend_from_slice(&width.to_be_bytes());
            v.extend_from_slice(&height.to_be_bytes());
            v
        }
        assert_eq!(png_size(&png_header(1280, 800)), Some((1280, 800)));
        assert_eq!(png_size(&png_header(1, 1)), Some((1, 1)));
        assert_eq!(png_size(b"GIF89a\x01\x00\x01\x00"), None);
        assert_eq!(png_size(&[0x89, b'P', b'N']), None);
    }

    #[test]
    fn workspace_names_are_short_and_safe_for_a_folder_name() {
        let long = "x".repeat(MAX_WORKSPACE_LEN);
        let too_long = "x".repeat(MAX_WORKSPACE_LEN + 1);
        for ok in ["shared", "team-1", "a_b", long.as_str()] {
            assert_eq!(validate_workspace(ok), Ok(()), "{ok}");
        }
        for bad in ["", "../etc", "a b", "a/b", "ä", too_long.as_str()] {
            assert!(
                matches!(validate_workspace(bad), Err(ScreenError::InvalidArgs(_))),
                "{bad}"
            );
        }
    }

    #[test]
    fn idle_screen_without_clients_stops_after_30_minutes() {
        assert!(should_auto_stop(0, IDLE_STOP_MS));
        assert!(should_auto_stop(0, IDLE_STOP_MS * 2));
        assert!(!should_auto_stop(0, IDLE_STOP_MS - 1));
        assert!(!should_auto_stop(1, IDLE_STOP_MS * 2));
    }

    #[test]
    fn screen_error_reasons_are_stable() {
        assert_eq!(ScreenError::Unsupported.reason(), "unsupported");
        assert_eq!(ScreenError::MissingComponent("xdotool").reason(), "missing_component");
        assert_eq!(ScreenError::StartFailed("x".into()).reason(), "start_failed");
        assert_eq!(ScreenError::UserControls.reason(), "user_controls");
    }

    // Off Linux there is no screen: every call says so.

    #[cfg(not(target_os = "linux"))]
    #[tokio::test]
    async fn every_screen_call_is_unsupported_off_linux() {
        let dir = tempfile::tempdir().unwrap();
        let mgr = ScreenManager::new(dir.path().to_path_buf());
        assert_eq!(
            mgr.start(DEFAULT_WORKSPACE, DEFAULT_WIDTH, DEFAULT_HEIGHT).await,
            Err(ScreenError::Unsupported)
        );
        assert_eq!(mgr.status(DEFAULT_WORKSPACE).await, Err(ScreenError::Unsupported));
        assert_eq!(mgr.stop(DEFAULT_WORKSPACE).await, Err(ScreenError::Unsupported));
        assert_eq!(
            mgr.control(DEFAULT_WORKSPACE, Some(Controller::User)).await,
            Err(ScreenError::Unsupported)
        );
        assert_eq!(
            mgr.agent_action(DEFAULT_WORKSPACE, AgentAction::Screenshot).await,
            Err(ScreenError::Unsupported)
        );
        assert!(mgr.env_for(DEFAULT_WORKSPACE).await.is_empty());
        mgr.shutdown_all().await;
    }

    // Linux integration: needs Xvfb, x11vnc, xdotool, ImageMagick, openbox, xauth and xdpyinfo,
    // which are in daemon/tests/docker/screen-it.Dockerfile. Run from the repository root:
    //   mkdir -p screen-it
    //   # 1. build the lib test binary in rust:1-bookworm and copy it to ./screen-it/lib-test-bin
    //   docker run --rm -v "$PWD":/src:ro -v bandito-target:/target -v "$PWD/screen-it":/out \
    //     -e CARGO_TARGET_DIR=/target -w /src/daemon rust:1-bookworm sh -c \
    //     'cargo test --lib --no-run --message-format=json | grep "\"executable\":\"" \
    //      | sed "s/.*\"executable\":\"\([^\"]*\)\".*/\1/" | tail -1 | xargs -I{} cp {} /out/lib-test-bin'
    //   # 2. build the image and run the ignored test in it
    //   docker build -f daemon/tests/docker/screen-it.Dockerfile -t bandito-screen-it daemon/tests/docker
    //   docker run --rm -e BANDITO_SCREEN_IT=1 -v "$PWD/screen-it:/t" --entrypoint /t/lib-test-bin \
    //     bandito-screen-it --ignored screen_lifecycle --nocapture

    #[cfg(target_os = "linux")]
    fn it_enabled() -> bool {
        std::env::var("BANDITO_SCREEN_IT").as_deref() == Ok("1")
    }

    /// Whether `xdpyinfo` opens `:display`, with `xauthority` as the cookie file. `None` means no
    /// `XAUTHORITY` at all (the variable is removed, and the test's HOME has no cookie for the display).
    #[cfg(target_os = "linux")]
    fn display_opens(display: u32, xauthority: Option<&Path>) -> bool {
        let mut cmd = std::process::Command::new("xdpyinfo");
        cmd.arg("-display")
            .arg(format!(":{display}"))
            .env_remove("XAUTHORITY")
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(auth) = xauthority {
            cmd.env("XAUTHORITY", auth);
        }
        cmd.status().is_ok_and(|status| status.success())
    }

    #[cfg(target_os = "linux")]
    fn listening_on(port: u16) -> bool {
        let tcp = std::fs::read_to_string("/proc/net/tcp").unwrap_or_default();
        let tcp6 = std::fs::read_to_string("/proc/net/tcp6").unwrap_or_default();
        is_listening(&tcp, port) || is_listening(&tcp6, port)
    }

    #[cfg(target_os = "linux")]
    fn alive(pid: i32) -> bool {
        // SAFETY: kill with signal 0 sends nothing; it only checks that the process exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    #[ignore = "needs Xvfb, x11vnc, xdotool, imagemagick, openbox, xauth, xdpyinfo; BANDITO_SCREEN_IT=1 cargo test -- --ignored"]
    async fn screen_lifecycle_end_to_end() {
        if !it_enabled() {
            return;
        }
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let mgr = ScreenManager::new(dir.path().to_path_buf());
        let auth = dir.path().join(DEFAULT_WORKSPACE).join(XAUTH_FILE);

        let st = mgr.start(DEFAULT_WORKSPACE, 800, 600).await.unwrap();
        assert!(st.running, "{st:?}");
        assert_eq!(st.width, Some(800));
        assert_eq!(st.height, Some(600));
        assert_eq!(st.controller, None);
        let port = st.vnc_port.expect("vnc port");
        assert!(listening_on(port), "vnc port {port} is not listening");
        assert_eq!(st.vnc_password.as_deref().map(str::len), Some(PASSWORD_LEN));

        // The screen is protected by its cookie: without XAUTHORITY the display refuses, with it, opens.
        let display = st.display.expect("display");
        let mode = std::fs::metadata(&auth)
            .expect("Xauthority exists")
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "Xauthority must be owner-only");
        assert!(!display_opens(display, None), ":{display} opened without XAUTHORITY");
        assert!(
            display_opens(display, Some(&auth)),
            ":{display} did not open with XAUTHORITY"
        );

        // Starting again returns the same screen.
        let again = mgr.start(DEFAULT_WORKSPACE, 800, 600).await.unwrap();
        assert_eq!(again.display, st.display);
        assert_eq!(again.vnc_port, st.vnc_port);

        let shot = mgr
            .agent_action(DEFAULT_WORKSPACE, AgentAction::Screenshot)
            .await
            .unwrap();
        let png = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            shot["png_base64"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(&png[..8], b"\x89PNG\r\n\x1a\n");
        assert_eq!(shot["width"], 800);
        assert_eq!(shot["height"], 600);

        for action in [
            AgentAction::Move { x: 10, y: 10 },
            AgentAction::Click {
                x: 10,
                y: 10,
                button: Button::Left,
                double: false,
            },
            AgentAction::Click {
                x: 20,
                y: 20,
                button: Button::Right,
                double: true,
            },
            AgentAction::Type { text: "hello".into() },
            AgentAction::Key { keys: "ctrl+l".into() },
            AgentAction::Scroll {
                direction: Direction::Down,
                amount: 2,
            },
        ] {
            mgr.agent_action(DEFAULT_WORKSPACE, action.clone())
                .await
                .unwrap_or_else(|e| panic!("{action:?}: {e}"));
        }

        let env = mgr.env_for(DEFAULT_WORKSPACE).await;
        assert!(
            env.contains(&("DISPLAY".to_string(), format!(":{}", st.display.unwrap()))),
            "{env:?}"
        );
        assert!(
            env.contains(&("XAUTHORITY".to_string(), auth.display().to_string())),
            "{env:?}"
        );

        let pids = mgr.pids_for_test(DEFAULT_WORKSPACE).await;
        assert!(!pids.is_empty());
        assert!(pids.iter().all(|&p| alive(p)));

        mgr.stop(DEFAULT_WORKSPACE).await.unwrap();
        assert!(!mgr.status(DEFAULT_WORKSPACE).await.unwrap().running);
        assert!(pids.iter().all(|&p| !alive(p)), "processes still alive: {pids:?}");
        assert!(!auth.exists(), "the Xauthority file stays after the screen stops");
    }
}
