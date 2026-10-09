//! HTTP + WebSocket transport: `GET /v1/health`, `GET /v1/rpc` (WebSocket).
//! Auth: `Authorization: Bearer <device token>`. Without a token the socket
//! is anonymous (only `daemon.hello` and `pair.redeem`).

use super::{App, Peer, serve};
use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use futures_util::{SinkExt, StreamExt};
use std::sync::Arc;
use tokio::sync::mpsc;

pub fn router(app: Arc<App>) -> Router {
    Router::new()
        .route("/v1/health", get(|| async { "ok" }))
        .route("/v1/rpc", get(rpc))
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

async fn rpc(State(app): State<Arc<App>>, headers: HeaderMap, ws: WebSocketUpgrade) -> Response {
    // Browsers attach Origin; native apps don't. A web page must not drive the
    // daemon through the user's browser, even for pairing.
    if headers.contains_key(axum::http::header::ORIGIN) {
        return (StatusCode::FORBIDDEN, "browser origins are not allowed").into_response();
    }
    let peer = match bearer(&headers) {
        None => Peer::Anonymous,
        Some(token) => match app.sup.hub().store.device_auth(token) {
            Ok(Some(d)) => Peer::Device(d),
            Ok(None) => return (StatusCode::UNAUTHORIZED, "unknown or revoked token").into_response(),
            Err(e) => {
                tracing::error!("device auth: {e:#}");
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        },
    };
    ws.max_message_size(1 << 20)
        .on_upgrade(move |socket| handle(app, peer, socket))
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
