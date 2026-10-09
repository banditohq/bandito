//! The server's browser: one Chrome per workspace, driven over the DevTools protocol.
//! The app watches it through the tunnel (CDP screencast); agents use it through the
//! crew MCP tools, which call the `browser.agent.*` methods. See docs/ARCHITECTURE.md#browser.

use crate::cdp::{Cdp, Element};
use crate::event::Decision;
use crate::rpc::preview::client;
use crate::setup;
use crate::supervisor::{ApprovalSpec, Supervisor};
use anyhow::{Context, Result, bail};
use axum::body::Body;
use axum::http::{Request, Uri};
use http_body_util::BodyExt;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak};
use std::time::{Duration, Instant};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;

/// Workspace the agents share, and the default for every method.
pub const DEFAULT_WORKSPACE: &str = "shared";
/// Stopped after this long with no agent call and no status/touch from the app.
const IDLE_LIMIT: Duration = Duration::from_secs(30 * 60);
/// How often the idle check runs.
const IDLE_CHECK: Duration = Duration::from_secs(60);
/// How long Chrome may take to answer on its DevTools port.
const STARTUP_LIMIT: Duration = Duration::from_secs(10);
/// How long Chrome may take to exit after SIGTERM.
const STOP_GRACE: Duration = Duration::from_secs(5);
/// Set to `1` to pass `--no-sandbox` (needed when running as root, e.g. in Docker tests).
const NO_SANDBOX_ENV: &str = "BANDITO_BROWSER_NO_SANDBOX";
const MAC_CHROME: &str = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
/// How long the user has to answer a risky click before it is refused.
pub const CLICK_APPROVAL_LIMIT: Duration = Duration::from_secs(10 * 60);

/// Who drives the browser right now. The agents wait while it is the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Holder {
    User,
    Agent,
    None,
}

/// What the app sees of a workspace's browser.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    pub running: bool,
    pub cdp_port: Option<u16>,
    pub browser_ws_path: Option<String>,
    pub pid: Option<u32>,
    pub started_at: Option<i64>,
    pub controller: Option<Holder>,
}

impl Status {
    fn stopped() -> Self {
        Self {
            running: false,
            cdp_port: None,
            browser_ws_path: None,
            pid: None,
            started_at: None,
            controller: None,
        }
    }
}

/// Why a browser method failed. The RPC layer maps each one (see rpc/browser.rs).
#[derive(Debug)]
pub enum BrowserError {
    /// No Chrome or Chromium on this server.
    MissingComponent,
    StartFailed(String),
    Unsupported,
    NotRunning,
    /// The user holds the browser, so an agent may not drive it.
    UserControls,
    /// The user refused a risky click, or did not answer it in time.
    Declined,
    Failed(String),
    InvalidWorkspace,
    UnsupportedUrl,
}

/// One running Chrome.
struct Running {
    child: Child,
    pid: u32,
    port: u16,
    browser_path: String,
    started_at: i64,
    controller: Holder,
    /// The tab the agent tools work in (a DevTools target id).
    target: Option<String>,
    last_activity: Instant,
}

impl Running {
    fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    fn status(&self) -> Status {
        Status {
            running: true,
            cdp_port: Some(self.port),
            browser_ws_path: Some(self.browser_path.clone()),
            pid: Some(self.pid),
            started_at: Some(self.started_at),
            controller: Some(self.controller),
        }
    }

    /// SIGTERM to the whole process group, then SIGKILL after the grace period.
    async fn shutdown(&mut self) {
        signal_group(self.pid, libc::SIGTERM);
        if tokio::time::timeout(STOP_GRACE, self.child.wait()).await.is_err() {
            signal_group(self.pid, libc::SIGKILL);
            let _ = self.child.wait().await;
        }
    }
}

/// Owns the browsers of this server. Held in `App` as an `Arc`.
pub struct BrowserManager {
    home: PathBuf,
    idle_limit: Duration,
    /// Whether the idle check task is running (started by the first `start`).
    watching: AtomicBool,
    running: Mutex<HashMap<String, Running>>,
}

impl BrowserManager {
    /// Profiles live under `<home>/workspaces/<workspace>/browser`.
    pub fn new(home: PathBuf) -> Arc<Self> {
        Self::with_idle_limit(home, IDLE_LIMIT)
    }

    /// The manager for the data directory of this server (`$BANDITO_HOME` or `~/.bandito`).
    pub fn system() -> Arc<Self> {
        Self::new(setup::default_home())
    }

    fn with_idle_limit(home: PathBuf, idle_limit: Duration) -> Arc<Self> {
        Arc::new(Self {
            home,
            idle_limit,
            watching: AtomicBool::new(false),
            running: Mutex::new(HashMap::new()),
        })
    }

    fn workspace_dir(&self, workspace: &str) -> PathBuf {
        self.home.join("workspaces").join(workspace)
    }

