//! Phone access: a TLS listener for the iPhone app, next to the loopback one (docs/ARCHITECTURE.md#phone-access).
//!
//! Off by default. The owner turns it on with the server setting `phone_access`:
//! - `tailscale`: listens only on this machine's Tailscale addresses (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`), found
//!   in the interface list, and on a `utun*` only when `tailscale ip` reports its address;
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
use std::ffi::OsStr;
use std::future::Future;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};
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
/// Open connections one source (an IPv4 address, or an IPv6 /64) may hold on the phone listeners together. Above a
/// paired phone's own need: its RPC, up to 64 tunnels (`tunnel_limit`), file and preview requests and DevTools are each
/// a connection, and the slot is taken before the token is known. Anonymous sockets have their own, small limit.
#[cfg(not(test))]
pub const MAX_PER_SOURCE: usize = 128;
#[cfg(test)]
pub const MAX_PER_SOURCE: usize = 8;
/// Anonymous WebSockets (the only way to pair) one source may hold at once.
pub const MAX_ANONYMOUS_PER_SOURCE: usize = 3;
/// A TLS handshake that takes longer is dropped.
#[cfg(not(test))]
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const HANDSHAKE_TIMEOUT: Duration = Duration::from_millis(800);
/// An anonymous WebSocket that has sent no `pair.redeem` in this time is closed.
#[cfg(not(test))]
pub const ANONYMOUS_IDLE: Duration = Duration::from_secs(30);
#[cfg(test)]
pub const ANONYMOUS_IDLE: Duration = Duration::from_millis(800);
/// After its `pair.redeem` an anonymous WebSocket lives this much longer at most (the app reconnects with its token).
#[cfg(not(test))]
pub const ANONYMOUS_AFTER_REDEEM: Duration = Duration::from_secs(60);
#[cfg(test)]
pub const ANONYMOUS_AFTER_REDEEM: Duration = Duration::from_secs(3);
/// Time a client has to send a request's headers (also between two requests of one connection).
const HEADER_TIMEOUT: Duration = Duration::from_secs(20);
/// How often the listeners are matched to the machine's addresses (Tailscale may come up after the daemon).
const WATCH_INTERVAL: Duration = Duration::from_secs(30);

/// How long `tailscale ip` may take before it is given up (and killed).
const TAILSCALE_TIMEOUT: Duration = Duration::from_secs(2);
/// Hosts in a pairing link.
const MAX_HOSTS: usize = 6;
/// Characters of the server name in a pairing link.
const MAX_NAME_CHARS: usize = 64;
/// The version of the pairing link (`v=`). An app that does not know it asks for an update.
pub const LINK_VERSION: u32 = 1;

/// An address of this machine and the name of the interface that carries it (`en0`, `utun4`, `tailscale0`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct IfaceAddr {
    pub name: String,
    pub ip: IpAddr,
}

impl IfaceAddr {
    pub fn new(name: &str, ip: IpAddr) -> Self {
        Self {
            name: name.to_string(),
            ip,
        }
    }
}

/// Where the machine's addresses come from. Replaced in tests.
pub type Ifaces = Arc<dyn Fn() -> Vec<IfaceAddr> + Send + Sync>;
/// The addresses Tailscale reports for this machine. Replaced in tests.
pub type TailscaleIps = Arc<dyn Fn() -> Vec<IpAddr> + Send + Sync>;
/// Which addresses a mode listens on. Replaced in tests, to listen on loopback with a port the system picks.
type Planner = Arc<dyn Fn(PhoneMode, u16) -> Vec<SocketAddr> + Send + Sync>;

/// Whether `ip` is in a range Tailscale uses: `100.64.0.0/10` or `fd7a:115c:a1e0::/48`. Other carriers use the
/// 100.64.0.0/10 block too, so the range alone does not make an address Tailscale's: see [`is_tailscale`].
pub fn is_tailscale_range(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.octets()[0] == 100 && v4.octets()[1] & 0xC0 == 64,
        IpAddr::V6(v6) => {
            let s = v6.segments();
            s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0
        }
    }
}

/// Whether an interface of this name is Tailscale's by its name: `tailscale*` or `ts*`. A `utun*` is not: macOS
/// names every VPN's tunnel so, see [`is_tailscale`].
pub fn is_tailscale_iface(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name.starts_with("tailscale") || name.starts_with("ts")
}

/// Whether the address is Tailscale's: in Tailscale's range, and either on an interface of Tailscale's name, or on a
/// `utun*` with one of the addresses Tailscale reports itself (`tailscale_ips`). Without that answer a utun is not.
pub fn is_tailscale(addr: &IfaceAddr, tailscale_ips: &[IpAddr]) -> bool {
    let utun = addr.name.to_ascii_lowercase().starts_with("utun");
    is_tailscale_range(addr.ip) && (is_tailscale_iface(&addr.name) || (utun && tailscale_ips.contains(&addr.ip)))
}

/// Whether `ip` is a private address of a local network: RFC 1918 or `fc00::/7`. Not Tailscale's range, not
/// link-local, not loopback, and never a public address.
fn is_private(ip: IpAddr) -> bool {
    if is_tailscale_range(ip) {
        return false;
    }
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.is_private(),
        IpAddr::V6(v6) => v6.segments()[0] & 0xfe00 == 0xfc00,
    }
}

/// An address the `lan` mode may listen on and the pairing link may name: private (a local network) or Tailscale's.
fn is_phone_reachable(addr: &IfaceAddr, tailscale_ips: &[IpAddr]) -> bool {
    is_private(addr.ip) || is_tailscale(addr, tailscale_ips)
}

/// The addresses `tailscale ip` prints, one per line; a line that is no address is skipped.
pub fn parse_tailscale_ips(text: &str) -> Vec<IpAddr> {
    text.lines()
        .filter_map(|line| line.trim().parse::<IpAddr>().ok())
        .collect()
}

/// Runs `<program> ip` and reads the addresses it prints. Nothing when it fails, or takes longer than
/// [`TAILSCALE_TIMEOUT`] (then the child is killed: it dies with the future that waited for it).
pub async fn run_tailscale_ip(program: &Path) -> Vec<IpAddr> {
    let mut command = tokio::process::Command::new(program);
    command.arg("ip").stdin(std::process::Stdio::null()).kill_on_drop(true);
    match tokio::time::timeout(TAILSCALE_TIMEOUT, command.output()).await {
        Ok(Ok(out)) if out.status.success() => parse_tailscale_ips(&String::from_utf8_lossy(&out.stdout)),
        _ => Vec::new(),
    }
}

/// The places Tailscale's command is looked for after the `PATH`: the app's own (macOS, from the App Store or the
/// standalone download), then Homebrew's and a manual install's. A launchd service has a short `PATH` and does not
/// find the command there.
const TAILSCALE_FALLBACKS: [&str; 3] = [
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
];

