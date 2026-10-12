//! Phone access: a TLS listener for the iPhone app, next to the loopback one (docs/ARCHITECTURE.md#phone-access).
//!
//! Off by default. The owner turns it on with the server setting `phone_access`:
//! - `tailscale`: listens only on this machine's Tailscale addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`), found
//!   in the interface list (no call to the `tailscale` command);
//! - `lan`: listens on every address (`0.0.0.0` and `::`).
//!
//! Only TLS 1.3 is spoken there, with a self-signed certificate made at the first switch-on and kept in
//! `<home>/tls/` (0600). The app pins the certificate's SHA-256 fingerprint, which comes in the pairing link. The
//! routes are the ones of the loopback listener (a device token for everything but `daemon.hello` and
//! `pair.redeem`), plus a limit on anonymous upgrades per address. Agents never come this way: they speak on
//! `agent.sock`, and a token of theirs is no device token.

use crate::rpc::{App, ws};
use crate::server_settings::{DEFAULT_PHONE_PORT, PhoneMode};
use anyhow::{Context, Result, anyhow};
use hyper_util::rt::{TokioExecutor, TokioIo, TokioTimer};
use hyper_util::server::conn::auto;
use hyper_util::service::TowerToHyperService;
use rustls::pki_types::pem::PemObject;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, VecDeque};
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::task::{JoinHandle, JoinSet};
use tokio_rustls::TlsAcceptor;
use tokio_util::sync::CancellationToken;

/// Anonymous WebSocket upgrades one address may make in the window, on the phone listener.
pub const ATTEMPT_MAX: usize = 10;
/// The window of that limit, in ms.
pub const ATTEMPT_WINDOW_MS: i64 = 10 * 60 * 1000;
/// Distinct addresses the limit remembers. A full table refuses new addresses (it takes thousands of them).
const MAX_SOURCES: usize = 4096;
/// Open connections one phone listener keeps. More are closed at once.
const MAX_CONNECTIONS: usize = 256;
/// A TLS handshake that takes longer is dropped.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Time a client has to send a request's headers (also between two requests of one connection).
const HEADER_TIMEOUT: Duration = Duration::from_secs(20);
/// How often the listeners are matched to the machine's addresses (Tailscale may come up after the daemon).
const WATCH_INTERVAL: Duration = Duration::from_secs(30);
/// Hosts in a pairing link.
const MAX_HOSTS: usize = 6;
/// Characters of the server name in a pairing link.
const MAX_NAME_CHARS: usize = 64;
/// The version of the pairing link (`v=`). An app that does not know it asks for an update.
pub const LINK_VERSION: u32 = 1;

/// Where the machine's addresses come from. Replaced in tests.
pub type Ifaces = Arc<dyn Fn() -> Vec<IpAddr> + Send + Sync>;
/// Which addresses a mode listens on. Replaced in tests, to listen on loopback with a port the system picks.
type Planner = Arc<dyn Fn(PhoneMode, u16) -> Vec<SocketAddr> + Send + Sync>;

/// Whether `ip` is a Tailscale address: `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
pub fn is_tailscale(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.octets()[0] == 100 && v4.octets()[1] & 0xC0 == 64,
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

/// Whether `ip` is a private address of a local network (not Tailscale, not link-local, not loopback).
fn is_lan(ip: IpAddr) -> bool {
    if is_tailscale(ip) {
        return false;
    }
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.is_private(),
        IpAddr::V6(v6) => v6.segments()[0] & 0xfe00 == 0xfc00,
    }
}

/// The addresses of the interfaces that are up, loopback left out. Empty when the list cannot be read.
pub fn interface_addrs() -> Vec<IpAddr> {
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: `getifaddrs` fills `head` with a list that `freeifaddrs` releases; the list is only read in between.
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return out;
    }
    let mut cur = head;
    while !cur.is_null() {
        // SAFETY: `cur` is a node of the list returned above, which is alive until `freeifaddrs`.
        let node = unsafe { &*cur };
        cur = node.ifa_next;
        if node.ifa_flags & (libc::IFF_UP as u32) == 0 || node.ifa_addr.is_null() {
            continue;
        }
        // SAFETY: `ifa_addr` is not null; the family says which sockaddr type it really is.
        let ip = unsafe {
            match i32::from((*node.ifa_addr).sa_family) {
                libc::AF_INET => {
                    let sin = &*(node.ifa_addr as *const libc::sockaddr_in);
                    Some(IpAddr::V4(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr))))
                }
                libc::AF_INET6 => {
                    let sin6 = &*(node.ifa_addr as *const libc::sockaddr_in6);
                    Some(IpAddr::V6(Ipv6Addr::from(sin6.sin6_addr.s6_addr)))
                }
                _ => None,
            }
        };
        if let Some(ip) = ip
            && !ip.is_loopback()
            && !ip.is_unspecified()
            && !out.contains(&ip)
        {
            out.push(ip);
        }
    }
    // SAFETY: `head` came from `getifaddrs` and nothing points into the list any more.
    unsafe { libc::freeifaddrs(head) };
    out
}

/// The addresses the daemon listens on for `mode` and `port`, given the machine's `ifaces`.
pub fn plan(mode: PhoneMode, port: u16, ifaces: &[IpAddr]) -> Vec<SocketAddr> {
    match mode {
        PhoneMode::Off => Vec::new(),
        PhoneMode::Tailscale => {
            let mut ips: Vec<IpAddr> = ifaces.iter().copied().filter(|ip| is_tailscale(*ip)).collect();
            ips.sort();
            ips.dedup();
            ips.into_iter().map(|ip| SocketAddr::new(ip, port)).collect()
        }
        PhoneMode::Lan => vec![
            SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port),
            SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), port),
        ],
    }
}

/// The `host:port` strings a phone can try for this machine, the best first: Tailscale, then the local network
/// (not in `tailscale` mode). IPv6 is in square brackets.
pub fn pair_hosts(mode: PhoneMode, port: u16, ifaces: &[IpAddr]) -> Vec<String> {
    let mut hosts: Vec<IpAddr> = Vec::new();
    let mut push = |filter: &dyn Fn(IpAddr) -> bool| {
        let mut found: Vec<IpAddr> = ifaces.iter().copied().filter(|ip| filter(*ip)).collect();
        // IPv4 first: it is the one every phone network has.
        found.sort_by_key(|ip| (ip.is_ipv6(), *ip));
        hosts.extend(found);
    };
    match mode {
        PhoneMode::Off => return Vec::new(),
        PhoneMode::Tailscale => push(&is_tailscale),
        PhoneMode::Lan => {
            push(&is_tailscale);
            push(&is_lan);
        }
    }
    hosts.dedup();
    hosts
        .into_iter()
        .take(MAX_HOSTS)
        .map(|ip| match ip {
            IpAddr::V4(v4) => format!("{v4}:{port}"),
            IpAddr::V6(v6) => format!("[{v6}]:{port}"),
        })
        .collect()
}