    /// Start the workspace's browser, or return the running one.
    pub async fn start(self: &Arc<Self>, workspace: &str) -> Result<Status, BrowserError> {
        check_workspace(workspace)?;
        ensure_platform()?;
        let mut running = self.running.lock().await;
        if let Some(r) = live(&mut running, workspace) {
            return Ok(r.status());
        }

        let path_var = std::env::var_os("PATH").unwrap_or_default();
        let binary = find_browser(&path_var).ok_or(BrowserError::MissingComponent)?;
        let dir = self.workspace_dir(workspace);
        let profile = dir.join("browser");
        std::fs::create_dir_all(&profile).map_err(start_failed)?;
        let log_path = dir.join("browser.log");
        let log = std::fs::File::create(&log_path).map_err(start_failed)?;
        let log_again = log.try_clone().map_err(start_failed)?;
        let port = free_port().map_err(start_failed)?;
        let no_sandbox = std::env::var(NO_SANDBOX_ENV).is_ok_and(|v| v == "1");
        let mut child = Command::new(&binary)
            .args(chrome_args(&profile, port, no_sandbox))
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(log_again))
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .map_err(start_failed)?;
        let pid = child.id().unwrap_or_default();
        let browser_path = match wait_for_devtools(port, &mut child).await {
            Ok(path) => path,
            Err(e) => {
                signal_group(pid, libc::SIGKILL);
                let _ = child.wait().await;
                return Err(BrowserError::StartFailed(format!(
                    "{e:#} (log: {})",
                    log_path.display()
                )));
            }
        };
        let entry = Running {
            child,
            pid,
            port,
            browser_path,
            started_at: crate::store::now_ms(),
            controller: Holder::None,
            target: None,
            last_activity: Instant::now(),
        };
        let status = entry.status();
        running.insert(workspace.to_string(), entry);
        drop(running);
        if !self.watching.swap(true, Ordering::SeqCst) {
            spawn_idle_check(Arc::downgrade(self), IDLE_CHECK);
        }
        Ok(status)
    }

    /// The workspace's browser as the app sees it. Counts as app activity.
    pub async fn status(&self, workspace: &str) -> Status {
        let mut running = self.running.lock().await;
        match live(&mut running, workspace) {
            Some(r) => {
                r.last_activity = Instant::now();
                r.status()
            }
            None => Status::stopped(),
        }
    }

    /// Stop the workspace's browser. Nothing happens when it is not running.
    pub async fn stop(&self, workspace: &str) {
        let removed = self.running.lock().await.remove(workspace);
        if let Some(mut r) = removed {
            r.shutdown().await;
        }
    }

    /// Who drives the browser: the user (agents wait), an agent, or nobody.
    pub async fn control(&self, workspace: &str, holder: Holder) -> Result<Status, BrowserError> {
        let mut running = self.running.lock().await;
        let r = live(&mut running, workspace).ok_or(BrowserError::NotRunning)?;
        r.controller = holder;
        r.last_activity = Instant::now();
        Ok(r.status())
    }

    /// App activity: keeps the browser from being stopped as idle.
    pub async fn touch(&self, workspace: &str) {
        if let Some(r) = self.running.lock().await.get_mut(workspace) {
            r.last_activity = Instant::now();
        }
    }

    /// Stop every browser that has been idle for the limit.
    async fn reap_idle(&self) {
        let idle: Vec<String> = {
            let running = self.running.lock().await;
            running
                .iter()
                .filter(|(_, r)| r.last_activity.elapsed() >= self.idle_limit)
                .map(|(workspace, _)| workspace.clone())
                .collect()
        };
        for workspace in idle {
            self.stop(&workspace).await;
        }
    }

    async fn is_running(&self, workspace: &str) -> bool {
        let mut running = self.running.lock().await;
        live(&mut running, workspace).is_some()
    }

    async fn browser_endpoint(&self, workspace: &str) -> Option<(u16, String)> {
        self.running
            .lock()
            .await
            .get(workspace)
            .map(|r| (r.port, r.browser_path.clone()))
    }

    /// The port and current tab of the default workspace, for an agent call. Starts the browser
    /// when it is not running, refuses while the user holds it, and counts as activity.
    async fn agent_state(self: &Arc<Self>) -> Result<(u16, Option<String>), BrowserError> {
        if !self.is_running(DEFAULT_WORKSPACE).await {
            self.start(DEFAULT_WORKSPACE).await?;
        }
        let mut running = self.running.lock().await;
        let r = running.get_mut(DEFAULT_WORKSPACE).ok_or(BrowserError::NotRunning)?;
        if r.controller == Holder::User {
            return Err(BrowserError::UserControls);
        }
        r.last_activity = Instant::now();
        Ok((r.port, r.target.clone()))
    }

    async fn set_target(&self, target: &str) {
        if let Some(r) = self.running.lock().await.get_mut(DEFAULT_WORKSPACE) {
            r.target = Some(target.to_string());
        }
    }

    /// The agent's current tab, connected. Opens a new blank tab when `new_tab`, or when the browser has none.
    async fn agent_page(self: &Arc<Self>, new_tab: bool) -> Result<Cdp, BrowserError> {
        let (port, current) = self.agent_state().await?;
        let target = if new_tab {
            self.create_tab(port).await?
        } else {
            let pages = page_tabs(port).await.map_err(failed)?;
            match current
                .filter(|c| pages.iter().any(|p| &p.id == c))
                .or_else(|| pages.first().map(|p| p.id.clone()))
            {
                Some(id) => id,
                None => self.create_tab(port).await?,
            }
        };
        self.set_target(&target).await;
        Cdp::connect(&page_url(port, &target)).await.map_err(failed)
    }

    async fn create_tab(&self, port: u16) -> Result<String, BrowserError> {
        let created = self
            .browser_command(port, "Target.createTarget", json!({ "url": "about:blank" }))
            .await?;
        created["targetId"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| BrowserError::Failed("the browser created no tab".into()))
    }

    /// One command on the browser-level DevTools socket.
    async fn browser_command(&self, port: u16, method: &str, params: Value) -> Result<Value, BrowserError> {
        let path = self
            .browser_endpoint(DEFAULT_WORKSPACE)
            .await
            .map(|(_, path)| path)
            .ok_or(BrowserError::NotRunning)?;
        let mut browser = Cdp::connect(&format!("ws://127.0.0.1:{port}{path}"))
            .await
            .map_err(failed)?;
        browser.call(method, params).await.map_err(failed)
    }

    /// Open a URL in the agent's tab (a new tab with `new_tab`).
    pub async fn agent_open(self: &Arc<Self>, url: &str, new_tab: bool) -> Result<String, BrowserError> {
        let url = url.trim();
        check_url(url)?;
        let mut cdp = self.agent_page(new_tab).await?;
        cdp.open(url).await.map_err(failed)?;
        Ok(format!("Opened {url}. Take a snapshot to see the page."))
    }

    pub async fn agent_snapshot(self: &Arc<Self>) -> Result<String, BrowserError> {
        let mut cdp = self.agent_page(false).await?;
        cdp.snapshot().await.map_err(failed)
    }

    /// What a click on this ref would hit: the element and the page it is on.
    pub async fn agent_target(self: &Arc<Self>, node: i64) -> Result<ClickTarget, BrowserError> {
        let mut cdp = self.agent_page(false).await?;
        let element = cdp.element(node).await.map_err(failed)?;
        let page = cdp.url().await.map_err(failed)?;
        Ok(ClickTarget { element, page })
    }

    /// Click a ref for the agent. A risky element (see [`needs_approval`]) is clicked only when the
    /// user allows it in the agent's feed; see [`approve_click`].
    pub async fn agent_click(
        self: &Arc<Self>,
        sup: &Supervisor,
        agent_id: &str,
        node: i64,
        approval_limit: Duration,
    ) -> Result<String, BrowserError> {
        let target = self.agent_target(node).await?;
        if needs_approval(&target.element) {
            approve_click(sup, agent_id, &target, approval_limit).await?;
            // The user approved this element. The page may have changed while they decided, so the
            // ref must still be that element.
            if self.agent_target(node).await?.element != target.element {
                return Err(BrowserError::Failed(
                    "the element changed while the user was deciding; take a new snapshot".to_string(),
                ));
            }
        }
        let mut cdp = self.agent_page(false).await?;
        cdp.click(node).await.map_err(failed)?;
        Ok(format!(
            "Clicked [{node}] {} \"{}\".",
            target.element.role, target.element.name
        ))
    }

    pub async fn agent_type(self: &Arc<Self>, node: i64, text: &str, submit: bool) -> Result<String, BrowserError> {
        let mut cdp = self.agent_page(false).await?;
        cdp.type_text(node, text, submit).await.map_err(failed)?;
        Ok(format!("Typed {} characters into [{node}].", text.chars().count()))
    }

    pub async fn agent_press(self: &Arc<Self>, key: &str) -> Result<String, BrowserError> {
        let mut cdp = self.agent_page(false).await?;
        cdp.press(key).await.map_err(failed)?;
        Ok(format!("Pressed {key}."))
    }

    pub async fn agent_back(self: &Arc<Self>) -> Result<String, BrowserError> {
        let mut cdp = self.agent_page(false).await?;
        let went_back = cdp.back().await.map_err(failed)?;
        Ok(if went_back {
            "Went back.".to_string()
        } else {
            "No earlier page in this tab.".to_string()
        })
    }

    /// The page as a base64 PNG.
    pub async fn agent_screenshot(self: &Arc<Self>) -> Result<String, BrowserError> {
        let mut cdp = self.agent_page(false).await?;
        cdp.screenshot().await.map_err(failed)
    }

    pub async fn agent_tabs(self: &Arc<Self>) -> Result<String, BrowserError> {
        let (port, current) = self.agent_state().await?;
        let tabs = page_tabs(port).await.map_err(failed)?;
        if tabs.is_empty() {
            return Ok("No tabs.".to_string());
        }
        let lines: Vec<String> = tabs
            .iter()
            .enumerate()
            .map(|(i, tab)| {
                let mark = if current.as_deref() == Some(tab.id.as_str()) {
                    "* "
                } else {
                    ""
                };
                format!("[{i}] {mark}{} <{}>", tab.title, tab.url)
            })
            .collect();
        Ok(lines.join("\n"))
    }

    /// Make tab `index` (as `browser_tabs` lists it) the agent's tab, and bring it to the front.
    pub async fn agent_switch(self: &Arc<Self>, index: usize) -> Result<String, BrowserError> {
        let (port, _) = self.agent_state().await?;
        let tabs = page_tabs(port).await.map_err(failed)?;
        let tab = tabs
            .get(index)
            .ok_or_else(|| BrowserError::Failed(format!("no tab {index}; browser_tabs lists them")))?;
        self.browser_command(port, "Target.activateTarget", json!({ "targetId": tab.id }))
            .await?;
        self.set_target(&tab.id).await;
        Ok(format!("Switched to tab {index}: {}", tab.title))
    }
}

