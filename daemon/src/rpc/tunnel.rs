//! TCP tunnel over WebSocket: `GET /v1/tunnel?port=<1..=65535>` connects to a
//! port on the server's loopback interface and copies bytes both ways.
//! The route and its checks are in `ws.rs`; see docs/ARCHITECTURE.md#tunnel.

use axum::body::Bytes;
use axum::extract::ws::{CloseFrame, Message, WebSocket};
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

/// Largest WebSocket message a client may send.
pub const MAX_MESSAGE_SIZE: usize = 1 << 20;
/// Bytes read from the target per WebSocket message.
const READ_CHUNK: usize = 64 * 1024;
/// How long connecting to the target may take, both addresses together.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

/// Most live tunnels per device.
#[cfg(not(test))]
pub(super) fn tunnel_limit() -> usize {
    64
}

/// Tests use a small limit; the 64 itself is covered by the `TunnelSlots` test.
#[cfg(test)]
pub(super) fn tunnel_limit() -> usize {
    2
}

/// Live tunnels per device id. Held in `App`.
#[derive(Default)]
pub struct TunnelSlots {
    open: Mutex<HashMap<String, usize>>,
}

/// One live tunnel of a device. Dropping it frees the slot.
pub struct TunnelSlot {
    slots: Arc<TunnelSlots>,
    device_id: String,
}

impl TunnelSlots {
    /// A slot for `device_id`, or `None` when it already has `limit` tunnels.
    pub fn acquire(self: &Arc<Self>, device_id: &str, limit: usize) -> Option<TunnelSlot> {
        let mut open = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let count = open.entry(device_id.to_owned()).or_insert(0);
        if *count >= limit {
            return None;
        }
        *count += 1;
        Some(TunnelSlot {
            slots: self.clone(),
            device_id: device_id.to_owned(),
        })
    }
}

impl Drop for TunnelSlot {
    fn drop(&mut self) {
        let mut open = self.slots.open.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(count) = open.get_mut(&self.device_id) {
            *count -= 1;
            if *count == 0 {
                open.remove(&self.device_id);
            }
        }
    }
}

/// Connects to `port` on loopback: IPv4 first, then IPv6.
async fn connect(port: u16) -> io::Result<TcpStream> {
    let attempt = async {
        match TcpStream::connect(("127.0.0.1", port)).await {
            Ok(stream) => Ok(stream),
            Err(_) => TcpStream::connect(("::1", port)).await,
        }
    };
    tokio::time::timeout(CONNECT_TIMEOUT, attempt)
        .await
        .unwrap_or_else(|_| Err(io::Error::new(io::ErrorKind::TimedOut, "connect timed out")))
}

/// Runs one tunnel: connects to the target, then copies bytes until either side
/// ends. `_slot` frees the device's slot when this returns.
pub async fn run(mut socket: WebSocket, port: u16, _slot: TunnelSlot) {
    let tcp = match connect(port).await {
        Ok(tcp) => tcp,
        Err(e) => {
            tracing::debug!("tunnel to port {port} failed: {e}");
            let close = CloseFrame {
                code: 1011,
                reason: "connect failed".into(),
            };
            let _ = socket.send(Message::Close(Some(close))).await;
            return;
        }
    };
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    let (mut ws_tx, mut ws_rx) = socket.split();

    // The first side to end stops the other: the other future is dropped.
    tokio::select! {
        () = uplink(&mut ws_rx, &mut tcp_w) => {}
        () = downlink(&mut tcp_r, &mut ws_tx) => {}
    }
    let close = CloseFrame {
        code: 1000,
        reason: "".into(),
    };
    let _ = ws_tx.send(Message::Close(Some(close))).await;
}

/// WebSocket to TCP. Returns when the client closes, fails, or the TCP write
/// fails; then the TCP write side is shut down.
async fn uplink(ws_rx: &mut SplitStream<WebSocket>, tcp_w: &mut OwnedWriteHalf) {
    while let Some(Ok(msg)) = ws_rx.next().await {
        match msg {
            Message::Binary(data) => {
                if tcp_w.write_all(&data).await.is_err() {
                    break;
                }
            }
            Message::Close(_) => break,
            // Text is not part of the protocol. Pings are answered by the library.
            _ => {}
        }
    }
    let _ = tcp_w.shutdown().await;
}

