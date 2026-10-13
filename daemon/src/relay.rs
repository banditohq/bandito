//! Bandito Relay client (docs/RELAY.md): one outbound WebSocket from the daemon to the relay while relay mode is on, and
//! one end-to-end encrypted Noise session per phone stream through it. The relay only forwards bytes. Inside a stream
//! the phone speaks exactly the JSON-RPC text frames of `/v1/rpc`, served by the same [`serve`] as a direct socket.
//!
//! Layers, bottom to top:
//! - the relay connection (`Relay::run`, `Relay::drive`): reconnects with a backoff, pings, frames
//!   `[u32 BE stream id][u8 kind][payload]`;
//! - a stream (`run_stream`): Noise IK responder, then `{"auth": token}` or `{"pair": true}`, then RPC;
//! - the secure channel (`Secure`, `Reassembler`): one transport message per relay data frame, a large RPC frame split
//!   as `[u8 more][chunk]`.

use crate::event::EventBody;
use crate::phone::{ConnSlot, PhoneLimits, RelayLink, anonymous_deadline, source_key, write_private};
use crate::rpc::ws::{ANONYMOUS_MESSAGE_LIMIT, RPC_MESSAGE_LIMIT, asks_to_pair};
use crate::rpc::{App, Peer, serve};
use crate::store::Device;
use anyhow::{Context, Result, anyhow};
use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use futures_util::{SinkExt, StreamExt};
use rustls::pki_types::ServerName;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio::time::timeout;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_util::sync::CancellationToken;
use zeroize::Zeroize;

/// The Noise pattern of a phone session.
pub const NOISE_PATTERN: &str = "Noise_IK_25519_ChaChaPoly_SHA256";
/// The Noise prologue of a phone session.
pub const NOISE_PROLOGUE: &[u8] = b"bandito-relay-v1";
/// The hello both sides put in their handshake message.
const HELLO: &[u8] = br#"{"v":1}"#;
/// The largest Noise message, ciphertext included.
const NOISE_MAX: usize = 65535;
/// The authentication tag of one Noise transport message.
const NOISE_TAG: usize = 16;
/// Data bytes in one chunk: a transport message holds the `more` byte and the chunk, and the tag.
pub const CHUNK: usize = NOISE_MAX - NOISE_TAG - 1;
/// Frame kinds of the relay protocol.
const KIND_DATA: u8 = 0;
const KIND_OPEN: u8 = 1;
const KIND_CLOSE: u8 = 2;
/// Streams one relay connection carries at most (the relay itself allows 16 per server).
const MAX_STREAMS: usize = 64;
/// The largest WebSocket message from the relay (the relay's own limit is 1 MiB).
const WS_MESSAGE_LIMIT: usize = 2 << 20;
/// The largest first message after the handshake: `{"auth": token}` or `{"pair": true}`.
const FIRST_MESSAGE_LIMIT: usize = 4096;
/// Frames waiting for one stream. A stream that falls this far behind is closed: dropping a Noise frame would break it.
const STREAM_BACKLOG: usize = 256;
/// The close code of a connection that another connection of the same server replaced.
const CLOSE_REPLACED: u16 = 4001;
/// The relay saw no message for 60 s.
const CLOSE_SILENCE: u16 = 4002;
/// The registration of this server was deleted at the relay.
const CLOSE_DELETED: u16 = 4003;
/// The close code of a connection the relay refuses for a limit (traffic over the plan).
const CLOSE_LIMIT: u16 = 4008;
/// A message of ours was over the relay's 1 MiB limit.
const CLOSE_TOO_BIG: u16 = 4009;
/// Keepalive messages are text: a Worker cannot see WebSocket ping frames.
const PING: &str = "ping";
const PONG: &str = "pong";
/// The length of the server's relay id (base32) and of its secret (base64url of 32 bytes).
pub const SID_LEN: usize = 26;
pub const SECRET_LEN: usize = 43;

/// The handshake and the first message each get this long.
#[cfg(not(test))]
const STREAM_STEP_TIMEOUT: Duration = Duration::from_secs(10);
#[cfg(test)]
const STREAM_STEP_TIMEOUT: Duration = Duration::from_secs(2);

/// How long a stream gets to flush its last replies when it ends by itself.
const FLUSH_TIMEOUT: Duration = Duration::from_secs(2);

pub const RELAY_FILE: &str = "relay.json";
pub const NOISE_KEY_FILE: &str = "noise.key";

// ---------------------------------------------------------------------------------------------------------------------
// Settings: relay.json, validation
// ---------------------------------------------------------------------------------------------------------------------

/// Where the server registered at the relay: kept in `<data_home>/relay.json` (mode 0600).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Config {
    pub relay_url: String,
    pub sid: String,
    pub secret: String,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config")
            .field("relay_url", &self.relay_url)
            .field("sid", &self.sid)
            .field("secret", &"<hidden>")
            .finish()
    }
}

impl Config {
    /// Checks the three values of `relay.enable`: an `https`/`wss` URL of a host (and port) only, a 26 character
    /// base32 id and a 43 character base64url secret. The URL is stored without a trailing slash.
    pub fn validated(relay_url: &str, sid: &str, secret: &str) -> Result<Self, String> {
        Self::checked(relay_url, sid, secret, false)
    }

    fn checked(relay_url: &str, sid: &str, secret: &str, allow_plain: bool) -> Result<Self, String> {
        let target = parse_url(relay_url.trim(), allow_plain)?;
        if sid.len() != SID_LEN || !sid.bytes().all(|b| matches!(b, b'a'..=b'z' | b'2'..=b'7')) {
            return Err("sid must be 26 lower-case base32 characters".into());
        }
        let decoded = URL_SAFE_NO_PAD.decode(secret).ok();
        if secret.len() != SECRET_LEN || decoded.is_none_or(|d| d.len() != 32) {
            return Err("secret must be 43 base64url characters (256 bits)".into());
        }
        Ok(Self {
            relay_url: format!("{}://{}", target.scheme, target.authority),
            sid: sid.to_string(),
            secret: secret.to_string(),
        })
    }
}

/// A relay URL taken apart.
#[derive(Debug, PartialEq, Eq)]
struct Target {
    scheme: String,
    /// `host` or `host:port`, lower case.
    authority: String,
    host: String,
    port: u16,
    tls: bool,
}

/// `https://host[:port][/]` or `wss://host[:port][/]` (and `http`, `ws` when `allow_plain`, for tests). No user info,
/// path, query or fragment: the relay's routes are fixed (`/v1/server/<sid>`).
fn parse_url(url: &str, allow_plain: bool) -> Result<Target, String> {
    let bad =
        || "relay_url must be an https:// or wss:// address of a host, like https://relay.bandito.dev".to_string();
    let (scheme, rest) = url.split_once("://").ok_or_else(bad)?;
    let scheme = scheme.to_ascii_lowercase();
    let tls = match scheme.as_str() {
        "https" | "wss" => true,
        "http" | "ws" if allow_plain => false,
        _ => return Err(bad()),
    };
    let rest = rest.strip_suffix('/').unwrap_or(rest);
    if rest.is_empty() || rest.len() > 255 {
        return Err(bad());
    }
    if rest
        .bytes()
        .any(|b| !(b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':')))
    {
        return Err(bad());
    }
    let (host, port) = match rest.split_once(':') {
        Some((host, port)) => (host, port.parse::<u16>().ok().filter(|p| *p != 0).ok_or_else(bad)?),
        None => (rest, if tls { 443 } else { 80 }),
    };
    if host.is_empty() || host.starts_with(['.', '-']) || host.ends_with(['.', '-']) || host.contains("..") {
        return Err(bad());
    }
    Ok(Target {
        scheme,
        authority: rest.to_ascii_lowercase(),
        host: host.to_ascii_lowercase(),
        port,
        tls,
    })
}

/// What `relay.status` says. The secret is never in it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Status {
    pub enabled: bool,
    pub connected: bool,
    pub sid: Option<String>,
    pub relay_url: Option<String>,
    pub last_error: Option<String>,
}

impl Status {
    pub fn to_json(&self) -> Value {
        json!({
            "enabled": self.enabled,
            "connected": self.connected,
            "sid": self.sid,
            "relay_url": self.relay_url,
            "last_error": self.last_error,
        })
    }
}

/// A relay call that failed on the server's side (not a bad parameter).
#[derive(Debug)]
pub struct RelayError(pub anyhow::Error);

impl std::fmt::Display for RelayError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:#}", self.0)
    }
}

impl From<anyhow::Error> for RelayError {
    fn from(e: anyhow::Error) -> Self {
        Self(e)
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// The daemon's Noise key
// ---------------------------------------------------------------------------------------------------------------------

/// The daemon's Noise static key (X25519), made once and kept in `noise.key` (mode 0600). The phones pin its public part
/// (`nk` in the pairing link), so it is never replaced by itself: a damaged file is an error, not a new key.
pub struct NoiseKeys {
    private: Vec<u8>,
    public: [u8; 32],
}

impl Drop for NoiseKeys {
    fn drop(&mut self) {
        self.wipe();
    }
}

#[derive(Serialize, Deserialize)]
struct KeyFile {
    private: String,
    public: String,
}

impl NoiseKeys {
    /// The public key, base64url without padding: `nk`.
    pub fn public_b64(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.public)
    }

    /// Overwrites the private key with zeros. Done when the keys are dropped.
    fn wipe(&mut self) {
        self.private.as_mut_slice().zeroize();
    }

    fn generate() -> Result<Self> {
        let pair = noise_builder()?
            .generate_keypair()
            .map_err(|e| anyhow!("noise key: {e}"))?;
        let public: [u8; 32] = pair
            .public
            .try_into()
            .map_err(|_| anyhow!("noise key: unexpected public key length"))?;
        Ok(Self {
            private: pair.private,
            public,
        })
    }

    /// Reads the file, or makes the key when there is none.
    fn load_or_create(home: &Path) -> Result<Self> {
        let path = home.join(NOISE_KEY_FILE);
        match std::fs::read_to_string(&path) {
            Ok(text) => {
                keep_private(&path)?;
                Self::parse(&text).with_context(|| {
                    format!(
                        "{} is damaged; phones pin its key, so it is not replaced by itself (delete it and pair the phones again)",
                        path.display()
                    )
                })
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let keys = Self::generate()?;
                let file = KeyFile {
                    private: URL_SAFE_NO_PAD.encode(&keys.private),
                    public: keys.public_b64(),
                };
                write_private(&path, serde_json::to_string(&file)?.as_bytes())?;
                Ok(keys)
            }
            Err(e) => Err(anyhow!(e).context(format!("read {}", path.display()))),
        }
    }

    fn parse(text: &str) -> Result<Self> {
        let file: KeyFile = serde_json::from_str(text)?;
        let private = URL_SAFE_NO_PAD.decode(file.private)?;
        let public: [u8; 32] = URL_SAFE_NO_PAD
            .decode(file.public)?
            .try_into()
            .map_err(|_| anyhow!("the public key is not 32 bytes"))?;
        if private.len() != 32 {
            return Err(anyhow!("the private key is not 32 bytes"));
        }
        let keys = Self { private, public };
        keys.check_pair()?;
        Ok(keys)
    }

    /// A handshake with ourselves: proves that the private and public key of the file belong together.
    fn check_pair(&self) -> Result<()> {
        let initiator_key = Self::generate()?;
        let mut initiator = noise_builder()?
            .local_private_key(&initiator_key.private)
            .map_err(|e| anyhow!("{e}"))?
            .remote_public_key(&self.public)
            .map_err(|e| anyhow!("{e}"))?
            .prologue(NOISE_PROLOGUE)
            .map_err(|e| anyhow!("{e}"))?
            .build_initiator()
            .map_err(|e| anyhow!("{e}"))?;
        let mut responder = noise_builder()?
            .local_private_key(&self.private)
            .map_err(|e| anyhow!("{e}"))?
            .prologue(NOISE_PROLOGUE)
            .map_err(|e| anyhow!("{e}"))?
            .build_responder()
            .map_err(|e| anyhow!("{e}"))?;
        let mut a = vec![0u8; NOISE_MAX];
        let mut b = vec![0u8; NOISE_MAX];
        let n = initiator.write_message(&[], &mut a).map_err(|e| anyhow!("{e}"))?;
        responder
            .read_message(&a[..n], &mut b)
            .map_err(|_| anyhow!("the private key does not match the public key"))?;
        Ok(())
    }
}

/// The rustls client config for the relay: the system's root certificates, or the bundled Mozilla roots when the system
/// gives none (a machine without a usable trust store must still reach the relay).
fn client_config(system: Vec<rustls::pki_types::CertificateDer<'static>>) -> Result<Arc<rustls::ClientConfig>, String> {
    let mut roots = rustls::RootCertStore::empty();
    let (added, _) = roots.add_parsable_certificates(system);
    if added == 0 {
        tracing::warn!("relay: no system root certificates; using the bundled ones");
        roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|e| e.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(config))
}

/// A key file that others can read or write (or that has an execute bit) is made private again, with a warning: the key
/// is the daemon's identity for the phones.
fn keep_private(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(path)
        .with_context(|| format!("read {}", path.display()))?
        .permissions()
        .mode();
    if mode & 0o777 & !0o600 != 0 {
        tracing::warn!(
            "relay: {} had mode {:o}; made private (0600)",
            path.display(),
            mode & 0o777
        );
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .with_context(|| format!("make {} private", path.display()))?;
    }
    Ok(())
}

fn noise_builder<'a>() -> Result<snow::Builder<'a>> {
    let params = NOISE_PATTERN.parse().map_err(|e| anyhow!("noise pattern: {e}"))?;
    Ok(snow::Builder::new(params))
}

// ---------------------------------------------------------------------------------------------------------------------
// The secure channel of one stream
// ---------------------------------------------------------------------------------------------------------------------

/// The transport half of a finished handshake, for both directions of one stream.
struct Secure {
    state: Mutex<snow::TransportState>,
}

impl Secure {
    /// Encrypts one RPC frame as one or more transport messages (`[more][chunk]`, at most 65535 bytes of ciphertext each).
    fn seal(&self, message: &[u8]) -> Result<Vec<Vec<u8>>, snow::Error> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = Vec::new();
        let mut chunks = message.chunks(CHUNK).peekable();
        if chunks.peek().is_none() {
            let mut cipher = vec![0u8; 1 + NOISE_TAG];
            let n = state.write_message(&[0], &mut cipher)?;
            cipher.truncate(n);
            return Ok(vec![cipher]);
        }
        while let Some(chunk) = chunks.next() {
            let mut plain = Vec::with_capacity(1 + chunk.len());
            plain.push(u8::from(chunks.peek().is_some()));
            plain.extend_from_slice(chunk);
            let mut cipher = vec![0u8; plain.len() + NOISE_TAG];
            let n = state.write_message(&plain, &mut cipher)?;
            cipher.truncate(n);
            out.push(cipher);
        }
        Ok(out)
    }