/// The workspace's browser if its process is still alive. A dead one is dropped from the map.
fn live<'a>(running: &'a mut HashMap<String, Running>, workspace: &str) -> Option<&'a mut Running> {
    let alive = running.get_mut(workspace)?.is_alive();
    if alive {
        running.get_mut(workspace)
    } else {
        running.remove(workspace);
        None
    }
}

/// The element a click is about to hit, and the page it is on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClickTarget {
    pub element: Element,
    pub page: String,
}

/// Lets a click through. A risky element asks the user in the agent's feed, with the element's real
/// name; only Allow lets it go ahead. Refusal and no answer within `limit` are [`BrowserError::Declined`].
pub async fn approve_click(
    sup: &Supervisor,
    agent_id: &str,
    target: &ClickTarget,
    limit: Duration,
) -> Result<(), BrowserError> {
    if !needs_approval(&target.element) {
        return Ok(());
    }
    let name = if target.element.name.is_empty() {
        target.element.role.as_str()
    } else {
        target.element.name.as_str()
    };
    let spec = ApprovalSpec {
        tool: "browser_click".to_string(),
        title: format!("Нажать «{name}» на {}", host_of(&target.page)),
        command: Some(target.page.clone()),
        reason: "browser: risky click".to_string(),
        input: json!({
            "role": target.element.role,
            "name": target.element.name,
            "value": target.element.value,
            "page": target.page,
        }),
    };
    match sup.ask_external(agent_id, spec, limit).await {
        Ok(Decision::Allow) => Ok(()),
        Ok(_) => Err(BrowserError::Declined),
        Err(e) => Err(failed(e)),
    }
}

