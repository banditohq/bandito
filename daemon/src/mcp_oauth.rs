//! Signing in to remote MCP servers in the browser: the authorization part of the MCP specification (2025-06-18):
//! OAuth 2.1 with PKCE, protected-resource and authorization-server metadata (RFC 9728, RFC 8414), dynamic client
//! registration (RFC 7591) and resource indicators (RFC 8707). See docs/ARCHITECTURE.md#integrations.
//!
//! The daemon does all of it. It builds the address the person opens, takes back the one-time code, trades it for
//! tokens and keeps them in its secrets (names in `integrations::oauth_access_name` and `oauth_state_name`); the
//! app never sees a token. Nothing here writes a token, a code or a verifier to a log or into an error: errors are
//! made of fixed sentences plus the service's short `error` code, and the text the service sends is cleaned and
//! passed through a [`Redactor`] first. Requests go through `curl` with the request on stdin, like the http probe
//! of `rpc/integrations.rs`, so no value reaches an argument list.

use crate::integrations::{oauth_access_name, oauth_client_name, oauth_state_name};
use crate::redact::Redactor;
use crate::store::{Integration, IntegrationAuth, IntegrationKind, NewIntegration, Store};
use anyhow::{Context, Result, anyhow, bail};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// The only address a service may send the person back to.
pub const REDIRECT_URI: &str = "bandito://oauth/callback";
/// How long a started sign-in waits for its answer.
pub const FLOW_TTL_MS: i64 = 10 * 60 * 1000;
/// Sign-ins waiting at once; the oldest is dropped past this.
const MAX_FLOWS: usize = 32;
/// A session start renews a token that ends within this time.
pub const SESSION_SKEW_MS: i64 = 5 * 60 * 1000;
/// The background renewal takes a token that ends within this time.
pub const BACKGROUND_SKEW_MS: i64 = 10 * 60 * 1000;
/// Longest wait for one answer of the service.
const REQUEST_SECONDS: u64 = 15;
/// Longest wait for the lookup of a name.
const RESOLVE_SECONDS: u64 = 5;
/// Most bytes read from one answer.
const MAX_RESPONSE_BYTES: u64 = 2 * 1024 * 1024;
/// The MCP protocol version sent to the server.
const PROTOCOL: &str = "2025-06-18";

// ---- addresses ----

/// An `http(s)` address, parsed by hand: the pieces the sign-in needs, nothing else.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Url {
    https: bool,
    host: String,
    port: Option<u16>,
    /// As written; empty for none.
    path: String,
    query: Option<String>,
}

impl Url {
    fn parse(text: &str) -> Result<Url> {
        if text.chars().any(char::is_control) {
            bail!("not a valid address");
        }
        let text = text.trim();
        if text.is_empty() || text.len() > 2048 || text.chars().any(|c| c.is_control() || c == ' ' || c == '\\') {
            bail!("not a valid address");
        }
        if text.contains('#') {
            bail!("an address with a fragment is not accepted");
        }
        let (https, rest) = if let Some(rest) = text.strip_prefix("https://") {
            (true, rest)
        } else if let Some(rest) = text.strip_prefix("http://") {
            (false, rest)
        } else {
            bail!("an address must start with https://");
        };
        let end = rest.find(['/', '?']).unwrap_or(rest.len());
        let (authority, tail) = rest.split_at(end);
        if authority.contains('@') {
            bail!("an address with a user name is not accepted");
        }
        let (host, port) = if let Some(inner) = authority.strip_prefix('[') {
            let (host, after) = inner.split_once(']').ok_or_else(|| anyhow!("not a valid address"))?;
            if !after.is_empty() && !after.starts_with(':') {
                bail!("not a valid address");
            }
            let port = after.strip_prefix(':');
            // Written one way only: the address as `Ipv6Addr` prints it.
            let ip = host
                .parse::<std::net::Ipv6Addr>()
                .map_err(|_| anyhow!("not a valid address"))?;
            (format!("[{ip}]"), port)
        } else {
            match authority.split_once(':') {
                Some((host, port)) => (normal_name(host)?, Some(port)),
                None => (normal_name(authority)?, None),
            }
        };
        let port = match port {
            Some(p) => Some(p.parse::<u16>().map_err(|_| anyhow!("not a valid address"))?),
            None => None,
        };
        let (path, query) = match tail.split_once('?') {
            Some((path, query)) => (path.to_string(), Some(query.to_string())),
            None => (tail.to_string(), None),
        };
        Ok(Url {
            https,
            host,
            port,
            path,
            query,
        })
    }

    fn origin(&self) -> String {
        let port = self.port.map(|p| format!(":{p}")).unwrap_or_default();
        format!("{}://{}{port}", if self.https { "https" } else { "http" }, self.host)
    }

    /// The address as one string, with `/` for an empty path.
    fn text(&self) -> String {
        let path = if self.path.is_empty() { "/" } else { &self.path };
        let query = self.query.as_ref().map(|q| format!("?{q}")).unwrap_or_default();
        format!("{}{path}{query}", self.origin())
    }

    /// The path without a trailing slash; empty for the root.
    fn trimmed_path(&self) -> &str {
        self.path.trim_end_matches('/')
    }
}

/// A host name or IPv4 address, as one string in one spelling: lower case, one trailing dot (the root) cut, ASCII
/// letters, digits, `-` and `_` in labels that are not empty. An address written as a number in any way but the
/// canonical dotted quad (`127.1`, `0x7f.0.0.1`, `0177.0.0.1`, `2130706433`) is refused: `curl` and the system
/// resolver read those as other addresses than a person does.
fn normal_name(host: &str) -> Result<String> {
    let host = host.to_ascii_lowercase();
    let host = host.strip_suffix('.').unwrap_or(&host);
    let plain = !host.is_empty()
        && host.len() <= 253
        && host.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        });
    if !plain {
        bail!("not a valid address");
    }
    let last = host.rsplit('.').next().unwrap_or_default();
    let digits = last.bytes().all(|b| b.is_ascii_digit());
    let hex = last
        .strip_prefix("0x")
        .is_some_and(|h| h.bytes().all(|b| b.is_ascii_hexdigit()));
    if (digits || hex) && host.parse::<std::net::Ipv4Addr>().is_err() {
        bail!("an address written as a number is not accepted: use the usual form");
    }
    Ok(host.to_string())
}

/// Whether `ip` is the machine itself or a network that is not the public internet: loopback, private, link-local,
/// carrier-grade NAT, unspecified, multicast, broadcast, reserved, unique-local (IPv6), and an IPv4 address inside an
/// IPv6 one (mapped, compatible, NAT64, 6to4) that is any of those.
fn ip_is_local(ip: std::net::IpAddr) -> bool {
    use std::net::{IpAddr, Ipv4Addr};
    fn v4(ip: Ipv4Addr) -> bool {
        let o = ip.octets();
        ip.is_loopback()
            || ip.is_private()
            || ip.is_link_local()
            || ip.is_unspecified()
            || ip.is_broadcast()
            || ip.is_multicast()
            || o[0] == 0
            || (o[0] == 100 && (64..128).contains(&o[1]))
            || (o[0] == 192 && o[1] == 0 && o[2] == 0)
            || (o[0] == 192 && o[1] == 0 && o[2] == 2)
            || (o[0] == 198 && (o[1] == 18 || o[1] == 19))
            || (o[0] == 198 && o[1] == 51 && o[2] == 100)
            || (o[0] == 203 && o[1] == 0 && o[2] == 113)
            || o[0] >= 240
            // 192.88.99.0/24, the old 6to4 relay anycast
            || (o[0] == 192 && o[1] == 88 && o[2] == 99)
    }
    match ip {
        IpAddr::V4(ip) => v4(ip),
        IpAddr::V6(ip) => {
            let s = ip.segments();
            let embedded = |a: u16, b: u16| Ipv4Addr::from([(a >> 8) as u8, a as u8, (b >> 8) as u8, b as u8]);
            ip.is_loopback()
                || ip.is_unspecified()
                || ip.is_multicast()
                || (s[0] & 0xfe00) == 0xfc00
                || (s[0] & 0xffc0) == 0xfe80
                || (s[0] & 0xffc0) == 0xfec0
                || (s[0] == 0x2001 && s[1] == 0x0db8)
                // 2001::/32 (Teredo) carries a server and a client IPv4 address: the whole prefix is refused
                // (both would be local-looking tunnels anyway), and 64:ff9b:1::/48 (local-use NAT64) too
                || (s[0] == 0x2001 && s[1] == 0)
                || (s[0] == 0x0064 && s[1] == 0xff9b && s[2] == 1)
                || ip.to_ipv4_mapped().is_some_and(v4)
                // ::a.b.c.d, the old IPv4-compatible form
                || (s[..6] == [0; 6] && v4(embedded(s[6], s[7])))
                // 64:ff9b::/96 (NAT64)
                || (s[0] == 0x0064 && s[1] == 0xff9b && s[2..6] == [0; 4] && v4(embedded(s[6], s[7])))
                // 2002::/16 (6to4) carries the IPv4 address in the next 32 bits
                || (s[0] == 0x2002 && v4(embedded(s[1], s[2])))
        }
    }
}