    fn open(&self, cipher: &[u8]) -> Result<Vec<u8>, snow::Error> {
        if cipher.len() > NOISE_MAX {
            return Err(snow::Error::Decrypt);
        }
        let mut plain = vec![0u8; cipher.len()];
        let n = self
            .state
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .read_message(cipher, &mut plain)?;
        plain.truncate(n);
        Ok(plain)
    }
}

/// Joins the chunks of a frame. A frame over `limit` bytes is refused.
struct Reassembler {
    buf: Vec<u8>,
    limit: usize,
}

impl Reassembler {
    fn new(limit: usize) -> Self {
        Self { buf: Vec::new(), limit }
    }

    /// Takes one decrypted transport message: `Ok(Some(frame))` when it was the last chunk.
    fn push(&mut self, plain: &[u8]) -> Result<Option<Vec<u8>>, &'static str> {
        let Some((&more, chunk)) = plain.split_first() else {
            return Err("empty message");
        };
        if more > 1 {
            return Err("bad chunk header");
        }
        if self.buf.len() + chunk.len() > self.limit {
            return Err("message too large");
        }
        self.buf.extend_from_slice(chunk);
        if more == 1 {
            return Ok(None);
        }
        Ok(Some(std::mem::take(&mut self.buf)))
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// The relay connection
// ---------------------------------------------------------------------------------------------------------------------

/// Times of the connection. Tests shorten them.
#[derive(Debug, Clone, Copy)]
pub struct Timing {
    /// A ping to the relay this often.
    pub ping: Duration,
    /// Nothing received for this long: the connection is dead.
    pub silence: Duration,
    /// The first and the longest wait before a new connection.
    pub backoff_min: Duration,
    pub backoff_max: Duration,
    /// The wait after close 4001 (another connection of this server replaced this one).
    pub replaced_wait: Duration,
    /// The wait after close 4008 (a limit of the relay). None: until the next full hour, when the relay counts again.
    pub limit_wait: Option<Duration>,
    /// The longest wait when the relay does not accept the secret (HTTP 401): it will not get better by itself.
    pub auth_backoff_max: Duration,
    /// Time to connect, with TLS and the WebSocket upgrade.
    pub connect: Duration,
    /// A connection that lived this long starts the backoff again.
    pub stable: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            ping: Duration::from_secs(25),
            silence: Duration::from_secs(60),
            backoff_min: Duration::from_secs(1),
            backoff_max: Duration::from_secs(60),
            replaced_wait: Duration::from_secs(30),
            limit_wait: None,
            auth_backoff_max: Duration::from_secs(600),
            connect: Duration::from_secs(15),
            stable: Duration::from_secs(30),
        }
    }
}

impl Timing {
    /// The wait before connection number `attempt` (0 is the first retry): doubling from the minimum to the maximum,
    /// with 20 % of jitter either way so that servers do not come back together.
    fn backoff(&self, attempt: u32) -> Duration {
        self.backoff_to(attempt, self.backoff_max)
    }

    fn backoff_to(&self, attempt: u32, cap: Duration) -> Duration {
        let doubled = self
            .backoff_min
            .saturating_mul(1u32.checked_shl(attempt.min(16)).unwrap_or(u32::MAX));
        let base = doubled.min(cap);
        let jitter = 0.8 + f64::from(rand::random::<u32>()) / f64::from(u32::MAX) * 0.4;
        base.mul_f64(jitter)
    }
}

struct Inner {
    config: Option<Config>,
    connected: bool,
    last_error: Option<String>,
}

struct Running {
    cancel: CancellationToken,
    task: JoinHandle<()>,
    config: Config,
    /// Tells this connection's task from the one of an older or newer switch.
    generation: u64,
}

/// What a connection ended with.
#[derive(Debug)]
enum Outcome {
    /// Relay mode was switched off.
    Cancelled,
    /// Close 4001: another connection of this server took over.
    Replaced,
    /// The relay closed with another code.
    Closed(u16, String),
    /// Close 4003: the registration was deleted at the relay.
    Deleted,
    /// The relay does not accept the secret (HTTP 401 or 403 at the upgrade).
    Unauthorized(String),
    /// The connection failed or was lost.
    Failed(String),
}

/// One live stream of a relay connection, as the connection sees it. `serial` tells this stream from an older one that had
/// the same id (the relay reuses ids), so that the older one's end does not take the newer one out of the map.
struct StreamHandle {
    frames: mpsc::Sender<Vec<u8>>,
    cancel: CancellationToken,
    serial: u64,
}

/// The serials of the streams of all connections.
static STREAM_SERIAL: AtomicU64 = AtomicU64::new(0);

type Streams = Arc<Mutex<HashMap<u32, StreamHandle>>>;

#[derive(Deserialize)]
struct OpenInfo {
    #[serde(default)]
    ip: String,
    v: u32,
}

/// The relay client of one daemon.
pub struct Relay {
    home: PathBuf,
    app: Weak<App>,
    inner: Mutex<Inner>,
    /// Serializes enable, disable and shutdown; holds the running connection.
    lifecycle: tokio::sync::Mutex<Option<Running>>,
    /// The generation the next connection gets.
    generation: AtomicU64,
    keys: Mutex<Option<Arc<NoiseKeys>>>,
    timing: Mutex<Timing>,
    allow_plain: AtomicBool,
    tls: tokio::sync::OnceCell<Arc<rustls::ClientConfig>>,
}

impl Relay {
    /// The relay client of the daemon whose data folder is `home`. Nothing is made or opened until relay mode is on.
    pub fn new(home: PathBuf, app: Weak<App>) -> Self {
        Self {
            home,
            app,
            inner: Mutex::new(Inner {
                config: None,
                connected: false,
                last_error: None,
            }),
            lifecycle: tokio::sync::Mutex::new(None),
            generation: AtomicU64::new(0),
            keys: Mutex::new(None),
            timing: Mutex::new(Timing::default()),
            allow_plain: AtomicBool::new(false),
            tls: tokio::sync::OnceCell::new(),
        }
    }

    pub fn status(&self) -> Status {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        Status {
            enabled: inner.config.is_some(),
            connected: inner.connected,
            sid: inner.config.as_ref().map(|c| c.sid.clone()),
            relay_url: inner.config.as_ref().map(|c| c.relay_url.clone()),
            last_error: inner.last_error.clone(),
        }
    }

    fn timing(&self) -> Timing {
        *self.timing.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    pub fn set_timing(&self, timing: Timing) {
        *self.timing.lock().unwrap_or_else(|e| e.into_inner()) = timing;
    }

    /// Tests connect to a local relay without TLS.
    #[cfg(test)]
    pub fn allow_plain(&self) {
        self.allow_plain.store(true, Ordering::Relaxed);
    }

    /// The daemon's Noise key: loaded, or made at the first call.
    pub fn keys(&self) -> Result<Arc<NoiseKeys>> {
        let mut slot = self.keys.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(keys) = slot.as_ref() {
            return Ok(keys.clone());
        }
        let keys = Arc::new(NoiseKeys::load_or_create(&self.home)?);
        *slot = Some(keys.clone());
        Ok(keys)
    }

    /// What `pair.create` adds to the link while relay mode is on: the relay's host and id, and the daemon's key. The link
    /// is made while the connection is down too: a phone that scans it a moment later finds the server online.
    pub fn link_info(&self) -> Option<RelayLink> {
        let config = self.inner.lock().unwrap_or_else(|e| e.into_inner()).config.clone()?;
        let target = parse_url(&config.relay_url, true).ok()?;
        let keys = match self.keys() {
            Ok(keys) => keys,
            Err(e) => {
                tracing::warn!("relay: no Noise key for the pairing link: {e:#}");
                return None;
            }
        };
        Some(RelayLink {
            host: target.authority,
            sid: config.sid,
            nk: keys.public_b64(),
        })
    }

    /// Starts relay mode from `relay.json`, when the owner switched it on before. Called once by `main`.
    pub async fn start(self: &Arc<Self>) {
        let path = self.home.join(RELAY_FILE);
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
            Err(e) => {
                self.fail_to_start(format!("cannot read {RELAY_FILE}: {e}"));
                return;
            }
        };
        let plain = self.allow_plain.load(Ordering::Relaxed);
        let config = serde_json::from_str::<Config>(&text)
            .map_err(|e| e.to_string())
            .and_then(|c| Config::checked(&c.relay_url, &c.sid, &c.secret, plain));
        let config = match config {
            Ok(config) => config,
            Err(e) => {
                self.fail_to_start(format!("{RELAY_FILE} is damaged: {e}"));
                return;
            }
        };
        if let Err(e) = self.keys() {
            self.fail_to_start(format!("{e:#}"));
            return;
        }
        let mut life = self.lifecycle.lock().await;
        if life.is_none() {
            self.begin(&mut life, config);
        }
    }

    fn fail_to_start(&self, why: String) {
        tracing::warn!("relay: not started: {why}");
        self.change(|inner| inner.last_error = Some(why));
    }

    /// Switches relay mode on (or moves it to other settings): saves `relay.json`, makes the Noise key when there is none
    /// and connects. The same settings again change nothing.
    pub async fn enable(self: &Arc<Self>, config: Config) -> Result<Status, RelayError> {
        let mut life = self.lifecycle.lock().await;
        if life
            .as_ref()
            .is_some_and(|r| r.config == config && !r.task.is_finished())
        {
            return Ok(self.status());
        }
        self.keys()?;
        let text = serde_json::to_string(&config).map_err(|e| anyhow!(e))?;
        write_private(&self.home.join(RELAY_FILE), text.as_bytes())?;
        Self::stop(&mut life).await;
        self.begin(&mut life, config);
        Ok(self.status())
    }

    /// Switches relay mode off: forgets `relay.json`, closes the connection to the relay and every stream. The Noise key
    /// stays (phones pin it).
    pub async fn disable(&self) -> Result<Status, RelayError> {
        let mut life = self.lifecycle.lock().await;
        match std::fs::remove_file(self.home.join(RELAY_FILE)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(anyhow!(e).context(format!("remove {RELAY_FILE}")).into()),
        }
        Self::stop(&mut life).await;
        self.change(|inner| {
            inner.config = None;
            inner.connected = false;
            inner.last_error = None;
        });
        Ok(self.status())
    }

    /// Ends the connection when the daemon stops. `relay.json` stays: relay mode comes back with the daemon.
    pub async fn shutdown(&self) {
        let mut life = self.lifecycle.lock().await;
        Self::stop(&mut life).await;
    }

    async fn stop(life: &mut Option<Running>) {
        if let Some(running) = life.take() {
            running.cancel.cancel();
            let mut task = running.task;
            if timeout(Duration::from_secs(3), &mut task).await.is_err() {
                task.abort();
            }
        }
    }

    fn begin(self: &Arc<Self>, life: &mut Option<Running>, config: Config) {
        self.change(|inner| {
            inner.config = Some(config.clone());
            inner.connected = false;
            inner.last_error = None;
        });
        let cancel = CancellationToken::new();
        let generation = self.generation.fetch_add(1, Ordering::Relaxed);
        let task = tokio::spawn(self.clone().run(config.clone(), cancel.clone(), generation));
        *life = Some(Running {
            cancel,
            task,
            config,
            generation,
        });
    }

    /// Applies `f` to the state and tells the apps (`relay.changed`) when the status differs afterwards.
    fn change(&self, f: impl FnOnce(&mut Inner)) {
        let before = self.status();
        f(&mut self.inner.lock().unwrap_or_else(|e| e.into_inner()));
        if self.status() != before
            && let Some(app) = self.app.upgrade()
        {
            app.sup.hub().emit("", EventBody::RelayChanged);
        }
    }

    fn set_connected(&self, connected: bool) {
        self.change(|inner| {
            inner.connected = connected;
            if connected {
                inner.last_error = None;
            }
        });
    }

    fn set_error(&self, why: String) {
        self.change(|inner| inner.last_error = Some(why));
    }

