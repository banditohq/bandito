//! HTTP + WebSocket transport: `GET /v1/health`, `GET /v1/rpc` (WebSocket),
//! `GET` and `HEAD /v1/files/raw` (file bytes, see docs/ARCHITECTURE.md#files),
//! `GET /v1/tunnel` (TCP to the server's loopback, see docs/ARCHITECTURE.md#tunnel).
//! Auth: `Authorization: Bearer <device token>`. Without a token the socket
//! is anonymous (only `daemon.hello` and `pair.redeem`); raw files and the
//! tunnel need a token.

use super::tunnel;
use super::{App, Peer, serve};
use crate::files::{EntryKind, FsError};
use crate::store::Device;
use axum::Router;
use axum::body::Body;
use axum::extract::Query;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, Method, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use std::io::{self, ErrorKind, SeekFrom};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncSeekExt};
use tokio::sync::mpsc;
use tokio_util::io::ReaderStream;

pub fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/v1/health", get(|| async { "ok" }))
        .route("/v1/rpc", get(rpc))
        .route("/v1/files/raw", get(files_raw))
        .route("/v1/tunnel", get(tunnel_upgrade))
        .with_state(app)
}

fn bearer(headers: &HeaderMap) -> Option<&str> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::trim)
}

/// Browsers attach Origin; native apps don't. A web page must not drive the
/// daemon through the user's browser, even for pairing or file downloads.
fn has_browser_origin(headers: &HeaderMap) -> bool {
    headers.contains_key(header::ORIGIN)
}

/// The paired device behind the bearer token: `Ok(None)` without a token. The
/// error is the status and message to send when the token is unknown or revoked.
fn device_for(app: &App, headers: &HeaderMap) -> Result<Option<Device>, (StatusCode, &'static str)> {
    let Some(token) = bearer(headers) else {
        return Ok(None);
    };
    match app.sup.hub().store.device_auth(token) {
        Ok(Some(device)) => Ok(Some(device)),
        Ok(None) => Err((StatusCode::UNAUTHORIZED, "unknown or revoked token")),
        Err(e) => {
            tracing::error!("device auth: {e:#}");
            Err((StatusCode::INTERNAL_SERVER_ERROR, "device auth failed"))
        }
    }
}

/// The paired device behind the request. The error is the status and message to
/// send when the request has a browser origin, or the token is missing or unknown.
fn require_device(app: &App, headers: &HeaderMap) -> Result<Device, (StatusCode, &'static str)> {
    if has_browser_origin(headers) {
        return Err((StatusCode::FORBIDDEN, "browser origins are not allowed"));
    }
    match device_for(app, headers) {
        Ok(Some(device)) => Ok(device),
        Ok(None) => Err((StatusCode::UNAUTHORIZED, "device token required")),
        Err(e) => Err(e),
    }
}

async fn rpc(State(app): State<Arc<App>>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    if has_browser_origin(&headers) {
        return (StatusCode::FORBIDDEN, "browser origins are not allowed").into_response();
    }
    let peer = match device_for(&app, &headers) {
        Ok(Some(device)) => Peer::Device(device),
        Ok(None) => Peer::Anonymous,
        Err(e) => return e.into_response(),
    };
    ws.max_message_size(4 << 20)
        .on_upgrade(move |socket| handle(app, peer, socket))
}

#[derive(Deserialize)]
struct RawQuery {
    path: String,
}