/// Whether `host` (as `Url` keeps it) is the machine itself or a network of the person's own, by its spelling.
fn is_local_host(host: &str) -> bool {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = bare.parse::<std::net::IpAddr>() {
        return ip_is_local(ip);
    }
    bare == "localhost"
        || bare.ends_with(".localhost")
        || bare.ends_with(".local")
        || bare.ends_with(".internal")
        || bare.ends_with(".lan")
        || bare.ends_with(".home.arpa")
        || !bare.contains('.')
}

/// The address as an IP, when the host is one.
fn literal_ip(host: &str) -> Option<std::net::IpAddr> {
    host.trim_start_matches('[').trim_end_matches(']').parse().ok()
}

fn is_loopback_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "[::1]")
}

/// Whether the address of the MCP server itself is acceptable: https and public, or (in tests) a loopback http one.
/// The same rule holds for every request (`pin_address`), so a server on the person's own network cannot sign in.
fn check_server_url(url: &Url, allow_local: bool) -> Result<()> {
    if allow_local && is_loopback_host(&url.host) {
        return Ok(());
    }
    if !url.https {
        bail!("signing in needs an https:// address");
    }
    if is_local_host(&url.host) {
        bail!("signing in works with services on the internet, not on a local address");
    }
    Ok(())
}

/// Whether an address the service named (its metadata, its endpoints) is acceptable. It is https and public:
/// a service may not send the daemon to the person's own machine or network.
fn check_remote_url(url: &Url, what: &str, allow_local: bool) -> Result<()> {
    if allow_local && is_loopback_host(&url.host) {
        return Ok(());
    }
    if !url.https {
        bail!("the service's {what} is not an https:// address");
    }
    if is_local_host(&url.host) {
        bail!("the service's {what} points to a local address");
    }
    Ok(())
}

fn allow_local() -> bool {
    cfg!(test)
}

