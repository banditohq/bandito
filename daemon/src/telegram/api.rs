//! The Bot API over `curl`, like the other web calls of the daemon. The token is in the address, and an address in the
//! arguments of a process shows in `ps`, so `curl` gets its whole request on standard input (`--config -`): the
//! arguments are always the same three. Nothing that leaves this module carries the token.

use crate::mcp_oauth::{Group, quote};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// The address of the Bot API. Only tests use another (a fake on the loopback).
pub const DEFAULT_BASE: &str = "https://api.telegram.org";

/// Most of an answer that is read.
const MAX_RESPONSE_BYTES: u64 = 4 * 1024 * 1024;

/// What a call came to when it did not work.
#[derive(Debug, Clone, PartialEq)]
pub enum ApiError {
    /// 401: the token is not (or no longer) a bot's.
    Unauthorized,
    /// 409: another server polls this bot.
    Conflict,
    /// 429: wait this many seconds.
    RateLimited(u64),
    /// No answer: the network, `curl`, a timeout, an answer that is not the Bot API's.
    Network(String),
    /// Any other refusal, with Telegram's words.
    Rejected { code: i64, description: String },
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Unauthorized => f.write_str("Telegram does not accept the bot token"),
            ApiError::Conflict => f.write_str("another server is polling this bot"),
            ApiError::RateLimited(n) => write!(f, "Telegram asks to wait {n} s"),
            ApiError::Network(m) => write!(f, "could not reach Telegram ({m})"),
            ApiError::Rejected { code, description } => {
                write!(f, "Telegram refused the request ({code}: {description})")
            }
        }
    }
}

impl std::error::Error for ApiError {}

/// The arguments of every `curl` of the bot: no address, no token, no body.
pub fn curl_argv() -> [&'static str; 3] {
    ["-q", "--config", "-"]
}

/// What goes to `curl` on standard input: the address with the token, the method, the limits and the JSON body. A
/// value with a control character is refused (it could start another line of the configuration).
pub fn curl_config(base: &str, token: &str, method: &str, body: &Value, max_time: u64) -> Result<String> {
    let secure = base.starts_with("https://");
    let mut config = String::new();
    config.push_str(&format!("url = {}\n", quote(&format!("{base}/bot{token}/{method}"))?));
    config.push_str("request = \"POST\"\n");
    // No `location`: a redirect is not followed. `globoff`: no `[]` or `{}` expansion in the address.
    config.push_str("silent\nshow-error\ngloboff\n");
    config.push_str(if secure {
        "proto = \"=https\"\n"
    } else {
        // The fake of the tests on the loopback. The environment's proxy would not reach it.
        "proto = \"=https,http\"\nnoproxy = \"*\"\n"
    });
    config.push_str(&format!(
        "max-time = {max_time}\nconnect-timeout = 15\nmax-filesize = {MAX_RESPONSE_BYTES}\n"
    ));
    config.push_str("header = \"Content-Type: application/json\"\n");
    config.push_str(&format!("data-raw = {}\n", quote(&body.to_string())?));
    Ok(config)
}

/// Takes DEL and the C1 controls (U+007F, U+0080 to U+009F) out of every string of a body. JSON escapes the controls
/// below U+0020 but not these, and `curl`'s configuration refuses any control character, so a message that held one
/// (a command an agent printed, say) would never go out. Telegram shows none of them anyway.
pub fn strip_controls(value: &mut Value) {
    match value {
        Value::String(s) => {
            if s.chars().any(|c| matches!(c, '\u{7f}'..='\u{9f}')) {
                *s = s.chars().filter(|c| !matches!(c, '\u{7f}'..='\u{9f}')).collect();
            }
        }
        Value::Array(items) => items.iter_mut().for_each(strip_controls),
        Value::Object(map) => map.values_mut().for_each(strip_controls),
        _ => {}
    }
}

