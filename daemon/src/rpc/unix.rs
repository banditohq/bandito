//! Unix socket transport: newline-delimited JSON-RPC, trusted (same user).

use super::{App, Peer, serve};
use std::path::Path;
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;

/// Bind the socket (replacing a stale one) with mode 0600.
pub fn bind(path: &Path) -> anyhow::Result<UnixListener> {
    if path.exists() {
        // A live daemon would answer; a dead one leaves the file behind.
        if std::os::unix::net::UnixStream::connect(path).is_ok() {
            anyhow::bail!("another bandito daemon is already running ({})", path.display());
        }
        std::fs::remove_file(path)?;
    }
    let listener = UnixListener::bind(path)?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

pub async fn run(app: Arc<App>, listener: UnixListener) {
    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(handle(app.clone(), stream));
            }
            Err(e) => {
                tracing::warn!("unix accept: {e}");
                tokio::time::sleep(std::time::Duration::from_millis(200)).await;
            }
        }
    }
}

async fn handle(app: Arc<App>, stream: UnixStream) {
    let (read, mut write) = stream.into_split();
    let (in_tx, in_rx) = mpsc::channel::<String>(64);
    let (out_tx, mut out_rx) = mpsc::channel::<String>(256);
    let writer = tokio::spawn(async move {
        while let Some(line) = out_rx.recv().await {
            if write.write_all(line.as_bytes()).await.is_err() || write.write_all(b"\n").await.is_err() {
                break;
            }
        }
    });
    let reader = tokio::spawn(async move {
        let mut lines = BufReader::new(read).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if !line.trim().is_empty() && in_tx.send(line).await.is_err() {
                break;
            }
        }
    });
    serve(app, Peer::Local, in_rx, out_tx).await;
    reader.abort();
    let _ = writer.await;
}

/// Client side, for the `bandito` CLI: one request, one response.
pub async fn call(path: &Path, method: &str, params: serde_json::Value) -> anyhow::Result<serde_json::Value> {
    let stream = UnixStream::connect(path)
        .await
        .map_err(|e| anyhow::anyhow!("cannot reach the daemon at {} ({e}). Is it running?", path.display()))?;
    let (read, mut write) = stream.into_split();
    let req = serde_json::json!({ "jsonrpc": "2.0", "id": 1, "method": method, "params": params });
    write.write_all(format!("{req}\n").as_bytes()).await?;
    let mut lines = BufReader::new(read).lines();
    while let Some(line) = lines.next_line().await? {
        let v: serde_json::Value = serde_json::from_str(&line)?;
        if v.get("id") != Some(&serde_json::json!(1)) {
            continue;
        }
        if let Some(err) = v.get("error") {
            anyhow::bail!("{}", err["message"].as_str().unwrap_or("daemon error"));
        }
        return Ok(v["result"].clone());
    }
    anyhow::bail!("the daemon closed the connection")
}