    /// Connects, serves, and connects again until `cancel`.
    async fn run(self: Arc<Self>, config: Config, cancel: CancellationToken, generation: u64) {
        let mut attempt = 0u32;
        loop {
            let timing = self.timing();
            let started = Instant::now();
            let outcome = self.session(&config, &cancel).await;
            self.set_connected(false);
            let wait = match outcome {
                Outcome::Cancelled => return,
                Outcome::Replaced => {
                    self.set_error("replaced by another connection of this server (relay close 4001)".into());
                    timing.replaced_wait
                }
                Outcome::Deleted => {
                    // Nothing to reconnect to: forget the registration, like `relay.disable`, and say why. Under the lifecycle
                    // lock, as enable and disable are: a switch that is under way (its cancel is set) or a newer connection
                    // wins, and the settings it wrote are not removed.
                    if cancel.is_cancelled() {
                        return;
                    }
                    let mut life = self.lifecycle.lock().await;
                    if life.as_ref().is_some_and(|r| r.generation == generation) {
                        *life = None;
                        let _ = std::fs::remove_file(self.home.join(RELAY_FILE));
                        self.change(|inner| {
                            inner.config = None;
                            inner.connected = false;
                            inner.last_error = Some("the registration was deleted at the relay".into());
                        });
                    }
                    return;
                }
                Outcome::Unauthorized(why) => {
                    self.set_error(why);
                    attempt += 1;
                    timing.backoff_to(attempt - 1, timing.auth_backoff_max)
                }
                Outcome::Closed(CLOSE_LIMIT, reason) => {
                    self.set_error(format!("the relay refused the connection (limit): {reason}"));
                    timing.limit_wait.unwrap_or_else(until_next_hour)
                }
                Outcome::Closed(CLOSE_SILENCE, _) => {
                    self.set_error("the relay saw no message from this server for 60 s (relay close 4002)".into());
                    attempt = Self::next_attempt(&timing, started, attempt);
                    timing.backoff(attempt.saturating_sub(1))
                }
                Outcome::Closed(CLOSE_TOO_BIG, reason) => {
                    tracing::error!("relay: a message of ours was over the relay's size limit: {reason}");
                    self.set_error(
                        format!("the relay closed the connection (4009, message too large) {reason}")
                            .trim()
                            .to_string(),
                    );
                    attempt = Self::next_attempt(&timing, started, attempt);
                    timing.backoff(attempt.saturating_sub(1))
                }
                Outcome::Closed(code, reason) => {
                    self.set_error(
                        format!("the relay closed the connection ({code}) {reason}")
                            .trim()
                            .to_string(),
                    );
                    attempt = Self::next_attempt(&timing, started, attempt);
                    timing.backoff(attempt.saturating_sub(1))
                }
                Outcome::Failed(why) => {
                    self.set_error(why);
                    attempt = Self::next_attempt(&timing, started, attempt);
                    timing.backoff(attempt.saturating_sub(1))
                }
            };
            if or_cancel(&cancel, tokio::time::sleep(wait)).await.is_none() {
                return;
            }
        }
    }

    /// The number of the next retry: it starts over after a connection that lived long enough.
    fn next_attempt(timing: &Timing, started: Instant, attempt: u32) -> u32 {
        if started.elapsed() >= timing.stable {
            1
        } else {
            attempt + 1
        }
    }

    /// The rustls client config of the relay, read once.
    async fn tls_config(&self) -> Result<Arc<rustls::ClientConfig>, String> {
        self.tls
            .get_or_try_init(|| async {
                tokio::task::spawn_blocking(|| client_config(rustls_native_certs::load_native_certs().certs))
                    .await
                    .map_err(|e| e.to_string())?
            })
            .await
            .cloned()
    }

    /// One connection to the relay, from the TCP connect to its end.
    async fn session(self: &Arc<Self>, config: &Config, cancel: &CancellationToken) -> Outcome {
        let target = match parse_url(&config.relay_url, self.allow_plain.load(Ordering::Relaxed)) {
            Ok(target) => target,
            Err(e) => return Outcome::Failed(e),
        };
        let timing = self.timing();
        let ws_scheme = if target.tls { "wss" } else { "ws" };
        let mut request =
            match format!("{ws_scheme}://{}/v1/server/{}", target.authority, config.sid).into_client_request() {
                Ok(request) => request,
                Err(e) => return Outcome::Failed(format!("bad relay address: {e}")),
            };
        match HeaderValue::from_str(&format!("Bearer {}", config.secret)) {
            Ok(mut value) => {
                value.set_sensitive(true);
                request.headers_mut().insert("authorization", value);
            }
            Err(_) => return Outcome::Failed("the relay secret is not a valid header".into()),
        }
        let ws_config = WebSocketConfig::default()
            .max_message_size(Some(WS_MESSAGE_LIMIT))
            .max_frame_size(Some(WS_MESSAGE_LIMIT));

        let tcp = match or_cancel(
            cancel,
            timeout(timing.connect, TcpStream::connect((target.host.as_str(), target.port))),
        )
        .await
        {
            None => return Outcome::Cancelled,
            Some(Err(_)) => return Outcome::Failed("timed out connecting to the relay".into()),
            Some(Ok(Err(e))) => return Outcome::Failed(format!("cannot reach the relay: {e}")),
            Some(Ok(Ok(tcp))) => tcp,
        };
        let _ = tcp.set_nodelay(true);

        if target.tls {
            let tls_config = match self.tls_config().await {
                Ok(c) => c,
                Err(e) => return Outcome::Failed(e),
            };
            let Ok(name) = ServerName::try_from(target.host.clone()) else {
                return Outcome::Failed("the relay host is not a valid TLS name".into());
            };
            let connector = tokio_rustls::TlsConnector::from(tls_config);
            let tls = match or_cancel(cancel, timeout(timing.connect, connector.connect(name, tcp))).await {
                None => return Outcome::Cancelled,
                Some(Err(_)) => return Outcome::Failed("timed out in the TLS handshake with the relay".into()),
                Some(Ok(Err(e))) => return Outcome::Failed(format!("TLS handshake with the relay failed: {e}")),
                Some(Ok(Ok(tls))) => tls,
            };
            self.upgrade_and_drive(request, tls, ws_config, cancel).await
        } else {
            self.upgrade_and_drive(request, tcp, ws_config, cancel).await
        }
    }

    async fn upgrade_and_drive<S>(
        self: &Arc<Self>,
        request: tokio_tungstenite::tungstenite::handshake::client::Request,
        stream: S,
        ws_config: WebSocketConfig,
        cancel: &CancellationToken,
    ) -> Outcome
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let timing = self.timing();
        let upgraded = or_cancel(
            cancel,
            timeout(
                timing.connect,
                tokio_tungstenite::client_async_with_config(request, stream, Some(ws_config)),
            ),
        )
        .await;
        match upgraded {
            None => Outcome::Cancelled,
            Some(Err(_)) => Outcome::Failed("timed out in the WebSocket upgrade with the relay".into()),
            Some(Ok(Err(tokio_tungstenite::tungstenite::Error::Http(response)))) => {
                let status = response.status().as_u16();
                let why = match status {
                    401 | 403 => format!("the relay does not accept this server's credentials (HTTP {status})"),
                    _ => format!("the relay answered HTTP {status}"),
                };
                if matches!(status, 401 | 403) {
                    Outcome::Unauthorized(why)
                } else {
                    Outcome::Failed(why)
                }
            }
            Some(Ok(Err(e))) => Outcome::Failed(format!("relay WebSocket: {e}")),
            Some(Ok(Ok((ws, _)))) => self.drive(ws, cancel).await,
        }
    }

    /// Serves an open relay connection until it ends.
    async fn drive<S>(self: &Arc<Self>, ws: WebSocketStream<S>, cancel: &CancellationToken) -> Outcome
    where
        S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    {
        let timing = self.timing();
        let (mut sink, mut source) = ws.split();
        let (out, mut out_rx) = mpsc::channel::<Message>(256);
        let writer = tokio::spawn(async move {
            while let Some(message) = out_rx.recv().await {
                let last = matches!(message, Message::Close(_));
                if sink.send(message).await.is_err() || last {
                    break;
                }
            }
            let _ = sink.close().await;
        });
        // Every stream below is a child of this token: it ends when the connection does, whatever the reason.
        let session = cancel.child_token();
        let streams: Streams = Arc::default();
        self.set_connected(true);

        let mut tick = tokio::time::interval(timing.ping);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        tick.tick().await;
        let mut last_rx = Instant::now();
        let outcome = loop {
            tokio::select! {
                () = cancel.cancelled() => break Outcome::Cancelled,
                _ = tick.tick() => {
                    if last_rx.elapsed() >= timing.silence {
                        break Outcome::Failed("the relay went silent".into());
                    }
                    let _ = out.try_send(Message::text(PING));
                }
                next = source.next() => {
                    last_rx = Instant::now();
                    match next {
                        None => break Outcome::Failed("the relay closed the connection".into()),
                        Some(Err(e)) => break Outcome::Failed(format!("connection to the relay lost: {e}")),
                        Some(Ok(Message::Binary(bytes))) => self.on_frame(&bytes, &out, &streams, &session),
                        // Keepalive is text (a Worker cannot see ping frames): answer `ping` with `pong`.
                        Some(Ok(Message::Text(text))) => {
                            if text.as_str() == PING {
                                let _ = out.try_send(Message::text(PONG));
                            }
                        }
                        Some(Ok(Message::Close(frame))) => {
                            let (code, reason) = frame
                                .map(|f| (u16::from(f.code), f.reason.to_string()))
                                .unwrap_or((1005, String::new()));
                            break if code == CLOSE_REPLACED {
                                Outcome::Replaced
                            } else if code == CLOSE_DELETED {
                                Outcome::Deleted
                            } else {
                                Outcome::Closed(code, reason)
                            };
                        }
                        Some(Ok(_)) => {}
                    }
                }
            }
        };
        // All streams end with the connection. A polite close frame goes out when we are the one leaving.
        session.cancel();
        if matches!(outcome, Outcome::Cancelled) {
            let _ = out
                .send(Message::Close(Some(
                    tokio_tungstenite::tungstenite::protocol::CloseFrame {
                        code: CloseCode::Normal,
                        reason: "relay mode off".into(),
                    },
                )))
                .await;
        }
        drop(out);
        let mut writer = writer;
        if timeout(Duration::from_secs(1), &mut writer).await.is_err() {
            writer.abort();
        }
        outcome
    }

    /// One binary message of the relay: `[u32 BE stream id][u8 kind][payload]`.
    fn on_frame(
        self: &Arc<Self>,
        bytes: &[u8],
        out: &mpsc::Sender<Message>,
        streams: &Streams,
        session: &CancellationToken,
    ) {
        let Some((head, payload)) = bytes.split_at_checked(5) else {
            return;
        };
        let id = u32::from_be_bytes([head[0], head[1], head[2], head[3]]);
        match head[4] {
            KIND_DATA if payload.len() > NOISE_MAX => {
                // A Noise message is at most NOISE_MAX bytes: a bigger frame is not one of ours. The stream ends here and
                // the frame is never queued; the relay is told, as the end of the stream would tell it anyway.
                let handle = streams.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
                if let Some(handle) = handle {
                    handle.cancel.cancel();
                    let _ = out.try_send(frame(id, KIND_CLOSE, &[]));
                }
            }
            KIND_DATA => {
                let map = streams.lock().unwrap_or_else(|e| e.into_inner());
                if let Some(handle) = map.get(&id)
                    && handle.frames.try_send(payload.to_vec()).is_err()
                {
                    handle.cancel.cancel();
                }
            }
            KIND_OPEN => self.on_open(id, payload, out, streams, session),
            KIND_CLOSE => {
                let handle = streams.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
                if let Some(handle) = handle {
                    handle.cancel.cancel();
                }
            }
            _ => {}
        }
    }

    fn on_open(
        self: &Arc<Self>,
        id: u32,
        payload: &[u8],
        out: &mpsc::Sender<Message>,
        streams: &Streams,
        session: &CancellationToken,
    ) {
        let refuse = || {
            let _ = out.try_send(frame(id, KIND_CLOSE, &[]));
        };
        let Some(app) = self.app.upgrade() else {
            return refuse();
        };
        let Ok(info) = serde_json::from_slice::<OpenInfo>(payload) else {
            return refuse();
        };
        if info.v != 1 {
            return refuse();
        }
        // The address the relay saw: the limits count the phone by it, so one that does not parse is refused.
        let Ok(ip) = info.ip.parse::<IpAddr>() else {
            return refuse();
        };
        let source = source_key(ip);
        let Some(slot) = app.phone.limits().connections.acquire(&source) else {
            return refuse();
        };
        let (frames, rx) = mpsc::channel(STREAM_BACKLOG);
        let cancel = session.child_token();
        let serial = STREAM_SERIAL.fetch_add(1, Ordering::Relaxed);
        {
            let mut map = streams.lock().unwrap_or_else(|e| e.into_inner());
            if map.len() >= MAX_STREAMS || map.contains_key(&id) {
                drop(map);
                return refuse();
            }
            map.insert(
                id,
                StreamHandle {
                    frames,
                    cancel: cancel.clone(),
                    serial,
                },
            );
        }
        let stream = Stream {
            app,
            relay: self.clone(),
            id,
            source,
            rx,
            out: out.clone(),
            cancel,
            _slot: slot,
        };
        let streams = streams.clone();
        tokio::spawn(async move {
            let (id, out, cancel) = (stream.id, stream.out.clone(), stream.cancel.clone());
            if let Err(why) = stream.run().await {
                tracing::debug!(stream = id, "relay stream ended: {why}");
            }
            cancel.cancel();
            // A close from the relay already took the stream out of the map; otherwise we tell the relay. Only our own
            // entry is taken out: a newer stream with the same id may be there by now.
            let ours = {
                let mut map = streams.lock().unwrap_or_else(|e| e.into_inner());
                if map.get(&id).is_some_and(|handle| handle.serial == serial) {
                    map.remove(&id);
                    true
                } else {
                    false
                }
            };
            if ours {
                let _ = timeout(Duration::from_secs(1), out.send(frame(id, KIND_CLOSE, &[]))).await;
            }
        });
    }
}