/// `text` with everything but letters, digits and `-._~` as `%XX`.
fn pct_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn form(pairs: &[(&str, &str)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", pct_encode(k), pct_encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

// ---- requests ----

struct Resp {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl Resp {
    fn json(&self) -> Result<Value> {
        serde_json::from_str(&self.body).map_err(|_| anyhow!("the service did not answer with JSON"))
    }

    fn headers_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a str> {
        self.headers
            .iter()
            .filter(move |(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
}

/// A `curl` config string: quoted, with a refusal of control characters, which could start another line.
fn quote(value: &str) -> Result<String> {
    if value.chars().any(|c| c.is_control()) {
        bail!("a request value has a control character");
    }
    Ok(format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\"")))
}

/// Kills the process group of a `curl` when dropped.
struct Group(i32);

impl Drop for Group {
    fn drop(&mut self) {
        if self.0 > 0 {
            // SAFETY: killpg only sends a signal; an unknown group yields ESRCH, which is ignored.
            let _ = unsafe { libc::killpg(self.0, libc::SIGKILL) };
        }
    }
}

struct Req<'a> {
    method: &'a str,
    url: &'a Url,
    headers: Vec<(&'a str, String)>,
    body: Option<String>,
    seconds: u64,
}

impl<'a> Req<'a> {
    fn get(url: &'a Url) -> Self {
        Req {
            method: "GET",
            url,
            headers: vec![("Accept", "application/json".into())],
            body: None,
            seconds: REQUEST_SECONDS,
        }
    }

    fn post(url: &'a Url, content_type: &'static str, body: String) -> Self {
        Req {
            method: "POST",
            url,
            headers: vec![
                ("Content-Type", content_type.into()),
                ("Accept", "application/json".into()),
            ],
            body: Some(body),
            seconds: REQUEST_SECONDS,
        }
    }
}

/// The addresses of `host`. In tests a name can be given addresses by hand (`fake_dns`), so the checks that follow
/// a lookup can be tried without a network.
async fn resolve_host(host: &str, port: u16) -> Result<Vec<std::net::IpAddr>> {
    #[cfg(test)]
    if let Some(found) = fake_dns().lock().unwrap_or_else(|e| e.into_inner()).get(host) {
        return Ok(found.clone());
    }
    let lookup = tokio::net::lookup_host((host, port));
    let found = tokio::time::timeout(Duration::from_secs(RESOLVE_SECONDS), lookup)
        .await
        .map_err(|_| anyhow!("the service's address did not resolve in time"))?
        .map_err(|_| anyhow!("the service's address could not be found"))?;
    Ok(found.map(|a| a.ip()).collect())
}

/// Names the tests gave addresses to.
#[cfg(test)]
pub(crate) fn fake_dns() -> &'static Mutex<HashMap<String, Vec<std::net::IpAddr>>> {
    static MAP: LazyLock<Mutex<HashMap<String, Vec<std::net::IpAddr>>>> = LazyLock::new(Mutex::default);
    &MAP
}

/// The `curl` `resolve` entry that pins `host:port` to the addresses just checked, or `None` when the address is
/// an IP already (or, in tests, the loopback of the fake service). Every address of the name must be public: one
/// address in a private range is enough to refuse, since `curl` could pick it. Pinning means the connection goes to
/// exactly what was checked, not to what a second lookup says (DNS rebinding).
async fn pin_address(url: &Url) -> Result<Option<String>> {
    if allow_local() && is_loopback_host(&url.host) {
        return Ok(None);
    }
    if let Some(ip) = literal_ip(&url.host) {
        if ip_is_local(ip) {
            bail!("the address {} is not a public one", url.host);
        }
        return Ok(None);
    }
    if is_local_host(&url.host) {
        bail!("the address {} is not a public one", url.host);
    }
    let port = url.port.unwrap_or(if url.https { 443 } else { 80 });
    let found = resolve_host(&url.host, port).await?;
    if found.is_empty() {
        bail!("the service's address could not be found");
    }
    if found.iter().any(|ip| ip_is_local(*ip)) {
        bail!("the address {} points to a local address", url.host);
    }
    let list: Vec<String> = found
        .iter()
        .map(|ip| match ip {
            std::net::IpAddr::V4(v4) => v4.to_string(),
            std::net::IpAddr::V6(v6) => format!("[{v6}]"),
        })
        .collect();
    Ok(Some(format!("{}:{port}:{}", url.host, list.join(","))))
}

/// The arguments of every `curl` that carries a sign-in: `-q` first, so `~/.curlrc` is not read (it could set a
/// proxy, a resolver or a redirect), then the request on stdin.
pub(crate) const CURL_ARGS: [&str; 3] = ["-q", "--config", "-"];

/// For a request made outside this module that carries a token (the probe of `rpc/integrations.rs`): the same checks
/// as a sign-in request. Returns the address to use (in the one spelling the pin is made for) and the `curl`
/// configuration lines that pin the connection and switch off globbing, proxies and plain http.
pub(crate) async fn guard_http(url: &str) -> Result<(String, String)> {
    let parsed = Url::parse(url)?;
    check_server_url(&parsed, allow_local())?;
    let pin = pin_address(&parsed).await?;
    let mut lines = String::from("globoff\nnoproxy = \"*\"\n");
    lines.push_str(if allow_local() {
        "proto = \"=https,http\"\n"
    } else {
        "proto = \"=https\"\n"
    });
    if let Some(pin) = pin {
        lines.push_str(&format!("resolve = {}\n", quote(&pin)?));
    }
    Ok((parsed.text(), lines))
}

/// The `curl` configuration of a request. `pin` is the `resolve` entry from [`pin_address`].
fn curl_config(req: &Req<'_>, pin: Option<&str>, local: bool) -> Result<String> {
    let mut config = String::new();
    config.push_str(&format!("url = {}\n", quote(&req.url.text())?));
    config.push_str(&format!("request = {}\n", quote(req.method)?));
    // `globoff`: no `[]`/`{}` expansion in the address. No `location`: a redirect is not followed.
    // `noproxy`: a proxy would do the lookup itself, and `resolve` pins nothing then.
    config.push_str("silent\nshow-error\ninclude\ngloboff\nnoproxy = \"*\"\n");
    config.push_str(if local {
        "proto = \"=https,http\"\n"
    } else {
        "proto = \"=https\"\n"
    });
    config.push_str(&format!(
        "max-time = {}\nconnect-timeout = 8\nmax-filesize = {MAX_RESPONSE_BYTES}\n",
        req.seconds
    ));
    if let Some(pin) = pin {
        config.push_str(&format!("resolve = {}\n", quote(pin)?));
    }
    for (name, value) in &req.headers {
        config.push_str(&format!("header = {}\n", quote(&format!("{name}: {value}"))?));
    }
    if let Some(body) = &req.body {
        config.push_str(&format!("data-raw = {}\n", quote(body)?));
    }
    Ok(config)
}

/// One request. Redirects are not followed: a service may not hand the daemon on to another address. The name is
/// looked up here, every address must be public, and the connection is pinned to what was checked.
async fn send(req: Req<'_>) -> Result<Resp> {
    let pin = pin_address(req.url).await?;
    let config = curl_config(&req, pin.as_deref(), allow_local())?;
    let mut cmd = tokio::process::Command::new("curl");
    cmd.args(CURL_ARGS)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    std::os::unix::process::CommandExt::process_group(cmd.as_std_mut(), 0);
    let mut child = cmd.spawn().map_err(|e| anyhow!("cannot run curl: {e}"))?;
    let _group = Group(child.id().unwrap_or(0) as i32);
    let mut stdin = child.stdin.take().ok_or_else(|| anyhow!("no stdin"))?;
    let mut stdout = child.stdout.take().ok_or_else(|| anyhow!("no stdout"))?;
    let mut stderr = child.stderr.take().ok_or_else(|| anyhow!("no stderr"))?;
    let limit = Duration::from_secs(req.seconds + 5);
    let run = async {
        stdin.write_all(config.as_bytes()).await?;
        drop(stdin);
        let mut out = Vec::new();
        (&mut stdout).take(MAX_RESPONSE_BYTES).read_to_end(&mut out).await?;
        let mut err = Vec::new();
        (&mut stderr).take(4096).read_to_end(&mut err).await?;
        let status = child.wait().await?;
        anyhow::Ok((out, err, status))
    };
    let (out, err, status) = tokio::time::timeout(limit, run)
        .await
        .map_err(|_| anyhow!("the service did not answer in time"))??;
    if !status.success() {
        let line: String = String::from_utf8_lossy(&err)
            .lines()
            .next()
            .unwrap_or_default()
            .chars()
            .filter(|c| !c.is_control())
            .take(200)
            .collect();
        bail!("could not reach the service ({line})");
    }
    parse_response(&String::from_utf8_lossy(&out))
}

/// Status, headers (names in lower case) and body of a `curl -i` answer. An interim `1xx` block is skipped.
fn parse_response(raw: &str) -> Result<Resp> {
    let mut rest = raw;
    loop {
        let (head, body) = rest
            .split_once("\r\n\r\n")
            .or_else(|| rest.split_once("\n\n"))
            .unwrap_or((rest, ""));
        let mut lines = head.lines();
        let status = lines
            .next()
            .and_then(|l| l.split_whitespace().nth(1))
            .and_then(|c| c.parse::<u16>().ok())
            .ok_or_else(|| anyhow!("the service's answer has no HTTP status"))?;
        if (100..200).contains(&status) && body.starts_with("HTTP/") {
            rest = body;
            continue;
        }
        let headers = lines
            .filter_map(|l| l.split_once(':'))
            .map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string()))
            .collect();
        return Ok(Resp {
            status,
            headers,
            body: body.to_string(),
        });
    }
}

/// The `name="value"` pairs of a `WWW-Authenticate` header, after its scheme.
fn challenge_params(header: &str) -> Vec<(String, String)> {
    let chars: Vec<char> = header.trim().chars().collect();
    let mut i = chars.iter().position(|c| c.is_whitespace()).unwrap_or(chars.len());
    let mut out = Vec::new();
    while i < chars.len() {
        while i < chars.len() && (chars[i].is_whitespace() || chars[i] == ',') {
            i += 1;
        }
        let start = i;
        while i < chars.len() && chars[i] != '=' && chars[i] != ',' && !chars[i].is_whitespace() {
            i += 1;
        }
        let key: String = chars[start..i].iter().collect();
        if i >= chars.len() || chars[i] != '=' {
            continue;
        }
        i += 1;
        let mut value = String::new();
        if i < chars.len() && chars[i] == '"' {
            i += 1;
            while i < chars.len() && chars[i] != '"' {
                if chars[i] == '\\' && i + 1 < chars.len() {
                    i += 1;
                }
                value.push(chars[i]);
                i += 1;
            }
            i += 1;
        } else {
            while i < chars.len() && chars[i] != ',' && !chars[i].is_whitespace() {
                value.push(chars[i]);
                i += 1;
            }
        }
        if !key.is_empty() {
            out.push((key.to_ascii_lowercase(), value));
        }
    }
    out
}

fn challenge_param(resp: &Resp, name: &str) -> Option<String> {
    resp.headers_named("www-authenticate")
        .flat_map(challenge_params)
        .find(|(k, _)| k == name)
        .map(|(_, v)| v)
}

// ---- discovery ----

/// What the sign-in needs to know about a service.
#[derive(Debug, Clone)]
struct Discovery {
    /// The `resource` parameter: the MCP server the token is for.
    resource: String,
    issuer: String,
    authorization_endpoint: Url,
    token_endpoint: Url,
    registration_endpoint: Option<Url>,
    revocation_endpoint: Option<Url>,
    /// The scope the server asked for in its challenge, if it did.
    scope: Option<String>,
}

/// Whether `resource` (from the metadata) names `server` or a part of the address above it.
fn resource_covers(resource: &Url, server: &Url) -> bool {
    if resource.origin() != server.origin() {
        return false;
    }
    let base = resource.trimmed_path();
    let path = server.trimmed_path();
    path == base || path.starts_with(&format!("{base}/"))
}

async fn fetch_json(url: &Url) -> Result<Value> {
    let resp = send(Req::get(url)).await?;
    if resp.status != 200 {
        bail!("HTTP {}", resp.status);
    }
    resp.json()
}

/// The protected-resource metadata of `server`: from the challenge, else the well-known addresses.
async fn protected_resource(server: &Url, from_challenge: Option<String>) -> Result<(String, Vec<String>)> {
    let mut candidates: Vec<String> = Vec::new();
    candidates.extend(from_challenge);
    let origin = server.origin();
    if !server.trimmed_path().is_empty() {
        candidates.push(format!(
            "{origin}/.well-known/oauth-protected-resource{}",
            server.trimmed_path()
        ));
    }
    candidates.push(format!("{origin}/.well-known/oauth-protected-resource"));
    for candidate in candidates {
        let Ok(url) = Url::parse(&candidate) else { continue };
        if check_remote_url(&url, "metadata address", allow_local()).is_err() {
            continue;
        }
        let Ok(meta) = fetch_json(&url).await else { continue };
        let Some(resource) = meta.get("resource").and_then(Value::as_str) else {
            continue;
        };
        let Ok(parsed) = Url::parse(resource) else { continue };
        if !resource_covers(&parsed, server) {
            bail!("the service's metadata describes a different server");
        }
        let servers: Vec<String> = meta
            .get("authorization_servers")
            .and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_str).map(str::to_string).collect())
            .unwrap_or_default();
        if servers.is_empty() {
            continue;
        }
        return Ok((resource.to_string(), servers));
    }
    bail!("no protected-resource metadata")
}