/// The Tailscale command: the first `tailscale` on `path`, else the first of `fallbacks` that is there.
pub fn find_tailscale(path: &OsStr, fallbacks: &[PathBuf]) -> Option<PathBuf> {
    crate::setup::which("tailscale", path).or_else(|| fallbacks.iter().find(|p| p.is_file()).cloned())
}

/// The addresses Tailscale reports for this machine (see [`find_tailscale`]). Nothing when the command is not there.
pub async fn fetch_tailscale_ips() -> Vec<IpAddr> {
    let path = std::env::var_os("PATH").unwrap_or_default();
    let fallbacks: Vec<PathBuf> = TAILSCALE_FALLBACKS.iter().map(PathBuf::from).collect();
    match find_tailscale(&path, &fallbacks) {
        Some(program) => run_tailscale_ip(&program).await,
        None => Vec::new(),
    }
}

/// The last answer of `tailscale ip` and when it came. The command runs in [`PhoneAccess::apply`] (the watcher's round,
/// and a settings change), never while a pairing waits: planning and pairing read the kept answer.
#[derive(Default)]
pub struct TailscaleCache {
    last: Mutex<Option<(Instant, Vec<IpAddr>)>>,
}

impl TailscaleCache {
    pub fn store(&self, at: Instant, ips: Vec<IpAddr>) {
        *self.last.lock().unwrap_or_else(|e| e.into_inner()) = Some((at, ips));
    }

    /// The kept answer when it is younger than [`WATCH_INTERVAL`] at `now`; nothing otherwise.
    pub fn get(&self, now: Instant) -> Vec<IpAddr> {
        match self.last.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            Some((at, ips)) if now.saturating_duration_since(*at) < WATCH_INTERVAL => ips.clone(),
            _ => Vec::new(),
        }
    }
}

/// The key a source is counted under: an IPv4 address, or the /64 of an IPv6 one (a host can use any address of its
/// /64, so counting single addresses would let it step around a limit).
pub fn source_key(ip: IpAddr) -> String {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => {
            let s = v6.segments();
            format!("{:x}:{:x}:{:x}:{:x}::/64", s[0], s[1], s[2], s[3])
        }
    }
}

/// The addresses of the interfaces that are up, loopback left out, each with its interface's name. Empty when the list
/// cannot be read.
pub fn interface_addrs() -> Vec<IfaceAddr> {
    let mut out: Vec<IfaceAddr> = Vec::new();
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
        {
            // SAFETY: `ifa_name` is a NUL-terminated string of the node.
            let name = unsafe { std::ffi::CStr::from_ptr(node.ifa_name) }
                .to_string_lossy()
                .into_owned();
            let entry = IfaceAddr { name, ip };
            if !out.contains(&entry) {
                out.push(entry);
            }
        }
    }
    // SAFETY: `head` came from `getifaddrs` and nothing points into the list any more.
    unsafe { libc::freeifaddrs(head) };
    out
}

/// The addresses the daemon listens on for `mode` and `port`, given the machine's `ifaces` and the addresses Tailscale
/// reports (`tailscale_ips`). Never a wildcard and never a public address: `tailscale` takes Tailscale's addresses,
/// `lan` takes those and the private ones (RFC 1918, `fc00::/7`). Link-local IPv6 (`fe80::/10`) is left out: it needs
/// the interface's scope to be bound or named in a link, and no phone pairs through it.
pub fn plan(mode: PhoneMode, port: u16, ifaces: &[IfaceAddr], tailscale_ips: &[IpAddr]) -> Vec<SocketAddr> {
    let wanted = |addr: &&IfaceAddr| match mode {
        PhoneMode::Off => false,
        PhoneMode::Tailscale => is_tailscale(addr, tailscale_ips),
        PhoneMode::Lan => is_phone_reachable(addr, tailscale_ips),
    };
    let mut ips: Vec<IpAddr> = ifaces.iter().filter(wanted).map(|a| a.ip).collect();
    ips.sort();
    ips.dedup();
    ips.into_iter().map(|ip| SocketAddr::new(ip, port)).collect()
}