/// The pairing link: `bandito://pair?v=1&code=…&fp=…&name=…&host=…&host=…`. `host` repeats, best first.
/// Values are percent-encoded; `fp` is 64 lower-case hex digits.
pub fn pair_link(code: &str, fingerprint: &str, name: &str, hosts: &[String]) -> String {
    let name: String = name.chars().take(MAX_NAME_CHARS).collect();
    let mut link = format!(
        "bandito://pair?v={LINK_VERSION}&code={}&fp={fingerprint}&name={}",
        percent_encode(code),
        percent_encode(&name)
    );
    for host in hosts {
        link.push_str("&host=");
        link.push_str(&percent_encode(host));
    }
    link
}

/// Percent-encodes every byte but the unreserved ones and `:` (so `host:port` stays readable).
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b':' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Anonymous upgrades by address and time: at most [`ATTEMPT_MAX`] in [`ATTEMPT_WINDOW_MS`] from one address.
#[derive(Default)]
pub struct AttemptLimiter {
    by_source: Mutex<HashMap<String, VecDeque<i64>>>,
}

impl AttemptLimiter {
    /// Counts an attempt of `source` at `now` (unix ms). False when it is over the limit (and then not counted).
    pub fn attempt(&self, source: &str, now: i64) -> bool {
        let mut map = self.by_source.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, times| {
            while times.front().is_some_and(|t| *t <= now - ATTEMPT_WINDOW_MS) {
                times.pop_front();
            }
            !times.is_empty()
        });
        if !map.contains_key(source) && map.len() >= MAX_SOURCES {
            return false;
        }
        let times = map.entry(source.to_string()).or_default();
        if times.len() >= ATTEMPT_MAX {
            return false;
        }
        times.push_back(now);
        true
    }
}

/// What the phone listener is doing now, for the settings reply and `daemon.info`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Status {
    pub mode: PhoneMode,
    pub port: u16,
    /// The addresses bound now, as `ip:port`.
    pub listening: Vec<String>,
    /// Why the listener is not (fully) up, in one short sentence; None when all is well.
    pub error: Option<String>,
}

impl Status {
    fn off() -> Self {
        Self {
            mode: PhoneMode::Off,
            port: DEFAULT_PHONE_PORT,
            listening: Vec::new(),
            error: None,
        }
    }

    pub fn to_json(&self, fingerprint: Option<&str>) -> Value {
        json!({
            "mode": self.mode.as_str(),
            "port": self.port,
            "listening": self.listening,
            "error": self.error,
            "tls_fingerprint": fingerprint,
        })
    }
}

/// What `pair.create` adds for a phone. `link` is None when the phone listener is not up.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairInfo {
    pub link: Option<String>,
    pub hosts: Vec<String>,
    pub fingerprint: Option<String>,
}

/// Where the addresses come from, and (in tests) where to listen instead.
#[derive(Clone)]
struct Sources {
    ifaces: Ifaces,
    planner: Option<Planner>,
}

struct Tls {
    config: Arc<rustls::ServerConfig>,
    fingerprint: String,
}

struct Listener {
    cancel: CancellationToken,
    task: JoinHandle<()>,
    bound: SocketAddr,
}

struct Running {
    mode: PhoneMode,
    port: u16,
    listeners: HashMap<SocketAddr, Listener>,
    last_error: Option<String>,
}

/// The phone listener of one daemon.
pub struct PhoneAccess {
    home: PathBuf,
    /// The daemon this belongs to (the routers of the listeners serve it).
    app: Weak<App>,
    sources: Mutex<Sources>,
    /// Serializes `apply`: one change at a time.
    running: tokio::sync::Mutex<Running>,
    status: Mutex<Status>,
    tls: Mutex<Option<Arc<Tls>>>,
    limiter: Arc<AttemptLimiter>,
}

impl PhoneAccess {
    /// Phone access of the daemon whose data folder is `home`. Nothing is made or opened until it is switched on.
    pub fn new(home: PathBuf, app: Weak<App>) -> Self {
        Self {
            home,
            app,
            sources: Mutex::new(Sources {
                ifaces: Arc::new(interface_addrs),
                planner: None,
            }),
            running: tokio::sync::Mutex::new(Running {
                mode: PhoneMode::Off,
                port: DEFAULT_PHONE_PORT,
                listeners: HashMap::new(),
                last_error: None,
            }),
            status: Mutex::new(Status::off()),
            tls: Mutex::new(None),
            limiter: Arc::new(AttemptLimiter::default()),
        }
    }

    /// Replaces the interface list, and the addresses to listen on (tests: loopback, any port).
    #[cfg(test)]
    pub fn set_sources(&self, ifaces: Ifaces, planner: Option<Planner>) {
        *self.sources.lock().unwrap_or_else(|e| e.into_inner()) = Sources { ifaces, planner };
    }