/// The authorization-server metadata of `issuer`: OAuth first, then OpenID. The `issuer` in it must be `issuer`.
async fn authorization_server(issuer: &str, resource: &str, scope: Option<String>) -> Result<Discovery> {
    let base = Url::parse(issuer)?;
    check_remote_url(&base, "authorization server", allow_local())?;
    let origin = base.origin();
    let path = base.trimmed_path();
    let mut candidates = Vec::new();
    if path.is_empty() {
        candidates.push(format!("{origin}/.well-known/oauth-authorization-server"));
        candidates.push(format!("{origin}/.well-known/openid-configuration"));
    } else {
        candidates.push(format!("{origin}/.well-known/oauth-authorization-server{path}"));
        candidates.push(format!("{origin}/.well-known/openid-configuration{path}"));
        candidates.push(format!("{origin}{path}/.well-known/openid-configuration"));
    }
    let mut missing = anyhow!("no authorization-server metadata");
    // A document that answered but is not acceptable says more than a 404 on the next address.
    let mut refused: Option<anyhow::Error> = None;
    for candidate in candidates {
        let url = Url::parse(&candidate)?;
        let meta = match fetch_json(&url).await {
            Ok(meta) => meta,
            Err(e) => {
                missing = e;
                continue;
            }
        };
        match read_server_metadata(&meta, issuer, resource, scope.clone()) {
            Ok(found) => return Ok(found),
            Err(e) => refused = refused.or(Some(e)),
        }
    }
    Err(refused
        .unwrap_or(missing)
        .context("could not read the service's sign-in metadata"))
}

fn read_server_metadata(meta: &Value, issuer: &str, resource: &str, scope: Option<String>) -> Result<Discovery> {
    let text = |key: &str| meta.get(key).and_then(Value::as_str);
    if text("issuer").map(|i| i.trim_end_matches('/')) != Some(issuer.trim_end_matches('/')) {
        bail!("the service's metadata names another issuer");
    }
    let endpoint = |key: &str, what: &str| -> Result<Url> {
        let url = Url::parse(text(key).ok_or_else(|| anyhow!("the service's metadata has no {what}"))?)?;
        check_remote_url(&url, what, allow_local())?;
        Ok(url)
    };
    // The specification: without `code_challenge_methods_supported` the server does not do PKCE, and a client
    // must not go on.
    let pkce = meta
        .get("code_challenge_methods_supported")
        .and_then(Value::as_array)
        .is_some_and(|m| m.iter().any(|v| v.as_str() == Some("S256")));
    if !pkce {
        bail!("the service does not support PKCE (S256)");
    }
    if let Some(grants) = meta.get("grant_types_supported").and_then(Value::as_array)
        && !grants.iter().any(|g| g.as_str() == Some("authorization_code"))
    {
        bail!("the service does not offer the authorization code grant");
    }
    Ok(Discovery {
        resource: resource.to_string(),
        issuer: issuer.to_string(),
        authorization_endpoint: endpoint("authorization_endpoint", "authorization address")?,
        token_endpoint: endpoint("token_endpoint", "token address")?,
        registration_endpoint: endpoint("registration_endpoint", "registration address").ok(),
        revocation_endpoint: endpoint("revocation_endpoint", "revocation address").ok(),
        scope,
    })
}

/// Reads the metadata of a server: the challenge of an unsigned request, the resource metadata, the first
/// authorization server that answers.
async fn discover(server: &Url) -> Result<Discovery> {
    let init = json!({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {
            "protocolVersion": PROTOCOL,
            "capabilities": {},
            "clientInfo": { "name": "bandito", "version": env!("CARGO_PKG_VERSION") },
        }
    });
    let mut req = Req::post(server, "application/json", init.to_string());
    req.headers
        .push(("Accept", "application/json, text/event-stream".into()));
    req.headers.push(("MCP-Protocol-Version", PROTOCOL.into()));
    let probe = send(req).await.context("could not reach the server")?;
    let (from_challenge, scope) = if probe.status == 401 {
        (
            challenge_param(&probe, "resource_metadata"),
            challenge_param(&probe, "scope"),
        )
    } else {
        (None, None)
    };
    match protected_resource(server, from_challenge).await {
        Ok((resource, issuers)) => {
            let mut last = anyhow!("the server names no authorization server");
            for issuer in issuers {
                match authorization_server(&issuer, &resource, scope.clone()).await {
                    Ok(found) => return Ok(found),
                    Err(e) => last = e,
                }
            }
            Err(last)
        }
        // A server of the earlier specification has no resource metadata: its own address is the issuer.
        Err(e) if e.to_string() == "no protected-resource metadata" => {
            let issuer = server.origin();
            authorization_server(&issuer, server.text().trim_end_matches('/'), scope).await
        }
        Err(e) => Err(e),
    }
}

// ---- registration ----

/// Registers Bandito as a public client (RFC 7591) and returns its `client_id`.
async fn register(endpoint: &Url) -> Result<String> {
    let body = json!({
        "client_name": "Bandito",
        "redirect_uris": [REDIRECT_URI],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
        "application_type": "native",
    });
    let resp = send(Req::post(endpoint, "application/json", body.to_string())).await?;
    if resp.status != 200 && resp.status != 201 {
        bail!("the service refused to register Bandito (HTTP {})", resp.status);
    }
    let v = resp.json()?;
    let client_id = v
        .get("client_id")
        .and_then(Value::as_str)
        .filter(|id| valid_client_id(id))
        .ok_or_else(|| anyhow!("the service's registration has no usable client_id"))?;
    if let Some(uris) = v.get("redirect_uris").and_then(Value::as_array)
        && !uris.iter().any(|u| u.as_str() == Some(REDIRECT_URI))
    {
        bail!("the service registered another redirect address");
    }
    if v.get("token_endpoint_auth_method")
        .and_then(Value::as_str)
        .is_some_and(|m| m != "none")
    {
        bail!("the service wants a client secret, which Bandito does not hold");
    }
    Ok(client_id.to_string())
}

fn valid_client_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 512 && !id.chars().any(|c| c.is_control() || c.is_whitespace())
}

// ---- pending sign-ins ----

/// A sign-in the person has been sent to the browser for.
struct Flow {
    /// Who started it: only this device may finish it.
    device: String,
    integration_id: Option<String>,
    draft: Option<NewIntegration>,
    /// The server's address as it was when the sign-in started.
    url: String,
    verifier: String,
    client_id: String,
    issuer: String,
    token_endpoint: String,
    revocation_endpoint: Option<String>,
    resource: String,
    scope: Option<String>,
    created_at: i64,
}

/// The sign-ins waiting for the browser. One state, one use, ten minutes.
#[derive(Default)]
pub struct Flows(Mutex<HashMap<String, Flow>>);

impl Flows {
    fn insert(&self, state: String, flow: Flow, now: i64) {
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        map.retain(|_, f| now - f.created_at <= FLOW_TTL_MS);
        while map.len() >= MAX_FLOWS {
            let oldest = map.iter().min_by_key(|(_, f)| f.created_at).map(|(s, _)| s.clone());
            match oldest {
                Some(s) => map.remove(&s),
                None => break,
            };
        }
        map.insert(state, flow);
    }

    /// Takes the flow of `state` out: it can be used once. A device other than the one that started it is refused
    /// and leaves the flow where it is.
    fn take(&self, state: &str, device: &str, now: i64) -> Result<Flow> {
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let Some(flow) = map.get(state) else {
            bail!("this sign-in is not waiting any more: start it again");
        };
        if flow.device != device {
            bail!("this sign-in was started on another device");
        }
        let flow = map
            .remove(state)
            .ok_or_else(|| anyhow!("this sign-in is not waiting any more"))?;
        if now - flow.created_at > FLOW_TTL_MS {
            bail!("this sign-in expired: start it again");
        }
        Ok(flow)
    }