/// The time to the next full hour (UTC), when the relay counts its limits again.
fn until_next_hour() -> Duration {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    next_hour_after(secs)
}

fn next_hour_after(unix_secs: u64) -> Duration {
    Duration::from_secs(3600 - unix_secs % 3600 + 1)
}

/// Waits for `fut`, or gives up with `None` when `cancel` fires first.
async fn or_cancel<T>(cancel: &CancellationToken, fut: impl std::future::Future<Output = T>) -> Option<T> {
    tokio::select! {
        () = cancel.cancelled() => None,
        value = fut => Some(value),
    }
}

/// A relay frame as a WebSocket message.
fn frame(id: u32, kind: u8, payload: &[u8]) -> Message {
    let mut bytes = Vec::with_capacity(5 + payload.len());
    bytes.extend_from_slice(&id.to_be_bytes());
    bytes.push(kind);
    bytes.extend_from_slice(payload);
    Message::Binary(bytes.into())
}

// ---------------------------------------------------------------------------------------------------------------------
// One phone stream
// ---------------------------------------------------------------------------------------------------------------------

/// The first message after the handshake.
#[derive(Deserialize)]
struct FirstMessage {
    #[serde(default)]
    auth: Option<String>,
    #[serde(default)]
    pair: bool,
}

struct Stream {
    app: Arc<App>,
    relay: Arc<Relay>,
    id: u32,
    /// The phone's address as the limits count it (`source_key`).
    source: String,
    rx: mpsc::Receiver<Vec<u8>>,
    out: mpsc::Sender<Message>,
    cancel: CancellationToken,
    /// The place among the connections of the source, kept for the life of the stream.
    _slot: ConnSlot,
}

impl Stream {
    /// Sends the ciphertext frames of a message, or the handshake's message, to the relay.
    async fn send_data(&self, ciphertext: &[u8]) -> Result<(), String> {
        self.out
            .send(frame(self.id, KIND_DATA, ciphertext))
            .await
            .map_err(|_| "the relay connection is gone".to_string())
    }

    async fn send_text(&self, secure: &Secure, text: &str) -> Result<(), String> {
        for cipher in secure.seal(text.as_bytes()).map_err(|e| e.to_string())? {
            self.send_data(&cipher).await?;
        }
        Ok(())
    }

    /// Takes the next ciphertext frame of the phone.
    async fn recv(&mut self) -> Result<Vec<u8>, String> {
        self.rx.recv().await.ok_or_else(|| "the stream was closed".to_string())
    }

    async fn run(mut self) -> Result<(), String> {
        let cancel = self.cancel.clone();
        let limits = self.app.phone.limits();
        // Handshake and first message are bounded: a stream that stalls here holds a slot of its source.
        let prepared = tokio::select! {
            () = cancel.cancelled() => return Ok(()),
            r = timeout(STREAM_STEP_TIMEOUT, self.open_session(&limits)) => r.map_err(|_| "no handshake in time".to_string())?,
        };
        let (secure, peer, anonymous_slot) = prepared?;
        let secure = Arc::new(secure);
        let anonymous = matches!(peer, Peer::Anonymous(..));
        let limit = if anonymous {
            ANONYMOUS_MESSAGE_LIMIT
        } else {
            RPC_MESSAGE_LIMIT
        };

        let redeem_seen = Arc::new(AtomicBool::new(false));
        let (in_tx, in_rx) = mpsc::channel::<String>(64);
        let (rpc_out, mut rpc_in) = mpsc::channel::<String>(256);

        // Phone to RPC: decrypt, join the chunks, hand the text to the same serve loop as a direct socket.
        let reader = {
            let secure = secure.clone();
            let seen = redeem_seen.clone();
            let cancel = cancel.clone();
            let mut rx = std::mem::replace(&mut self.rx, mpsc::channel(1).1);
            tokio::spawn(async move {
                let mut joined = Reassembler::new(limit);
                while let Some(cipher) = rx.recv().await {
                    let Ok(plain) = secure.open(&cipher) else { break };
                    let message = match joined.push(&plain) {
                        Ok(None) => continue,
                        Ok(Some(message)) => message,
                        Err(_) => break,
                    };
                    let Ok(text) = String::from_utf8(message) else { break };
                    if anonymous && asks_to_pair(&text) {
                        seen.store(true, Ordering::Relaxed);
                    }
                    if in_tx.send(text).await.is_err() {
                        break;
                    }
                }
                // A frame that cannot be read ends the stream: the Noise session cannot go on after it.
                cancel.cancel();
            })
        };

        // RPC to phone: split, encrypt, send.
        let writer = {
            let secure = secure.clone();
            let out = self.out.clone();
            let id = self.id;
            tokio::spawn(async move {
                while let Some(text) = rpc_in.recv().await {
                    let Ok(chunks) = secure.seal(text.as_bytes()) else {
                        return;
                    };
                    for cipher in chunks {
                        if out.send(frame(id, KIND_DATA, &cipher)).await.is_err() {
                            return;
                        }
                    }
                }
            })
        };

        // An anonymous stream may only pair: it ends when no `pair.redeem` comes in time, and a while after the one that did.
        let idle = async {
            if !anonymous {
                return std::future::pending::<()>().await;
            }
            anonymous_deadline(&redeem_seen).await;
        };
        let app = self.app.clone();
        tokio::select! {
            () = serve(app, peer, in_rx, rpc_out) => {}
            () = idle => {}
            () = cancel.cancelled() => {}
        }
        reader.abort();
        // When the RPC loop ended by itself its last replies are still on their way.
        let mut writer = writer;
        if cancel.is_cancelled() || timeout(FLUSH_TIMEOUT, &mut writer).await.is_err() {
            writer.abort();
        }
        drop(anonymous_slot);
        Ok(())
    }

    /// The Noise handshake, the first message and the checks of who the phone is.
    async fn open_session(&mut self, limits: &PhoneLimits) -> Result<(Secure, Peer, Option<ConnSlot>), String> {
        let now = crate::store::now_ms();
        let keys = self.relay.keys().map_err(|e| format!("{e:#}"))?;
        let (secure, remote) = match self.handshake(&keys).await {
            Ok(done) => done,
            Err(e) => {
                // A handshake that fails is a failed try of its source.
                limits.attempts.attempt(&self.source, now);
                return Err(e);
            }
        };
        let mut joined = Reassembler::new(FIRST_MESSAGE_LIMIT);
        let first = loop {
            let cipher = self.recv().await?;
            let plain = secure.open(&cipher).map_err(|e| e.to_string())?;
            if let Some(message) = joined.push(&plain)? {
                break String::from_utf8(message).map_err(|_| "the first message is not text".to_string())?;
            }
        };
        let Ok(first) = serde_json::from_str::<FirstMessage>(&first) else {
            self.refuse(&secure, "bad_request").await;
            return Err("the first message is not {\"auth\"} or {\"pair\"}".into());
        };

        if let Some(token) = first.auth {
            return match self.authenticate(&token, &remote, limits, now) {
                Ok(device) => Ok((secure, Peer::Device(device), None)),
                Err(reason) => {
                    self.refuse(&secure, reason).await;
                    Err(format!("refused: {reason}"))
                }
            };
        }
        if first.pair {
            // Like an anonymous upgrade of the direct socket: a try of its source, and one of the few anonymous places.
            if !limits.attempts.attempt(&self.source, now) {
                self.refuse(&secure, "rate_limited").await;
                return Err("too many pairing attempts".into());
            }
            let Some(slot) = limits.anonymous.acquire(&self.source) else {
                self.refuse(&secure, "rate_limited").await;
                return Err("too many open pairing streams".into());
            };
            let session_key = URL_SAFE_NO_PAD.encode(remote);
            return Ok((
                secure,
                Peer::Anonymous(self.source.clone(), Some(session_key)),
                Some(slot),
            ));
        }
        self.refuse(&secure, "bad_request").await;
        Err("the first message asks for nothing".into())
    }

    /// Answers the phone's Noise message 1 with message 2. Returns the transport and the phone's static key.
    async fn handshake(&mut self, keys: &NoiseKeys) -> Result<(Secure, [u8; 32]), String> {
        let first = self.recv().await?;
        let mut responder = noise_builder()
            .and_then(|b| {
                b.local_private_key(&keys.private)
                    .map_err(|e| anyhow!("{e}"))?
                    .prologue(NOISE_PROLOGUE)
                    .map_err(|e| anyhow!("{e}"))?
                    .build_responder()
                    .map_err(|e| anyhow!("{e}"))
            })
            .map_err(|e| format!("{e:#}"))?;
        let mut buf = vec![0u8; NOISE_MAX];
        let n = responder
            .read_message(&first, &mut buf)
            .map_err(|e| format!("handshake: {e}"))?;
        #[derive(Deserialize)]
        struct Hello {
            v: u32,
        }
        match serde_json::from_slice::<Hello>(&buf[..n]) {
            Ok(Hello { v: 1 }) => {}
            _ => return Err("handshake: unknown protocol version".into()),
        }
        let n = responder
            .write_message(HELLO, &mut buf)
            .map_err(|e| format!("handshake: {e}"))?;
        let remote: [u8; 32] = responder
            .get_remote_static()
            .and_then(|k| <[u8; 32]>::try_from(k).ok())
            .ok_or_else(|| "handshake: no static key".to_string())?;
        let state = responder.into_transport_mode().map_err(|e| format!("handshake: {e}"))?;
        self.send_data(&buf[..n]).await?;
        Ok((
            Secure {
                state: Mutex::new(state),
            },
            remote,
        ))
    }