/// The host of a page URL, for the approval title. A `data:` page has no host.
pub fn host_of(url: &str) -> String {
    if url.starts_with("data:") {
        return "data page".to_string();
    }
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    if host.is_empty() {
        url.to_string()
    } else {
        host.to_string()
    }
}

/// True when a click on this element needs the human: its name or value matches a risky word.
pub fn needs_approval(element: &Element) -> bool {
    is_risky_name(&element.name) || is_risky_name(&element.value)
}

/// Words that make a click a payment, send, delete or confirmation, in English and Russian. A
/// substring match, case-insensitive: `order` also matches `border`, which errs on the safe side.
const RISKY_STEMS: [&str; 20] = [
    "pay",
    "buy",
    "purchase",
    "checkout",
    "order",
    "subscribe",
    "send",
    "submit",
    "delete",
    "remove",
    "transfer",
    "confirm",
    "оплат",
    "куп",
    "заказ",
    "подпис",
    "отправ",
    "удал",
    "перев",
    "подтверд",
];

pub fn is_risky_name(text: &str) -> bool {
    let lower = text.to_lowercase();
    RISKY_STEMS.iter().any(|stem| lower.contains(stem))
}

/// The arguments that start Chrome for the agent's browser.
pub fn chrome_args(profile: &Path, port: u16, no_sandbox: bool) -> Vec<String> {
    let mut args = vec![
        format!("--remote-debugging-port={port}"),
        "--remote-debugging-address=127.0.0.1".to_string(),
        format!("--user-data-dir={}", profile.display()),
        "--no-first-run".to_string(),
        "--no-default-browser-check".to_string(),
        "--disable-dev-shm-usage".to_string(),
        "--password-store=basic".to_string(),
        "--window-size=1440,900".to_string(),
        "--headless=new".to_string(),
    ];
    if no_sandbox {
        args.push("--no-sandbox".to_string());
    }
    args
}