    fn sources(&self) -> Sources {
        self.sources.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn status(&self) -> Status {
        self.status.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The certificate's fingerprint, once there is a certificate (made at the first switch-on).
    pub fn fingerprint(&self) -> Option<String> {
        if let Some(tls) = self.tls.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            return Some(tls.fingerprint.clone());
        }
        let (cert, _) = tls_files(&self.home);
        let der = read_cert(&cert).ok()?;
        Some(fingerprint_of(&der))
    }

    /// The status with the fingerprint, as `server.settings_*` shows it.
    pub fn status_json(&self) -> Value {
        self.status().to_json(self.fingerprint().as_deref())
    }

    /// The anonymous-upgrade limit shared by every phone listener.
    pub fn limiter(&self) -> Arc<AttemptLimiter> {
        self.limiter.clone()
    }

    /// The link and hosts for a pairing `code`, from what is listening now.
    pub fn pair_info(&self, code: &str, server_name: &str) -> PairInfo {
        let status = self.status();
        let fingerprint = self.fingerprint();
        let hosts = if status.listening.is_empty() {
            Vec::new()
        } else {
            pair_hosts(status.mode, status.port, &(self.sources().ifaces)())
        };
        let link = match (&fingerprint, hosts.is_empty()) {
            (Some(fp), false) => Some(pair_link(code, fp, server_name, &hosts)),
            _ => None,
        };
        PairInfo {
            link,
            hosts,
            fingerprint,
        }
    }

    /// Matches the listeners to the stored settings and the machine's addresses: closes what is no longer wanted,
    /// opens what is missing. Safe to call at any time and again.
    pub async fn apply(&self) -> Status {
        let Some(app) = self.app.upgrade() else {
            return self.status();
        };
        let settings = app.sup.hub().store.server_settings_or_default();
        self.apply_with(&app, settings.phone_access, settings.phone_port).await
    }

    async fn apply_with(&self, app: &Arc<App>, mode: PhoneMode, port: u16) -> Status {
        let mut state = self.running.lock().await;
        let sources = self.sources();
        let wanted: Vec<SocketAddr> = match (&sources.planner, mode) {
            (_, PhoneMode::Off) => Vec::new(),
            (Some(planner), _) => planner(mode, port),
            (None, _) => plan(mode, port, &(sources.ifaces)()),
        };
        // Close what is not wanted any more. The mode or the port changing drops the listeners of the old one.
        let stale: Vec<SocketAddr> = state
            .listeners
            .keys()
            .filter(|a| !wanted.contains(a))
            .copied()
            .collect();
        for addr in stale {
            if let Some(listener) = state.listeners.remove(&addr) {
                listener.cancel.cancel();
                let _ = listener.task.await;
                tracing::info!(%addr, "phone access: closed the listener");
            }
        }
        state.mode = mode;
        state.port = port;
        let mut error = None;
        if mode != PhoneMode::Off {
            match self.ensure_tls(&app.hostname).await {
                Ok(tls) => {
                    error = self.open_missing(&mut state, app, &tls, &wanted).await;
                    if wanted.is_empty() {
                        error = Some("No Tailscale address on this machine. Install Tailscale and sign in.".into());
                    }
                }
                Err(e) => error = Some(format!("{e:#}")),
            }
        }
        if error != state.last_error {
            match &error {
                Some(e) => tracing::warn!("phone access: {e}"),
                None if mode != PhoneMode::Off => tracing::info!("phone access: listening"),
                None => {}
            }
            state.last_error.clone_from(&error);
        }
        let mut listening: Vec<String> = state.listeners.values().map(|l| l.bound.to_string()).collect();
        listening.sort();
        let status = Status {
            mode,
            port,
            listening,
            error,
        };
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = status.clone();
        status
    }

    /// Binds the wanted addresses that have no listener yet. Returns why something is missing, if it is.
    async fn open_missing(
        &self,
        state: &mut Running,
        app: &Arc<App>,
        tls: &Arc<Tls>,
        wanted: &[SocketAddr],
    ) -> Option<String> {
        let mut specific_error = None;
        let mut wildcard_error = None;
        for addr in wanted {
            if state.listeners.contains_key(addr) {
                continue;
            }
            match TcpListener::bind(addr).await {
                Ok(tcp) => {
                    let bound = tcp.local_addr().unwrap_or(*addr);
                    let router = ws::router_phone(app.clone(), bound.ip(), self.limiter.clone());
                    let cancel = CancellationToken::new();
                    let acceptor = TlsAcceptor::from(tls.config.clone());
                    let task = tokio::spawn(accept_loop(tcp, acceptor, router, cancel.clone()));
                    tracing::info!(%bound, "phone access: listening (TLS)");
                    state.listeners.insert(*addr, Listener { cancel, task, bound });
                }
                // One of `::` and `0.0.0.0` may already cover the other (a dual-stack socket), and a machine may
                // have no IPv6: that is no failure while the other one listens.
                Err(e) if addr.ip().is_unspecified() => {
                    wildcard_error.get_or_insert(format!("Could not listen on {addr}: {e}."));
                }
                Err(e) => {
                    specific_error.get_or_insert(format!("Could not listen on {addr}: {e}."));
                }
            }
        }
        specific_error.or(if state.listeners.is_empty() {
            wildcard_error
        } else {
            None
        })
    }

    /// The certificate and key, made at the first call and loaded afterwards. Blocking work runs off the runtime.
    async fn ensure_tls(&self, hostname: &str) -> Result<Arc<Tls>> {
        if let Some(tls) = self.tls.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            return Ok(tls.clone());
        }
        let home = self.home.clone();
        let hostname = hostname.to_string();
        let ips = (self.sources().ifaces)();
        let tls = tokio::task::spawn_blocking(move || load_or_create(&home, &hostname, &ips))
            .await
            .map_err(|e| anyhow!("certificate task failed: {e}"))??;
        let tls = Arc::new(tls);
        *self.tls.lock().unwrap_or_else(|e| e.into_inner()) = Some(tls.clone());
        Ok(tls)
    }

    /// Applies the settings now and then keeps the listeners matched to the machine's addresses.
    pub fn spawn_watcher(self: &Arc<Self>) {
        let phone = self.clone();
        tokio::spawn(async move {
            loop {
                phone.apply().await;
                tokio::time::sleep(WATCH_INTERVAL).await;
            }
        });
    }

    /// Closes every listener and its connections (the daemon is stopping, or a test is over).
    pub async fn shutdown(&self) {
        let mut state = self.running.lock().await;
        for (_, listener) in state.listeners.drain() {
            listener.cancel.cancel();
            let _ = listener.task.await;
        }
        state.mode = PhoneMode::Off;
        *self.status.lock().unwrap_or_else(|e| e.into_inner()) = Status::off();
    }
}