    /// Drops a waiting sign-in of `device`. `false` when there was none.
    pub fn cancel(&self, state: &str, device: &str) -> bool {
        let mut map = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if map.get(state).is_some_and(|f| f.device == device) {
            map.remove(state);
            return true;
        }
        false
    }
}

// ---- stored sign-in ----

/// What the daemon keeps besides the access token (secret `…_STATE`, JSON).
#[derive(Serialize, Deserialize, Clone)]
struct Stored {
    #[serde(default)]
    refresh_token: Option<String>,
    client_id: String,
    issuer: String,
    token_endpoint: String,
    #[serde(default)]
    revocation_endpoint: Option<String>,
    resource: String,
    #[serde(default)]
    scope: Option<String>,
    /// Unix ms the access token ends; `None` when the service did not say (`expires_in` missing: the token is taken
    /// as long-lived, it is not renewed in the background, and only a 401 renews it).
    #[serde(default)]
    expires_at: Option<i64>,
    /// Unix ms the last token was issued.
    #[serde(default)]
    issued_at: Option<i64>,
    /// How long the last token lived (`expires_in`), in ms. A token is renewed when the margin of the caller or
    /// half of this is left, whichever is less.
    #[serde(default)]
    lifetime_ms: Option<i64>,
    /// The service refused the refresh token: the person has to sign in again.
    #[serde(default)]
    needs_login: bool,
}

impl Stored {
    /// The token lives for this long, if known.
    fn lifetime(&self) -> Option<i64> {
        self.lifetime_ms
            .or_else(|| self.expires_at.zip(self.issued_at).map(|(end, start)| end - start))
            .filter(|l| *l > 0)
    }

    /// Whether the token should be renewed now: it ends within `skew` ms, but never earlier than half its life, so a
    /// token that lives five minutes is renewed once per life and not on every look.
    fn due(&self, skew: i64, now: i64) -> bool {
        let margin = self.lifetime().map_or(skew, |l| skew.min(l / 2));
        self.expires_at.is_some_and(|e| e - now <= margin)
    }
}

fn load_stored(store: &Store, id: &str) -> Result<Option<Stored>> {
    let Some(text) = store.secret_get(&oauth_state_name(id))? else {
        return Ok(None);
    };
    // A state that does not read is no state: the person signs in again.
    Ok(serde_json::from_str(&text).ok())
}

/// Writes the access token and the state together, in one transaction: a failure leaves both as they were. A
/// rotated refresh token and the access token it came with are never apart.
fn save_tokens(store: &Store, id: &str, access: &str, stored: &Stored) -> Result<()> {
    store.secrets_set_many(&[
        (&oauth_access_name(id), access),
        (&oauth_state_name(id), &serde_json::to_string(stored)?),
    ])
}

/// Writes the state alone (a mark that the person has to sign in again).
fn save_state(store: &Store, id: &str, stored: &Stored) -> Result<()> {
    store.secrets_set_many(&[(&oauth_state_name(id), &serde_json::to_string(stored)?)])
}

/// The client Bandito registered with a service (RFC 7591), kept apart from the tokens: a disconnect deletes the
/// tokens and leaves this, so the next sign-in does not register again.
#[derive(Serialize, Deserialize, Clone)]
struct Client {
    issuer: String,
    redirect_uri: String,
    client_id: String,
}

fn load_client(store: &Store, id: &str) -> Result<Option<Client>> {
    let Some(text) = store.secret_get(&oauth_client_name(id))? else {
        return Ok(None);
    };
    Ok(serde_json::from_str(&text).ok())
}

/// Deletes the registered client of an integration, after the service said it does not know it. A failure to delete
/// only goes to the log (the next sign-in then fails the same way and tries this again).
fn forget_client(store: &Store, id: &str) {
    if let Err(e) = store.secrets_delete_many(&[&oauth_client_name(id)]) {
        tracing::warn!("could not forget a client the service refused: {e:#}");
    }
}

// ---- a renewal that could not be written ----

/// A renewed sign-in that the database refused twice. The service has rotated the refresh token already, so the old
/// state is dead; this is the only copy of the live one. It is written at the next try, and sessions use its access
/// token meanwhile. In memory, under the integration's lock.
static HELD: LazyLock<Mutex<HashMap<String, (String, Stored)>>> = LazyLock::new(Mutex::default);

fn held_access(id: &str) -> Option<String> {
    HELD.lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(id)
        .map(|(access, _)| access.clone())
}

fn forget_held(id: &str) {
    HELD.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
}

/// Puts the access tokens that could not be written into `secrets` (name, value), over the stored ones.
pub fn overlay_held(secrets: &mut [(String, String)]) {
    let map = HELD.lock().unwrap_or_else(|e| e.into_inner());
    if map.is_empty() {
        return;
    }
    for (id, (access, _)) in map.iter() {
        let name = oauth_access_name(id);
        if let Some(slot) = secrets.iter_mut().find(|(n, _)| *n == name) {
            slot.1 = access.clone();
        }
    }
}

// ---- failed renewals ----

/// A renewal that failed for a reason that may pass.
struct Failing {
    failures: u32,
    retry_at: i64,
    error: String,
}

/// Per integration; in memory only: a restart tries again at once.
static FAILING: LazyLock<Mutex<HashMap<String, Failing>>> = LazyLock::new(Mutex::default);

/// Longest wait between two tries after failures.
const MAX_BACKOFF_MS: i64 = 30 * 60 * 1000;
/// The wait after the first failure; it doubles with each next one.
const FIRST_BACKOFF_MS: i64 = 60 * 1000;

fn backoff_ms(failures: u32) -> i64 {
    FIRST_BACKOFF_MS
        .saturating_mul(1 << failures.saturating_sub(1).min(16))
        .min(MAX_BACKOFF_MS)
}

fn note_failure(id: &str, text: &str, now: i64) {
    let mut map = FAILING.lock().unwrap_or_else(|e| e.into_inner());
    let failures = map.get(id).map_or(1, |f| f.failures.saturating_add(1));
    let error: String = text.chars().filter(|c| !c.is_control()).take(160).collect();
    map.insert(
        id.to_string(),
        Failing {
            failures,
            retry_at: now + backoff_ms(failures),
            error,
        },
    );
}

fn clear_failure(id: &str) {
    FAILING.lock().unwrap_or_else(|e| e.into_inner()).remove(id);
}

/// `(retry_at, error)` of a renewal that is failing.
fn failing(id: &str) -> Option<(i64, String)> {
    FAILING
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(id)
        .map(|f| (f.retry_at, f.error.clone()))
}

/// Per integration: one refresh, sign-in or disconnect at a time.
static LOCKS: LazyLock<Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>> = LazyLock::new(Mutex::default);

async fn lock(id: &str) -> tokio::sync::OwnedMutexGuard<()> {
    let slot = LOCKS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .entry(id.to_string())
        .or_default()
        .clone();
    slot.lock_owned().await
}

// ---- tokens ----

struct Tokens {
    access: String,
    refresh: Option<String>,
    expires_at: Option<i64>,
    /// `expires_in` in ms.
    lifetime_ms: Option<i64>,
    scope: Option<String>,
}

#[derive(Debug, thiserror::Error)]
enum TokenFail {
    /// The service said the grant or the client is no good (HTTP 400 or 401 with `invalid_grant` or
    /// `invalid_client`): it will not work again, the person signs in.
    /// The flag: the error was `invalid_client`, so the registered client is no good either.
    #[error("{0}")]
    Rejected(String, bool),
    /// Anything that may pass: no network, a 5xx, an answer that did not read.
    #[error("{0}")]
    Transient(String),
}

/// A short text from the service, safe to show: control characters out, known secrets hidden, cut.
fn clean(text: &str, redactor: &Redactor, max: usize) -> String {
    redactor
        .redact(text)
        .chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect()
}

/// `error` codes are `[A-Za-z0-9_.:-]` and short; anything else is dropped.
fn error_code(v: &Value) -> Option<String> {
    let code = v.get("error")?.as_str()?;
    (!code.is_empty() && code.len() <= 64 && code.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b)))
        .then(|| code.to_string())
}