/// `GET` / `HEAD /v1/files/raw?path=…`: the file's bytes, streamed. One `Range`
/// (`bytes=a-b`, `a-`, `-n`) is served as 206; anything else that is not a
/// satisfiable single range gets 416. Served as `sandbox` so that a downloaded
/// file never runs script in the daemon's origin.
async fn files_raw(
    State(app): State<Arc<App>>,
    method: Method,
    headers: HeaderMap,
    Query(query): Query<RawQuery>,
) -> Response {
    if let Err(e) = require_device(&app, &headers) {
        return e.into_response();
    }

    let files = app.files.clone();
    let entry = match tokio::task::spawn_blocking(move || files.stat(&query.path)).await {
        Ok(Ok(entry)) => entry,
        Ok(Err(e)) => return raw_error(e),
        Err(e) => {
            tracing::error!("files raw: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    match entry.kind {
        EntryKind::File => {}
        EntryKind::Dir => return raw_error(FsError::IsADirectory(entry.path)),
        _ => return raw_error(FsError::NotAFile(entry.path)),
    }

    let size = entry.size;
    let range = match headers.get(header::RANGE) {
        None => None,
        Some(value) => match value.to_str().ok().and_then(|v| parse_range(v, size)) {
            Some(range) => Some(range),
            None => return range_not_satisfiable(size),
        },
    };
    let (status, start, len) = match range {
        Some((first, last)) => (StatusCode::PARTIAL_CONTENT, first, last - first + 1),
        None => (StatusCode::OK, 0, size),
    };
    let mut builder = Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, content_type(&entry.name))
        .header(header::CONTENT_LENGTH, len.to_string())
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::ETAG, format!("\"{size}-{}\"", entry.modified_ms))
        .header(header::CACHE_CONTROL, "private, no-cache")
        .header("x-content-type-options", "nosniff")
        .header(header::CONTENT_SECURITY_POLICY, "sandbox")
        .header(
            header::CONTENT_DISPOSITION,
            format!("inline; filename*=UTF-8''{}", percent_encode(&entry.name)),
        );
    if let Some((first, last)) = range {
        builder = builder.header(header::CONTENT_RANGE, format!("bytes {first}-{last}/{size}"));
    }

    let body = if method == Method::HEAD || len == 0 {
        Body::empty()
    } else {
        let mut file = match tokio::fs::File::open(&entry.path).await {
            Ok(file) => file,
            Err(e) => return raw_error(io_error(e, entry.path.clone())),
        };
        if let Err(e) = file.seek(SeekFrom::Start(start)).await {
            return raw_error(io_error(e, entry.path.clone()));
        }
        Body::from_stream(ReaderStream::with_capacity(file.take(len), 64 * 1024))
    };
    builder
        .body(body)
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

#[derive(Deserialize)]
struct TunnelQuery {
    /// Text, so that a bad value is refused after the auth checks, with 400.
    port: Option<String>,
}

/// `GET /v1/tunnel?port=<n>`: after the upgrade, the WebSocket carries one TCP
/// connection to `127.0.0.1:<n>` on the server. Checks run before the upgrade.
async fn tunnel_upgrade(
    State(app): State<Arc<App>>,
    headers: HeaderMap,
    Query(query): Query<TunnelQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let device = match require_device(&app, &headers) {
        Ok(device) => device,
        Err(e) => return e.into_response(),
    };
    let port = match query.port.as_deref().map(str::parse::<u16>) {
        Some(Ok(port)) if port != 0 => port,
        _ => return (StatusCode::BAD_REQUEST, "port must be 1..=65535").into_response(),
    };
    let Some(slot) = app.tunnels.acquire(&device.id, tunnel::tunnel_limit()) else {
        return (StatusCode::TOO_MANY_REQUESTS, "too many tunnels").into_response();
    };
    ws.max_message_size(tunnel::MAX_MESSAGE_SIZE)
        .on_upgrade(move |socket| tunnel::run(socket, port, slot))
}

fn raw_error(e: FsError) -> Response {
    let status = match e {
        FsError::NotFound(_) | FsError::NotADirectory(_) => StatusCode::NOT_FOUND,
        FsError::NotAFile(_) | FsError::IsADirectory(_) | FsError::InvalidPath(_) => StatusCode::BAD_REQUEST,
        FsError::OutsideRoots(_) | FsError::PermissionDenied(_) => StatusCode::FORBIDDEN,
        _ => StatusCode::INTERNAL_SERVER_ERROR,
    };
    (status, e.to_string()).into_response()
}

/// The open or seek failed: keep NotFound and PermissionDenied apart from I/O errors.
fn io_error(e: io::Error, path: String) -> FsError {
    match e.kind() {
        ErrorKind::NotFound => FsError::NotFound(path),
        ErrorKind::PermissionDenied => FsError::PermissionDenied(path),
        _ => FsError::Io(e),
    }
}

fn range_not_satisfiable(size: u64) -> Response {
    Response::builder()
        .status(StatusCode::RANGE_NOT_SATISFIABLE)
        .header(header::CONTENT_RANGE, format!("bytes */{size}"))
        .header(header::ACCEPT_RANGES, "bytes")
        .body(Body::empty())
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

/// The inclusive `(first, last)` byte range that a `Range` header asks for in a
/// file of `size` bytes. `None` if the header is not one valid `bytes=` range
/// inside the file (multiple ranges are not supported).
fn parse_range(value: &str, size: u64) -> Option<(u64, u64)> {
    let spec = value.strip_prefix("bytes=")?;
    if spec.contains(',') {
        return None;
    }
    let (first, last) = spec.split_once('-')?;
    let (start, end) = if first.is_empty() {
        // `-n`: the last n bytes.
        let n: u64 = last.parse().ok().filter(|n| *n > 0)?;
        if size == 0 {
            return None;
        }
        (size.saturating_sub(n), size - 1)
    } else {
        let start: u64 = first.parse().ok()?;
        let end = if last.is_empty() {
            size.checked_sub(1)?
        } else {
            last.parse::<u64>().ok()?.min(size.checked_sub(1)?)
        };
        (start, end)
    };
    (start <= end && start < size).then_some((start, end))
}

/// Content-Type by extension. Markup and SVG are sent as text, so a browser
/// never renders them; unknown types are octet streams.
fn content_type(name: &str) -> &'static str {
    let ext = name
        .rsplit_once('.')
        .map(|(_, ext)| ext.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "webm" => "video/webm",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "pdf" => "application/pdf",
        "txt" | "md" | "log" | "json" | "rs" | "swift" | "py" | "js" | "ts" | "toml" | "yaml" | "yml" | "svg" => {
            "text/plain; charset=utf-8"
        }
        _ => "application/octet-stream",
    }
}

/// Percent-encodes every byte outside the RFC 3986 unreserved set.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

async fn handle(app: Arc<App>, peer: Peer, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let (in_tx, in_rx) = mpsc::channel::<String>(64);
    let (out_tx, mut out_rx) = mpsc::channel::<String>(256);
    let writer = tokio::spawn(async move {
        while let Some(text) = out_rx.recv().await {
            if sink.send(Message::Text(text.into())).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });
    let reader = tokio::spawn(async move {
        while let Some(Ok(msg)) = stream.next().await {
            let text = match msg {
                Message::Text(t) => t.to_string(),
                Message::Close(_) => break,
                // Pings are answered by the library; binary is not used.
                _ => continue,
            };
            if in_tx.send(text).await.is_err() {
                break;
            }
        }
    });
    serve(app, peer, in_rx, out_tx).await;
    reader.abort();
    let _ = writer.await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::FileService;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use axum::body::{Body, to_bytes};
    use axum::http::{Method, Request};
    use std::path::Path;
    use tower::ServiceExt;

    const TOKEN: &str = "bdt_test_token";
    const AUTH: (&str, &str) = ("authorization", "Bearer bdt_test_token");

    /// An app with one paired device (`TOKEN`) whose file service serves `dir`.
    fn served(dir: &Path) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        store.device_add("test", TOKEN).unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new_with_files(sup, dir.join("agents"), FileService::new(dir.to_path_buf(), None))
    }

    async fn send(app: &Arc<App>, method: Method, uri: &str, headers: &[(&str, &str)]) -> Response {
        let mut req = Request::builder().method(method).uri(uri);
        for (name, value) in headers {
            req = req.header(*name, *value);
        }
        router(app.clone())
            .oneshot(req.body(Body::empty()).unwrap())
            .await
            .unwrap()
    }

    /// `GET /v1/files/raw?path=…` with the device token, plus extra headers.
    async fn get_raw(app: &Arc<App>, path: &str, extra: &[(&str, &str)]) -> Response {
        let uri = format!("/v1/files/raw?path={}", percent_encode(path));
        let mut headers = vec![AUTH];
        headers.extend_from_slice(extra);
        send(app, Method::GET, &uri, &headers).await
    }

    async fn body_of(res: Response) -> Vec<u8> {
        to_bytes(res.into_body(), 1 << 20).await.unwrap().to_vec()
    }

    fn header(res: &Response, name: &str) -> String {
        res.headers()
            .get(name)
            .unwrap_or_else(|| panic!("no {name} header"))
            .to_str()
            .unwrap()
            .to_string()
    }

    /// Writes `clip.mp4` (ten bytes, `0123456789`) into `dir` and returns its path.
    fn clip(dir: &Path) -> String {
        std::fs::write(dir.join("clip.mp4"), b"0123456789").unwrap();
        dir.join("clip.mp4").display().to_string()
    }

    #[tokio::test]
    async fn raw_needs_a_device_token_and_refuses_browser_origins() {
        let dir = tempfile::tempdir().unwrap();
        let path = clip(dir.path());
        let app = served(dir.path());
        let uri = format!("/v1/files/raw?path={}", percent_encode(&path));

        let res = send(&app, Method::GET, &uri, &[]).await;
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
        let res = send(&app, Method::GET, &uri, &[("authorization", "Bearer bdt_revoked")]).await;
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
        let res = send(&app, Method::GET, &uri, &[AUTH, ("origin", "https://evil.example")]).await;
        assert_eq!(res.status(), StatusCode::FORBIDDEN);
        let res = send(&app, Method::GET, &uri, &[AUTH]).await;
        assert_eq!(res.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn raw_streams_the_whole_file_with_type_and_safety_headers() {
        let dir = tempfile::tempdir().unwrap();
        let path = clip(dir.path());
        let app = served(dir.path());

        let res = get_raw(&app, &path, &[]).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(header(&res, "content-type"), "video/mp4");
        assert_eq!(header(&res, "content-length"), "10");
        assert_eq!(header(&res, "accept-ranges"), "bytes");
        assert_eq!(header(&res, "cache-control"), "private, no-cache");
        assert_eq!(header(&res, "x-content-type-options"), "nosniff");
        assert_eq!(header(&res, "content-security-policy"), "sandbox");
        assert_eq!(header(&res, "content-disposition"), "inline; filename*=UTF-8''clip.mp4");
        let etag = header(&res, "etag");
        assert!(etag.starts_with("\"10-") && etag.ends_with('"'), "{etag}");
        assert_eq!(body_of(res).await, b"0123456789");
    }

    #[tokio::test]
    async fn raw_ranges_return_partial_content_or_416() {
        let dir = tempfile::tempdir().unwrap();
        let path = clip(dir.path());
        let app = served(dir.path());

        let partial = [
            ("bytes=2-5", "bytes 2-5/10", b"2345".as_slice()),
            ("bytes=7-", "bytes 7-9/10", b"789".as_slice()),
            ("bytes=-3", "bytes 7-9/10", b"789".as_slice()),
            ("bytes=2-100", "bytes 2-9/10", b"23456789".as_slice()),
        ];
        for (range, content_range, expected) in partial {
            let res = get_raw(&app, &path, &[("range", range)]).await;
            assert_eq!(res.status(), StatusCode::PARTIAL_CONTENT, "{range}");
            assert_eq!(header(&res, "content-range"), content_range, "{range}");
            assert_eq!(header(&res, "content-length"), expected.len().to_string(), "{range}");
            assert_eq!(body_of(res).await, expected, "{range}");
        }

        for range in [
            "bytes=100-",
            "bytes=5-2",
            "bytes=-0",
            "bytes=0-1,3-4",
            "items=0-1",
            "bytes=abc",
        ] {
            let res = get_raw(&app, &path, &[("range", range)]).await;
            assert_eq!(res.status(), StatusCode::RANGE_NOT_SATISFIABLE, "{range}");
            assert_eq!(header(&res, "content-range"), "bytes */10", "{range}");
        }
    }

    #[tokio::test]
    async fn an_empty_file_is_served_with_length_zero_and_no_range() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("empty.mp4"), b"").unwrap();
        let path = dir.path().join("empty.mp4").display().to_string();
        let app = served(dir.path());

        let res = get_raw(&app, &path, &[]).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(header(&res, "content-length"), "0");

        let res = get_raw(&app, &path, &[("range", "bytes=0-")]).await;
        assert_eq!(res.status(), StatusCode::RANGE_NOT_SATISFIABLE);
        assert_eq!(header(&res, "content-range"), "bytes */0");
    }

    #[tokio::test]
    async fn raw_content_type_follows_the_extension_and_never_serves_html_or_svg_as_markup() {
        let dir = tempfile::tempdir().unwrap();
        let app = served(dir.path());
        let cases = [
            ("a.svg", "text/plain; charset=utf-8"),
            ("a.html", "application/octet-stream"),
            ("a.htm", "application/octet-stream"),
            ("a.pdf", "application/pdf"),
            ("a.PNG", "image/png"),
            ("a.jpeg", "image/jpeg"),
            ("a.webp", "image/webp"),
            ("a.gif", "image/gif"),
            ("a.mov", "video/quicktime"),
            ("a.webm", "video/webm"),
            ("a.mp3", "audio/mpeg"),
            ("a.m4a", "audio/mp4"),
            ("a.wav", "audio/wav"),
            ("a.md", "text/plain; charset=utf-8"),
            ("a.yml", "text/plain; charset=utf-8"),
            ("a.bin", "application/octet-stream"),
        ];
        for (name, expected) in cases {
            std::fs::write(dir.path().join(name), b"<svg onload=alert(1)/>").unwrap();
            let path = dir.path().join(name).display().to_string();
            let res = get_raw(&app, &path, &[]).await;
            assert_eq!(res.status(), StatusCode::OK, "{name}");
            assert_eq!(header(&res, "content-type"), expected, "{name}");
        }
    }

    #[tokio::test]
    async fn head_gives_the_headers_without_a_body() {
        let dir = tempfile::tempdir().unwrap();
        let path = clip(dir.path());
        let app = served(dir.path());
        let uri = format!("/v1/files/raw?path={}", percent_encode(&path));

        let res = send(&app, Method::HEAD, &uri, &[AUTH]).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(header(&res, "content-length"), "10");
        assert_eq!(header(&res, "content-type"), "video/mp4");
        assert!(body_of(res).await.is_empty());
    }

    #[tokio::test]
    async fn raw_reports_missing_files_folders_and_bad_paths() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("folder")).unwrap();
        let app = served(dir.path());
        let missing = dir.path().join("nope.mp4").display().to_string();
        let folder = dir.path().join("folder").display().to_string();

        assert_eq!(get_raw(&app, &missing, &[]).await.status(), StatusCode::NOT_FOUND);
        assert_eq!(get_raw(&app, &folder, &[]).await.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            get_raw(&app, "relative.mp4", &[]).await.status(),
            StatusCode::BAD_REQUEST
        );
        assert_eq!(get_raw(&app, "", &[]).await.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            send(&app, Method::GET, "/v1/files/raw", &[AUTH]).await.status(),
            StatusCode::BAD_REQUEST
        );
    }

    #[tokio::test]
    async fn raw_decodes_the_path_and_encodes_the_file_name_for_content_disposition() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("Мой клип 1.mp4"), b"abc").unwrap();
        let path = dir.path().join("Мой клип 1.mp4").display().to_string();
        let app = served(dir.path());

        let res = get_raw(&app, &path, &[]).await;
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(
            header(&res, "content-disposition"),
            "inline; filename*=UTF-8''%D0%9C%D0%BE%D0%B9%20%D0%BA%D0%BB%D0%B8%D0%BF%201.mp4"
        );
        assert_eq!(body_of(res).await, b"abc");
    }

    #[test]
    fn ranges_are_resolved_against_the_file_size() {
        assert_eq!(parse_range("bytes=0-0", 10), Some((0, 0)));
        assert_eq!(parse_range("bytes=9-", 10), Some((9, 9)));
        assert_eq!(parse_range("bytes=-10", 10), Some((0, 9)));
        assert_eq!(parse_range("bytes=-20", 10), Some((0, 9)));
        assert_eq!(parse_range("bytes=2-100", 10), Some((2, 9)));
        assert_eq!(parse_range("bytes=10-", 10), None);
        assert_eq!(parse_range("bytes=0-", 0), None);
        assert_eq!(parse_range("bytes=3-1", 10), None);
        assert_eq!(parse_range("bytes=1-2,4-5", 10), None);
        assert_eq!(parse_range("bytes=-", 10), None);
        assert_eq!(parse_range("bytes=a-b", 10), None);
    }

    #[test]
    fn percent_encoding_keeps_only_unreserved_characters() {
        assert_eq!(percent_encode("a-b_c.d~E9/ é"), "a-b_c.d~E9%2F%20%C3%A9");
    }
}