/// Accepts connections until `cancel`, then drops the listener and every open connection.
async fn accept_loop(tcp: TcpListener, acceptor: TlsAcceptor, router: axum::Router, cancel: CancellationToken) {
    let mut connections: JoinSet<()> = JoinSet::new();
    loop {
        let accepted = tokio::select! {
            () = cancel.cancelled() => break,
            accepted = tcp.accept() => accepted,
        };
        while connections.try_join_next().is_some() {}
        let (stream, peer) = match accepted {
            Ok(pair) => pair,
            Err(e) => {
                // Out of descriptors, or a connection reset before it was accepted: go on after a pause.
                tracing::warn!("phone access: accept failed: {e}");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        if connections.len() >= MAX_CONNECTIONS {
            drop(stream);
            continue;
        }
        let peer = SocketAddr::new(peer.ip().to_canonical(), peer.port());
        let acceptor = acceptor.clone();
        let router = router.clone().layer(axum::Extension(axum::extract::ConnectInfo(peer)));
        let cancel = cancel.clone();
        connections.spawn(async move {
            let tls = match tokio::time::timeout(HANDSHAKE_TIMEOUT, acceptor.accept(stream)).await {
                Ok(Ok(tls)) => tls,
                // A scanner, a client that does not trust or speak TLS 1.3, a stalled handshake: nothing to log loudly.
                Ok(Err(e)) => {
                    tracing::debug!(%peer, "phone access: handshake failed: {e}");
                    return;
                }
                Err(_) => return,
            };
            let mut builder = auto::Builder::new(TokioExecutor::new()).http1_only();
            builder
                .http1()
                .timer(TokioTimer::new())
                .header_read_timeout(HEADER_TIMEOUT);
            let served = builder.serve_connection_with_upgrades(
                TokioIo::new(Guarded::new(tls, cancel)),
                TowerToHyperService::new(router),
            );
            if let Err(e) = served.await {
                tracing::debug!(%peer, "phone access: connection ended: {e}");
            }
        });
    }
    // The connections end with the listener (their tasks are aborted and waited for).
    connections.shutdown().await;
}

/// A connection that fails its reads and writes once `cancel` is cancelled. An upgraded socket (the RPC stream, a
/// tunnel, the browser's DevTools) is served by a task of its own that ending the connection's task would not stop;
/// this makes switching phone access off end those too.
struct Guarded<S> {
    inner: S,
    read_cancelled: std::pin::Pin<Box<tokio_util::sync::WaitForCancellationFutureOwned>>,
    write_cancelled: std::pin::Pin<Box<tokio_util::sync::WaitForCancellationFutureOwned>>,
}

impl<S> Guarded<S> {
    fn new(inner: S, cancel: CancellationToken) -> Self {
        Self {
            inner,
            read_cancelled: Box::pin(cancel.clone().cancelled_owned()),
            write_cancelled: Box::pin(cancel.cancelled_owned()),
        }
    }
}

fn aborted() -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::ConnectionAborted, "phone access was switched off")
}

impl<S: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for Guarded<S> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        if self.read_cancelled.as_mut().poll(cx).is_ready() {
            return std::task::Poll::Ready(Err(aborted()));
        }
        std::pin::Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl<S: tokio::io::AsyncWrite + Unpin> tokio::io::AsyncWrite for Guarded<S> {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        if self.write_cancelled.as_mut().poll(cx).is_ready() {
            return std::task::Poll::Ready(Err(aborted()));
        }
        std::pin::Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

// ---- the certificate ----

/// `<home>/tls` and the two files in it: the certificate and the key.
fn tls_files(home: &Path) -> (PathBuf, PathBuf) {
    let dir = home.join("tls");
    (dir.join("phone-cert.pem"), dir.join("phone-key.pem"))
}

/// SHA-256 of the certificate (DER), 64 lower-case hex digits.
pub fn fingerprint_of(der: &CertificateDer<'_>) -> String {
    hex::encode(Sha256::digest(der.as_ref()))
}

fn read_cert(path: &Path) -> Result<CertificateDer<'static>> {
    let bytes = std::fs::read(path).with_context(|| format!("read {}", path.display()))?;
    CertificateDer::pem_slice_iter(&bytes)
        .next()
        .ok_or_else(|| anyhow!("{} holds no certificate", path.display()))?
        .map_err(|e| anyhow!("{} is not a certificate: {e}", path.display()))
}

fn load_or_create(home: &Path, hostname: &str, ips: &[IpAddr]) -> Result<Tls> {
    let (cert_path, key_path) = tls_files(home);
    let dir = cert_path.parent().map(Path::to_path_buf).unwrap_or_default();
    if cert_path.exists() && key_path.exists() {
        return load(&cert_path, &key_path);
    }
    // One of the two is missing: an earlier switch-on was cut off before it finished, so no fingerprint was
    // ever given out. A new pair is safe to make.
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    set_mode(&dir, 0o700)?;
    let (cert_pem, key_pem) = generate(hostname, ips)?;
    // The key first: a certificate without its key is never left behind.
    write_private(&key_path, key_pem.as_bytes())?;
    write_private(&cert_path, cert_pem.as_bytes())?;
    tracing::info!(dir = %dir.display(), "phone access: made a self-signed certificate");
    load(&cert_path, &key_path)
}

fn generate(hostname: &str, ips: &[IpAddr]) -> Result<(String, String)> {
    let mut names = vec!["localhost".to_string()];
    let host = hostname.trim();
    if !host.is_empty() && host.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.') {
        names.push(host.to_string());
    }
    names.extend(ips.iter().map(ToString::to_string));
    let mut params = rcgen::CertificateParams::new(names).context("certificate names")?;
    let mut name = rcgen::DistinguishedName::new();
    name.push(rcgen::DnType::CommonName, "Bandito");
    params.distinguished_name = name;
    params.not_before = rcgen::date_time_ymd(2024, 1, 1);
    params.not_after = rcgen::date_time_ymd(2074, 1, 1);
    let key = rcgen::KeyPair::generate().context("generate the key")?;
    let cert = params.self_signed(&key).context("sign the certificate")?;
    Ok((cert.pem(), key.serialize_pem()))
}

fn load(cert_path: &Path, key_path: &Path) -> Result<Tls> {
    let fix = "Delete the folder to make a new certificate; phones then have to pair again";
    let cert = read_cert(cert_path).with_context(|| fix.to_string())?;
    // The key was written 0600; a loosened mode is tightened, not trusted.
    if let Ok(meta) = std::fs::metadata(key_path) {
        use std::os::unix::fs::PermissionsExt;
        if meta.permissions().mode() & 0o077 != 0 {
            tracing::warn!(path = %key_path.display(), "phone access: the key file was readable by others: fixed");
            set_mode(key_path, 0o600)?;
        }
    }
    let key_bytes = std::fs::read(key_path).with_context(|| format!("read {}", key_path.display()))?;
    let key = PrivateKeyDer::from_pem_slice(&key_bytes)
        .map_err(|e| anyhow!("{} is not a private key: {e}. {fix}", key_path.display()))?;
    let fingerprint = fingerprint_of(&cert);
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .context("TLS versions")?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .map_err(|e| anyhow!("the certificate and key do not fit: {e}. {fix}"))?;
    config.alpn_protocols = vec![b"http/1.1".to_vec()];
    Ok(Tls {
        config: Arc::new(config),
        fingerprint,
    })
}