/// One call to a token endpoint. `secrets` are the values to hide in anything written about a failure.
async fn token_call(
    endpoint: &str,
    pairs: &[(&str, &str)],
    secrets: &[(String, String)],
    now: i64,
) -> Result<Tokens, TokenFail> {
    let redactor = Redactor::exact(secrets.iter().cloned());
    let url = Url::parse(endpoint).map_err(|e| TokenFail::Transient(format!("{e:#}")))?;
    let resp = send(Req::post(&url, "application/x-www-form-urlencoded", form(pairs)))
        .await
        .map_err(|e| TokenFail::Transient(clean(&format!("{e:#}"), &redactor, 300)))?;
    let body = resp.json().ok();
    if resp.status != 200 {
        let code = body.as_ref().and_then(error_code);
        let detail = body
            .as_ref()
            .and_then(|b| b.get("error_description"))
            .and_then(Value::as_str)
            .map(|d| clean(d, &redactor, 200))
            .filter(|d| !d.is_empty());
        let mut text = format!("the service answered HTTP {}", resp.status);
        if let Some(code) = &code {
            text.push_str(&format!(" ({code})"));
        }
        if let Some(detail) = detail {
            text.push_str(&format!(": {detail}"));
        }
        // Only these two say the sign-in itself is over. Any other answer (a 403 from a gateway, a 429, a 5xx, a
        // 400 with another error) may pass, and must not cost the person their sign-in.
        let refused =
            matches!(resp.status, 400 | 401) && matches!(code.as_deref(), Some("invalid_grant" | "invalid_client"));
        return Err(if refused {
            TokenFail::Rejected(text, code.as_deref() == Some("invalid_client"))
        } else {
            TokenFail::Transient(text)
        });
    }
    let body = body.ok_or_else(|| TokenFail::Transient("the service's token answer is not JSON".into()))?;
    let access = body
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
        .ok_or_else(|| TokenFail::Transient("the service's answer has no access token".into()))?;
    if body
        .get("token_type")
        .and_then(Value::as_str)
        .is_some_and(|t| !t.eq_ignore_ascii_case("bearer"))
    {
        return Err(TokenFail::Transient(
            "the service issued a token that is not a Bearer token".into(),
        ));
    }
    let seconds = match body.get("expires_in") {
        Some(Value::Number(n)) => n.as_i64(),
        Some(Value::String(s)) => s.parse::<i64>().ok(),
        _ => None,
    };
    Ok(Tokens {
        access: access.to_string(),
        refresh: body
            .get("refresh_token")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
            .map(str::to_string),
        expires_at: seconds
            .filter(|s| *s > 0)
            .map(|s| now + s.min(10 * 365 * 86_400) * 1000),
        lifetime_ms: seconds.filter(|s| *s > 0).map(|s| s.min(10 * 365 * 86_400) * 1000),
        scope: body
            .get("scope")
            .and_then(Value::as_str)
            .map(|s| clean(s, &Redactor::default(), 500)),
    })
}

// ---- begin and complete ----

/// What a sign-in is for: a row that exists, or one the sign-in creates when it succeeds.
pub enum Target {
    Existing(Integration),
    Draft(NewIntegration),
}

pub struct Begun {
    pub authorize_url: String,
    pub state: String,
}