/// The `host:port` strings a phone can try for this machine, the best first: Tailscale, then the local network
/// (not in `tailscale` mode). IPv6 is in square brackets.
pub fn pair_hosts(mode: PhoneMode, port: u16, ifaces: &[IfaceAddr], tailscale_ips: &[IpAddr]) -> Vec<String> {
    let mut hosts: Vec<IpAddr> = Vec::new();
    let mut push = |filter: &dyn Fn(&IfaceAddr) -> bool| {
        let mut found: Vec<IpAddr> = ifaces.iter().filter(|a| filter(a)).map(|a| a.ip).collect();
        // IPv4 first: it is the one every phone network has.
        found.sort_by_key(|ip| (ip.is_ipv6(), *ip));
        hosts.extend(found);
    };
    match mode {
        PhoneMode::Off => return Vec::new(),
        PhoneMode::Tailscale => push(&|a: &IfaceAddr| is_tailscale(a, tailscale_ips)),
        PhoneMode::Lan => {
            push(&|a: &IfaceAddr| is_tailscale(a, tailscale_ips));
            push(&|a: &IfaceAddr| is_private(a.ip));
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

/// The relay part of a pairing link (docs/RELAY.md): where the phone reaches the server, and the key it pins.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayLink {
    /// The relay's host, with its port when it is not the default: `relay.bandito.dev`.
    pub host: String,
    /// The server's relay id (26 base32 characters).
    pub sid: String,
    /// The daemon's Noise static public key, base64url without padding.
    pub nk: String,
}

impl RelayLink {
    /// The `relay` parameter of the link: `<host>/<sid>`.
    pub fn param(&self) -> String {
        format!("{}/{}", self.host, self.sid)
    }
}

/// The pairing link: `bandito://pair?v=1&code=…&fp=…&name=…&host=…&host=…`. `host` repeats, best first.
/// Values are percent-encoded; `fp` is 64 lower-case hex digits.
pub fn pair_link(code: &str, fingerprint: &str, name: &str, hosts: &[String]) -> String {
    pair_link_with_relay(code, Some(fingerprint), name, hosts, None)
}

/// The pairing link with the relay's parameters when relay mode is on: `…&relay=<host>/<sid>&nk=<base64url>`. `fp` is
/// left out when the server has no phone certificate (relay only, no `host`).
pub fn pair_link_with_relay(
    code: &str,
    fingerprint: Option<&str>,
    name: &str,
    hosts: &[String],
    relay: Option<&RelayLink>,
) -> String {
    let name: String = name.chars().take(MAX_NAME_CHARS).collect();
    let mut link = format!("bandito://pair?v={LINK_VERSION}&code={}", percent_encode(code));
    if let Some(fp) = fingerprint {
        link.push_str("&fp=");
        link.push_str(fp);
    }
    link.push_str("&name=");
    link.push_str(&percent_encode(&name));
    for host in hosts {
        link.push_str("&host=");
        link.push_str(&percent_encode(host));
    }
    if let Some(relay) = relay {
        link.push_str("&relay=");
        // The slash between host and id stays readable; each part is encoded on its own.
        link.push_str(&format!(
            "{}/{}",
            percent_encode(&relay.host),
            percent_encode(&relay.sid)
        ));
        link.push_str("&nk=");
        link.push_str(&percent_encode(&relay.nk));
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

/// Waits as long as an anonymous connection may live: [`ANONYMOUS_IDLE`] without a `pair.redeem`, and
/// [`ANONYMOUS_AFTER_REDEEM`] more once `redeem_seen` is set. Used by the direct socket and by relay streams alike.
pub async fn anonymous_deadline(redeem_seen: &std::sync::atomic::AtomicBool) {
    tokio::time::sleep(ANONYMOUS_IDLE).await;
    if !redeem_seen.load(std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    tokio::time::sleep(ANONYMOUS_AFTER_REDEEM).await;
}

/// Anonymous upgrades by source and time: at most [`ATTEMPT_MAX`] in [`ATTEMPT_WINDOW_MS`] from one source (an IPv4
/// address or an IPv6 /64, see [`source_key`]).
#[derive(Default)]
pub struct AttemptLimiter {
    by_source: Mutex<HashMap<String, VecDeque<i64>>>,
}

impl AttemptLimiter {
    /// Counts an attempt of `source` at `now` (unix ms). False when it is over the limit (and then not counted). A full
    /// table drops the source that was quiet the longest to make room: flooding it with new sources pushes out the
    /// oldest records, it never locks everybody else out.
    pub fn attempt(&self, source: &str, now: i64) -> bool {
        let mut map = self.by_source.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, times| {
            while times.front().is_some_and(|t| *t <= now - ATTEMPT_WINDOW_MS) {
                times.pop_front();
            }
            !times.is_empty()
        });
        if !map.contains_key(source) && map.len() >= MAX_SOURCES {
            let oldest = map
                .iter()
                .min_by_key(|(_, times)| times.back().copied().unwrap_or(i64::MIN))
                .map(|(key, _)| key.clone());
            if let Some(key) = oldest {
                map.remove(&key);
            }
        }
        let times = map.entry(source.to_string()).or_default();
        if times.len() >= ATTEMPT_MAX {
            return false;
        }
        times.push_back(now);
        true
    }
}

/// Open connections per source, with a ceiling. A slot is held for the life of the connection and freed on drop.
pub struct ConnLimiter {
    max: usize,
    open: Mutex<HashMap<String, usize>>,
}

/// One open connection of a source.
pub struct ConnSlot {
    limiter: Arc<ConnLimiter>,
    key: String,
}

impl ConnLimiter {
    pub fn new(max: usize) -> Arc<Self> {
        Arc::new(Self {
            max,
            open: Mutex::new(HashMap::new()),
        })
    }

    /// A slot for `key`, or None when the source already holds the most it may.
    pub fn acquire(self: &Arc<Self>, key: &str) -> Option<ConnSlot> {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let count = open.entry(key.to_string()).or_insert(0);
        if *count >= self.max {
            return None;
        }
        *count += 1;
        Some(ConnSlot {
            limiter: self.clone(),
            key: key.to_string(),
        })
    }

    /// How many connections `key` holds now.
    pub fn held(&self, key: &str) -> usize {
        self.open
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(key)
            .copied()
            .unwrap_or(0)
    }
}

impl Drop for ConnSlot {
    fn drop(&mut self) {
        let mut open = self.limiter.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(count) = open.get_mut(&self.key) {
            *count -= 1;
            if *count == 0 {
                open.remove(&self.key);
            }
        }
    }
}

/// What the phone listeners share against floods: pairing attempts, anonymous WebSockets and open connections per
/// source.
#[derive(Clone)]
pub struct PhoneLimits {
    pub attempts: Arc<AttemptLimiter>,
    pub anonymous: Arc<ConnLimiter>,
    pub connections: Arc<ConnLimiter>,
}

impl Default for PhoneLimits {
    fn default() -> Self {
        Self {
            attempts: Arc::default(),
            anonymous: ConnLimiter::new(MAX_ANONYMOUS_PER_SOURCE),
            connections: ConnLimiter::new(MAX_PER_SOURCE),
        }
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
    /// The addresses Tailscale reports for this machine: the kept answer ([`TailscaleCache`]).
    tailscale: TailscaleIps,
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
    /// The last `tailscale ip` answer, read by planning and pairing.
    tailscale_cache: Arc<TailscaleCache>,
    /// Serializes `apply`: one change at a time.
    running: tokio::sync::Mutex<Running>,
    status: Mutex<Status>,
    tls: Mutex<Option<Arc<Tls>>>,
    limits: PhoneLimits,
}

impl PhoneAccess {
    /// Phone access of the daemon whose data folder is `home`. Nothing is made or opened until it is switched on.
    pub fn new(home: PathBuf, app: Weak<App>) -> Self {
        let tailscale_cache = Arc::new(TailscaleCache::default());
        let reader = tailscale_cache.clone();
        Self {
            home,
            app,
            sources: Mutex::new(Sources {
                ifaces: Arc::new(interface_addrs),
                planner: None,
                tailscale: Arc::new(move || reader.get(Instant::now())),
            }),
            tailscale_cache,
            running: tokio::sync::Mutex::new(Running {
                mode: PhoneMode::Off,
                port: DEFAULT_PHONE_PORT,
                listeners: HashMap::new(),
                last_error: None,
            }),
            status: Mutex::new(Status::off()),
            tls: Mutex::new(None),
            limits: PhoneLimits::default(),
        }
    }

    /// Replaces the interface list, and the addresses to listen on (tests: loopback, any port).
    #[cfg(test)]
    pub fn set_sources(&self, ifaces: Ifaces, planner: Option<Planner>) {
        *self.sources.lock().unwrap_or_else(|e| e.into_inner()) = Sources {
            ifaces,
            planner,
            tailscale: Arc::new(Vec::new),
        };
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

    /// The limits shared by every phone listener.
    pub fn limits(&self) -> PhoneLimits {
        self.limits.clone()
    }

    /// The link and hosts for a pairing `code`, from what is listening now.
    pub fn pair_info(&self, code: &str, server_name: &str, relay: Option<&RelayLink>) -> PairInfo {
        let status = self.status();
        let fingerprint = self.fingerprint();
        let hosts = if status.listening.is_empty() {
            Vec::new()
        } else {
            let sources = self.sources();
            let tailscale = (sources.tailscale)();
            pair_hosts(status.mode, status.port, &(sources.ifaces)(), &tailscale)
        };
        // Direct hosts need the certificate to pin; the relay needs only its key. With neither, there is no link.
        let link = match (&fingerprint, hosts.is_empty(), relay) {
            (Some(fp), false, relay) => Some(pair_link_with_relay(code, Some(fp), server_name, &hosts, relay)),
            (fp, _, Some(relay)) => Some(pair_link_with_relay(
                code,
                fp.as_deref().filter(|_| !hosts.is_empty()),
                server_name,
                &hosts,
                Some(relay),
            )),
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
        if settings.phone_access != PhoneMode::Off {
            // The one place the command runs: the watcher's round and a settings change (bounded by its timeout).
            self.tailscale_cache.store(Instant::now(), fetch_tailscale_ips().await);
        }
        self.apply_with(&app, settings.phone_access, settings.phone_port).await
    }

    async fn apply_with(&self, app: &Arc<App>, mode: PhoneMode, port: u16) -> Status {
        let mut state = self.running.lock().await;
        let sources = self.sources();
        let wanted: Vec<SocketAddr> = match (&sources.planner, mode) {
            (_, PhoneMode::Off) => Vec::new(),
            (Some(planner), _) => planner(mode, port),
            (None, _) => {
                let ips = (sources.tailscale)();
                plan(mode, port, &(sources.ifaces)(), &ips)
            }
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
                        error = Some(match mode {
                            PhoneMode::Tailscale => "No Tailscale address on this machine. Install Tailscale and sign in.",
                            _ => "No private network address on this machine. Connect to a local network and try again.",
                        }
                        .into());
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
                    let router = ws::router_phone(app.clone(), bound.ip(), self.limits.clone());
                    let cancel = CancellationToken::new();
                    let acceptor = TlsAcceptor::from(tls.config.clone());
                    let task = tokio::spawn(accept_loop(
                        tcp,
                        acceptor,
                        router,
                        cancel.clone(),
                        self.limits.connections.clone(),
                    ));
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
        let ips: Vec<IpAddr> = (self.sources().ifaces)().into_iter().map(|a| a.ip).collect();
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
async fn accept_loop(
    tcp: TcpListener,
    acceptor: TlsAcceptor,
    router: axum::Router,
    cancel: CancellationToken,
    per_source: Arc<ConnLimiter>,
) {
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
        // One source (an address, or an IPv6 /64) holds only so many connections: a slow or idle client cannot take
        // every slot of the listener. The slot is held until the connection ends.
        let Some(slot) = per_source.acquire(&source_key(peer.ip())) else {
            drop(stream);
            continue;
        };
        let acceptor = acceptor.clone();
        let router = router.clone().layer(axum::Extension(axum::extract::ConnectInfo(peer)));
        let cancel = cancel.clone();
        connections.spawn(async move {
            let _slot = slot;
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
pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
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
        ws_path(addr, fp, "/v1/rpc", headers).await
    }

    async fn ws_path(
        addr: SocketAddr,
        fp: &str,
        path: &str,
        headers: &[(&str, &str)],
    ) -> Result<Ws, tokio_tungstenite::tungstenite::Error> {
        let tls = tls_connect(addr, fp).await.expect("TLS handshake");
        let mut req = format!("ws://localhost:{}{path}", addr.port())
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

    fn ia(name: &str, ip: &str) -> IfaceAddr {
        IfaceAddr::new(name, ip.parse().unwrap())
    }

    /// Waits until the closed anonymous sockets have given their slots back (the server notices a close a moment later).
    async fn wait_no_anonymous(app: &Arc<App>) {
        let limits = app.phone.limits();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while limits.anonymous.held("127.0.0.1") > 0 {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the anonymous slots were not freed"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    /// The HTTP status of a refused upgrade (0 when it was accepted).
    fn status_of(result: Result<Ws, tokio_tungstenite::tungstenite::Error>) -> u16 {
        match result {
            Err(tokio_tungstenite::tungstenite::Error::Http(res)) => res.status().as_u16(),
            Err(other) => panic!("expected an HTTP refusal, got {other:?}"),
            Ok(_) => 0,
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
        let ifaces: Ifaces = Arc::new(|| vec![ia("tailscale0", "100.101.102.103"), ia("en0", "192.168.1.5")]);
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
            wait_no_anonymous(&w.app).await;
        }
        assert_eq!(status_of(ws(addr, &fp, &[]).await), 429);
        // A paired device is not held back by it.
        let auth = format!("Bearer {TOKEN}");
        assert!(ws(addr, &fp, &[("Authorization", &auth)]).await.is_ok());
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_wrong_scheme_of_authorization_is_still_anonymous_and_still_counted() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let headers = [
            "Basic dXNlcjpwYXNz",
            "Basic",
            "Digest x=1",
            "bearer lowercase",
            "Bearer",
            "Token abc",
        ];
        for header in headers {
            // No device token in it: an anonymous upgrade, counted, whatever the header says.
            let mut socket = ws(addr, &fp, &[("Authorization", header)])
                .await
                .unwrap_or_else(|e| panic!("{header}: {e}"));
            assert_eq!(
                rpc_call(&mut socket, "daemon.hello").await["result"]["authenticated"],
                json!(false),
                "{header}"
            );
            let _ = socket.close(None).await;
            wait_no_anonymous(&w.app).await;
        }
        // A bearer token that no device has is refused as one (401), and it uses one of the source's tries.
        assert_eq!(
            status_of(ws(addr, &fp, &[("Authorization", "Bearer bdt_not_a_device")]).await),
            401
        );
        let basic = [("Authorization", "Basic dXNlcjpwYXNz")];
        let counted = ATTEMPT_MAX - headers.len() - 1;
        for i in 0..counted {
            let result = ws(addr, &fp, &basic).await;
            assert_eq!(status_of(result), 0, "attempt {i}");
            wait_no_anonymous(&w.app).await;
        }
        assert_eq!(
            status_of(ws(addr, &fp, &basic).await),
            429,
            "the limit is reached with Basic headers too"
        );
        assert_eq!(
            status_of(ws(addr, &fp, &[]).await),
            429,
            "and it is one limit for the source"
        );
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_source_may_hold_only_a_few_anonymous_sockets_and_a_closed_one_frees_its_place() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let mut open = Vec::new();
        for i in 0..MAX_ANONYMOUS_PER_SOURCE {
            open.push(ws(addr, &fp, &[]).await.unwrap_or_else(|e| panic!("socket {i}: {e}")));
        }
        assert_eq!(
            status_of(ws(addr, &fp, &[]).await),
            429,
            "one more than the source may hold"
        );
        // A paired device is not held by the anonymous slots.
        let auth = format!("Bearer {TOKEN}");
        assert!(ws(addr, &fp, &[("Authorization", &auth)]).await.is_ok());
        let mut first = open.remove(0);
        first.close(None).await.unwrap();
        drop(first);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        loop {
            if status_of(ws(addr, &fp, &[]).await) == 0 {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "the freed place was never usable"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn an_anonymous_socket_that_does_not_pair_in_time_is_closed_and_a_paired_one_is_not() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let auth = format!("Bearer {TOKEN}");
        let mut paired = ws(addr, &fp, &[("Authorization", &auth)]).await.unwrap();
        // Silent, and hello only: neither asks to pair.
        let mut silent = ws(addr, &fp, &[]).await.unwrap();
        let mut hello = ws(addr, &fp, &[]).await.unwrap();
        assert!(rpc_call(&mut hello, "daemon.hello").await["result"].is_object());
        for socket in [&mut silent, &mut hello] {
            let ended = tokio::time::timeout(ANONYMOUS_IDLE + Duration::from_secs(3), async {
                while let Some(Ok(_)) = socket.next().await {}
            })
            .await;
            assert!(ended.is_ok(), "an anonymous socket without a pairing request is closed");
        }
        // One that asks to pair gets longer, but not forever.
        let mut redeeming = ws(addr, &fp, &[]).await.unwrap();
        redeeming
            .send(Message::Text(
                json!({"jsonrpc":"2.0","id":1,"method":"pair.redeem","params":{"code":"nope-nope-nope-nope-nope-nope","device_name":"x"}})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        let ended = tokio::time::timeout(
            ANONYMOUS_IDLE + ANONYMOUS_AFTER_REDEEM + Duration::from_secs(3),
            async { while let Some(Ok(_)) = redeeming.next().await {} },
        )
        .await;
        assert!(ended.is_ok(), "even one that asked to pair does not stay for ever");
        // The paired socket lived through all of that.
        assert!(rpc_call(&mut paired, "devices.list").await["result"].is_array());
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_client_that_never_finishes_the_tls_handshake_does_not_keep_its_place() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        // Connect and say nothing: the handshake times out and the connection is closed.
        let mut idle = TcpStream::connect(addr).await.unwrap();
        let mut buf = [0u8; 16];
        let read = tokio::time::timeout(Duration::from_secs(5), idle.read(&mut buf)).await;
        assert!(matches!(read, Ok(Ok(0)) | Ok(Err(_))), "the server closed it: {read:?}");
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn one_source_cannot_fill_the_listener_with_idle_connections() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let mut held = Vec::new();
        for _ in 0..MAX_PER_SOURCE {
            held.push(TcpStream::connect(addr).await.unwrap());
        }
        // The next one from the same source is closed at once, before any handshake.
        let mut extra = TcpStream::connect(addr).await.unwrap();
        let mut buf = [0u8; 16];
        let read = tokio::time::timeout(Duration::from_millis(400), extra.read(&mut buf)).await;
        assert!(
            matches!(read, Ok(Ok(0)) | Ok(Err(_))),
            "the source is over its share: {read:?}"
        );
        // When the idle ones time out, the source can connect again. Until the listener has seen them close, a new
        // connection is still refused before its handshake: that is retried, not a failure.
        drop(held);
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            if tls_connect(addr, &fp).await.is_ok() {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        w.app.phone.shutdown().await;
    }

    /// A TCP target on loopback that sends a never-ending HTTP answer, slowly. For the tunnel and the preview proxy.
    async fn endless_server() -> u16 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    return;
                };
                tokio::spawn(async move {
                    let mut request = [0u8; 2048];
                    let _ = socket.read(&mut request).await;
                    if socket
                        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000000\r\nContent-Type: application/octet-stream\r\n\r\n")
                        .await
                        .is_err()
                    {
                        return;
                    }
                    let chunk = vec![7u8; 16 * 1024];
                    while socket.write_all(&chunk).await.is_ok() {
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                });
            }
        });
        port
    }

    /// Reads until the connection ends, within `within`. Returns how many bytes came.
    async fn read_until_end(tls: &mut tokio_rustls::client::TlsStream<TcpStream>, within: Duration) -> Option<usize> {
        let mut total = 0;
        let mut buf = vec![0u8; 64 * 1024];
        let finished = tokio::time::timeout(within, async {
            loop {
                match tls.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => total += n,
                }
            }
        })
        .await;
        finished.ok().map(|()| total)
    }

    #[tokio::test]
    async fn a_connection_that_asks_for_its_cancel_token_between_the_revoke_and_its_cancel_gets_a_cancelled_one() {
        let w = world();
        let id = w.app.sup.hub().store.device_list().unwrap()[0].id.clone();
        // A connection that came first holds a live token; the revoke's cancel ends it.
        let early = w.app.device_cancel(&id);
        assert!(!early.is_cancelled());
        // The revoke has deleted the device but not yet cancelled: a connection now must not get a fresh live token.
        assert!(w.app.sup.hub().store.device_revoke(&id).unwrap());
        let late = w.app.device_cancel(&id);
        assert!(
            late.is_cancelled(),
            "a token taken after the delete is cancelled at once"
        );
        w.app.cancel_device(&id);
        assert!(early.is_cancelled());
    }

    #[tokio::test]
    async fn revoking_a_device_ends_its_rpc_tunnel_file_and_preview_connections_within_a_second() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let auth = format!("Bearer {TOKEN}");
        let id = w.app.sup.hub().store.device_list().unwrap()[0].id.clone();

        // RPC.
        let mut rpc_socket = ws(addr, &fp, &[("Authorization", &auth)]).await.unwrap();
        assert!(rpc_call(&mut rpc_socket, "daemon.hello").await["result"].is_object());
        // A tunnel to a TCP target that accepts and holds.
        let target = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let target_port = target.local_addr().unwrap().port();
        tokio::spawn(async move {
            let mut held = Vec::new();
            while let Ok((socket, _)) = target.accept().await {
                held.push(socket);
            }
        });
        let mut tunnel = ws_path(
            addr,
            &fp,
            &format!("/v1/tunnel?port={target_port}"),
            &[("Authorization", &auth)],
        )
        .await
        .unwrap();
        // A file the client does not read: the server is blocked in the middle of it.
        let size = 48usize << 20;
        std::fs::write(w.home.path().join("big.bin"), vec![1u8; size]).unwrap();
        let mut file = tls_connect(addr, &fp).await.unwrap();
        let request = format!(
            "GET /v1/files/raw?path={} HTTP/1.1\r\nHost: localhost\r\nAuthorization: {auth}\r\n\r\n",
            w.home.path().join("big.bin").display()
        );
        file.write_all(request.as_bytes()).await.unwrap();
        let mut head = [0u8; 512];
        let n = file.read(&mut head).await.unwrap();
        assert!(String::from_utf8_lossy(&head[..n]).starts_with("HTTP/1.1 200"));
        // The preview proxy, to a server that never stops.
        let endless = endless_server().await;
        let mut proxy = tls_connect(addr, &fp).await.unwrap();
        proxy
            .write_all(
                format!("GET /v1/proxy/{endless}/x HTTP/1.1\r\nHost: localhost\r\nAuthorization: {auth}\r\n\r\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        let n = proxy.read(&mut head).await.unwrap();
        assert!(String::from_utf8_lossy(&head[..n]).starts_with("HTTP/1.1 200"));

        let revoked = rpc::dispatch(&w.app, &Peer::Local, "devices.revoke", json!({"id": id}))
            .await
            .unwrap();
        assert_eq!(revoked["revoked"], json!(true));

        let one_second = Duration::from_secs(1);
        let rpc_ended =
            tokio::time::timeout(one_second, async { while let Some(Ok(_)) = rpc_socket.next().await {} }).await;
        assert!(rpc_ended.is_ok(), "the RPC socket ended");
        let tunnel_ended =
            tokio::time::timeout(one_second, async { while let Some(Ok(_)) = tunnel.next().await {} }).await;
        assert!(tunnel_ended.is_ok(), "the tunnel ended");
        let file_bytes = read_until_end(&mut file, one_second)
            .await
            .expect("the file stream ended");
        assert!(
            file_bytes + n < size,
            "the file stopped before its end ({file_bytes} of {size})"
        );
        assert!(
            read_until_end(&mut proxy, one_second).await.is_some(),
            "the preview stream ended"
        );
        // And the token opens nothing any more, not even a new tunnel.
        assert!(
            matches!(ws_path(addr, &fp, "/v1/tunnel?port=1", &[("Authorization", &auth)]).await,
            Err(tokio_tungstenite::tungstenite::Error::Http(res)) if res.status().as_u16() == 401)
        );
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
    fn a_full_table_makes_room_by_dropping_the_quietest_source_not_by_refusing_everyone() {
        let limiter = AttemptLimiter::default();
        for i in 0..MAX_SOURCES {
            assert!(limiter.attempt(&format!("src-{i}"), 5 + i as i64));
        }
        // A new source is let in; the one that was quiet the longest (src-0) is forgotten for it.
        assert!(limiter.attempt("one-more", 100_000));
        for _ in 0..ATTEMPT_MAX - 1 {
            assert!(limiter.attempt("one-more", 100_001));
        }
        assert!(
            !limiter.attempt("one-more", 100_002),
            "and it is limited like any other"
        );
        // src-0 lost its record: it starts over (the others kept theirs).
        for _ in 0..ATTEMPT_MAX {
            assert!(limiter.attempt("src-0", 100_003));
        }
        assert!(!limiter.attempt("src-0", 100_004));
        assert!(
            limiter.attempt("src-1", 100_005),
            "a source with older records is let in too"
        );
    }

    #[test]
    fn sources_are_counted_per_ipv4_address_and_per_ipv6_64() {
        let key = |s: &str| source_key(s.parse().unwrap());
        assert_eq!(key("203.0.113.7"), "203.0.113.7");
        assert_eq!(key("::ffff:203.0.113.7"), "203.0.113.7");
        assert_eq!(key("2001:db8:1:2:aaaa:bbbb:cccc:dddd"), key("2001:db8:1:2:1::1"));
        assert_ne!(key("2001:db8:1:2::1"), key("2001:db8:1:3::1"));
        let limiter = AttemptLimiter::default();
        // A host steps through addresses of its /64: all of them are one source.
        for i in 0..ATTEMPT_MAX {
            assert!(limiter.attempt(&key(&format!("2001:db8:1:2::{i:x}")), 10));
        }
        assert!(!limiter.attempt(&key("2001:db8:1:2:ffff::1"), 11));
        assert!(
            limiter.attempt(&key("2001:db8:1:99::1"), 11),
            "another /64 is another source"
        );
    }

    #[test]
    fn a_source_holds_only_so_many_connections() {
        let limiter = ConnLimiter::new(2);
        let first = limiter.acquire("a").unwrap();
        let second = limiter.acquire("a").unwrap();
        assert!(limiter.acquire("a").is_none());
        assert!(limiter.acquire("b").is_some(), "another source has its own");
        drop(first);
        assert_eq!(limiter.held("a"), 1);
        let third = limiter.acquire("a").expect("a freed slot is usable");
        drop((second, third));
        assert_eq!(limiter.held("a"), 0);
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
    async fn an_empty_plan_says_what_the_mode_lacks() {
        let w = world();
        w.app.phone.set_sources(Arc::new(Vec::new), None);
        set(&w.app, json!({"phone_access": "lan"})).await;
        let error = w.app.phone.status().error.expect("an error");
        assert!(error.contains("private network address"), "{error}");
        assert!(!error.contains("Tailscale"), "{error}");
        set(&w.app, json!({"phone_access": "tailscale"})).await;
        let error = w.app.phone.status().error.expect("an error");
        assert!(error.contains("No Tailscale address"), "{error}");
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_hello_that_only_names_pair_redeem_does_not_extend_the_anonymous_window() {
        let w = world();
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr = bound(&w.app);
        let fp = w.app.phone.fingerprint().unwrap();
        let mut socket = ws(addr, &fp, &[]).await.unwrap();
        // The text "pair.redeem" inside another request is no pairing request: the socket gets the idle time only.
        socket
            .send(Message::Text(
                json!({"jsonrpc":"2.0","id":1,"method":"daemon.hello","params":{"note":"pair.redeem"}})
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
        let ended = tokio::time::timeout(ANONYMOUS_IDLE + ANONYMOUS_AFTER_REDEEM / 2, async {
            while let Some(Ok(_)) = socket.next().await {}
        })
        .await;
        assert!(ended.is_ok(), "closed at the idle time, not after the pairing window");
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_wrong_token_is_a_failed_try_from_its_source_and_another_source_has_its_own() {
        let w = world();
        let planner: Planner = Arc::new(|_, _| vec!["127.0.0.1:0".parse().unwrap(), "[::1]:0".parse().unwrap()]);
        w.app.phone.set_sources(Arc::new(Vec::new), Some(planner));
        set(&w.app, json!({"phone_access": "lan"})).await;
        let listening: Vec<SocketAddr> = w
            .app
            .phone
            .status()
            .listening
            .iter()
            .map(|a| a.parse().unwrap())
            .collect();
        let v4 = *listening.iter().find(|a| a.is_ipv4()).expect("an IPv4 listener");
        let v6 = *listening.iter().find(|a| a.is_ipv6()).expect("an IPv6 listener on ::1");
        let fp = w.app.phone.fingerprint().unwrap();
        let wrong = [("Authorization", "Bearer bdt_not_a_device")];
        for i in 0..ATTEMPT_MAX {
            assert_eq!(status_of(ws(v4, &fp, &wrong).await), 401, "try {i}");
        }
        assert_eq!(status_of(ws(v4, &fp, &wrong).await), 429, "over the source's tries");
        // A valid token of the same source is not held back by the tries spent on wrong ones.
        let auth = format!("Bearer {TOKEN}");
        assert!(ws(v4, &fp, &[("Authorization", &auth)]).await.is_ok());
        // Another source (the IPv6 loopback is another /64) still has its own tries.
        assert_eq!(status_of(ws(v6, &fp, &wrong).await), 401);
        w.app.phone.shutdown().await;
    }

    #[tokio::test]
    async fn a_wrong_token_on_another_route_is_a_failed_try_too() {
        let w = world();
        let planner: Planner = Arc::new(|_, _| vec!["127.0.0.1:0".parse().unwrap()]);
        w.app.phone.set_sources(Arc::new(Vec::new), Some(planner));
        set(&w.app, json!({"phone_access": "lan"})).await;
        let addr: SocketAddr = w.app.phone.status().listening[0].parse().unwrap();
        let fp = w.app.phone.fingerprint().unwrap();
        let wrong = [("Authorization", "Bearer bdt_not_a_device")];
        let raw = "/v1/files/raw?path=%2Ftmp%2Fnothing";
        for i in 0..ATTEMPT_MAX {
            assert_eq!(https(addr, &fp, raw, &wrong).await.0, 401, "try {i}");
        }
        assert_eq!(https(addr, &fp, raw, &wrong).await.0, 429, "over the source's tries");
        // The tries are the source's: the RPC upgrade from the same source is refused too.
        assert_eq!(status_of(ws(addr, &fp, &wrong).await), 429);
        // A valid token is never counted, so it is not held back by the wrong ones.
        let auth = format!("Bearer {TOKEN}");
        assert_ne!(https(addr, &fp, raw, &[("Authorization", &auth)]).await.0, 429);
        w.app.phone.shutdown().await;
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
        // The link carries the machine's name cut to MAX_NAME_CHARS (a CI runner's name is longer than that).
        let name = percent_encode(&w.app.hostname.chars().take(MAX_NAME_CHARS).collect::<String>());
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
        assert!(!rpc::allowed(
            &Peer::Anonymous("203.0.113.7".into(), None),
            "pair.create"
        ));
        assert!(!rpc::allowed(&Peer::Agent("a".into()), "pair.create"));
        w.app.phone.shutdown().await;
    }

    #[test]
    fn tailscale_ranges_are_the_cgnat_block_and_the_tailscale_ula() {
        for yes in [
            "100.64.0.0",
            "100.100.1.2",
            "100.127.255.255",
            "fd7a:115c:a1e0::1",
            "fd7a:115c:a1e0:ab12::9",
            "::ffff:100.64.0.1",
        ] {
            assert!(is_tailscale_range(yes.parse().unwrap()), "{yes}");
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
            assert!(!is_tailscale_range(no.parse().unwrap()), "{no}");
        }
    }

    fn ip(s: &str) -> IpAddr {
        s.parse().unwrap()
    }

    #[test]
    fn a_tailscale_address_is_on_an_interface_of_tailscales_name() {
        let none: &[IpAddr] = &[];
        for name in ["tailscale0", "ts0", "Tailscale"] {
            assert!(is_tailscale(&ia(name, "100.101.102.103"), none), "{name}");
        }
        // The same range on another carrier (a mobile network's CGNAT, another VPN) is not Tailscale.
        for name in ["en0", "wlan0", "ppp0", "eth0", "wg0", "bridge100"] {
            assert!(!is_tailscale(&ia(name, "100.101.102.103"), none), "{name}");
        }
        // The name alone is not enough either.
        assert!(!is_tailscale(&ia("tailscale0", "10.0.0.1"), none));
        assert!(!is_tailscale(&ia("utun4", "192.168.1.5"), &[ip("192.168.1.5")]));
    }

    #[test]
    fn a_utun_address_is_tailscales_only_when_tailscale_reports_it() {
        // macOS names every VPN's tunnel utun*: only the addresses Tailscale itself reports make one Tailscale's.
        let reported = [ip("100.101.102.103"), ip("fd7a:115c:a1e0::5")];
        assert!(is_tailscale(&ia("utun4", "100.101.102.103"), &reported));
        assert!(is_tailscale(&ia("utun4", "fd7a:115c:a1e0::5"), &reported));
        assert!(
            !is_tailscale(&ia("utun5", "100.101.102.104"), &reported),
            "a 100.x that Tailscale does not report is another VPN's"
        );
        assert!(
            !is_tailscale(&ia("utun5", "100.101.102.103"), &[]),
            "without an answer from Tailscale, utun is not Tailscale's"
        );
        assert!(is_tailscale(&ia("tailscale0", "100.101.102.103"), &[]));
    }

    #[test]
    fn tailscale_ips_are_read_one_per_line_and_other_lines_are_skipped() {
        assert_eq!(
            parse_tailscale_ips("100.101.102.103\nfd7a:115c:a1e0::5\n\nnot an address\n"),
            vec![ip("100.101.102.103"), ip("fd7a:115c:a1e0::5")]
        );
        assert!(parse_tailscale_ips("").is_empty());
    }

    #[test]
    fn the_tailscale_answer_is_kept_for_one_watch_interval() {
        let cache = TailscaleCache::default();
        let t0 = Instant::now();
        assert!(cache.get(t0).is_empty(), "nothing asked yet");
        cache.store(t0, vec![ip("100.101.102.103")]);
        assert_eq!(
            cache.get(t0 + WATCH_INTERVAL - Duration::from_millis(1)),
            vec![ip("100.101.102.103")]
        );
        assert!(
            cache.get(t0 + WATCH_INTERVAL).is_empty(),
            "older than the interval: nothing"
        );
    }

    #[tokio::test]
    async fn a_tailscale_command_that_is_missing_or_fails_reports_no_addresses() {
        assert!(
            run_tailscale_ip(Path::new("/nonexistent/dir/tailscale"))
                .await
                .is_empty()
        );
        assert!(run_tailscale_ip(Path::new("/usr/bin/false")).await.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn the_tailscale_command_gives_its_addresses_and_one_that_hangs_is_given_up() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::TempDir::new().unwrap();
        let script = |name: &str, body: &str| {
            let path = dir.path().join(name);
            std::fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            path
        };
        let good = script("good", "echo 100.101.102.103\necho fd7a:115c:a1e0::5");
        assert_eq!(
            run_tailscale_ip(&good).await,
            vec![ip("100.101.102.103"), ip("fd7a:115c:a1e0::5")]
        );
        let hangs = script("hangs", "exec sleep 30");
        let started = std::time::Instant::now();
        assert!(run_tailscale_ip(&hangs).await.is_empty());
        assert!(
            started.elapsed() < Duration::from_secs(10),
            "given up after the timeout"
        );
    }

    #[cfg(unix)]
    #[test]
    fn tailscale_is_looked_for_on_the_path_and_then_at_the_usual_places() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::TempDir::new().unwrap();
        let exe = |sub: &str| {
            let folder = dir.path().join(sub);
            std::fs::create_dir_all(&folder).unwrap();
            let path = folder.join("tailscale");
            std::fs::write(&path, "#!/bin/sh\n").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
            path
        };
        let on_path = exe("on_path");
        let usual = exe("usual");
        let missing = dir.path().join("nowhere").join("tailscale");
        let path = std::env::join_paths([dir.path().join("on_path")]).unwrap();
        // The PATH wins over the usual places.
        assert_eq!(find_tailscale(&path, std::slice::from_ref(&usual)), Some(on_path));
        // Not on the PATH (a directory with no such file): the usual place is taken.
        let nowhere = std::env::join_paths([dir.path().join("nowhere")]).unwrap();
        assert_eq!(find_tailscale(&nowhere, &[missing.clone(), usual.clone()]), Some(usual));
        assert_eq!(find_tailscale(&nowhere, &[missing]), None);
    }

    fn machine() -> Vec<IfaceAddr> {
        vec![
            ia("en0", "192.168.1.5"),
            ia("tailscale0", "100.101.102.103"),
            ia("en0", "10.0.0.2"),
            ia("tailscale0", "fd7a:115c:a1e0::5"),
            ia("en0", "fe80::1"),
            ia("utun3", "100.64.0.9"),
            ia("tailscale0", "100.101.102.103"),
            ia("ppp0", "100.80.0.7"),
            ia("en1", "203.0.113.50"),
            ia("en1", "2001:db8::77"),
            ia("en0", "172.16.4.4"),
            ia("en0", "fd12::7"),
            ia("en0", "172.32.0.1"),
            ia("en0", "169.254.7.7"),
        ]
    }

    #[test]
    fn the_plan_follows_the_mode_and_never_names_a_wildcard_or_a_public_address() {
        let ifaces = machine();
        let reported = [ip("100.64.0.9"), ip("100.101.102.103"), ip("fd7a:115c:a1e0::5")];
        assert!(plan(PhoneMode::Off, 7879, &ifaces, &reported).is_empty());
        let ts: Vec<String> = plan(PhoneMode::Tailscale, 7879, &ifaces, &reported)
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(
            ts,
            vec!["100.64.0.9:7879", "100.101.102.103:7879", "[fd7a:115c:a1e0::5]:7879"]
        );
        assert!(plan(PhoneMode::Tailscale, 7879, &[], &reported).is_empty());
        // utun3 carries 100.64.0.9, but that is only Tailscale's when Tailscale reports it.
        assert!(
            plan(PhoneMode::Tailscale, 7879, &ifaces, &[])
                .iter()
                .all(|a| a.ip() != ip("100.64.0.9")),
            "a utun is not listened on as Tailscale's unless Tailscale reports its address"
        );
        let lan: Vec<String> = plan(PhoneMode::Lan, 7900, &ifaces, &reported)
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(
            lan,
            vec![
                "10.0.0.2:7900",
                "100.64.0.9:7900",
                "100.101.102.103:7900",
                "172.16.4.4:7900",
                "192.168.1.5:7900",
                "[fd12::7]:7900",
                "[fd7a:115c:a1e0::5]:7900",
            ]
        );
        for mode in [PhoneMode::Tailscale, PhoneMode::Lan] {
            for addr in plan(mode, 7879, &ifaces, &reported) {
                assert!(!addr.ip().is_unspecified(), "{addr}");
                let public = [
                    "203.0.113.50",
                    "2001:db8::77",
                    "172.32.0.1",
                    "100.80.0.7",
                    "169.254.7.7",
                    "fe80::1",
                ];
                assert!(
                    !public.contains(&addr.ip().to_string().as_str()),
                    "{addr} is not for a phone"
                );
            }
        }
        assert!(
            plan(PhoneMode::Lan, 7879, &[ia("en1", "203.0.113.50")], &[]).is_empty(),
            "only a public address: nothing listens"
        );
    }

    #[test]
    fn the_hosts_put_tailscale_first_then_the_local_network() {
        let ifaces = machine();
        let reported = [ip("100.64.0.9"), ip("100.101.102.103"), ip("fd7a:115c:a1e0::5")];
        assert_eq!(
            pair_hosts(PhoneMode::Lan, 7879, &ifaces, &reported),
            vec![
                "100.64.0.9:7879",
                "100.101.102.103:7879",
                "[fd7a:115c:a1e0::5]:7879",
                "10.0.0.2:7879",
                "172.16.4.4:7879",
                "192.168.1.5:7879"
            ]
        );
        assert_eq!(
            pair_hosts(PhoneMode::Tailscale, 7879, &ifaces, &reported),
            vec!["100.64.0.9:7879", "100.101.102.103:7879", "[fd7a:115c:a1e0::5]:7879"]
        );
        assert!(pair_hosts(PhoneMode::Off, 7879, &ifaces, &reported).is_empty());
    }

    #[test]
    fn the_link_names_the_relay_and_its_key_and_may_have_no_host_or_fingerprint() {
        let relay = RelayLink {
            host: "relay.bandito.dev".into(),
            sid: "abcdefghijklmnopqrstuvwxyz".into(),
            nk: "A-_9".into(),
        };
        let hosts = vec!["10.0.0.2:7879".to_string()];
        let fp = "ab".repeat(32);
        let both = pair_link_with_relay("c-o-d-e", Some(&fp), "Mac", &hosts, Some(&relay));
        assert_eq!(
            both,
            format!(
                "bandito://pair?v=1&code=c-o-d-e&fp={fp}&name=Mac&host=10.0.0.2:7879&relay=relay.bandito.dev/abcdefghijklmnopqrstuvwxyz&nk=A-_9"
            )
        );
        let only = pair_link_with_relay("c", None, "Mac", &[], Some(&relay));
        assert_eq!(
            only,
            "bandito://pair?v=1&code=c&name=Mac&relay=relay.bandito.dev/abcdefghijklmnopqrstuvwxyz&nk=A-_9"
        );
        // Without the relay the link is the old one, byte for byte.
        assert_eq!(
            pair_link_with_relay("c", Some(&fp), "Mac", &hosts, None),
            pair_link("c", &fp, "Mac", &hosts)
        );
        assert_eq!(relay.param(), "relay.bandito.dev/abcdefghijklmnopqrstuvwxyz");
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
        for addr in interface_addrs() {
            assert!(!addr.ip.is_loopback() && !addr.ip.is_unspecified(), "{addr:?}");
            assert!(!addr.name.is_empty());
        }
    }
}