fn set_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode))
        .with_context(|| format!("set the mode of {}", path.display()))
}

/// Writes `bytes` to `path` as a file only the owner reads, through a temporary file and a rename.
fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let tmp = path.with_extension(format!("tmp-{}", hex::encode(rand::random::<[u8; 6]>())));
    let result = (|| -> Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&tmp)
            .with_context(|| format!("create {}", tmp.display()))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path).with_context(|| format!("write {}", path.display()))
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::FileService;
    use crate::hub::Hub;
    use crate::rpc::{self, Peer};
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use futures_util::{SinkExt, StreamExt};
    use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
    use rustls::pki_types::{ServerName, UnixTime};
    use rustls::{DigitallySignedStruct, SignatureScheme};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;
    use tokio_tungstenite::tungstenite::Message;
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;

    const TOKEN: &str = "bdt_phone_test_token";

    /// Accepts the one certificate whose fingerprint is `fp`, as the phone app does.
    #[derive(Debug)]
    struct Pin {
        fp: String,
        provider: Arc<rustls::crypto::CryptoProvider>,
    }

    impl ServerCertVerifier for Pin {
        fn verify_server_cert(
            &self,
            end_entity: &CertificateDer<'_>,
            _: &[CertificateDer<'_>],
            _: &ServerName<'_>,
            _: &[u8],
            _: UnixTime,
        ) -> Result<ServerCertVerified, rustls::Error> {
            if fingerprint_of(end_entity) == self.fp {
                Ok(ServerCertVerified::assertion())
            } else {
                Err(rustls::Error::General("fingerprint differs".into()))
            }
        }
        fn verify_tls12_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
        }
        fn verify_tls13_signature(
            &self,
            message: &[u8],
            cert: &CertificateDer<'_>,
            dss: &DigitallySignedStruct,
        ) -> Result<HandshakeSignatureValid, rustls::Error> {
            rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
        }
        fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
            self.provider.signature_verification_algorithms.supported_schemes()
        }
    }

    async fn tls_connect(addr: SocketAddr, fp: &str) -> std::io::Result<tokio_rustls::client::TlsStream<TcpStream>> {
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let config = rustls::ClientConfig::builder_with_provider(provider.clone())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(Pin {
                fp: fp.to_string(),
                provider,
            }))
            .with_no_client_auth();
        let tcp = TcpStream::connect(addr).await?;
        tokio_rustls::TlsConnector::from(Arc::new(config))
            .connect(ServerName::try_from("localhost").unwrap(), tcp)
            .await
    }

    /// One HTTPS request on a connection of its own: the status and the body.
    async fn https(addr: SocketAddr, fp: &str, path: &str, headers: &[(&str, &str)]) -> (u16, String) {
        let mut tls = tls_connect(addr, fp).await.expect("TLS handshake");
        let mut req = format!("GET {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n");
        for (k, v) in headers {
            req.push_str(&format!("{k}: {v}\r\n"));
        }
        req.push_str("\r\n");
        tls.write_all(req.as_bytes()).await.unwrap();
        let mut out = Vec::new();
        let _ = tls.read_to_end(&mut out).await;
        let text = String::from_utf8_lossy(&out).to_string();
        let status = text.split_whitespace().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
        (status, text)
    }

    type Ws = tokio_tungstenite::WebSocketStream<tokio_rustls::client::TlsStream<TcpStream>>;

    async fn ws(
        addr: SocketAddr,
        fp: &str,
        headers: &[(&str, &str)],
    ) -> Result<Ws, tokio_tungstenite::tungstenite::Error> {
        let tls = tls_connect(addr, fp).await.expect("TLS handshake");
        let mut req = format!("ws://localhost:{}/v1/rpc", addr.port())
            .into_client_request()
            .unwrap();
        for (k, v) in headers {
            req.headers_mut().insert(
                tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(k.as_bytes()).unwrap(),
                tokio_tungstenite::tungstenite::http::HeaderValue::from_str(v).unwrap(),
            );
        }
        tokio_tungstenite::client_async(req, tls).await.map(|(s, _)| s)
    }

    async fn rpc_call(ws: &mut Ws, method: &str) -> Value {
        ws.send(Message::Text(
            json!({"jsonrpc":"2.0","id":1,"method":method,"params":{}})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
        loop {
            match ws.next().await.expect("an answer").unwrap() {
                Message::Text(t) => return serde_json::from_str(&t).unwrap(),
                _ => continue,
            }
        }
    }

    struct World {
        app: Arc<App>,
        home: tempfile::TempDir,
    }

    /// A daemon over a temp data folder, with one paired device (`TOKEN`) and a phone listener that, when switched
    /// on, listens on loopback with a port the system picks.
    fn world() -> World {
        let home = tempfile::TempDir::new().unwrap();
        world_in(home)
    }

    fn world_in(home: tempfile::TempDir) -> World {
        let store = Arc::new(Store::open_in_memory().unwrap());
        store.device_add("test phone", TOKEN).unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let app = App::new_in_home(
            sup,
            home.path().join("agents"),
            FileService::new(home.path().to_path_buf(), None),
            home.path().to_path_buf(),
        );
        let planner: Planner = Arc::new(|mode, _| match mode {
            PhoneMode::Off => Vec::new(),
            _ => vec!["127.0.0.1:0".parse().unwrap()],
        });
        let ifaces: Ifaces = Arc::new(|| vec!["100.101.102.103".parse().unwrap(), "192.168.1.5".parse().unwrap()]);
        app.phone.set_sources(ifaces, Some(planner));
        World { app, home }
    }

    async fn set(app: &Arc<App>, patch: Value) -> Value {
        rpc::dispatch(app, &Peer::Local, "server.settings_set", patch)
            .await
            .unwrap()
    }

    fn bound(app: &Arc<App>) -> SocketAddr {
        app.phone.status().listening[0].parse().expect("a listening address")
    }

    #[tokio::test]
    async fn nothing_listens_and_no_certificate_exists_until_it_is_switched_on() {
        let w = world();
        assert_eq!(w.app.phone.apply().await.mode, PhoneMode::Off);
        let status = w.app.phone.status();
        assert!(status.listening.is_empty());
        assert_eq!(w.app.phone.fingerprint(), None);
        assert!(!w.home.path().join("tls").exists());
        let info = rpc::dispatch(&w.app, &Peer::Local, "daemon.info", json!({}))
            .await
            .unwrap();
        assert_eq!(info["phone_access"], json!("off"));
        assert_eq!(info["tls_fingerprint"], Value::Null);
        assert!(info["features"].as_array().unwrap().contains(&json!("phone_access")));
    }

    #[tokio::test]
    async fn switching_on_makes_a_private_certificate_and_a_tls_only_listener() {
        use std::os::unix::fs::PermissionsExt;
        let w = world();
        let reply = set(&w.app, json!({"phone_access": "lan"})).await;
        assert_eq!(reply["phone"]["mode"], json!("lan"));
        assert_eq!(reply["phone"]["error"], Value::Null);
        let fp = w.app.phone.fingerprint().expect("a fingerprint");
        assert_eq!(fp.len(), 64);
        assert!(fp.chars().all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c)));
        assert_eq!(reply["phone"]["tls_fingerprint"], json!(fp));
        for name in ["phone-cert.pem", "phone-key.pem"] {
            let mode = std::fs::metadata(w.home.path().join("tls").join(name))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600, "{name}");
        }
        assert_eq!(
            std::fs::metadata(w.home.path().join("tls"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        let addr = bound(&w.app);
        let (status, body) = https(addr, &fp, "/v1/health", &[]).await;
        assert_eq!((status, body.ends_with("ok")), (200, true));
        // A client that pins another certificate does not get through the handshake.
        assert!(tls_connect(addr, &"0".repeat(64)).await.is_err());
        // Plain HTTP is never answered.
        let mut plain = TcpStream::connect(addr).await.unwrap();
        plain
            .write_all(b"GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n")
            .await
            .unwrap();
        let mut got = Vec::new();
        let _ = tokio::time::timeout(Duration::from_secs(5), plain.read_to_end(&mut got)).await;
        assert!(!String::from_utf8_lossy(&got).contains("HTTP/1.1 200"));
        let info = rpc::dispatch(&w.app, &Peer::Local, "daemon.info", json!({}))
            .await
            .unwrap();
        assert_eq!(info["phone_access"], json!("lan"));
        assert_eq!(info["tls_fingerprint"], json!(fp));
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn without_a_device_token_a_client_gets_nothing_but_hello_and_redeem() {
        let w = world();
        set(&w.app, json!({"phone_access": "tailscale"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        // HTTP routes.
        for path in ["/v1/files/raw?path=/etc/hosts", "/v1/browser/tabs", "/v1/proxy/80/"] {
            assert_eq!(https(addr, &fp, path, &[]).await.0, 401, "{path}");
        }
        let bad = "Bearer bdt_not_a_token";
        assert_eq!(
            https(addr, &fp, "/v1/files/raw?path=/etc/hosts", &[("Authorization", bad)])
                .await
                .0,
            401
        );
        // An agent's session token is no device token.
        let agent = "Bearer bat_0000000000000000000000000000000000000000000";
        assert_eq!(
            https(addr, &fp, "/v1/files/raw?path=/etc/hosts", &[("Authorization", agent)])
                .await
                .0,
            401
        );
        assert!(ws(addr, &fp, &[("Authorization", agent)]).await.is_err());
        // A browser page (an Origin) is refused even with a good token.
        let auth = format!("Bearer {TOKEN}");
        assert_eq!(
            https(
                addr,
                &fp,
                "/v1/files/raw?path=/etc/hosts",
                &[("Authorization", &auth), ("Origin", "https://evil.test")]
            )
            .await
            .0,
            403
        );
        assert!(
            ws(addr, &fp, &[("Authorization", &auth), ("Origin", "https://evil.test")])
                .await
                .is_err()
        );
        // The Host is not checked on this listener (the token is the protection).
        assert_eq!(https(addr, &fp, "/v1/health", &[]).await.0, 200);
        // An anonymous socket: hello and redeem only.
        let mut anon = ws(addr, &fp, &[]).await.expect("an anonymous socket");
        assert_eq!(
            rpc_call(&mut anon, "daemon.hello").await["result"]["authenticated"],
            json!(false)
        );
        for method in [
            "agents.list",
            "devices.list",
            "pair.create",
            "fs.list",
            "server.settings_get",
            "daemon.info",
        ] {
            assert!(rpc_call(&mut anon, method).await["error"].is_object(), "{method}");
        }
        // A paired device is served.
        let mut paired = ws(addr, &fp, &[("Authorization", &auth)])
            .await
            .expect("a paired socket");
        assert_eq!(
            rpc_call(&mut paired, "daemon.hello").await["result"]["authenticated"],
            json!(true)
        );
        assert!(rpc_call(&mut paired, "devices.list").await["result"].is_array());
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn the_eleventh_anonymous_upgrade_from_an_address_in_ten_minutes_gets_429() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        for i in 0..ATTEMPT_MAX {
            assert!(ws(addr, &fp, &[]).await.is_ok(), "attempt {i}");
        }
        match ws(addr, &fp, &[]).await {
            Err(tokio_tungstenite::tungstenite::Error::Http(res)) => assert_eq!(res.status().as_u16(), 429),
            other => panic!("expected 429, got {:?}", other.map(|_| ())),
        }
        // A paired device is not held back by it.
        let auth = format!("Bearer {TOKEN}");
        assert!(ws(addr, &fp, &[("Authorization", &auth)]).await.is_ok());
        w.app.phone.shutdown().await;
    }

    #[test]
    fn the_attempt_limit_is_per_address_and_slides() {
        let limiter = AttemptLimiter::default();
        let t0 = 1_000_000;
        for i in 0..ATTEMPT_MAX {
            assert!(limiter.attempt("203.0.113.7", t0 + i as i64), "{i}");
        }
        assert!(!limiter.attempt("203.0.113.7", t0 + 1000));
        assert!(limiter.attempt("198.51.100.9", t0 + 1000), "another address is free");
        assert!(!limiter.attempt("203.0.113.7", t0 + ATTEMPT_WINDOW_MS - 1));
        assert!(
            limiter.attempt("203.0.113.7", t0 + ATTEMPT_WINDOW_MS + 1),
            "the window slid"
        );
    }

    #[test]
    fn a_full_table_of_addresses_refuses_new_ones() {
        let limiter = AttemptLimiter::default();
        for i in 0..MAX_SOURCES {
            assert!(limiter.attempt(&format!("src-{i}"), 5));
        }
        assert!(!limiter.attempt("one-more", 6));
        assert!(limiter.attempt("src-1", 6), "a known address still counts");
        assert!(
            limiter.attempt("one-more", 5 + ATTEMPT_WINDOW_MS + 1),
            "old entries make room"
        );
    }

    #[tokio::test]
    async fn the_fingerprint_survives_a_restart() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let first = w.app.phone.fingerprint().unwrap();
        let cert_bytes = std::fs::read(w.home.path().join("tls/phone-cert.pem")).unwrap();
        w.app.phone.shutdown().await;
        // A new daemon over the same data folder.
        let again = world_in(w.home);
        assert_eq!(
            again.app.phone.fingerprint().as_deref(),
            Some(first.as_str()),
            "read before it listens"
        );
        set(&again.app, json!({"phone_access": "lan"})).await;
        assert_eq!(again.app.phone.fingerprint().as_deref(), Some(first.as_str()));
        assert_eq!(
            std::fs::read(again.home.path().join("tls/phone-cert.pem")).unwrap(),
            cert_bytes
        );
        assert_eq!(
            https(bound(&again.app), &first, "/v1/health", &[]).await.0,
            200,
            "the same certificate is served"
        );
        again.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_damaged_certificate_is_not_replaced_behind_the_owners_back() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        w.app.phone.shutdown().await;
        std::fs::write(w.home.path().join("tls/phone-cert.pem"), "garbage").unwrap();
        let again = world_in(w.home);
        let reply = set(&again.app, json!({"phone_access": "lan"})).await;
        assert!(reply["phone"]["listening"].as_array().unwrap().is_empty());
        let error = reply["phone"]["error"].as_str().expect("an error");
        assert!(error.contains("Delete the folder"), "{error}");
        assert_eq!(
            std::fs::read_to_string(again.home.path().join("tls/phone-cert.pem")).unwrap(),
            "garbage"
        );
    }

    #[tokio::test]
    async fn switching_off_closes_the_listener_and_its_open_connections() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let auth = format!("Bearer {TOKEN}");
        let mut open = ws(addr, &fp, &[("Authorization", &auth)]).await.unwrap();
        assert!(rpc_call(&mut open, "daemon.hello").await["result"].is_object());
        let reply = set(&w.app, json!({"phone_access": "off"})).await;
        assert_eq!(reply["phone"]["mode"], json!("off"));
        assert!(reply["phone"]["listening"].as_array().unwrap().is_empty());
        // (Another test may take the freed port number: what matters is that this certificate is not served.)
        assert!(tls_connect(addr, &fp).await.is_err(), "the port is closed");
        let ended = tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(Ok(_)) = open.next().await {}
        })
        .await;
        assert!(ended.is_ok(), "the open connection ended");
        // The certificate stays: switching on again gives the same fingerprint.
        set(&w.app, json!({"phone_access": "tailscale"})).await;
        assert_eq!(w.app.phone.fingerprint().as_deref(), Some(fp.as_str()));
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn an_address_that_goes_away_loses_its_listener_and_a_new_one_gets_one() {
        let w = world();
        let free = |n: usize| -> Vec<SocketAddr> {
            let held: Vec<std::net::TcpListener> = (0..n)
                .map(|_| std::net::TcpListener::bind("127.0.0.1:0").unwrap())
                .collect();
            held.iter().map(|l| l.local_addr().unwrap()).collect()
        };
        let ports = free(2);
        let (a, b) = (ports[0], ports[1]);
        let current = Arc::new(Mutex::new(vec![a]));
        let seen = current.clone();
        let planner: Planner = Arc::new(move |_, _| seen.lock().unwrap().clone());
        let ifaces: Ifaces = Arc::new(Vec::new);
        w.app.phone.set_sources(ifaces, Some(planner));
        set(&w.app, json!({"phone_access": "tailscale"})).await;
        assert_eq!(w.app.phone.status().listening, vec![a.to_string()]);
        *current.lock().unwrap() = vec![b];
        let status = w.app.phone.apply().await;
        assert_eq!(status.listening, vec![b.to_string()]);
        let fp = w.app.phone.fingerprint().unwrap();
        assert!(tls_connect(a, &fp).await.is_err(), "the old address is closed");
        assert!(tls_connect(b, &fp).await.is_ok());
        // Tailscale gone: nothing listens, and the owner is told why.
        *current.lock().unwrap() = Vec::new();
        let status = w.app.phone.apply().await;
        assert!(status.listening.is_empty());
        assert!(status.error.unwrap().contains("Tailscale"));
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_port_that_is_taken_is_reported_not_hidden() {
        let w = world();
        let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = taken.local_addr().unwrap();
        let planner: Planner = Arc::new(move |_, _| vec![addr]);
        w.app.phone.set_sources(Arc::new(Vec::new), Some(planner));
        let reply = set(&w.app, json!({"phone_access": "lan"})).await;
        assert!(reply["phone"]["listening"].as_array().unwrap().is_empty());
        assert!(reply["phone"]["error"].as_str().unwrap().contains("Could not listen"));
        // The setting is kept: the owner sees it on, with the reason.
        assert_eq!(reply["settings"]["phone_access"], json!("lan"));
    }

    #[tokio::test]
    async fn revoking_a_device_ends_its_open_connection() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let auth = format!("Bearer {TOKEN}");
        let mut paired = ws(addr, &fp, &[("Authorization", &auth)]).await.unwrap();
        let list = rpc_call(&mut paired, "devices.list").await;
        let id = list["result"][0]["id"].as_str().unwrap().to_string();
        let done = rpc::dispatch(&w.app, &Peer::Local, "devices.revoke", json!({"id": id}))
            .await
            .unwrap();
        assert_eq!(done["revoked"], json!(true));
        let ended = tokio::time::timeout(Duration::from_secs(5), async {
            while let Some(Ok(_)) = paired.next().await {}
        })
        .await;
        assert!(ended.is_ok(), "the revoked device is cut off");
        assert_eq!(
            https(addr, &fp, "/v1/files/raw?path=/etc/hosts", &[("Authorization", &auth)])
                .await
                .0,
            401
        );
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn pair_create_gives_a_link_only_while_the_phone_listener_is_up() {
        let w = world();
        let off = rpc::dispatch(&w.app, &Peer::Local, "pair.create", json!({}))
            .await
            .unwrap();
        assert_eq!(off["link"], Value::Null);
        assert_eq!(off["qr"], Value::Null);
        assert_eq!(off["hosts"], json!([]));
        assert!(off["code"].as_str().is_some());
        set(&w.app, json!({"phone_access": "lan", "phone_port": 7900})).await;
        let fp = w.app.phone.fingerprint().unwrap();
        let on = rpc::dispatch(&w.app, &Peer::Local, "pair.create", json!({}))
            .await
            .unwrap();
        let code = on["code"].as_str().unwrap();
        assert_eq!(on["hosts"], json!(["100.101.102.103:7900", "192.168.1.5:7900"]));
        assert_eq!(on["fingerprint"], json!(fp));
        let name = percent_encode(&w.app.hostname);
        assert_eq!(
            on["link"],
            json!(format!(
                "bandito://pair?v=1&code={code}&fp={fp}&name={name}&host=100.101.102.103:7900&host=192.168.1.5:7900"
            ))
        );
        assert_eq!(on["qr"], on["link"]);
        // Tailscale mode offers the Tailscale host only.
        set(&w.app, json!({"phone_access": "tailscale"})).await;
        let ts = rpc::dispatch(&w.app, &Peer::Local, "pair.create", json!({}))
            .await
            .unwrap();
        assert_eq!(ts["hosts"], json!(["100.101.102.103:7900"]));
        // Agents and anonymous peers cannot ask for codes.
        assert!(!rpc::allowed(&Peer::Anonymous("203.0.113.7".into()), "pair.create"));
        assert!(!rpc::allowed(&Peer::Agent("a".into()), "pair.create"));
        w.app.phone.shutdown().await;
    }

    #[test]
    fn tailscale_addresses_are_the_cgnat_block_and_the_tailscale_ula() {
        for yes in [
            "100.64.0.0",
            "100.100.1.2",
            "100.127.255.255",
            "fd7a:115c:a1e0::1",
            "fd7a:115c:a1e0:ab12::9",
            "::ffff:100.64.0.1",
        ] {
            assert!(is_tailscale(yes.parse().unwrap()), "{yes}");
        }
        for no in [
            "100.63.255.255",
            "100.128.0.0",
            "10.0.0.1",
            "192.168.1.5",
            "127.0.0.1",
            "fd7a:115c:a1e1::1",
            "fd7a:115d:a1e0::1",
            "fe80::1",
            "2001:db8::1",
        ] {
            assert!(!is_tailscale(no.parse().unwrap()), "{no}");
        }
    }

    #[test]
    fn the_plan_follows_the_mode() {
        let ifaces: Vec<IpAddr> = [
            "192.168.1.5",
            "100.101.102.103",
            "10.0.0.2",
            "fd7a:115c:a1e0::5",
            "fe80::1",
            "100.64.0.9",
            "100.101.102.103",
        ]
        .iter()
        .map(|s| s.parse().unwrap())
        .collect();
        assert!(plan(PhoneMode::Off, 7879, &ifaces).is_empty());
        let ts: Vec<String> = plan(PhoneMode::Tailscale, 7879, &ifaces)
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(
            ts,
            vec!["100.64.0.9:7879", "100.101.102.103:7879", "[fd7a:115c:a1e0::5]:7879"]
        );
        assert!(plan(PhoneMode::Tailscale, 7879, &[]).is_empty());
        let lan: Vec<String> = plan(PhoneMode::Lan, 7900, &ifaces)
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(lan, vec!["[::]:7900", "0.0.0.0:7900"]);
    }

    #[test]
    fn the_hosts_put_tailscale_first_then_the_local_network() {
        let ifaces: Vec<IpAddr> = [
            "192.168.1.5",
            "fd7a:115c:a1e0::5",
            "100.101.102.103",
            "fe80::1",
            "fd12::7",
            "172.17.0.1",
            "8.8.8.8",
        ]
        .iter()
        .map(|s| s.parse().unwrap())
        .collect();
        assert_eq!(
            pair_hosts(PhoneMode::Lan, 7879, &ifaces),
            vec![
                "100.101.102.103:7879",
                "[fd7a:115c:a1e0::5]:7879",
                "172.17.0.1:7879",
                "192.168.1.5:7879",
                "[fd12::7]:7879"
            ]
        );
        assert_eq!(
            pair_hosts(PhoneMode::Tailscale, 7879, &ifaces),
            vec!["100.101.102.103:7879", "[fd7a:115c:a1e0::5]:7879"]
        );
        assert!(pair_hosts(PhoneMode::Off, 7879, &ifaces).is_empty());
    }

    #[test]
    fn the_link_is_versioned_encoded_and_repeats_host() {
        let hosts = vec!["100.64.0.1:7879".to_string(), "[fd7a:115c:a1e0::1]:7879".to_string()];
        let fp = "a".repeat(64);
        let link = pair_link("otter-lava-mint-orbit-crane-fig", &fp, "Дом & Co #1", &hosts);
        assert_eq!(
            link,
            format!(
                "bandito://pair?v=1&code=otter-lava-mint-orbit-crane-fig&fp={fp}&name=%D0%94%D0%BE%D0%BC%20%26%20Co%20%231&host=100.64.0.1:7879&host=%5Bfd7a:115c:a1e0::1%5D:7879"
            )
        );
        let long = pair_link("c", &fp, &"é".repeat(100), &[]);
        let name = long.split("&name=").nth(1).unwrap();
        assert_eq!(
            name.matches("%C3%A9").count(),
            MAX_NAME_CHARS,
            "the name is cut at 64 characters"
        );
    }

    #[test]
    fn the_interface_list_never_has_loopback() {
        for ip in interface_addrs() {
            assert!(!ip.is_loopback() && !ip.is_unspecified(), "{ip}");
        }
    }
}