/// The first Chrome or Chromium: the macOS app bundle, then the names on `PATH`.
pub fn find_browser(path: &OsStr) -> Option<PathBuf> {
    if cfg!(target_os = "macos") {
        let app = PathBuf::from(MAC_CHROME);
        if app.is_file() {
            return Some(app);
        }
    }
    setup::BROWSERS.iter().find_map(|name| setup::which(name, path))
}

/// Workspace names are used in file paths: letters, digits, `-` and `_`, up to 64.
pub fn check_workspace(workspace: &str) -> Result<(), BrowserError> {
    let valid = !workspace.is_empty()
        && workspace.len() <= 64
        && workspace
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if valid {
        Ok(())
    } else {
        Err(BrowserError::InvalidWorkspace)
    }
}

/// Agents open web pages and `data:` pages only. Local `file:` and browser-internal URLs are refused.
pub fn check_url(url: &str) -> Result<(), BrowserError> {
    let lower = url.to_ascii_lowercase();
    let allowed = lower.starts_with("http://")
        || lower.starts_with("https://")
        || lower.starts_with("data:")
        || lower == "about:blank";
    if allowed {
        Ok(())
    } else {
        Err(BrowserError::UnsupportedUrl)
    }
}

fn ensure_platform() -> Result<(), BrowserError> {
    match std::env::consts::OS {
        "linux" | "macos" => Ok(()),
        _ => Err(BrowserError::Unsupported),
    }
}

fn start_failed(e: impl std::fmt::Display) -> BrowserError {
    BrowserError::StartFailed(e.to_string())
}

fn failed(e: anyhow::Error) -> BrowserError {
    BrowserError::Failed(format!("{e:#}"))
}

/// A free loopback port. Another process could take it before Chrome binds; then the start fails.
fn free_port() -> std::io::Result<u16> {
    Ok(std::net::TcpListener::bind("127.0.0.1:0")?.local_addr()?.port())
}

/// Waits for Chrome's DevTools port and returns the browser socket path (`/devtools/browser/<id>`).
async fn wait_for_devtools(port: u16, child: &mut Child) -> Result<String> {
    let deadline = Instant::now() + STARTUP_LIMIT;
    loop {
        if let Some(status) = child.try_wait()? {
            bail!("the browser exited ({status})");
        }
        if let Ok(version) = get_json(port, "/json/version").await
            && let Some(url) = version["webSocketDebuggerUrl"].as_str()
            && let Some(at) = url.find("/devtools/")
        {
            return Ok(url[at..].to_string());
        }
        if Instant::now() >= deadline {
            bail!("no DevTools answer within {} s", STARTUP_LIMIT.as_secs());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

/// Sends a signal to a process group. Pid 0 would mean our own group, so it is refused.
fn signal_group(pid: u32, signal: i32) {
    let Ok(group) = libc::pid_t::try_from(pid) else {
        return;
    };
    if group <= 0 {
        return;
    }
    // SAFETY: killpg only sends a signal. The group is the one `process_group(0)` made for this
    // browser; if it is gone, the call fails with ESRCH and nothing else happens.
    unsafe {
        libc::killpg(group, signal);
    }
}

fn spawn_idle_check(weak: Weak<BrowserManager>, every: Duration) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(every).await;
            let Some(manager) = weak.upgrade() else {
                return;
            };
            manager.reap_idle().await;
        }
    });
}

#[derive(Debug, Clone, Deserialize)]
struct Tab {
    id: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    url: String,
}

/// The page tabs of the browser, in the order DevTools lists them.
async fn page_tabs(port: u16) -> Result<Vec<Tab>> {
    let list: Vec<Tab> = serde_json::from_value(get_json(port, "/json/list").await?)?;
    Ok(list.into_iter().filter(|t| t.kind == "page").collect())
}

fn page_url(port: u16, target: &str) -> String {
    format!("ws://127.0.0.1:{port}/devtools/page/{target}")
}

/// GET on the browser's loopback DevTools HTTP port.
async fn get_json(port: u16, path: &str) -> Result<Value> {
    let uri: Uri = format!("http://127.0.0.1:{port}{path}").parse()?;
    let request = Request::get(uri).body(Body::empty())?;
    let response = client().request(request).await.context("no answer from the browser")?;
    let bytes = response.into_body().collect().await?.to_bytes();
    Ok(serde_json::from_slice(&bytes)?)
}

/// Stops the Chrome processes an earlier daemon left behind: any process whose command line has
/// this server's profile folder in `--user-data-dir`. Call it once at start, after this daemon owns
/// its socket. Chrome processes that are not ours, such as the user's own, are left alone.
pub fn reap_orphans(home: &Path) {
    let profiles = home.join("workspaces");
    let found = profile_pids(&profiles);
    if found.is_empty() {
        return;
    }
    tracing::info!(
        count = found.len(),
        "stopping browser processes left by an earlier daemon"
    );
    for pid in found {
        signal_orphan(pid, libc::SIGTERM);
    }
    std::thread::sleep(Duration::from_secs(1));
    for pid in profile_pids(&profiles) {
        signal_orphan(pid, libc::SIGKILL);
    }
}