fn random_token() -> String {
    let bytes: [u8; 32] = rand::random();
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Starts a sign-in for `device`: reads the service's metadata, registers Bandito if it must, and returns the address
/// the person opens in the browser. `client_id` is a client registered with the service beforehand, for one that
/// has no dynamic registration.
pub async fn begin(
    store: &Store,
    flows: &Flows,
    device: &str,
    target: Target,
    client_id: Option<String>,
    now: i64,
) -> Result<Begun> {
    let (integration_id, draft, kind, url) = match target {
        Target::Existing(row) => (Some(row.id), None, row.kind, row.url),
        Target::Draft(n) => {
            let (kind, url) = (n.kind, n.url.clone());
            (None, Some(n), kind, url)
        }
    };
    if kind != IntegrationKind::Http {
        bail!("only an http integration can sign in in the browser");
    }
    let url = url
        .filter(|u| !u.trim().is_empty())
        .ok_or_else(|| anyhow!("the integration has no url"))?;
    let server = Url::parse(&url)?;
    check_server_url(&server, allow_local())?;
    let found = discover(&server).await?;
    // A client registered earlier for this issuer and this redirect address is used again, also after a disconnect.
    let known = match &integration_id {
        Some(id) => load_client(store, id)?
            .filter(|c| c.issuer == found.issuer && c.redirect_uri == REDIRECT_URI && valid_client_id(&c.client_id)),
        None => None,
    };
    let client_id = match (client_id, known) {
        (Some(id), _) => {
            if !valid_client_id(&id) {
                bail!("the client id is not valid");
            }
            id
        }
        (None, Some(known)) => known.client_id,
        (None, None) => match &found.registration_endpoint {
            Some(endpoint) => register(endpoint).await?,
            None => bail!(
                "this service cannot be signed in to from Bandito (it does not take new clients): use a token instead"
            ),
        },
    };
    let verifier = random_token();
    let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let state = random_token();
    let mut pairs = vec![
        ("response_type", "code"),
        ("client_id", client_id.as_str()),
        ("redirect_uri", REDIRECT_URI),
        ("code_challenge", challenge.as_str()),
        ("code_challenge_method", "S256"),
        ("state", state.as_str()),
        ("resource", found.resource.as_str()),
    ];
    if let Some(scope) = &found.scope {
        pairs.push(("scope", scope.as_str()));
    }
    let endpoint = &found.authorization_endpoint;
    let joined = match &endpoint.query {
        Some(q) if !q.is_empty() => format!("{q}&{}", form(&pairs)),
        _ => form(&pairs),
    };
    let authorize_url = format!(
        "{}{}?{joined}",
        endpoint.origin(),
        if endpoint.path.is_empty() { "/" } else { &endpoint.path }
    );
    flows.insert(
        state.clone(),
        Flow {
            device: device.to_string(),
            integration_id,
            draft,
            url,
            verifier,
            client_id,
            issuer: found.issuer,
            token_endpoint: found.token_endpoint.text(),
            revocation_endpoint: found.revocation_endpoint.map(|u| u.text()),
            resource: found.resource,
            scope: found.scope,
            created_at: now,
        },
        now,
    );
    Ok(Begun { authorize_url, state })
}

pub struct Completed {
    pub integration: Integration,
    /// The sign-in made the row (it started from a draft).
    pub created: bool,
}

/// Finishes a sign-in: checks the state, trades the code for tokens and stores them. The state is spent whatever
/// the outcome. `iss` is the issuer the answer carried (RFC 9207), when it carried one.
pub async fn complete(
    store: &Store,
    flows: &Flows,
    device: &str,
    state: &str,
    code: &str,
    iss: Option<&str>,
    now: i64,
) -> Result<Completed> {
    let flow = flows.take(state, device, now)?;
    if code.is_empty() || code.len() > 4096 || code.chars().any(|c| c.is_control() || c.is_whitespace()) {
        bail!("the sign-in answer has no usable code");
    }
    if iss.is_some_and(|i| i.trim_end_matches('/') != flow.issuer.trim_end_matches('/')) {
        bail!("the sign-in answer came from another service than the one asked");
    }
    let hide = vec![
        ("CODE".to_string(), code.to_string()),
        ("CODE_VERIFIER".to_string(), flow.verifier.clone()),
    ];
    let tokens = token_call(
        &flow.token_endpoint,
        &[
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", REDIRECT_URI),
            ("client_id", &flow.client_id),
            ("code_verifier", &flow.verifier),
            ("resource", &flow.resource),
        ],
        &hide,
        now,
    )
    .await
    .map_err(|e| match e {
        TokenFail::Rejected(t, invalid_client) => {
            if invalid_client && let Some(id) = &flow.integration_id {
                // The service does not know this client (any more): the next sign-in registers a new one.
                forget_client(store, id);
            }
            anyhow!("the service refused the sign-in: {t}")
        }
        TokenFail::Transient(t) => anyhow!("the sign-in could not be finished: {t}"),
    })?;
    let stored = Stored {
        refresh_token: tokens.refresh.clone(),
        client_id: flow.client_id.clone(),
        issuer: flow.issuer.clone(),
        token_endpoint: flow.token_endpoint.clone(),
        revocation_endpoint: flow.revocation_endpoint.clone(),
        resource: flow.resource.clone(),
        scope: tokens.scope.clone().or(flow.scope.clone()),
        expires_at: tokens.expires_at,
        issued_at: Some(now),
        lifetime_ms: tokens.lifetime_ms,
        needs_login: false,
    };
    let client = Client {
        issuer: flow.issuer.clone(),
        redirect_uri: REDIRECT_URI.to_string(),
        client_id: flow.client_id.clone(),
    };
    let (integration, created) = match (&flow.integration_id, flow.draft) {
        (Some(id), _) => {
            let row = store
                .integration_get(id)?
                .ok_or_else(|| anyhow!("that integration was removed while the browser was open"))?;
            if row.url.as_deref() != Some(flow.url.as_str()) {
                bail!("the integration's address changed while the browser was open");
            }
            (row, false)
        }
        (None, Some(mut draft)) => {
            if store.integration_list()?.iter().any(|i| i.name == draft.name) {
                bail!("an integration named '{}' already exists", draft.name);
            }
            draft.auth = IntegrationAuth::Oauth;
            (store.integration_create(draft)?, true)
        }
        (None, None) => bail!("this sign-in has no integration"),
    };
    let _guard = lock(&integration.id).await;
    // The token, its state and the client go in together: a failure leaves what was there.
    let saved = serde_json::to_string(&stored)
        .map_err(anyhow::Error::from)
        .and_then(|state| {
            let client = serde_json::to_string(&client)?;
            store.secrets_set_many(&[
                (&oauth_access_name(&integration.id), &tokens.access),
                (&oauth_state_name(&integration.id), &state),
                (&oauth_client_name(&integration.id), &client),
            ])
        })
        .and_then(|()| {
            store
                .integration_set_auth(&integration.id, IntegrationAuth::Oauth)
                .map(|_| ())
        });
    if let Err(e) = saved {
        if created {
            let _ = store.integration_delete(&integration.id);
            let _ = store.secrets_delete_many(&[
                &oauth_access_name(&integration.id),
                &oauth_state_name(&integration.id),
                &oauth_client_name(&integration.id),
            ]);
        }
        return Err(e.context("could not store the sign-in"));
    }
    clear_failure(&integration.id);
    forget_held(&integration.id);
    let integration = store.integration_get(&integration.id)?.unwrap_or(integration);
    Ok(Completed { integration, created })
}

// ---- status ----

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Status {
    /// `connected`; `refresh_error` (the sign-in is there, but renewing it keeps failing for a reason that may pass:
    /// `error` says what, short); `needs_login` (the service refused or the token ran out with nothing to renew it);
    /// `not_connected` (no sign-in yet, or disconnected).
    pub status: &'static str,
    pub expires_at: Option<i64>,
    pub scope: Option<String>,
    /// For `refresh_error`: a short text, never a token.
    pub error: Option<String>,
}

pub fn status(store: &Store, id: &str, now: i64) -> Result<Status> {
    let stored = load_stored(store, id)?;
    let access = store.secret_get(&oauth_access_name(id))?;
    let (Some(stored), Some(_)) = (stored, access) else {
        return Ok(Status {
            status: "not_connected",
            expires_at: None,
            scope: None,
            error: None,
        });
    };
    let ended = stored.expires_at.is_some_and(|e| e <= now);
    let ok = !stored.needs_login && (!ended || stored.refresh_token.is_some());
    let failed = if ok { failing(id).map(|(_, error)| error) } else { None };
    Ok(Status {
        status: match (ok, &failed) {
            (false, _) => "needs_login",
            (true, Some(_)) => "refresh_error",
            (true, None) => "connected",
        },
        expires_at: stored.expires_at,
        scope: stored.scope,
        error: failed,
    })
}

// ---- refresh ----

/// Why a token is renewed.
pub enum Why {
    /// It ends within `skew` ms, but not before half of its life has passed (see [`Stored::due`]). A token without
    /// an end (`expires_in` missing) is never renewed for this reason.
    Expiring(i64),
    /// The service refused it (a 401); `stale` is the token that was refused. When the stored token is another one,
    /// somebody has renewed it already.
    Rejected(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing to do: the token is good, or was renewed by someone else, or the renewal gave the same token.
    Unchanged,
    /// The access token is another one now.
    Refreshed,
    /// There is no way to renew it: the person signs in again.
    NeedsLogin,
    /// The last renewal failed for a reason that may pass and the next try is not due yet.
    Waiting,
}

/// Renews the access token of an integration, once at a time per integration. The service saying the grant or the
/// client is no good (`invalid_grant`, `invalid_client`) marks the sign-in as needing the person. Anything else that
/// goes wrong (no network, a 5xx, a 403, a 429, an answer that does not read) is an error and touches nothing
/// stored: the next tries wait 1, 2, 4 ... up to 30 minutes, and `status` says `refresh_error`.
pub async fn refresh(store: &Store, id: &str, why: Why, now: i64) -> Result<Outcome> {
    let _guard = lock(id).await;
    // A renewal that could not be written earlier goes first: the service has the new refresh token already, so
    // asking again would use a dead one.
    let held = HELD.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned();
    if let Some((access, state)) = held {
        return match save_tokens(store, id, &access, &state) {
            Ok(()) => {
                forget_held(id);
                clear_failure(id);
                announce_renewed(id);
                Ok(Outcome::Refreshed)
            }
            Err(e) => {
                note_failure(id, "the renewed sign-in could not be stored", now);
                Err(e.context("could not store the renewed sign-in"))
            }
        };
    }
    let Some(mut stored) = load_stored(store, id)? else {
        return Ok(Outcome::NeedsLogin);
    };
    let Some(current) = store.secret_get(&oauth_access_name(id))? else {
        return Ok(Outcome::NeedsLogin);
    };
    if stored.needs_login {
        return Ok(Outcome::NeedsLogin);
    }
    let due = match &why {
        Why::Expiring(skew) => stored.due(*skew, now),
        Why::Rejected(stale) => *stale == current,
    };
    if !due {
        return Ok(Outcome::Unchanged);
    }
    let Some(refresh_token) = stored.refresh_token.clone() else {
        // Nothing renews it: while it still works it stays, once it ran out or was refused the person signs in.
        let ended = stored.expires_at.is_some_and(|e| e <= now) || matches!(why, Why::Rejected(_));
        if !ended {
            return Ok(Outcome::Unchanged);
        }
        stored.needs_login = true;
        save_state(store, id, &stored)?;
        return Ok(Outcome::NeedsLogin);
    };
    // A 401 is news about the token, not a tick of the clock: it is tried at once. A tick waits for its turn.
    if matches!(why, Why::Expiring(_)) && failing(id).is_some_and(|(retry_at, _)| now < retry_at) {
        return Ok(Outcome::Waiting);
    }
    let hide = vec![
        ("REFRESH_TOKEN".to_string(), refresh_token.clone()),
        ("ACCESS_TOKEN".to_string(), current.clone()),
    ];
    match token_call(
        &stored.token_endpoint,
        &[
            ("grant_type", "refresh_token"),
            ("refresh_token", &refresh_token),
            ("client_id", &stored.client_id),
            ("resource", &stored.resource),
        ],
        &hide,
        now,
    )
    .await
    {
        Ok(tokens) => {
            stored.refresh_token = tokens.refresh.or(Some(refresh_token));
            stored.expires_at = tokens.expires_at;
            stored.issued_at = Some(now);
            stored.lifetime_ms = tokens.lifetime_ms;
            if tokens.scope.is_some() {
                stored.scope = tokens.scope;
            }
            // Both secrets in one step. The service has rotated the refresh token by now, so a failed write is tried
            // once more at once; if that fails too, the new state is held in memory (sessions use its token, the
            // next try writes it) and the error is told.
            let wrote = save_tokens(store, id, &tokens.access, &stored)
                .or_else(|_| save_tokens(store, id, &tokens.access, &stored));
            if let Err(e) = wrote {
                HELD.lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .insert(id.to_string(), (tokens.access.clone(), stored));
                note_failure(id, "the renewed sign-in could not be stored", now);
                announce_renewed(id);
                return Err(e.context("could not store the renewed sign-in"));
            }
            clear_failure(id);
            if tokens.access == current {
                return Ok(Outcome::Unchanged);
            }
            announce_renewed(id);
            Ok(Outcome::Refreshed)
        }
        Err(TokenFail::Rejected(_, invalid_client)) => {
            if invalid_client {
                forget_client(store, id);
            }
            stored.needs_login = true;
            save_state(store, id, &stored)?;
            clear_failure(id);
            Ok(Outcome::NeedsLogin)
        }
        Err(TokenFail::Transient(text)) => {
            note_failure(id, &text, now);
            Err(anyhow!("could not renew the sign-in: {text}"))
        }
    }
}

/// The stored access token of an integration, if any.
/// One that could not be written yet counts as the stored one.
pub fn access_token(store: &Store, id: &str) -> Result<Option<String>> {
    if let Some(held) = held_access(id) {
        return Ok(Some(held));
    }
    store.secret_get(&oauth_access_name(id))
}

/// The ids of integrations whose access token changed. A listener (the daemon's renewal task) renews the sessions
/// that run with the old one: a renewal done by a session start, a test or a retry after a 401 concerns every agent
/// that has the integration, not only the one that asked.
static RENEWED: LazyLock<tokio::sync::broadcast::Sender<String>> =
    LazyLock::new(|| tokio::sync::broadcast::channel(64).0);

/// Listens for renewed tokens. A `Lagged` error means some were missed: the listener then looks at all of them.
pub fn renewed() -> tokio::sync::broadcast::Receiver<String> {
    RENEWED.subscribe()
}

fn announce_renewed(id: &str) {
    // No listener is no problem (tests, or a daemon that has not started its task yet).
    let _ = RENEWED.send(id.to_string());
}

/// Whether the stored token of `id` is still good at `now` (it has no end, or the end is ahead).
fn token_alive(store: &Store, id: &str, now: i64) -> bool {
    // A renewal that only the memory holds has a fresh token.
    held_access(id).is_some()
        || matches!(store.secret_get(&oauth_access_name(id)), Ok(Some(_)))
            && load_stored(store, id)
                .ok()
                .flatten()
                .is_some_and(|s| !s.needs_login && s.expires_at.is_none_or(|e| e > now))
}

/// How long a session start waits for the renewals, in all.
pub const SESSION_WAIT: Duration = Duration::from_secs(5);

/// Before a session starts: renews the tokens of `rows` that are due, all at once, waiting for them 5 seconds in all
/// (`SESSION_WAIT`). A renewal that is not done by then goes on in the background (it is not cancelled: the service
/// may have rotated the refresh token already). Returns the ids that cannot be used now, each with whether the
/// person has to sign in again (`true`) or the token ran out and the service could not be asked in time (`false`).
/// A token that is still good is used whatever happened to its renewal.
pub async fn ready_for_session(store: &Arc<Store>, rows: &[&Integration], now: i64) -> Vec<(String, bool)> {
    ready_within(store, rows, now, SESSION_WAIT).await
}

/// [`ready_for_session`] with the wait given, so a test need not wait five seconds.
async fn ready_within(store: &Arc<Store>, rows: &[&Integration], now: i64, wait: Duration) -> Vec<(String, bool)> {
    let tasks: Vec<_> = rows
        .iter()
        .filter(|r| r.auth == IntegrationAuth::Oauth)
        .map(|row| {
            let (store, id) = (store.clone(), row.id.clone());
            let task = tokio::spawn(async move { refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), now).await });
            (row, task)
        })
        .collect();
    let deadline = tokio::time::Instant::now() + wait;
    let mut skipped = Vec::new();
    for (row, task) in tasks {
        match tokio::time::timeout_at(deadline, task).await {
            Ok(Ok(Ok(Outcome::NeedsLogin))) => skipped.push((row.id.clone(), true)),
            Ok(Ok(Ok(Outcome::Unchanged | Outcome::Refreshed))) => {}
            late_or_failed => {
                match late_or_failed {
                    Ok(Ok(Err(e))) => tracing::warn!(integration = row.name, "{e:#}"),
                    Err(_) => tracing::warn!(
                        integration = row.name,
                        "the sign-in renewal is slow: using the token as it is"
                    ),
                    _ => {}
                }
                if !token_alive(store, &row.id, now) {
                    skipped.push((row.id.clone(), false));
                }
            }
        }
    }
    skipped
}

