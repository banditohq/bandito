//! A fake MCP server with its own authorization server, for the tests of `mcp_oauth.rs` and the probe: it listens on
//! `localhost`, answers the metadata, registers clients, issues and renews tokens, and serves `/mcp` to a good token.

use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct Inner {
    /// What the metadata says the issuer is, when it should be wrong.
    pub issuer: Option<String>,
    pub no_registration: bool,
    pub no_pkce: bool,
    /// A redirect address the registration answers with instead of the one asked for.
    pub registered_redirect: Option<String>,
    pub expires_in: i64,
    /// The token answers carry no `expires_in` at all.
    pub no_expires_in: bool,
    /// The refresh grant answers after this many ms.
    pub token_delay_ms: u64,
    /// `(status, error)` the refresh grant answers with, when it should fail.
    pub refresh_failure: Option<(u16, String)>,
    pub token_status: Option<(u16, String)>,
    pub revoke_status: u16,
    pub registrations: Vec<Value>,
    pub token_requests: Vec<HashMap<String, String>>,
    pub revoked: Vec<HashMap<String, String>>,
    /// code -> (challenge, client_id)
    codes: HashMap<String, (String, String)>,
    pub access: String,
    pub refresh: String,
    counter: u32,
    pub mcp_calls: u32,
}

pub struct Fake {
    /// `http://localhost:<port>`
    pub base: String,
    pub inner: Mutex<Inner>,
    task: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Drop for Fake {
    fn drop(&mut self) {
        if let Some(t) = self.task.lock().unwrap_or_else(|e| e.into_inner()).take() {
            t.abort();
        }
    }
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("00");
                out.push(u8::from_str_radix(hex, 16).unwrap_or(b'?'));
                i += 3;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub fn parse_form(text: &str) -> HashMap<String, String> {
    text.split('&')
        .filter(|p| !p.is_empty())
        .map(|pair| {
            let (k, v) = pair.split_once('=').unwrap_or((pair, ""));
            (decode(k), decode(v))
        })
        .collect()
}

/// The query of an authorization address, decoded.
pub fn query_of(url: &str) -> HashMap<String, String> {
    parse_form(url.split_once('?').map(|(_, q)| q).unwrap_or_default())
}

fn json_response(status: u16, body: Value) -> Response {
    (
        StatusCode::from_u16(status).unwrap(),
        [(header::CONTENT_TYPE, "application/json")],
        body.to_string(),
    )
        .into_response()
}

impl Fake {
    pub async fn start() -> Arc<Fake> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let fake = Arc::new(Fake {
            base: format!("http://localhost:{port}"),
            inner: Mutex::new(Inner {
                expires_in: 3600,
                revoke_status: 200,
                access: "at-initial".into(),
                refresh: "rt-initial".into(),
                ..Default::default()
            }),
            task: Mutex::new(None),
        });
        let app = Router::new()
            .route("/mcp", post(mcp))
            .route("/.well-known/oauth-protected-resource/mcp", get(resource_metadata))
            .route("/.well-known/oauth-authorization-server", get(server_metadata))
            .route("/register", post(register))
            .route("/token", post(token))
            .route("/revoke", post(revoke))
            .with_state(fake.clone());
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        *fake.task.lock().unwrap() = Some(task);
        fake
    }

    pub fn url(&self) -> String {
        format!("{}/mcp", self.base)
    }

    pub fn set(&self, f: impl FnOnce(&mut Inner)) {
        f(&mut self.inner.lock().unwrap());
    }

    /// What the person's browser does at the authorization address: checks it and returns the `(code, state)` the
    /// service would send back to `bandito://oauth/callback`.
    pub fn authorize(&self, authorize_url: &str) -> (String, String) {
        assert!(
            authorize_url.starts_with(&format!("{}/authorize?", self.base)),
            "{authorize_url}"
        );
        let q = query_of(authorize_url);
        assert_eq!(q["response_type"], "code");
        assert_eq!(q["code_challenge_method"], "S256");
        assert_eq!(q["redirect_uri"], super::REDIRECT_URI);
        assert!(q.contains_key("resource") && q.contains_key("state") && q.contains_key("client_id"));
        let mut inner = self.inner.lock().unwrap();
        inner.counter += 1;
        let code = format!("code-{}", inner.counter);
        inner
            .codes
            .insert(code.clone(), (q["code_challenge"].clone(), q["client_id"].clone()));
        (code, q["state"].clone())
    }
}

async fn resource_metadata(State(f): State<Arc<Fake>>) -> Response {
    json_response(
        200,
        json!({
            "resource": f.base,
            "authorization_servers": [f.base],
            "scopes_supported": ["read", "write"],
        }),
    )
}

async fn server_metadata(State(f): State<Arc<Fake>>) -> Response {
    let inner = f.inner.lock().unwrap();
    let mut meta = json!({
        "issuer": inner.issuer.clone().unwrap_or_else(|| f.base.clone()),
        "authorization_endpoint": format!("{}/authorize", f.base),
        "token_endpoint": format!("{}/token", f.base),
        "revocation_endpoint": format!("{}/revoke", f.base),
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "token_endpoint_auth_methods_supported": ["none"],
    });
    if !inner.no_registration {
        meta["registration_endpoint"] = json!(format!("{}/register", f.base));
    }
    if !inner.no_pkce {
        meta["code_challenge_methods_supported"] = json!(["S256"]);
    }
    json_response(200, meta)
}

async fn register(State(f): State<Arc<Fake>>, body: Bytes) -> Response {
    let asked: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let mut inner = f.inner.lock().unwrap();
    inner.registrations.push(asked.clone());
    let redirect = inner
        .registered_redirect
        .clone()
        .unwrap_or_else(|| asked["redirect_uris"][0].as_str().unwrap_or_default().to_string());
    json_response(
        201,
        json!({
            "client_id": format!("client-{}", inner.registrations.len()),
            "redirect_uris": [redirect],
            "token_endpoint_auth_method": "none",
        }),
    )
}

async fn token(State(f): State<Arc<Fake>>, body: Bytes) -> Response {
    let req = parse_form(&String::from_utf8_lossy(&body));
    let delay = f.inner.lock().unwrap().token_delay_ms;
    if delay > 0 && req.get("grant_type").is_some_and(|g| g == "refresh_token") {
        tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
    }
    let mut inner = f.inner.lock().unwrap();
    inner.token_requests.push(req.clone());
    if let Some((status, error)) = inner.token_status.clone() {
        // An error whose description repeats the code, as a careless service might.
        let echo = req.get("code").cloned().unwrap_or_default();
        return json_response(
            status,
            json!({ "error": error, "error_description": format!("bad request, code {echo} refused") }),
        );
    }
    let grant = req.get("grant_type").cloned().unwrap_or_default();
    match grant.as_str() {
        "authorization_code" => {
            let code = req.get("code").cloned().unwrap_or_default();
            let Some((challenge, client)) = inner.codes.remove(&code) else {
                return json_response(400, json!({ "error": "invalid_grant" }));
            };
            let verifier = req.get("code_verifier").cloned().unwrap_or_default();
            let ok = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes())) == challenge
                && req.get("client_id") == Some(&client)
                && req.get("redirect_uri").map(String::as_str) == Some(super::REDIRECT_URI)
                && req.contains_key("resource");
            if !ok {
                return json_response(400, json!({ "error": "invalid_grant" }));
            }
        }
        "refresh_token" => {
            if let Some((status, error)) = inner.refresh_failure.clone() {
                return json_response(status, json!({ "error": error }));
            }
            if req.get("refresh_token") != Some(&inner.refresh) || !req.contains_key("resource") {
                return json_response(400, json!({ "error": "invalid_grant" }));
            }
        }
        _ => return json_response(400, json!({ "error": "unsupported_grant_type" })),
    }
    inner.counter += 1;
    inner.access = format!("at-{}", inner.counter);
    inner.refresh = format!("rt-{}", inner.counter);
    let mut answer = json!({
        "access_token": inner.access,
        "refresh_token": inner.refresh,
        "token_type": "Bearer",
        "expires_in": inner.expires_in,
        "scope": "read write",
    });
    if inner.no_expires_in {
        answer.as_object_mut().map(|o| o.remove("expires_in"));
    }
    json_response(200, answer)
}

