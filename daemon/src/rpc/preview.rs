//! Preview proxy: `/v1/proxy/<port>/<path>` forwards HTTP to `127.0.0.1:<port>` on this server,
//! so the app can show what agents start there (a dev server, a page they built). The route and
//! its checks are in `ws.rs`. See docs/ARCHITECTURE.md#preview-proxy.

use axum::body::Body;
use axum::http::{HeaderMap, HeaderValue, Method, Request, StatusCode, Uri, header};
use axum::response::{IntoResponse, Response};
use hyper_util::client::legacy::Client;
use hyper_util::client::legacy::connect::HttpConnector;
use hyper_util::rt::TokioExecutor;
use std::sync::OnceLock;
use std::time::Duration;

/// How long connecting to the target may take.
const CONNECT_LIMIT: Duration = Duration::from_secs(5);
/// Headers that belong to one connection, plus the ones named by `Connection`.
const HOP_BY_HOP: [&str; 6] = [
    "connection",
    "keep-alive",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
];

pub type PreviewClient = Client<HttpConnector, Body>;

/// The HTTP client to the preview targets. Shared by the proxy and the browser's DevTools calls.
pub fn client() -> &'static PreviewClient {
    static CLIENT: OnceLock<PreviewClient> = OnceLock::new();
    CLIENT.get_or_init(|| {
        let mut connector = HttpConnector::new();
        connector.set_connect_timeout(Some(CONNECT_LIMIT));
        Client::builder(TokioExecutor::new()).build(connector)
    })
}

/// True for a header that a proxy must not pass on. `connection_tokens` are the names listed in
/// the message's own `Connection` header (lower case).
pub fn is_hop_by_hop(name: &str, connection_tokens: &[String]) -> bool {
    let name = name.to_ascii_lowercase();
    HOP_BY_HOP.contains(&name.as_str()) || name.starts_with("proxy-") || connection_tokens.contains(&name)
}

/// The lower-case names in a message's `Connection` header.
pub fn connection_tokens(headers: &HeaderMap) -> Vec<String> {
    headers
        .get_all(header::CONNECTION)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .flat_map(|value| value.split(','))
        .map(|token| token.trim().to_ascii_lowercase())
        .filter(|token| !token.is_empty())
        .collect()
}

/// A `Location` from the target, mapped to the proxy's own address for that port. Absolute
/// `http://127.0.0.1:<port>` and `http://localhost:<port>` URLs and root paths (`/x`) go under
/// `/v1/proxy/<port>/`, so a redirect stays inside the preview. Anything else is left as it is.
pub fn rewrite_location(location: &str, port: u16) -> String {
    let prefix = format!("/v1/proxy/{port}");
    for origin in [format!("http://127.0.0.1:{port}"), format!("http://localhost:{port}")] {
        if let Some(rest) = location.strip_prefix(&origin) {
            return match rest {
                "" => format!("{prefix}/"),
                r if r.starts_with('/') => format!("{prefix}{r}"),
                r if r.starts_with('?') => format!("{prefix}/{r}"),
                _ => location.to_string(),
            };
        }
    }
    if location.starts_with('/') && !location.starts_with("//") {
        return format!("{prefix}{location}");
    }
    location.to_string()
}

/// Forward one request to `127.0.0.1:<port>` and stream the answer back. `path_and_query` starts
/// with `/`. The device token (`Authorization`) is never passed on. A `Host` of `127.0.0.1:<port>`
/// is sent. WebSocket upgrades are refused with 501.
pub async fn forward(port: u16, method: Method, path_and_query: &str, headers: &HeaderMap, body: Body) -> Response {
    if headers.contains_key(header::UPGRADE) {
        return (StatusCode::NOT_IMPLEMENTED, "WebSockets are not proxied").into_response();
    }
    let Ok(uri) = format!("http://127.0.0.1:{port}{path_and_query}").parse::<Uri>() else {
        return (StatusCode::BAD_REQUEST, "bad path").into_response();
    };
    let tokens = connection_tokens(headers);
    let mut outgoing = HeaderMap::new();
    for (name, value) in headers {
        if *name == header::AUTHORIZATION || *name == header::HOST || is_hop_by_hop(name.as_str(), &tokens) {
            continue;
        }
        outgoing.append(name.clone(), value.clone());
    }
    if let Ok(host) = HeaderValue::try_from(format!("127.0.0.1:{port}")) {
        outgoing.insert(header::HOST, host);
    }
    let mut request = Request::new(body);
    *request.method_mut() = method;
    *request.uri_mut() = uri;
    *request.headers_mut() = outgoing;

    match client().request(request).await {
        Err(_) => (StatusCode::BAD_GATEWAY, "the preview target did not answer").into_response(),
        Ok(upstream) => {
            let (parts, incoming) = upstream.into_parts();
            let tokens = connection_tokens(&parts.headers);
            let mut headers = HeaderMap::new();
            for (name, value) in &parts.headers {
                if is_hop_by_hop(name.as_str(), &tokens) {
                    continue;
                }
                if *name == header::LOCATION {
                    let rewritten = value
                        .to_str()
                        .ok()
                        .map(|text| rewrite_location(text, port))
                        .and_then(|text| HeaderValue::try_from(text).ok());
                    if let Some(rewritten) = rewritten {
                        headers.append(name.clone(), rewritten);
                    }
                    continue;
                }
                headers.append(name.clone(), value.clone());
            }
            let mut response = Response::new(Body::new(incoming));
            *response.status_mut() = parts.status;
            *response.headers_mut() = headers;
            response
        }
    }
}