/// Renews every token that is due by the background margin, all at once. Returns the ids that got another token.
pub async fn refresh_due(store: &Store, now: i64) -> Vec<String> {
    let rows = match store.integration_list() {
        Ok(rows) => rows,
        Err(e) => {
            tracing::warn!("integration list for renewal: {e:#}");
            return Vec::new();
        }
    };
    let jobs = rows
        .iter()
        .filter(|r| r.auth == IntegrationAuth::Oauth)
        .map(|row| async move {
            match refresh(store, &row.id, Why::Expiring(BACKGROUND_SKEW_MS), now).await {
                Ok(Outcome::Refreshed) => Some(row.id.clone()),
                Ok(_) => None,
                Err(e) => {
                    tracing::warn!(integration = row.name, "{e:#}");
                    None
                }
            }
        });
    futures_util::future::join_all(jobs)
        .await
        .into_iter()
        .flatten()
        .collect()
}

// ---- disconnect ----

/// Asks the service to revoke the tokens, if it said where. Any failure only goes to the log, as a fixed line.
async fn revoke(stored: &Stored, access: Option<&str>, name: &str) -> bool {
    let Some(endpoint) = stored.revocation_endpoint.as_deref().and_then(|e| Url::parse(e).ok()) else {
        return false;
    };
    if check_remote_url(&endpoint, "revocation address", allow_local()).is_err() {
        return false;
    }
    let mut tokens: Vec<(&str, &str)> = Vec::new();
    if let Some(refresh) = &stored.refresh_token {
        tokens.push((refresh, "refresh_token"));
    }
    if let Some(access) = access {
        tokens.push((access, "access_token"));
    }
    let mut any = false;
    for (token, hint) in tokens {
        let body = form(&[
            ("token", token),
            ("token_type_hint", hint),
            ("client_id", &stored.client_id),
        ]);
        let mut req = Req::post(&endpoint, "application/x-www-form-urlencoded", body);
        req.seconds = 6;
        match send(req).await {
            Ok(resp) if (200..300).contains(&resp.status) => any = true,
            Ok(resp) => tracing::warn!(integration = name, status = resp.status, "token revocation was refused"),
            Err(_) => tracing::warn!(integration = name, "token revocation could not be sent"),
        }
    }
    any
}

/// Signs out: asks the service to revoke the tokens (a failure does not stop the rest) and deletes them, both in one
/// step. The client registered with the service stays, so signing in again does not register a new one; with
/// `remove` (the integration is going away) it is deleted too. Returns whether the service revoked something.
pub async fn disconnect(store: &Store, row: &Integration, remove: bool) -> Result<bool> {
    let _guard = lock(&row.id).await;
    let access = store.secret_get(&oauth_access_name(&row.id))?;
    let revoked = match load_stored(store, &row.id)? {
        Some(stored) => revoke(&stored, access.as_deref(), &row.name).await,
        None => false,
    };
    let (access_name, state_name, client_name) = (
        oauth_access_name(&row.id),
        oauth_state_name(&row.id),
        oauth_client_name(&row.id),
    );
    let mut names = vec![access_name.as_str(), state_name.as_str()];
    if remove {
        names.push(client_name.as_str());
    }
    store.secrets_delete_many(&names)?;
    clear_failure(&row.id);
    forget_held(&row.id);
    Ok(revoked)
}

#[cfg(test)]
pub(crate) mod fake;

#[cfg(test)]
mod tests;