async fn revoke(State(f): State<Arc<Fake>>, body: Bytes) -> Response {
    let mut inner = f.inner.lock().unwrap();
    inner.revoked.push(parse_form(&String::from_utf8_lossy(&body)));
    json_response(inner.revoke_status, json!({}))
}

async fn mcp(State(f): State<Arc<Fake>>, headers: HeaderMap, body: Bytes) -> Response {
    let mut inner = f.inner.lock().unwrap();
    inner.mcp_calls += 1;
    let expected = format!("Bearer {}", inner.access);
    let given = headers.get(header::AUTHORIZATION).and_then(|v| v.to_str().ok());
    if given != Some(expected.as_str()) {
        let challenge = format!(
            "Bearer realm=\"mcp\", resource_metadata=\"{}/.well-known/oauth-protected-resource/mcp\", scope=\"read write\"",
            f.base
        );
        return (
            StatusCode::UNAUTHORIZED,
            [(header::WWW_AUTHENTICATE, challenge)],
            String::new(),
        )
            .into_response();
    }
    let msg: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    let id = msg["id"].clone();
    match msg["method"].as_str() {
        Some("initialize") => json_response(
            200,
            json!({ "jsonrpc": "2.0", "id": id, "result": {
                "protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": { "name": "fake", "version": "1" } } }),
        ),
        Some("tools/list") => json_response(
            200,
            json!({ "jsonrpc": "2.0", "id": id, "result": { "tools": [{ "name": "search" }, { "name": "fetch" }] } }),
        ),
        // Echoes the tool and its arguments as text; the tool `fail` answers with `isError`, `big` with 1.5 MB of text.
        Some("tools/call") => {
            let name = msg["params"]["name"].as_str().unwrap_or_default();
            let text = match name {
                "big" => "x".repeat(1_500_000),
                _ => format!("{name} {}", msg["params"]["arguments"]),
            };
            json_response(
                200,
                json!({ "jsonrpc": "2.0", "id": id, "result": {
                    "content": [{ "type": "text", "text": text }], "isError": name == "fail" } }),
            )
        }
        _ => (StatusCode::ACCEPTED, String::new()).into_response(),
    }
}
