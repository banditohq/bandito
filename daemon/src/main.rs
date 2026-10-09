use anyhow::{Context, Result};
use bandito::hub::Hub;
use bandito::rpc::{self, App};
use bandito::runtime::claude::ClaudeRuntime;
use bandito::store::Store;
use bandito::supervisor::{Runtimes, Supervisor};
use clap::{Parser, Subcommand};
use serde_json::json;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

#[derive(Parser)]
#[command(name = "bandito", version, about = "Your AI crew. On your own server.")]
struct Cli {
    /// Data directory (default: $BANDITO_HOME or ~/.bandito).
    #[arg(long, global = true)]
    home: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the daemon in the foreground.
    Daemon {
        /// HTTP/WebSocket address. Keep it on loopback unless it's behind TLS or a private network.
        #[arg(long, default_value = "127.0.0.1:7878")]
        listen: SocketAddr,
    },
    /// Show daemon and runtime status.
    Status,
    /// Create a one-time pairing code for the app.
    Pair,
}

fn home_dir(arg: Option<PathBuf>) -> Result<PathBuf> {
    let dir = match arg.or_else(|| std::env::var_os("BANDITO_HOME").map(PathBuf::from)) {
        Some(d) => d,
        None => dirs::home_dir().context("no home directory")?.join(".bandito"),
    };
    std::fs::create_dir_all(&dir).with_context(|| format!("create {}", dir.display()))?;
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let cli = Cli::parse();
    let home = home_dir(cli.home)?;
    let sock = home.join("bandito.sock");
    match cli.cmd {
        Cmd::Daemon { listen } => daemon(&home, &sock, listen).await,
        Cmd::Status => status(&sock).await,
        Cmd::Pair => {
            let r = rpc::unix::call(&sock, "pair.create", json!({})).await?;
            let mins = r["expires_in_ms"].as_i64().unwrap_or(0) / 60_000;
            println!(
                "Pairing code (valid {mins} min, one use):\n\n    {}\n",
                r["code"].as_str().unwrap_or("?")
            );
            println!("Enter it in the Bandito app: Settings → Servers → Add server.");
            Ok(())
        }
    }
}

async fn status(sock: &Path) -> Result<()> {
    let info = rpc::unix::call(sock, "daemon.info", json!({})).await?;
    let s = |k: &str| info[k].as_str().unwrap_or("?").to_string();
    println!(
        "bandito {} on {} ({}/{})",
        s("version"),
        s("hostname"),
        s("os"),
        s("arch")
    );
    let rts = rpc::unix::call(sock, "runtimes.status", json!({})).await?;
    for r in rts.as_array().into_iter().flatten() {
        let state = if r["installed"].as_bool() == Some(true) {
            r["version"].as_str().unwrap_or("installed").to_string()
        } else {
            "not installed".into()
        };
        println!("  {:<7} {state}", r["kind"].as_str().unwrap_or("?"));
    }
    Ok(())
}

async fn daemon(home: &Path, sock: &Path, listen: SocketAddr) -> Result<()> {
    let store = Arc::new(Store::open(&home.join("bandito.db"))?);
    let hub = Hub::new(store);
    let mut runtimes = Runtimes::default();
    runtimes.insert(Arc::new(ClaudeRuntime::new()));
    let sup = Supervisor::new(hub, runtimes, None);
    sup.recover()?;
    let app = App::new(sup.clone());

    let unix = rpc::unix::bind(sock)?;
    tokio::spawn(rpc::unix::run(app.clone(), unix));

    let tcp = tokio::net::TcpListener::bind(listen)
        .await
        .with_context(|| format!("listen on {listen}"))?;
    let router = rpc::ws::router(app.clone());
    tokio::spawn(async move {
        if let Err(e) = axum::serve(tcp, router).await {
            tracing::error!("http server: {e}");
        }
    });

    bandito::scheduler::spawn_loop(sup.clone());

    {
        let sup = sup.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(600));
            loop {
                tick.tick().await;
                if let Err(e) = sup.expire_stale_approvals().await {
                    tracing::warn!("expire approvals: {e:#}");
                }
            }
        });
    }

    tracing::info!(version = rpc::VERSION, socket = %sock.display(), %listen, "bandito daemon is running");
    shutdown_signal().await;
    tracing::info!("shutting down");
    sup.stop_all().await;
    let _ = std::fs::remove_file(sock);
    Ok(())
}

async fn shutdown_signal() {
    use tokio::signal::unix::{SignalKind, signal};
    let Ok(mut term) = signal(SignalKind::terminate()) else {
        let _ = tokio::signal::ctrl_c().await;
        return;
    };
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = term.recv() => {}
    }
}