/// Processes whose command line has `--user-data-dir=<profiles>/` as an argument.
fn profile_pids(profiles: &Path) -> Vec<u32> {
    let flag = format!("--user-data-dir={}/", profiles.display());
    if cfg!(target_os = "linux") {
        let Ok(entries) = std::fs::read_dir("/proc") else {
            return Vec::new();
        };
        entries
            .flatten()
            .filter_map(|entry| {
                let pid: u32 = entry.file_name().to_str()?.parse().ok()?;
                let cmdline = std::fs::read(entry.path().join("cmdline")).ok()?;
                cmdline
                    .split(|b| *b == 0)
                    .any(|arg| arg.starts_with(flag.as_bytes()))
                    .then_some(pid)
            })
            .collect()
    } else {
        // `pgrep -f` matches the whole command line, and its pattern is a regular expression.
        let pattern = regex_escape(&flag);
        match std::process::Command::new("pgrep")
            .args(["-f", "--", &pattern])
            .output()
        {
            Ok(out) => String::from_utf8_lossy(&out.stdout)
                .lines()
                .filter_map(|line| line.trim().parse().ok())
                .collect(),
            Err(_) => Vec::new(),
        }
    }
}

fn regex_escape(text: &str) -> String {
    let mut out = String::new();
    for c in text.chars() {
        if "\\.^$|?*+()[]{}".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Sends a signal to the process's group, or to the process itself when it shares this daemon's group.
fn signal_orphan(pid: u32, signal: i32) {
    let Ok(pid) = libc::pid_t::try_from(pid) else {
        return;
    };
    // SAFETY: getpgid, kill and killpg only look up or signal a process; a process that is gone
    // makes them fail with ESRCH, and nothing else happens.
    unsafe {
        let group = libc::getpgid(pid);
        if group > 0 && group != libc::getpgrp() {
            libc::killpg(group, signal);
        } else {
            libc::kill(pid, signal);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{DecidedBy, Event, EventBody};
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::supervisor::Runtimes;
    use std::os::unix::process::CommandExt;
    use tokio::sync::broadcast;

    fn fake_running(child: Child, pid: u32, activity: Instant) -> Running {
        Running {
            child,
            pid,
            port: 9,
            browser_path: "/devtools/browser/x".into(),
            started_at: 0,
            controller: Holder::None,
            target: None,
            last_activity: activity,
        }
    }

    /// A stand-in for Chrome: a sleeping process in its own group.
    fn sleeper() -> (Child, u32) {
        let child = Command::new("sleep")
            .arg("30")
            .process_group(0)
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = child.id().unwrap();
        (child, pid)
    }

    /// A supervisor over an in-memory store with one agent. No runtime is started.
    fn with_agent() -> (Arc<Supervisor>, Arc<Store>, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                name: "Forge".into(),
                role: "builder".into(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/home/u/app".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        (sup, store, agent.id)
    }

    async fn next_event(events: &mut broadcast::Receiver<Event>, pred: impl Fn(&EventBody) -> bool) -> Event {
        loop {
            let e = tokio::time::timeout(Duration::from_secs(3), events.recv())
                .await
                .expect("timed out waiting for an event")
                .unwrap();
            if pred(&e.body) {
                return e;
            }
        }
    }

    fn target(role: &str, name: &str, page: &str) -> ClickTarget {
        ClickTarget {
            element: Element {
                role: role.into(),
                name: name.into(),
                value: String::new(),
            },
            page: page.into(),
        }
    }

    #[tokio::test]
    async fn stopped_browser_reports_not_running_and_control_refuses() {
        let manager = BrowserManager::new(std::env::temp_dir());
        let status = manager.status("nope").await;
        assert!(!status.running);
        assert_eq!(status.controller, None);
        assert!(matches!(
            manager.control("nope", Holder::User).await,
            Err(BrowserError::NotRunning)
        ));
    }

    #[tokio::test]
    async fn control_sets_the_holder_and_status_shows_it() {
        let manager = BrowserManager::with_idle_limit(std::env::temp_dir(), Duration::from_secs(3600));
        let (child, pid) = sleeper();
        manager
            .running
            .lock()
            .await
            .insert("shared".into(), fake_running(child, pid, Instant::now()));
        let status = manager.control("shared", Holder::User).await.unwrap();
        assert!(status.running);
        assert_eq!(status.controller, Some(Holder::User));
        assert_eq!(manager.status("shared").await.controller, Some(Holder::User));
        manager.stop("shared").await;
        assert!(!manager.status("shared").await.running);
    }

    #[tokio::test]
    async fn idle_browser_is_stopped_and_active_one_is_kept() {
        let manager = BrowserManager::with_idle_limit(std::env::temp_dir(), Duration::from_secs(60));
        let (idle_child, idle_pid) = sleeper();
        let (busy_child, busy_pid) = sleeper();
        let long_ago = Instant::now().checked_sub(Duration::from_secs(120)).unwrap();
        {
            let mut running = manager.running.lock().await;
            running.insert("idle".into(), fake_running(idle_child, idle_pid, long_ago));
            running.insert("busy".into(), fake_running(busy_child, busy_pid, Instant::now()));
        }
        manager.reap_idle().await;
        assert!(!manager.status("idle").await.running);
        assert!(manager.status("busy").await.running);
        manager.stop("busy").await;
    }

    #[test]
    fn workspace_names_are_safe_path_parts() {
        assert!(check_workspace("shared").is_ok());
        assert!(check_workspace("my-ws_2").is_ok());
        for bad in ["", "../x", "a/b", "a b", "ы", &"x".repeat(65)] {
            assert!(check_workspace(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn only_web_data_and_blank_urls_are_opened() {
        assert!(check_url("https://example.test/a").is_ok());
        assert!(check_url("HTTP://example.test").is_ok());
        assert!(check_url("data:text/html,<b>x</b>").is_ok());
        assert!(check_url("about:blank").is_ok());
        for bad in [
            "file:///etc/passwd",
            "chrome://settings",
            "javascript:alert(1)",
            "example.test",
        ] {
            assert!(check_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn holder_uses_lowercase_names() {
        assert_eq!(serde_json::to_value(Holder::User).unwrap(), json!("user"));
        assert_eq!(serde_json::from_value::<Holder>(json!("agent")).unwrap(), Holder::Agent);
    }

    #[test]
    fn the_approval_title_names_the_host_not_the_path() {
        assert_eq!(host_of("https://shop.example/cart?x=1"), "shop.example");
        assert_eq!(host_of("http://user@127.0.0.1:3000/a"), "127.0.0.1:3000");
        assert_eq!(host_of("data:text/html,<b>x</b>"), "data page");
    }

    #[tokio::test]
    async fn an_ordinary_click_needs_no_approval() {
        let (sup, store, agent) = with_agent();
        let t = target("link", "Home", "https://shop.example/");
        approve_click(&sup, &agent, &t, Duration::from_millis(50))
            .await
            .unwrap();
        assert!(store.approval_list_pending(None).unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_risky_click_asks_the_user_with_the_real_name_and_goes_ahead_on_allow() {
        let (sup, store, agent) = with_agent();
        let mut events = sup.hub().subscribe();
        let t = target("button", "Оплатить", "https://shop.example/cart");
        let (s, a) = (sup.clone(), agent.clone());
        let asked = tokio::spawn(async move { approve_click(&s, &a, &t, Duration::from_secs(5)).await });

        let e = next_event(&mut events, |b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        assert_eq!(e.agent_id, agent);
        let EventBody::ApprovalRequested {
            approval_id,
            title,
            tool,
            command,
            ..
        } = e.body
        else {
            unreachable!()
        };
        assert_eq!(title, "Нажать «Оплатить» на shop.example");
        assert_eq!(tool, "browser_click");
        assert_eq!(command.as_deref(), Some("https://shop.example/cart"));

        sup.resolve(&approval_id, Decision::Allow, false).await.unwrap();
        asked.await.unwrap().expect("allowed click may go ahead");
        assert!(store.approval_list_pending(None).unwrap().is_empty());
    }

    #[tokio::test]
    async fn a_refused_risky_click_is_declined() {
        let (sup, _store, agent) = with_agent();
        let mut events = sup.hub().subscribe();
        let t = target("button", "Удалить", "https://shop.example/");
        let (s, a) = (sup.clone(), agent.clone());
        let asked = tokio::spawn(async move { approve_click(&s, &a, &t, Duration::from_secs(5)).await });
        let e = next_event(&mut events, |b| matches!(b, EventBody::ApprovalRequested { .. })).await;
        let EventBody::ApprovalRequested { approval_id, .. } = e.body else {
            unreachable!()
        };
        sup.resolve(&approval_id, Decision::Deny, false).await.unwrap();
        assert!(matches!(asked.await.unwrap(), Err(BrowserError::Declined)));
    }

    #[tokio::test]
    async fn a_risky_click_nobody_answers_is_declined_at_the_limit() {
        let (sup, store, agent) = with_agent();
        let mut events = sup.hub().subscribe();
        let t = target("button", "Отправить", "https://shop.example/");
        let result = approve_click(&sup, &agent, &t, Duration::from_millis(100)).await;
        assert!(matches!(result, Err(BrowserError::Declined)), "{result:?}");
        assert!(store.approval_list_pending(None).unwrap().is_empty());
        let e = next_event(&mut events, |b| matches!(b, EventBody::ApprovalResolved { .. })).await;
        let EventBody::ApprovalResolved { decision, by, .. } = e.body else {
            unreachable!()
        };
        assert_eq!(decision, Decision::Deny);
        assert_eq!(by, DecidedBy::Policy);
    }

    #[tokio::test]
    async fn reap_orphans_stops_only_chrome_of_this_profile_folder() {
        let home = tempfile::tempdir().unwrap();
        let profile = home.path().join("workspaces").join("shared").join("browser");
        // An orphan: its command line carries our profile folder, and it leads its own group. The
        // trailing `; true` keeps the shell from exec-ing `sleep`, which would replace its arguments.
        let mut orphan = std::process::Command::new("sh")
            .arg("-c")
            .arg("sleep 30; true")
            .arg(format!("--user-data-dir={}", profile.display()))
            .process_group(0)
            .spawn()
            .unwrap();
        // Someone else's process, in its own group, without our profile.
        let mut other = std::process::Command::new("sleep")
            .arg("30")
            .process_group(0)
            .spawn()
            .unwrap();

        reap_orphans(home.path());

        assert!(!orphan.wait().unwrap().success(), "the orphan should have been stopped");
        assert!(other.try_wait().unwrap().is_none(), "an unrelated process was stopped");
        other.kill().unwrap();
        let _ = other.wait();
    }

    /// Real Chrome, and the approval flow end to end. An ordinary button needs no question. A
    /// risky button waits for the user: refused, it does nothing; allowed, it runs.
    /// Run with: `BANDITO_BROWSER_IT=1 cargo test -q -- --ignored browser_it` (as root in Docker, also
    /// `BANDITO_BROWSER_NO_SANDBOX=1`).
    #[tokio::test]
    #[ignore = "starts a real Chrome; BANDITO_BROWSER_IT=1 cargo test -- --ignored browser_it"]
    async fn browser_it_risky_clicks_wait_for_the_user() {
        if std::env::var("BANDITO_BROWSER_IT").as_deref() != Ok("1") {
            return;
        }
        let home = tempfile::tempdir().unwrap();
        let (sup, store, agent) = with_agent();
        let manager = BrowserManager::new(home.path().to_path_buf());
        manager.start(DEFAULT_WORKSPACE).await.expect("start");
        let page = "data:text/html;charset=utf-8,\
            <button onclick=\"document.title='paid'\">Оплатить</button>\
            <button onclick=\"document.title='removed'\">Удалить</button>\
            <button onclick=\"document.title='next'\">Далее</button>";
        manager.agent_open(page, false).await.expect("open");
        let snapshot = manager.agent_snapshot().await.expect("snapshot");
        let node = |name: &str| -> i64 {
            let needle = format!("button \"{name}\"");
            let line = snapshot
                .lines()
                .find(|l| l.contains(&needle))
                .unwrap_or_else(|| panic!("no {name} in:\n{snapshot}"));
            line.trim_start_matches('[').split(']').next().unwrap().parse().unwrap()
        };
        let title = |text: &str| text.lines().next().unwrap_or_default().to_string();

        // An ordinary click: no question.
        manager
            .agent_click(&sup, &agent, node("Далее"), Duration::from_secs(5))
            .await
            .expect("ordinary click");
        assert!(store.approval_list_pending(None).unwrap().is_empty());
        let now = manager.agent_snapshot().await.unwrap();
        assert_eq!(title(&now), "Title: next");

        // A risky click the user refuses: the page does not change.
        let (s, st) = (sup.clone(), store.clone());
        let refuse = tokio::spawn(async move {
            loop {
                if let Some(a) = st.approval_list_pending(None).unwrap().first() {
                    s.resolve(&a.id, Decision::Deny, false).await.unwrap();
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        });
        let refused = manager
            .agent_click(&sup, &agent, node("Удалить"), Duration::from_secs(10))
            .await;
        refuse.await.unwrap();
        assert!(matches!(refused, Err(BrowserError::Declined)), "{refused:?}");
        let now = manager.agent_snapshot().await.unwrap();
        assert_eq!(title(&now), "Title: next");

        // A risky click the user allows: the page changes.
        let (s, st) = (sup.clone(), store.clone());
        let allow = tokio::spawn(async move {
            loop {
                if let Some(a) = st.approval_list_pending(None).unwrap().first() {
                    s.resolve(&a.id, Decision::Allow, false).await.unwrap();
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        });
        manager
            .agent_click(&sup, &agent, node("Оплатить"), Duration::from_secs(10))
            .await
            .expect("allowed click");
        allow.await.unwrap();
        let now = manager.agent_snapshot().await.unwrap();
        assert_eq!(title(&now), "Title: paid");

        manager.stop(DEFAULT_WORKSPACE).await;
    }
}