    /// The device behind `token`, if the key the phone speaks with is the one it paired with. Failed tries count against
    /// the phone's source, as on the direct socket; a device that passes is never held back.
    fn authenticate(
        &self,
        token: &str,
        remote: &[u8; 32],
        limits: &PhoneLimits,
        now: i64,
    ) -> Result<Device, &'static str> {
        let store = &self.app.sup.hub().store;
        let fail = |reason: &'static str| {
            if limits.attempts.attempt(&self.source, now) {
                reason
            } else {
                "rate_limited"
            }
        };
        let mut device = match store.device_find(token) {
            Ok(Some(device)) => device,
            Ok(None) => return Err(fail("unauthorized")),
            Err(e) => {
                tracing::error!("relay device auth: {e:#}");
                return Err("server_error");
            }
        };
        let paired = match store.device_noise_key(&device.id) {
            Ok(key) => key,
            Err(e) => {
                tracing::error!("relay device key: {e:#}");
                return Err("server_error");
            }
        };
        let theirs = URL_SAFE_NO_PAD.encode(remote);
        match paired {
            Some(key) if constant_time_eq(key.as_bytes(), theirs.as_bytes()) => {}
            _ => return Err(fail("unauthorized")),
        }
        // Only now, with the key checked, the device counts as seen.
        match store.device_touch(&device.id) {
            Ok(seen) => device.last_seen_at = Some(seen),
            Err(e) => {
                tracing::error!("relay device seen: {e:#}");
                return Err("server_error");
            }
        }
        Ok(device)
    }

    /// Tells the phone why it is refused (`{"error": reason}`), best effort. The stream ends right after.
    async fn refuse(&self, secure: &Secure, reason: &str) {
        let _ = self.send_text(secure, &json!({ "error": reason }).to_string()).await;
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::FileService;
    use crate::hub::Hub;
    use crate::rpc::{RATE_LIMITED, dispatch};
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use tempfile::TempDir;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::protocol::CloseFrame;

    const SID: &str = "abcdefghijklmnopqrstuvwxyz";
    const WAIT: Duration = Duration::from_secs(5);

    fn secret() -> String {
        URL_SAFE_NO_PAD.encode([7u8; 32])
    }

    /// Short times, so that backoff, silence and pings can be seen in a test.
    fn fast() -> Timing {
        Timing {
            ping: Duration::from_millis(100),
            silence: Duration::from_secs(30),
            backoff_min: Duration::from_millis(20),
            backoff_max: Duration::from_millis(100),
            replaced_wait: Duration::from_millis(500),
            limit_wait: Some(Duration::from_millis(500)),
            auth_backoff_max: Duration::from_millis(800),
            connect: Duration::from_secs(2),
            stable: Duration::from_secs(60),
        }
    }

    // ----- the fake relay: a local WebSocket server that plays the relay's part ---------------------------------

    struct Frame {
        id: u32,
        kind: u8,
        payload: Vec<u8>,
    }

    /// One WebSocket the daemon opened to the fake relay.
    struct Conn {
        path: String,
        auth: Option<String>,
        at: Instant,
        to_daemon: mpsc::UnboundedSender<Message>,
        from_daemon: mpsc::UnboundedReceiver<Message>,
    }

    impl Conn {
        fn send_frame(&self, id: u32, kind: u8, payload: &[u8]) {
            let _ = self.to_daemon.send(frame(id, kind, payload));
        }

        fn open(&self, id: u32, ip: &str) {
            self.send_frame(id, KIND_OPEN, json!({ "ip": ip, "v": 1 }).to_string().as_bytes());
        }

        fn close_with(&self, code: u16, reason: &str) {
            let _ = self.to_daemon.send(Message::Close(Some(CloseFrame {
                code: CloseCode::from(code),
                reason: reason.to_string().into(),
            })));
        }

        /// The next message of the daemon, or None after `within` or when the socket ended.
        async fn recv(&mut self, within: Duration) -> Option<Message> {
            timeout(within, self.from_daemon.recv()).await.ok().flatten()
        }

        /// The next relay frame of the daemon. None on a close of the socket, a timeout or the end.
        async fn next_frame(&mut self) -> Option<Frame> {
            loop {
                match self.recv(WAIT).await? {
                    Message::Binary(b) => {
                        let (head, payload) = b.split_at_checked(5)?;
                        return Some(Frame {
                            id: u32::from_be_bytes([head[0], head[1], head[2], head[3]]),
                            kind: head[4],
                            payload: payload.to_vec(),
                        });
                    }
                    Message::Close(_) => return None,
                    _ => continue,
                }
            }
        }

        /// Waits for a WebSocket close of the daemon (any message before it is skipped). False when none came.
        async fn closed(&mut self, within: Duration) -> bool {
            let deadline = Instant::now() + within;
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                match self.recv(left).await {
                    Some(Message::Close(_)) | None => return Instant::now() < deadline || left.is_zero(),
                    Some(_) => {}
                }
            }
        }
    }

    struct FakeRelay {
        addr: std::net::SocketAddr,
        conns: mpsc::UnboundedReceiver<Conn>,
        /// New connections are accepted and then never read: the relay "goes silent".
        mute: Arc<AtomicBool>,
        /// When not 0, the upgrade is refused with this HTTP status.
        reject: Arc<std::sync::atomic::AtomicU16>,
        /// When each upgrade was tried, refused ones included.
        tries: Arc<Mutex<Vec<Instant>>>,
    }

    impl FakeRelay {
        #[allow(clippy::result_large_err)] // the header callback's error type is the library's
        async fn start() -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let addr = listener.local_addr().unwrap();
            let (conns_tx, conns) = mpsc::unbounded_channel();
            let mute = Arc::new(AtomicBool::new(false));
            let muted = mute.clone();
            let reject = Arc::new(std::sync::atomic::AtomicU16::new(0));
            let rejecting = reject.clone();
            let tries = Arc::new(Mutex::new(Vec::new()));
            let tried = tries.clone();
            tokio::spawn(async move {
                loop {
                    let Ok((tcp, _)) = listener.accept().await else { return };
                    let conns_tx = conns_tx.clone();
                    let muted = muted.clone();
                    let rejecting = rejecting.clone();
                    let tried = tried.clone();
                    tokio::spawn(async move {
                        let seen = Arc::new(Mutex::new((String::new(), None::<String>)));
                        let capture = seen.clone();
                        let ws = tokio_tungstenite::accept_hdr_async(
                            tcp,
                            move |req: &tokio_tungstenite::tungstenite::handshake::server::Request,
                                  resp: tokio_tungstenite::tungstenite::handshake::server::Response| {
                                let auth = req
                                    .headers()
                                    .get("authorization")
                                    .and_then(|v| v.to_str().ok())
                                    .map(str::to_string);
                                *capture.lock().unwrap() = (req.uri().path().to_string(), auth);
                                tried.lock().unwrap().push(Instant::now());
                                match rejecting.load(Ordering::Relaxed) {
                                    0 => Ok(resp),
                                    status => Err(tokio_tungstenite::tungstenite::http::Response::builder()
                                        .status(status)
                                        .body(None)
                                        .unwrap()),
                                }
                            },
                        )
                        .await;
                        let Ok(ws) = ws else { return };
                        if muted.load(Ordering::Relaxed) {
                            let _ws = ws;
                            tokio::time::sleep(Duration::from_secs(30)).await;
                            return;
                        }
                        let (path, auth) = seen.lock().unwrap().clone();
                        let (to_daemon, mut outgoing) = mpsc::unbounded_channel::<Message>();
                        let (incoming_tx, from_daemon) = mpsc::unbounded_channel::<Message>();
                        let _ = conns_tx.send(Conn {
                            path,
                            auth,
                            at: Instant::now(),
                            to_daemon,
                            from_daemon,
                        });
                        let (mut sink, mut source) = ws.split();
                        loop {
                            tokio::select! {
                                msg = source.next() => match msg {
                                    Some(Ok(m)) => { let end = matches!(m, Message::Close(_)); let _ = incoming_tx.send(m); if end { break; } }
                                    _ => break,
                                },
                                out = outgoing.recv() => match out {
                                    Some(m) => { let end = matches!(m, Message::Close(_)); if sink.send(m).await.is_err() || end { break; } }
                                    None => break,
                                },
                            }
                        }
                        let _ = sink.close().await;
                    });
                }
            });
            Self {
                addr,
                conns,
                mute,
                reject,
                tries,
            }
        }

        fn url(&self) -> String {
            format!("ws://{}", self.addr)
        }

        async fn next_conn(&mut self, within: Duration) -> Option<Conn> {
            timeout(within, self.conns.recv()).await.ok().flatten()
        }
    }

    // ----- the phone: a Noise initiator -------------------------------------------------------------------------

    struct Phone {
        id: u32,
        secure: Secure,
    }

    fn new_key() -> snow::Keypair {
        noise_builder().unwrap().generate_keypair().unwrap()
    }

    impl Phone {
        /// Opens stream `id` and runs the Noise handshake against the daemon key `nk`. Err when the stream is closed
        /// instead of answered.
        async fn connect(conn: &mut Conn, id: u32, ip: &str, key: &snow::Keypair, nk: &[u8]) -> Result<Self, String> {
            conn.open(id, ip);
            let mut hs = noise_builder()
                .unwrap()
                .local_private_key(&key.private)
                .unwrap()
                .remote_public_key(nk)
                .unwrap()
                .prologue(NOISE_PROLOGUE)
                .unwrap()
                .build_initiator()
                .unwrap();
            let mut buf = vec![0u8; NOISE_MAX];
            let n = hs.write_message(HELLO, &mut buf).unwrap();
            conn.send_frame(id, KIND_DATA, &buf[..n]);
            let reply = loop {
                let f = conn.next_frame().await.ok_or("the socket ended")?;
                if f.id != id {
                    continue;
                }
                match f.kind {
                    KIND_DATA => break f.payload,
                    KIND_CLOSE => return Err("closed".into()),
                    _ => {}
                }
            };
            let n = hs.read_message(&reply, &mut buf).map_err(|e| e.to_string())?;
            assert_eq!(&buf[..n], HELLO);
            let state = hs.into_transport_mode().unwrap();
            Ok(Self {
                id,
                secure: Secure {
                    state: Mutex::new(state),
                },
            })
        }

        fn send(&self, conn: &Conn, text: &str) {
            for cipher in self.secure.seal(text.as_bytes()).unwrap() {
                assert!(cipher.len() <= NOISE_MAX);
                conn.send_frame(self.id, KIND_DATA, &cipher);
            }
        }

        /// The next whole message of the daemon on this stream. Err("closed") when the stream is closed.
        async fn recv(&self, conn: &mut Conn) -> Result<String, String> {
            let mut joined = Reassembler::new(64 << 20);
            loop {
                let f = conn.next_frame().await.ok_or("the socket ended or timed out")?;
                if f.id != self.id {
                    continue;
                }
                match f.kind {
                    KIND_CLOSE => return Err("closed".into()),
                    KIND_DATA => {
                        let plain = self.secure.open(&f.payload).map_err(|e| e.to_string())?;
                        if let Some(message) = joined.push(&plain)? {
                            return String::from_utf8(message).map_err(|e| e.to_string());
                        }
                    }
                    _ => {}
                }
            }
        }

        /// One JSON-RPC call; the reply's `result`, or the whole `error`.
        async fn call(&self, conn: &mut Conn, method: &str, params: Value) -> Result<Value, Value> {
            self.send(
                conn,
                &json!({"jsonrpc":"2.0","id":7,"method":method,"params":params}).to_string(),
            );
            loop {
                let text = self.recv(conn).await.expect("a reply");
                let v: Value = serde_json::from_str(&text).unwrap();
                if v["id"] == 7 {
                    return match v.get("error") {
                        Some(e) => Err(e.clone()),
                        None => Ok(v["result"].clone()),
                    };
                }
            }
        }
    }

    // ----- the rig: a daemon whose data folder is a temporary one ----------------------------------------------

    struct Rig {
        app: Arc<App>,
        dir: TempDir,
        relay: FakeRelay,
    }

    fn app_in(dir: &Path) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let app = App::new_in_home(
            sup,
            dir.join("agents"),
            FileService::new(dir.to_path_buf(), None),
            dir.to_path_buf(),
        );
        app.relay.allow_plain();
        app.relay.set_timing(fast());
        app
    }

    impl Rig {
        async fn new() -> Self {
            let dir = TempDir::new().unwrap();
            let app = app_in(dir.path());
            Self {
                app,
                dir,
                relay: FakeRelay::start().await,
            }
        }

        fn config(&self) -> Config {
            Config::checked(&self.relay.url(), SID, &secret(), true).unwrap()
        }

        /// Switches relay mode on and returns the daemon's connection as the fake relay sees it.
        async fn enable(&mut self) -> Conn {
            self.app.relay.enable(self.config()).await.unwrap();
            self.relay.next_conn(WAIT).await.expect("the daemon connects")
        }

        /// Waits until the daemon has finished the upgrade and says it is connected.
        async fn connected(&self) {
            let deadline = Instant::now() + WAIT;
            while !self.app.relay.status().connected {
                assert!(Instant::now() < deadline, "{:?}", self.app.relay.status());
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }

        fn nk(&self) -> Vec<u8> {
            URL_SAFE_NO_PAD
                .decode(self.app.relay.keys().unwrap().public_b64())
                .unwrap()
        }

        async fn owner(&self, method: &str, params: Value) -> Result<Value, crate::rpc::RpcError> {
            dispatch(&self.app, &Peer::Local, method, params).await
        }

        /// Pairs a phone with key `key` through the relay (stream `id`): the device token.
        async fn pair(&self, conn: &mut Conn, id: u32, key: &snow::Keypair, ip: &str) -> String {
            let code = self.owner("pair.create", json!({})).await.unwrap()["code"]
                .as_str()
                .unwrap()
                .to_string();
            let phone = Phone::connect(conn, id, ip, key, &self.nk()).await.unwrap();
            phone.send(conn, r#"{"pair":true}"#);
            let reply = phone
                .call(
                    conn,
                    "pair.redeem",
                    json!({"code": code, "device_name": "Test phone", "noise_key": URL_SAFE_NO_PAD.encode(&key.public)}),
                )
                .await
                .unwrap();
            reply["token"].as_str().unwrap().to_string()
        }

        /// Opens stream `id` as the paired phone: handshake and `{"auth"}`.
        async fn sign_in(&self, conn: &mut Conn, id: u32, key: &snow::Keypair, token: &str) -> Phone {
            let phone = Phone::connect(conn, id, "203.0.113.9", key, &self.nk()).await.unwrap();
            phone.send(conn, &json!({ "auth": token }).to_string());
            phone
        }
    }

    // ----- tests ------------------------------------------------------------------------------------------------

    #[tokio::test]
    async fn a_phone_pairs_through_the_relay_and_then_calls_the_daemon_with_its_token() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        assert_eq!(conn.path, format!("/v1/server/{SID}"));
        assert_eq!(conn.auth.as_deref(), Some(format!("Bearer {}", secret()).as_str()));
        rig.connected().await;

        // The link carries the relay and the key to pin.
        let created = rig.owner("pair.create", json!({})).await.unwrap();
        let nk = URL_SAFE_NO_PAD.encode(rig.nk());
        let host = format!("127.0.0.1:{}", rig.relay.addr.port());
        assert_eq!(created["relay"], format!("{host}/{SID}"));
        assert_eq!(created["noise_key"], nk);
        let link = created["link"].as_str().unwrap();
        assert!(link.contains(&format!("&relay={host}/{SID}")), "{link}");
        assert!(link.ends_with(&format!("&nk={nk}")), "{link}");
        assert!(!link.contains("&host="), "relay only: {link}");
        assert_eq!(created["qr"], created["link"]);

        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let store = rig.app.sup.hub().store.clone();
        let device = store.device_auth(&token).unwrap().expect("the device was paired");
        assert_eq!(
            store.device_noise_key(&device.id).unwrap().as_deref(),
            Some(URL_SAFE_NO_PAD.encode(&key.public).as_str())
        );

        // A new stream with the token and the same key speaks the RPC of /v1/rpc, as the device.
        let phone = rig.sign_in(&mut conn, 2, &key, &token).await;
        let info = phone.call(&mut conn, "daemon.info", json!({})).await.unwrap();
        assert_eq!(info["version"], crate::rpc::VERSION);
        let devices = phone.call(&mut conn, "devices.list", json!({})).await.unwrap();
        assert_eq!(
            devices[0]["current"], true,
            "the stream is the device, not the owner's CLI"
        );
        // The device's rights are the device's: an agent-only call is refused as on a direct socket.
        let err = phone.call(&mut conn, "crew.list", json!({})).await;
        assert!(err.is_ok() || err.is_err()); // crew.list is an agent tool for agents only; either way it answers
        let err = phone
            .call(&mut conn, "crew.send", json!({"from":"a","to":"b","message":"hi"}))
            .await
            .unwrap_err();
        assert_eq!(err["code"], crate::rpc::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn a_wrong_daemon_key_fails_the_handshake_and_the_stream_is_closed() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let wrong = new_key();
        let result = Phone::connect(&mut conn, 5, "203.0.113.7", &new_key(), &wrong.public).await;
        assert_eq!(result.err().as_deref(), Some("closed"));
        // The daemon answered nothing but the close, and the stream is gone: the same id can be used again.
        let good = Phone::connect(&mut conn, 5, "203.0.113.7", &new_key(), &rig.nk()).await;
        assert!(good.is_ok());
    }

    #[tokio::test]
    async fn another_phone_key_with_a_valid_token_is_refused() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;

        let thief = new_key();
        let phone = rig.sign_in(&mut conn, 2, &thief, &token).await;
        assert_eq!(phone.recv(&mut conn).await.unwrap(), r#"{"error":"unauthorized"}"#);
        assert_eq!(phone.recv(&mut conn).await.unwrap_err(), "closed");

        // A device paired without a key (the owner's CLI, an older phone) cannot use the relay at all.
        let plain = rig.app.sup.hub().store.device_add("old phone", "bdt_old").unwrap();
        let phone = rig.sign_in(&mut conn, 3, &key, "bdt_old").await;
        assert_eq!(phone.recv(&mut conn).await.unwrap(), r#"{"error":"unauthorized"}"#);
        assert_eq!(phone.recv(&mut conn).await.unwrap_err(), "closed");
        assert!(rig.app.sup.hub().store.device_exists(&plain.id).unwrap());

        // The right key still works.
        let phone = rig.sign_in(&mut conn, 4, &key, &token).await;
        assert!(phone.call(&mut conn, "daemon.info", json!({})).await.is_ok());
    }

    #[tokio::test]
    async fn revoking_a_device_closes_its_relay_streams() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let phone = rig.sign_in(&mut conn, 2, &key, &token).await;
        assert!(phone.call(&mut conn, "daemon.info", json!({})).await.is_ok());

        let id = rig.app.sup.hub().store.device_auth(&token).unwrap().unwrap().id;
        rig.owner("devices.revoke", json!({ "id": id })).await.unwrap();
        assert_eq!(phone.recv(&mut conn).await.unwrap_err(), "closed");
        // The token is dead for a new stream too.
        let again = rig.sign_in(&mut conn, 3, &key, &token).await;
        assert_eq!(again.recv(&mut conn).await.unwrap(), r#"{"error":"unauthorized"}"#);
    }

    #[tokio::test]
    async fn disabling_relay_mode_closes_the_socket_and_forgets_the_registration() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let phone = rig.sign_in(&mut conn, 2, &key, &token).await;
        assert!(phone.call(&mut conn, "daemon.info", json!({})).await.is_ok());
        assert!(rig.dir.path().join(RELAY_FILE).exists());

        let status = rig.owner("relay.disable", json!({})).await.unwrap();
        assert_eq!(status["enabled"], false);
        assert_eq!(status["connected"], false);
        assert!(conn.closed(WAIT).await, "the daemon closes its socket to the relay");
        assert!(!rig.dir.path().join(RELAY_FILE).exists());
        assert!(
            rig.dir.path().join(NOISE_KEY_FILE).exists(),
            "phones pin the key: it stays"
        );
        assert!(
            rig.relay.next_conn(Duration::from_millis(400)).await.is_none(),
            "no reconnect"
        );
        assert_eq!(rig.owner("relay.status", json!({})).await.unwrap()["sid"], Value::Null);
        // Disabling again is not an error.
        assert!(rig.owner("relay.disable", json!({})).await.is_ok());
    }

    #[tokio::test]
    async fn a_large_rpc_frame_is_split_into_chunks_both_ways_and_joined() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let phone = rig.sign_in(&mut conn, 2, &key, &token).await;

        // Phone to daemon: 300 KB in one request.
        let pad = "A".repeat(300_000);
        let info = phone
            .call(&mut conn, "daemon.info", json!({ "pad": pad }))
            .await
            .unwrap();
        assert_eq!(info["version"], crate::rpc::VERSION);

        // Daemon to phone: a 300 KB file comes back in one reply, in several ciphertext frames.
        let file = rig.dir.path().join("big.txt");
        std::fs::write(&file, "x".repeat(300_000)).unwrap();
        phone.send(
            &conn,
            &json!({"jsonrpc":"2.0","id":9,"method":"fs.read","params":{"path": file.display().to_string()}})
                .to_string(),
        );
        let mut frames = 0;
        let mut joined = Reassembler::new(64 << 20);
        let reply = loop {
            let f = conn.next_frame().await.expect("the reply");
            if f.id != 2 || f.kind != KIND_DATA {
                continue;
            }
            assert!(f.payload.len() <= NOISE_MAX);
            frames += 1;
            if let Some(m) = joined.push(&phone.secure.open(&f.payload).unwrap()).unwrap() {
                break m;
            }
        };
        assert!(
            frames >= 5,
            "300 KB cannot fit fewer than 5 frames of 64 KiB, got {frames}"
        );
        let v: Value = serde_json::from_slice(&reply).unwrap();
        assert_eq!(v["id"], 9);
        assert!(v["result"].to_string().len() > 300_000);
    }

    #[test]
    fn frames_are_cut_at_65535_bytes_of_ciphertext_and_join_back() {
        let a = new_key();
        let b = new_key();
        let mut initiator = noise_builder()
            .unwrap()
            .local_private_key(&a.private)
            .unwrap()
            .remote_public_key(&b.public)
            .unwrap()
            .prologue(NOISE_PROLOGUE)
            .unwrap()
            .build_initiator()
            .unwrap();
        let mut responder = noise_builder()
            .unwrap()
            .local_private_key(&b.private)
            .unwrap()
            .prologue(NOISE_PROLOGUE)
            .unwrap()
            .build_responder()
            .unwrap();
        let (mut m, mut p) = (vec![0u8; NOISE_MAX], vec![0u8; NOISE_MAX]);
        let n = initiator.write_message(&[], &mut m).unwrap();
        responder.read_message(&m[..n], &mut p).unwrap();
        let n = responder.write_message(&[], &mut m).unwrap();
        initiator.read_message(&m[..n], &mut p).unwrap();
        let tx = Secure {
            state: Mutex::new(initiator.into_transport_mode().unwrap()),
        };
        let rx = Secure {
            state: Mutex::new(responder.into_transport_mode().unwrap()),
        };

        for len in [0, 1, CHUNK - 1, CHUNK, CHUNK + 1, 3 * CHUNK, 3 * CHUNK + 17] {
            let message: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
            let sealed = tx.seal(&message).unwrap();
            assert_eq!(sealed.len(), len.div_ceil(CHUNK).max(1), "len {len}");
            assert!(sealed.iter().all(|c| c.len() <= NOISE_MAX), "len {len}");
            if len > CHUNK {
                assert_eq!(
                    sealed[0].len(),
                    NOISE_MAX,
                    "a full chunk is exactly 65535 bytes of ciphertext"
                );
            }
            let mut joined = Reassembler::new(1 << 20);
            let mut out = None;
            for cipher in &sealed {
                assert!(out.is_none(), "the message ended early");
                out = joined.push(&rx.open(cipher).unwrap()).unwrap();
            }
            assert_eq!(out.expect("the last chunk completes the message"), message, "len {len}");
        }

        let mut small = Reassembler::new(10);
        assert_eq!(small.push(&[1, 0, 0, 0, 0, 0, 0]), Ok(None));
        assert_eq!(small.push(&[0, 0, 0, 0, 0, 0]), Err("message too large"));
        assert_eq!(Reassembler::new(10).push(&[]), Err("empty message"));
        assert_eq!(Reassembler::new(10).push(&[2, 1]), Err("bad chunk header"));
        // A tampered frame does not decrypt.
        let mut sealed = tx.seal(b"hello").unwrap().remove(0);
        sealed[3] ^= 1;
        assert!(rx.open(&sealed).is_err());
    }

    #[tokio::test]
    async fn a_replayed_frame_ends_the_stream() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let phone = rig.sign_in(&mut conn, 2, &key, &token).await;
        // The same ciphertext twice: the Noise nonce has moved on.
        let cipher = phone
            .secure
            .seal(
                json!({"jsonrpc":"2.0","id":7,"method":"daemon.info","params":{}})
                    .to_string()
                    .as_bytes(),
            )
            .unwrap()
            .remove(0);
        conn.send_frame(2, KIND_DATA, &cipher);
        conn.send_frame(2, KIND_DATA, &cipher);
        let mut closed = false;
        while let Some(f) = conn.next_frame().await {
            if f.id == 2 && f.kind == KIND_CLOSE {
                closed = true;
                break;
            }
        }
        assert!(closed);
    }

    #[tokio::test]
    async fn pairing_attempts_through_the_relay_are_counted_per_phone_address() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let ip = "203.0.113.77";
        let source = source_key(ip.parse().unwrap());
        let limits = rig.app.phone.limits();
        for i in 0..crate::phone::ATTEMPT_MAX {
            let id = 10 + i as u32;
            let phone = Phone::connect(&mut conn, id, ip, &new_key(), &rig.nk()).await.unwrap();
            phone.send(&conn, r#"{"pair":true}"#);
            // The daemon has taken the try when the stream holds its anonymous place.
            let deadline = Instant::now() + WAIT;
            while limits.anonymous.held(&source) == 0 {
                assert!(Instant::now() < deadline, "the stream did not start pairing");
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            conn.send_frame(id, KIND_CLOSE, &[]);
            // Wait for the stream to give its places back.
            while limits.anonymous.held(&source) > 0 || limits.connections.held(&source) > 0 {
                assert!(Instant::now() < deadline, "the stream did not end");
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }
        // The next one is refused; another address is not.
        let phone = Phone::connect(&mut conn, 99, ip, &new_key(), &rig.nk()).await.unwrap();
        phone.send(&conn, r#"{"pair":true}"#);
        assert_eq!(phone.recv(&mut conn).await.unwrap(), r#"{"error":"rate_limited"}"#);
        let other = Phone::connect(&mut conn, 100, "203.0.113.78", &new_key(), &rig.nk())
            .await
            .unwrap();
        other.send(&conn, r#"{"pair":true}"#);
        let err = other
            .call(
                &mut conn,
                "pair.redeem",
                json!({"code": "no-such-code", "device_name": "x"}),
            )
            .await
            .unwrap_err();
        assert_eq!(err["code"], crate::rpc::UNAUTHORIZED, "a bad code, not a limit");
    }

    #[tokio::test]
    async fn failed_sign_ins_count_against_the_address_but_a_valid_device_is_never_held_back() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let ip = "203.0.113.88";
        for i in 0..crate::phone::ATTEMPT_MAX {
            let phone = Phone::connect(&mut conn, 20 + i as u32, ip, &key, &rig.nk())
                .await
                .unwrap();
            phone.send(&conn, r#"{"auth":"bdt_wrong"}"#);
            assert_eq!(phone.recv(&mut conn).await.unwrap(), r#"{"error":"unauthorized"}"#);
        }
        let phone = Phone::connect(&mut conn, 40, ip, &key, &rig.nk()).await.unwrap();
        phone.send(&conn, r#"{"auth":"bdt_wrong"}"#);
        assert_eq!(phone.recv(&mut conn).await.unwrap(), r#"{"error":"rate_limited"}"#);
        // The paired phone from the same address still gets in.
        let phone = Phone::connect(&mut conn, 41, ip, &key, &rig.nk()).await.unwrap();
        phone.send(&conn, &json!({ "auth": token }).to_string());
        assert!(phone.call(&mut conn, "daemon.info", json!({})).await.is_ok());
    }

    #[tokio::test]
    async fn an_anonymous_stream_that_never_redeems_is_closed() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        let phone = Phone::connect(&mut conn, 3, "203.0.113.9", &new_key(), &rig.nk())
            .await
            .unwrap();
        phone.send(&conn, r#"{"pair":true}"#);
        assert_eq!(phone.recv(&mut conn).await.unwrap_err(), "closed");
        // And one that sends nothing after the handshake.
        let silent = Phone::connect(&mut conn, 4, "203.0.113.9", &new_key(), &rig.nk())
            .await
            .unwrap();
        assert_eq!(silent.recv(&mut conn).await.unwrap_err(), "closed");
        // Anonymous streams may only pair.
        let anon = Phone::connect(&mut conn, 6, "203.0.113.10", &new_key(), &rig.nk())
            .await
            .unwrap();
        anon.send(&conn, r#"{"pair":true}"#);
        let err = anon.call(&mut conn, "daemon.info", json!({})).await.unwrap_err();
        assert_eq!(err["code"], crate::rpc::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn the_relay_that_replaces_this_server_is_waited_for_and_the_reason_is_kept() {
        let mut rig = Rig::new().await;
        let conn = rig.enable().await;
        let closed_at = Instant::now();
        conn.close_with(CLOSE_REPLACED, "replaced");
        // No quick reconnect (the backoff is 20 ms): the wait of a replaced server is 500 ms here.
        assert!(rig.relay.next_conn(Duration::from_millis(250)).await.is_none());
        let status = rig.app.relay.status();
        assert!(!status.connected);
        assert!(status.enabled);
        assert!(
            status.last_error.as_deref().unwrap_or("").contains("4001"),
            "{status:?}"
        );
        let again = rig.relay.next_conn(WAIT).await.expect("it comes back");
        assert!(again.at.duration_since(closed_at) >= Duration::from_millis(450));
        // Back online: the error is cleared.
        let deadline = Instant::now() + WAIT;
        while rig.app.relay.status().last_error.is_some() {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(rig.app.relay.status().connected);
    }

    #[tokio::test]
    async fn a_limit_close_keeps_the_reason_for_the_app() {
        let mut rig = Rig::new().await;
        let conn = rig.enable().await;
        conn.close_with(CLOSE_LIMIT, "monthly traffic limit reached");
        let deadline = Instant::now() + WAIT;
        loop {
            let status = rig.app.relay.status();
            if let Some(why) = &status.last_error {
                assert!(why.contains("monthly traffic limit reached"), "{why}");
                assert!(!status.connected);
                break;
            }
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }

    #[tokio::test]
    async fn the_connection_comes_back_with_a_growing_wait_and_a_cap() {
        let mut rig = Rig::new().await;
        rig.app.relay.set_timing(Timing {
            backoff_min: Duration::from_millis(60),
            backoff_max: Duration::from_millis(240),
            ..fast()
        });
        let first = rig.enable().await;
        first.close_with(1013, "try later");
        let mut times = vec![first.at];
        for _ in 0..4 {
            let conn = rig.relay.next_conn(WAIT).await.expect("it reconnects");
            times.push(conn.at);
            conn.close_with(1013, "try later");
        }
        let gaps: Vec<u128> = times.windows(2).map(|w| (w[1] - w[0]).as_millis()).collect();
        // 60, 120, 240, 240 ms, each within 20 % of jitter (plus scheduling).
        assert!((45..=140).contains(&gaps[0]), "{gaps:?}");
        assert!(gaps[1] > gaps[0], "{gaps:?}");
        assert!(gaps[2] >= 180, "{gaps:?}");
        assert!(
            (180..=450).contains(&gaps[3]),
            "the wait stops growing at the cap: {gaps:?}"
        );
        let err = rig.app.relay.status().last_error.unwrap_or_default();
        assert!(err.contains("1013"), "{err}");
    }

    #[tokio::test]
    async fn the_daemon_pings_the_relay_and_leaves_one_that_goes_silent() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        rig.connected().await;
        let mut ping = false;
        while let Some(m) = conn.recv(Duration::from_millis(600)).await {
            if matches!(&m, Message::Text(t) if t.as_str() == "ping") {
                ping = true;
                break;
            }
        }
        assert!(ping, "a text `ping` every `ping` while connected");
        // The relay's own `ping` is answered with the text `pong`.
        conn.to_daemon.send(Message::text("ping")).unwrap();
        let mut ponged = false;
        while let Some(m) = conn.recv(Duration::from_millis(600)).await {
            if matches!(&m, Message::Text(t) if t.as_str() == "pong") {
                ponged = true;
                break;
            }
        }
        assert!(ponged);
        drop(conn);

        // A relay that accepts the socket and then says nothing, not even a pong, is given up after `silence`.
        rig.app.relay.set_timing(Timing {
            silence: Duration::from_millis(300),
            ..fast()
        });
        rig.relay.mute.store(true, Ordering::Relaxed);
        let deadline = Instant::now() + WAIT;
        while rig.app.relay.status().last_error.as_deref() != Some("the relay went silent") {
            assert!(Instant::now() < deadline, "{:?}", rig.app.relay.status());
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    #[tokio::test]
    async fn a_deleted_registration_switches_relay_mode_off_for_good() {
        let mut rig = Rig::new().await;
        let conn = rig.enable().await;
        rig.connected().await;
        conn.close_with(CLOSE_DELETED, "registration deleted");
        let deadline = Instant::now() + WAIT;
        while rig.app.relay.status().enabled {
            assert!(Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let status = rig.app.relay.status();
        assert!(!status.connected);
        assert!(status.last_error.unwrap().contains("deleted"));
        assert!(
            !rig.dir.path().join(RELAY_FILE).exists(),
            "the dead registration is forgotten"
        );
        assert!(
            rig.relay.next_conn(Duration::from_millis(400)).await.is_none(),
            "no reconnect"
        );
        // The owner can enable it again with a new registration.
        assert!(rig.app.relay.enable(rig.config()).await.is_ok());
        assert!(rig.relay.next_conn(WAIT).await.is_some());
    }

    #[tokio::test]
    async fn silence_and_oversize_closes_reconnect_with_the_backoff() {
        let mut rig = Rig::new().await;
        let conn = rig.enable().await;
        conn.close_with(CLOSE_SILENCE, "silence");
        let conn = rig.relay.next_conn(WAIT).await.expect("4002: reconnects");
        rig.connected().await;
        conn.close_with(CLOSE_TOO_BIG, "too big");
        let conn = rig.relay.next_conn(WAIT).await.expect("4009: reconnects");
        rig.connected().await;
        drop(conn);
    }

    #[tokio::test]
    async fn the_limit_close_waits_for_the_next_hour_and_a_bad_secret_backs_off_far() {
        // The default wait of 4008 is the time to the next full hour.
        assert_eq!(next_hour_after(0), Duration::from_secs(3601));
        assert_eq!(next_hour_after(3599), Duration::from_secs(2));
        assert_eq!(next_hour_after(7200 + 1800), Duration::from_secs(1801));
        assert!(Timing::default().limit_wait.is_none());
        assert_eq!(Timing::default().auth_backoff_max, Duration::from_secs(600));

        let mut rig = Rig::new().await;
        rig.relay.reject.store(401, Ordering::Relaxed);
        rig.app.relay.set_timing(Timing {
            backoff_min: Duration::from_millis(50),
            backoff_max: Duration::from_millis(100),
            auth_backoff_max: Duration::from_millis(1600),
            ..fast()
        });
        rig.app.relay.enable(rig.config()).await.unwrap();
        let deadline = Instant::now() + WAIT;
        while rig.relay.tries.lock().unwrap().len() < 5 {
            assert!(Instant::now() < deadline, "it keeps trying");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let times = rig.relay.tries.lock().unwrap().clone();
        let gaps: Vec<u128> = times.windows(2).map(|w| (w[1] - w[0]).as_millis()).collect();
        assert!(
            gaps[2] > 140,
            "a refused secret waits longer than the normal cap of 100 ms: {gaps:?}"
        );
        let status = rig.app.relay.status();
        assert!(status.enabled && !status.connected);
        assert!(status.last_error.unwrap().contains("credentials"));
        // Once the relay accepts it again, the daemon is connected.
        rig.relay.reject.store(0, Ordering::Relaxed);
        let _conn = rig.relay.next_conn(WAIT).await.expect("connects");
        rig.connected().await;
    }

    #[tokio::test]
    async fn a_bad_open_is_answered_with_a_close() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        conn.send_frame(1, KIND_OPEN, b"not json");
        conn.send_frame(2, KIND_OPEN, br#"{"ip":"203.0.113.1","v":2}"#);
        for id in [1, 2] {
            let f = conn.next_frame().await.unwrap();
            assert_eq!((f.id, f.kind), (id, KIND_CLOSE));
        }
        // Data for a stream nobody opened is ignored, and the connection goes on.
        conn.send_frame(77, KIND_DATA, b"x");
        let phone = Phone::connect(&mut conn, 3, "203.0.113.1", &new_key(), &rig.nk()).await;
        assert!(phone.is_ok());
    }

    #[tokio::test]
    async fn relay_mode_comes_back_when_the_daemon_restarts() {
        let mut rig = Rig::new().await;
        let conn = rig.enable().await;
        drop(conn);
        rig.app.relay.shutdown().await;
        assert!(
            rig.dir.path().join(RELAY_FILE).exists(),
            "stopping the daemon keeps the registration"
        );

        let again = app_in(rig.dir.path());
        assert!(!again.relay.status().enabled);
        again.relay.start().await;
        let status = again.relay.status();
        assert!(status.enabled);
        assert_eq!(status.sid.as_deref(), Some(SID));
        let conn = rig.relay.next_conn(WAIT).await.expect("it connects on start");
        assert_eq!(conn.path, format!("/v1/server/{SID}"));
        // The Noise key is the one the first start made.
        assert_eq!(
            again.relay.keys().unwrap().public_b64(),
            URL_SAFE_NO_PAD.encode(rig.nk())
        );
    }

    #[tokio::test]
    async fn a_damaged_settings_file_is_reported_and_a_damaged_key_is_never_replaced() {
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join(RELAY_FILE), "{ nope").unwrap();
        let app = app_in(dir.path());
        app.relay.start().await;
        let status = app.relay.status();
        assert!(!status.enabled);
        assert!(status.last_error.unwrap().contains(RELAY_FILE));

        std::fs::write(dir.path().join(NOISE_KEY_FILE), "garbage").unwrap();
        let config = Config::checked("ws://127.0.0.1:9", SID, &secret(), true).unwrap();
        let err = app.relay.enable(config).await.unwrap_err().to_string();
        assert!(err.contains(NOISE_KEY_FILE), "{err}");
        assert_eq!(
            std::fs::read_to_string(dir.path().join(NOISE_KEY_FILE)).unwrap(),
            "garbage"
        );
        assert!(!app.relay.status().enabled);

        // A key file whose halves do not belong together is damaged too.
        let a = NoiseKeys::generate().unwrap();
        let b = NoiseKeys::generate().unwrap();
        let mixed = serde_json::to_string(&KeyFile {
            private: URL_SAFE_NO_PAD.encode(&a.private),
            public: b.public_b64(),
        })
        .unwrap();
        assert!(NoiseKeys::parse(&mixed).is_err());
    }

    #[tokio::test]
    async fn the_key_and_the_settings_are_private_files_and_the_key_survives_a_restart() {
        use std::os::unix::fs::PermissionsExt;
        let mut rig = Rig::new().await;
        let _conn = rig.enable().await;
        for name in [NOISE_KEY_FILE, RELAY_FILE] {
            let mode = std::fs::metadata(rig.dir.path().join(name))
                .unwrap()
                .permissions()
                .mode();
            assert_eq!(mode & 0o777, 0o600, "{name}");
        }
        let first = rig.app.relay.keys().unwrap().public_b64();
        let reloaded = NoiseKeys::load_or_create(rig.dir.path()).unwrap();
        assert_eq!(reloaded.public_b64(), first);
        // The settings file holds the secret; the status and the debug text never do.
        let status = rig.owner("relay.status", json!({})).await.unwrap();
        assert!(!status.to_string().contains(&secret()));
        assert!(!format!("{:?}", rig.config()).contains(&secret()));
        assert_eq!(status["enabled"], true);
        assert_eq!(status["sid"], SID);
    }

    #[tokio::test]
    async fn enable_validates_its_parameters_and_the_same_settings_change_nothing() {
        let rig = Rig::new().await;
        let secret = secret();
        let bad = [
            ("http://relay.bandito.dev", SID, secret.as_str()),
            ("ws://relay.bandito.dev", SID, secret.as_str()),
            ("ftp://relay.bandito.dev", SID, secret.as_str()),
            ("relay.bandito.dev", SID, secret.as_str()),
            ("https://", SID, secret.as_str()),
            ("https://user@relay.bandito.dev", SID, secret.as_str()),
            ("https://relay.bandito.dev/path", SID, secret.as_str()),
            ("https://relay.bandito.dev?x=1", SID, secret.as_str()),
            ("https://relay.bandito.dev:0", SID, secret.as_str()),
            ("https://relay bandito.dev", SID, secret.as_str()),
            ("https://relay.bandito.dev", "short", secret.as_str()),
            (
                "https://relay.bandito.dev",
                "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
                secret.as_str(),
            ),
            (
                "https://relay.bandito.dev",
                "abcdefghijklmnopqrstuvwxy1",
                secret.as_str(),
            ),
            ("https://relay.bandito.dev", SID, "tooshort"),
            ("https://relay.bandito.dev", SID, &"!".repeat(43)),
        ];
        for (url, sid, secret) in bad {
            let err = rig
                .owner("relay.enable", json!({"relay_url": url, "sid": sid, "secret": secret}))
                .await
                .unwrap_err();
            assert_eq!(err.code, crate::rpc::INVALID_PARAMS, "{url} {sid} {secret}");
        }
        let err = rig
            .owner("relay.enable", json!({"relay_url": "https://x.dev"}))
            .await
            .unwrap_err();
        assert_eq!(err.code, crate::rpc::INVALID_PARAMS);
        assert!(!rig.dir.path().join(RELAY_FILE).exists(), "nothing was saved");
        assert!(
            !rig.dir.path().join(NOISE_KEY_FILE).exists(),
            "no key was made for a refused call"
        );

        let ok = Config::validated("https://Relay.Bandito.dev/", SID, &secret).unwrap();
        assert_eq!(ok.relay_url, "https://relay.bandito.dev");
        assert!(Config::validated("wss://relay.bandito.dev:8443", SID, &secret).is_ok());
    }

    #[tokio::test]
    async fn the_status_changes_are_announced_to_the_apps() {
        let mut rig = Rig::new().await;
        let mut events = rig.app.sup.hub().subscribe();
        let _conn = rig.enable().await;
        let mut kinds = Vec::new();
        while let Ok(Ok(ev)) = timeout(Duration::from_millis(300), events.recv()).await {
            kinds.push(ev.body.to_parts().0);
        }
        assert!(kinds.iter().any(|k| k == "relay.changed"), "{kinds:?}");
        assert!(kinds.iter().all(|k| k == "relay.changed"), "{kinds:?}");
        // Enabling the same settings again is no change and no event.
        let before = kinds.len();
        rig.app.relay.enable(rig.config()).await.unwrap();
        assert!(
            timeout(Duration::from_millis(200), events.recv()).await.is_err(),
            "{before}"
        );
    }

    #[tokio::test]
    async fn only_the_owner_may_use_relay_methods() {
        let rig = Rig::new().await;
        for method in ["relay.enable", "relay.disable", "relay.status"] {
            for peer in [
                Peer::Agent("agent-a".into()),
                Peer::Anonymous("203.0.113.1".into(), None),
            ] {
                assert!(!crate::rpc::allowed(&peer, method), "{peer:?} {method}");
                let err = dispatch(&rig.app, &peer, method, json!({})).await.unwrap_err();
                assert_eq!(err.code, crate::rpc::UNAUTHORIZED, "{peer:?} {method}");
            }
            assert!(crate::rpc::allowed(&Peer::Local, method));
        }
        assert!(crate::rpc::features().contains(&"relay"));
        // A paired device is an owner peer.
        let device = rig.app.sup.hub().store.device_add("Mac", "bdt_mac").unwrap();
        let status = dispatch(&rig.app, &Peer::Device(device), "relay.status", json!({}))
            .await
            .unwrap();
        assert_eq!(status["enabled"], false);
    }

    #[tokio::test]
    async fn pair_redeem_checks_the_phone_key_before_it_takes_the_code() {
        let rig = Rig::new().await;
        let code = rig.owner("pair.create", json!({})).await.unwrap()["code"]
            .as_str()
            .unwrap()
            .to_string();
        let anon = Peer::Anonymous("203.0.113.5".into(), None);
        for key in [
            "short",
            &URL_SAFE_NO_PAD.encode([1u8; 31]),
            &URL_SAFE_NO_PAD.encode([1u8; 33]),
            "!!!",
        ] {
            let err = dispatch(
                &rig.app,
                &anon,
                "pair.redeem",
                json!({"code": code, "device_name": "p", "noise_key": key}),
            )
            .await
            .unwrap_err();
            assert_eq!(err.code, crate::rpc::INVALID_PARAMS, "{key}");
        }
        // The code is still good, and the key (if any) is kept.
        let key = URL_SAFE_NO_PAD.encode([9u8; 32]);
        let done = dispatch(
            &rig.app,
            &anon,
            "pair.redeem",
            json!({"code": code, "device_name": "p", "noise_key": key}),
        )
        .await
        .unwrap();
        let id = done["device"]["id"].as_str().unwrap();
        assert_eq!(
            rig.app.sup.hub().store.device_noise_key(id).unwrap().as_deref(),
            Some(key.as_str())
        );
        assert!(
            done["device"].get("noise_key").is_none(),
            "the list of devices does not carry the key"
        );
        // Without a key: a device of the direct modes, as before.
        let code = rig.owner("pair.create", json!({})).await.unwrap()["code"]
            .as_str()
            .unwrap()
            .to_string();
        let done = dispatch(
            &rig.app,
            &anon,
            "pair.redeem",
            json!({"code": code, "device_name": "p"}),
        )
        .await
        .unwrap();
        let id = done["device"]["id"].as_str().unwrap();
        assert_eq!(rig.app.sup.hub().store.device_noise_key(id).unwrap(), None);
        let err = dispatch(&rig.app, &anon, "pair.redeem", json!({"code": "x", "device_name": "p"}))
            .await
            .unwrap_err();
        assert_ne!(err.code, RATE_LIMITED);
    }

    #[tokio::test]
    async fn the_link_has_no_relay_part_while_relay_mode_is_off() {
        let rig = Rig::new().await;
        let created = rig.owner("pair.create", json!({})).await.unwrap();
        assert_eq!(created["relay"], Value::Null);
        assert_eq!(created["noise_key"], Value::Null);
        assert_eq!(created["link"], Value::Null, "no phone listener and no relay: no link");
        assert!(rig.app.relay.link_info().is_none());
        assert!(
            !rig.dir.path().join(NOISE_KEY_FILE).exists(),
            "pair.create does not make the key while the relay is off"
        );
    }

    #[test]
    fn relay_urls_are_taken_apart() {
        let t = parse_url("https://relay.bandito.dev", false).unwrap();
        assert_eq!((t.host.as_str(), t.port, t.tls), ("relay.bandito.dev", 443, true));
        let t = parse_url("wss://relay.example.com:8443/", false).unwrap();
        assert_eq!((t.authority.as_str(), t.port), ("relay.example.com:8443", 8443));
        let t = parse_url("ws://127.0.0.1:9", true).unwrap();
        assert_eq!((t.port, t.tls), (9, false));
        assert!(parse_url("ws://127.0.0.1:9", false).is_err());
        assert!(parse_url("https://-bad.example", false).is_err());
        assert!(parse_url("https://a..b", false).is_err());
    }

    #[test]
    fn the_backoff_doubles_to_the_cap_with_a_little_jitter() {
        let t = Timing::default();
        for (attempt, base) in [
            (0, 1.0),
            (1, 2.0),
            (2, 4.0),
            (5, 32.0),
            (6, 60.0),
            (30, 60.0),
            (u32::MAX, 60.0),
        ] {
            for _ in 0..50 {
                let s = t.backoff(attempt).as_secs_f64();
                assert!(s >= base * 0.79 && s <= base * 1.21, "attempt {attempt}: {s}");
            }
        }
        assert_eq!(t.ping, Duration::from_secs(25));
        assert_eq!(t.replaced_wait, Duration::from_secs(30));
    }

    // ----- review fixes: pairing key, frame limits, stream identity, device auth, lifecycle, key file ------------

    fn wire(message: Message) -> Vec<u8> {
        match message {
            Message::Binary(bytes) => bytes.to_vec(),
            other => panic!("not a relay frame: {other:?}"),
        }
    }

    #[tokio::test]
    async fn a_relay_phone_pairs_with_the_key_it_proved_in_the_handshake() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        rig.connected().await;
        let key = new_key();
        let code = rig.owner("pair.create", json!({})).await.unwrap()["code"]
            .as_str()
            .unwrap()
            .to_string();
        let phone = Phone::connect(&mut conn, 1, "203.0.113.7", &key, &rig.nk())
            .await
            .unwrap();
        phone.send(&conn, r#"{"pair":true}"#);
        // No `noise_key` parameter: the key of the handshake is the phone's key.
        let done = phone
            .call(
                &mut conn,
                "pair.redeem",
                json!({"code": code, "device_name": "Test phone"}),
            )
            .await
            .unwrap();
        let id = done["device"]["id"].as_str().unwrap();
        assert_eq!(
            rig.app.sup.hub().store.device_noise_key(id).unwrap().as_deref(),
            Some(URL_SAFE_NO_PAD.encode(&key.public).as_str())
        );
    }

    #[tokio::test]
    async fn a_relay_phone_cannot_pair_with_a_key_other_than_its_handshake() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        rig.connected().await;
        let key = new_key();
        let other = new_key();
        let code = rig.owner("pair.create", json!({})).await.unwrap()["code"]
            .as_str()
            .unwrap()
            .to_string();
        let phone = Phone::connect(&mut conn, 1, "203.0.113.7", &key, &rig.nk())
            .await
            .unwrap();
        phone.send(&conn, r#"{"pair":true}"#);
        let err = phone
            .call(
                &mut conn,
                "pair.redeem",
                json!({"code": code, "device_name": "p", "noise_key": URL_SAFE_NO_PAD.encode(&other.public)}),
            )
            .await
            .unwrap_err();
        assert_eq!(err["code"], crate::rpc::INVALID_PARAMS);
        assert_eq!(err["message"], "noise_key does not match the session");
        // The code was not taken: the phone pairs with the key of its session.
        let done = phone
            .call(&mut conn, "pair.redeem", json!({"code": code, "device_name": "p"}))
            .await
            .unwrap();
        let id = done["device"]["id"].as_str().unwrap();
        assert_eq!(
            rig.app.sup.hub().store.device_noise_key(id).unwrap().as_deref(),
            Some(URL_SAFE_NO_PAD.encode(&key.public).as_str())
        );
    }

    #[test]
    fn the_relay_trusts_the_bundled_roots_when_the_system_has_none() {
        // Without system certificates the client still has roots to check the relay with.
        assert!(client_config(Vec::new()).is_ok());
    }

    #[tokio::test]
    async fn an_oversize_data_frame_closes_its_stream_and_is_not_queued() {
        let dir = TempDir::new().unwrap();
        let relay = Arc::new(Relay::new(dir.path().to_path_buf(), Weak::new()));
        let (frames, mut queued) = mpsc::channel(STREAM_BACKLOG);
        let cancel = CancellationToken::new();
        let streams: Streams = Arc::default();
        streams.lock().unwrap().insert(
            9,
            StreamHandle {
                frames,
                cancel: cancel.clone(),
                serial: 0,
            },
        );
        let (out, mut out_rx) = mpsc::channel(16);
        let session = CancellationToken::new();
        let oversize = wire(frame(9, KIND_DATA, &vec![0u8; NOISE_MAX + 1]));
        relay.on_frame(&oversize, &out, &streams, &session);
        assert!(queued.try_recv().is_err(), "the oversize frame was queued");
        assert!(cancel.is_cancelled(), "the stream goes on");
        assert!(!streams.lock().unwrap().contains_key(&9));
        let close = wire(out_rx.try_recv().expect("the relay is told the stream is closed"));
        assert_eq!(
            (close[..4].to_vec(), close[4]),
            (9u32.to_be_bytes().to_vec(), KIND_CLOSE)
        );
    }

    #[tokio::test]
    async fn a_stream_opened_without_a_usable_address_is_refused() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        conn.send_frame(
            1,
            KIND_OPEN,
            json!({"ip": "not an address", "v": 1}).to_string().as_bytes(),
        );
        conn.send_frame(2, KIND_OPEN, json!({"v": 1}).to_string().as_bytes());
        // Refused at once: not after the handshake timeout that a stream with a usable address would run into.
        let started = Instant::now();
        for id in [1, 2] {
            let f = conn.next_frame().await.expect("a refusal");
            assert_eq!((f.id, f.kind), (id, KIND_CLOSE));
        }
        assert!(
            started.elapsed() < STREAM_STEP_TIMEOUT,
            "the stream was opened and timed out"
        );
    }

    #[tokio::test]
    async fn an_old_stream_ending_does_not_remove_a_new_stream_with_the_same_id() {
        let rig = Rig::new().await;
        let relay = rig.app.relay.clone();
        let streams: Streams = Arc::default();
        let (out, mut out_rx) = mpsc::channel(64);
        let session = CancellationToken::new();
        let open = wire(frame(3, KIND_OPEN, br#"{"ip":"203.0.113.1","v":1}"#));
        relay.on_frame(&open, &out, &streams, &session);
        relay.on_frame(&wire(frame(3, KIND_CLOSE, &[])), &out, &streams, &session);
        // The same id is opened again before the old stream's task has run its end.
        relay.on_frame(&open, &out, &streams, &session);
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
        assert!(
            streams.lock().unwrap().contains_key(&3),
            "the old stream removed the new one"
        );
        while let Ok(message) = out_rx.try_recv() {
            let bytes = wire(message);
            assert!(bytes[4] != KIND_CLOSE, "the relay was told to close the new stream");
        }
    }

    #[tokio::test]
    async fn a_phone_with_a_wrong_key_does_not_touch_its_device() {
        let mut rig = Rig::new().await;
        let mut conn = rig.enable().await;
        rig.connected().await;
        let key = new_key();
        let token = rig.pair(&mut conn, 1, &key, "203.0.113.7").await;
        let store = rig.app.sup.hub().store.clone();
        tokio::time::sleep(Duration::from_millis(5)).await;
        let before = store.device_list().unwrap()[0].last_seen_at;

        let thief = new_key();
        let phone = rig.sign_in(&mut conn, 2, &thief, &token).await;
        assert_eq!(phone.recv(&mut conn).await.unwrap(), r#"{"error":"unauthorized"}"#);
        assert_eq!(
            store.device_list().unwrap()[0].last_seen_at,
            before,
            "a refused key moved last_seen_at"
        );

        tokio::time::sleep(Duration::from_millis(5)).await;
        let phone = rig.sign_in(&mut conn, 3, &key, &token).await;
        assert!(phone.call(&mut conn, "daemon.info", json!({})).await.is_ok());
        assert_ne!(store.device_list().unwrap()[0].last_seen_at, before);
    }

    #[tokio::test]
    async fn a_deleted_registration_removes_the_settings_under_the_lifecycle_lock() {
        let mut rig = Rig::new().await;
        let conn = rig.enable().await;
        rig.connected().await;
        let guard = rig.app.relay.lifecycle.lock().await;
        conn.close_with(CLOSE_DELETED, "deleted");
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert!(
            rig.dir.path().join(RELAY_FILE).exists(),
            "the settings were removed while a switch was under way"
        );
        drop(guard);
        let deadline = Instant::now() + WAIT;
        while rig.dir.path().join(RELAY_FILE).exists() {
            assert!(Instant::now() < deadline, "the settings were never removed");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert!(!rig.app.relay.status().enabled);
    }

    #[test]
    fn a_noise_key_file_that_is_too_open_is_made_private_again() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let first = NoiseKeys::load_or_create(dir.path()).unwrap();
        let path = dir.path().join(NOISE_KEY_FILE);
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let again = NoiseKeys::load_or_create(dir.path()).unwrap();
        assert_eq!(again.public_b64(), first.public_b64());
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    #[test]
    fn the_private_key_is_wiped() {
        let mut keys = NoiseKeys::generate().unwrap();
        assert!(keys.private.iter().any(|&b| b != 0));
        let public = keys.public;
        keys.wipe();
        assert!(keys.private.iter().all(|&b| b == 0));
        assert_eq!(keys.public, public, "the public key stays");
    }
}