/// `text` with the token, and anything shaped like a bot token (`digits:letters`, also after `/bot`), replaced.
pub fn scrub(text: &str, token: &str) -> String {
    let text = if token.is_empty() {
        text.to_string()
    } else {
        text.replace(token, "•••")
    };
    let token_char = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == ':';
    let mut out = String::with_capacity(text.len());
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut String| {
        if looks_like_token(run) {
            out.push_str(if run.starts_with("bot") {
                "bot•••"
            } else {
                "•••"
            });
        } else {
            out.push_str(run);
        }
        run.clear();
    };
    for c in text.chars() {
        if token_char(c) {
            run.push(c);
        } else {
            flush(&mut run, &mut out);
            out.push(c);
        }
    }
    flush(&mut run, &mut out);
    out
}

/// `12345:AbC_-…` with 5 to 12 digits and 30 or more token characters, with or without a leading `bot`.
fn looks_like_token(run: &str) -> bool {
    let run = run.strip_prefix("bot").unwrap_or(run);
    let Some((id, secret)) = run.split_once(':') else {
        return false;
    };
    (5..=12).contains(&id.len())
        && id.chars().all(|c| c.is_ascii_digit())
        && secret.len() >= 30
        && secret
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[derive(Debug, Clone)]
pub struct Api {
    base: String,
}

impl Api {
    pub fn new() -> Self {
        Self {
            base: DEFAULT_BASE.to_string(),
        }
    }

    /// An API at another address: the fake of the tests.
    #[cfg(test)]
    pub fn with_base(base: &str) -> Self {
        Self {
            base: base.trim_end_matches('/').to_string(),
        }
    }

    /// One Bot API call: `Ok` is the `result` of the answer. `max_time` is the seconds `curl` may take.
    pub async fn call(&self, token: &str, method: &str, mut body: Value, max_time: u64) -> Result<Value, ApiError> {
        strip_controls(&mut body);
        let raw = self.run(token, method, &body, max_time).await.map_err(|e| {
            let line: String = scrub(&format!("{e:#}"), token)
                .chars()
                .filter(|c| !c.is_control())
                .take(200)
                .collect();
            ApiError::Network(line)
        })?;
        let answer: Value = serde_json::from_str(&raw)
            .map_err(|_| ApiError::Network("the answer is not from the Bot API".to_string()))?;
        if answer["ok"].as_bool() == Some(true) {
            return Ok(answer["result"].clone());
        }
        let code = answer["error_code"].as_i64().unwrap_or(0);
        let description = scrub(answer["description"].as_str().unwrap_or_default(), token);
        Err(match code {
            401 => ApiError::Unauthorized,
            409 => ApiError::Conflict,
            429 => ApiError::RateLimited(answer["parameters"]["retry_after"].as_u64().unwrap_or(5)),
            _ => ApiError::Rejected { code, description },
        })
    }

    /// Runs `curl` and returns what it printed.
    async fn run(&self, token: &str, method: &str, body: &Value, max_time: u64) -> Result<String> {
        let config = curl_config(&self.base, token, method, body, max_time)?;
        let mut cmd = tokio::process::Command::new("curl");
        cmd.args(curl_argv())
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
        let limit = Duration::from_secs(max_time + 5);
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
            .map_err(|_| anyhow!("Telegram did not answer in time"))??;
        if !status.success() {
            let line = String::from_utf8_lossy(&err)
                .lines()
                .next()
                .unwrap_or_default()
                .to_string();
            bail!("curl failed ({line})");
        }
        Ok(String::from_utf8_lossy(&out).into_owned())
    }
}

impl Default for Api {
    fn default() -> Self {
        Self::new()
    }
}

/// The body of `getUpdates`.
pub fn updates_body(timeout: u64, offset: Option<i64>) -> Value {
    let mut body = json!({
        "timeout": timeout,
        "allowed_updates": ["message", "callback_query", "my_chat_member"],
    });
    if let Some(offset) = offset {
        body["offset"] = json!(offset);
    }
    body
}