/// TCP to WebSocket. Returns when the target closes or a send fails.
async fn downlink(tcp_r: &mut OwnedReadHalf, ws_tx: &mut SplitSink<WebSocket, Message>) {
    let mut buf = vec![0u8; READ_CHUNK];
    loop {
        match tcp_r.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                if ws_tx
                    .send(Message::Binary(Bytes::copy_from_slice(&buf[..n])))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::files::FileService;
    use crate::hub::Hub;
    use crate::rpc::{App, ws};
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use futures_util::{SinkExt, StreamExt};
    use std::net::SocketAddr;
    use std::time::Duration;
    use tokio::io::AsyncWriteExt;
    use tokio::net::{TcpListener, TcpStream};
    use tokio_tungstenite::tungstenite::client::IntoClientRequest;
    use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
    use tokio_tungstenite::tungstenite::{self, Message as ClientMessage};
    use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

    const TOKEN: &str = "bdt_test_token";
    const AUTH: (&str, &str) = ("authorization", "Bearer bdt_test_token");
    const WAIT: Duration = Duration::from_secs(5);

    type Client = WebSocketStream<MaybeTlsStream<TcpStream>>;

    /// An app with one paired device (`TOKEN`).
    fn app() -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        store.device_add("test", TOKEN).unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let dir = std::env::temp_dir();
        App::new_with_files(sup, dir.clone(), FileService::new(dir, None))
    }

    /// The router on a real socket, so that WebSocket upgrades work.
    async fn serve(app: Arc<App>) -> SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move { axum::serve(listener, ws::router(app)).await.unwrap() });
        addr
    }

    /// A TCP echo server on loopback; returns its port.
    async fn echo_server() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let (mut r, mut w) = stream.into_split();
                    let _ = tokio::io::copy(&mut r, &mut w).await;
                    let _ = w.shutdown().await;
                });
            }
        });
        port
    }

    /// A TCP server that sends `bye` and closes every connection; returns its port.
    async fn closing_server() -> u16 {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                tokio::spawn(async move {
                    let _ = stream.write_all(b"bye").await;
                    let _ = stream.shutdown().await;
                });
            }
        });
        port
    }

    /// Opens `GET /v1/tunnel?<query>` with extra headers.
    async fn open(addr: SocketAddr, query: &str, headers: &[(&str, &str)]) -> Result<Client, tungstenite::Error> {
        let mut req = format!("ws://{addr}/v1/tunnel?{query}").into_client_request().unwrap();
        for (name, value) in headers {
            let name = HeaderName::from_bytes(name.as_bytes()).unwrap();
            req.headers_mut().insert(name, HeaderValue::from_str(value).unwrap());
        }
        tokio_tungstenite::connect_async(req).await.map(|(ws, _)| ws)
    }

    /// A tunnel to `port` with the device token.
    async fn open_ok(addr: SocketAddr, port: u16) -> Client {
        open(addr, &format!("port={port}"), &[AUTH]).await.unwrap()
    }

    /// The HTTP status of a refused upgrade.
    fn refused(err: tungstenite::Error) -> u16 {
        match err {
            tungstenite::Error::Http(res) => res.status().as_u16(),
            other => panic!("expected an HTTP refusal, got {other:?}"),
        }
    }

    /// Reads until the server ends the socket. Returns the close frame it sent, if any.
    async fn closed_with(ws: &mut Client) -> Option<(u16, String)> {
        tokio::time::timeout(WAIT, async {
            while let Some(msg) = ws.next().await {
                match msg {
                    Ok(ClientMessage::Close(frame)) => {
                        return frame.map(|f| (u16::from(f.code), f.reason.to_string()));
                    }
                    Ok(_) => continue,
                    Err(_) => return None,
                }
            }
            None
        })
        .await
        .expect("socket did not close in time")
    }

    #[tokio::test]
    async fn echoes_binary_messages_in_both_directions() {
        let addr = serve(app()).await;
        let port = echo_server().await;
        let (mut tx, mut rx) = open_ok(addr, port).await.split();

        let big: Vec<u8> = (0..200 * 1024).map(|i| (i % 251) as u8).collect();
        let mut expected = b"onetwothree".to_vec();
        expected.extend_from_slice(&big);
        let sender = tokio::spawn(async move {
            for part in [b"one".to_vec(), b"two".to_vec(), b"three".to_vec(), big] {
                tx.send(ClientMessage::Binary(part.into())).await.unwrap();
            }
            tx
        });

        // The tunnel is a byte stream: the echo may come in other chunks, so compare the joined bytes.
        let mut got = Vec::new();
        tokio::time::timeout(Duration::from_secs(10), async {
            while got.len() < expected.len() {
                match rx.next().await {
                    Some(Ok(ClientMessage::Binary(b))) => got.extend_from_slice(&b),
                    other => panic!("unexpected message: {other:?}"),
                }
            }
        })
        .await
        .expect("echo did not come back in time");
        assert_eq!(got.len(), expected.len());
        assert!(got == expected, "echoed bytes differ from the sent bytes");
        drop(sender.await.unwrap());
    }

    #[tokio::test]
    async fn text_messages_from_the_client_are_ignored() {
        let addr = serve(app()).await;
        let port = echo_server().await;
        let mut ws = open_ok(addr, port).await;

        ws.send(ClientMessage::Text("ignored".into())).await.unwrap();
        ws.send(ClientMessage::Binary(b"kept".to_vec().into())).await.unwrap();
        let first = tokio::time::timeout(WAIT, ws.next()).await.unwrap();
        match first {
            Some(Ok(ClientMessage::Binary(b))) => assert_eq!(&b[..], b"kept"),
            other => panic!("expected the binary echo first, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn without_a_known_token_the_upgrade_is_refused_with_401() {
        let addr = serve(app()).await;
        let port = echo_server().await;
        let query = format!("port={port}");

        assert_eq!(refused(open(addr, &query, &[]).await.unwrap_err()), 401);
        let revoked = [("authorization", "Bearer bdt_revoked")];
        assert_eq!(refused(open(addr, &query, &revoked).await.unwrap_err()), 401);
    }

    #[tokio::test]
    async fn a_browser_origin_is_refused_with_403() {
        let addr = serve(app()).await;
        let port = echo_server().await;
        let query = format!("port={port}");

        let headers = [AUTH, ("origin", "https://evil.example")];
        assert_eq!(refused(open(addr, &query, &headers).await.unwrap_err()), 403);
    }

    #[tokio::test]
    async fn a_missing_or_invalid_port_is_refused_with_400_before_the_upgrade() {
        let addr = serve(app()).await;
        for query in ["port=0", "port=70000", "port=-1", "port=abc", ""] {
            let err = open(addr, query, &[AUTH]).await.unwrap_err();
            assert_eq!(refused(err), 400, "query {query:?}");
        }
    }

    #[tokio::test]
    async fn a_port_nobody_listens_on_closes_the_socket_with_1011() {
        let port = {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            listener.local_addr().unwrap().port()
        };
        let addr = serve(app()).await;
        let mut ws = open_ok(addr, port).await;

        assert_eq!(closed_with(&mut ws).await, Some((1011, "connect failed".to_string())));
    }

    #[tokio::test]
    async fn when_the_tcp_server_closes_the_websocket_closes() {
        let addr = serve(app()).await;
        let port = closing_server().await;
        let mut ws = open_ok(addr, port).await;

        let first = tokio::time::timeout(WAIT, ws.next()).await.unwrap();
        match first {
            Some(Ok(ClientMessage::Binary(b))) => assert_eq!(&b[..], b"bye"),
            other => panic!("expected the bytes sent before the close, got {other:?}"),
        }
        // The socket must end (`closed_with` panics if it does not, within WAIT).
        let _ = closed_with(&mut ws).await;
    }

    #[tokio::test]
    async fn a_message_over_1_mib_closes_the_tunnel() {
        let addr = serve(app()).await;
        let port = echo_server().await;
        let mut ws = open_ok(addr, port).await;

        let _ = ws.send(ClientMessage::Binary(vec![0u8; (1 << 20) + 1].into())).await;
        // The server must not echo it: the socket ends without bytes coming back.
        let ended = tokio::time::timeout(WAIT, async {
            while let Some(msg) = ws.next().await {
                if let Ok(ClientMessage::Binary(_)) = msg {
                    return false;
                }
            }
            true
        })
        .await;
        assert_eq!(ended, Ok(true));
    }

    #[tokio::test]
    async fn a_device_has_at_most_tunnel_limit_tunnels_and_a_closed_one_frees_its_slot() {
        let addr = serve(app()).await;
        let port = echo_server().await;
        let query = format!("port={port}");

        let mut live = Vec::new();
        for _ in 0..tunnel_limit() {
            live.push(open_ok(addr, port).await);
        }
        assert_eq!(refused(open(addr, &query, &[AUTH]).await.unwrap_err()), 429);

        let mut first = live.remove(0);
        first.close(None).await.unwrap();
        drop(first);
        tokio::time::timeout(WAIT, async {
            loop {
                match open(addr, &query, &[AUTH]).await {
                    Ok(ws) => {
                        live.push(ws);
                        break;
                    }
                    Err(e) => {
                        assert_eq!(refused(e), 429);
                        tokio::time::sleep(Duration::from_millis(20)).await;
                    }
                }
            }
        })
        .await
        .expect("the closed tunnel did not free its slot");
    }

    #[test]
    fn slots_count_per_device_up_to_the_limit_and_free_on_drop() {
        let slots = Arc::new(TunnelSlots::default());
        let mut held: Vec<TunnelSlot> = (0..64).map(|_| slots.acquire("dev-a", 64).expect("slot")).collect();
        assert!(slots.acquire("dev-a", 64).is_none());
        assert!(slots.acquire("dev-b", 64).is_some(), "another device has its own slots");

        held.pop();
        assert!(slots.acquire("dev-a", 64).is_some());
        held.clear();
        assert!(
            slots.open.lock().unwrap().is_empty(),
            "no entries once every slot is freed"
        );
    }
}
