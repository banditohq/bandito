use anyhow::{Context, Result, bail};
use bandito::home;
use bandito::hub::Hub;
use bandito::rpc::{self, App};
use bandito::runtime::claude::ClaudeRuntime;
use bandito::runtime::codex::CodexRuntime;
use bandito::runtime::grok::GrokRuntime;
use bandito::service;
use bandito::store::Store;
use bandito::supervisor::{Runtimes, Supervisor};
use clap::{Parser, Subcommand};
use serde_json::{Value, json};
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
    Pair {
        /// Print {"code","expires_in_ms"} as one JSON line.
        #[arg(long)]
        json: bool,
    },
    /// Show version, paths and whether the daemon answers.
    Info {
        /// Print the result as one JSON object.
        #[arg(long)]
        json: bool,
    },
    /// Install, remove or inspect the daemon as a user service.
    Service {
        #[command(subcommand)]
        cmd: ServiceCmd,
    },
    /// Crew MCP server for one agent (started by the daemon; speaks MCP on stdio).
    Mcp {
        #[arg(long)]
        agent: String,
    },
}

#[derive(Subcommand)]
enum ServiceCmd {
    /// Install and start the daemon as a user service (systemd, launchd, or a background process).
    Install {
        /// HTTP/WebSocket address for the daemon. Keep it on loopback unless it's behind TLS or a private network.
        #[arg(long, default_value = "127.0.0.1:7878")]
        listen: SocketAddr,
        /// Print the result as one JSON object.
        #[arg(long)]
        json: bool,
        /// Print what would be written and run. Changes nothing.
        #[arg(long)]
        dry_run: bool,
    },
    /// Stop the service and remove its unit or plist. Data is kept.
    Uninstall,
    /// Show whether the service is installed and running.
    Status {
        /// Print the result as one JSON object.
        #[arg(long)]
        json: bool,
    },
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

/// One line for `bandito pair --json`.
fn pair_json(code: &str, expires_in_ms: i64) -> String {
    json!({ "code": code, "expires_in_ms": expires_in_ms }).to_string()
}

/// The object for `bandito info --json`. `daemon` is the `daemon.info` result when the daemon answered.
fn info_json(version: &str, home: &Path, socket: &Path, listen: &str, daemon: Option<&Value>) -> Value {
    let features = daemon
        .map(|d| d["features"].clone())
        .filter(Value::is_array)
        .unwrap_or_else(|| json!([]));
    json!({
        "version": version,
        "home": home.display().to_string(),
        "socket": socket.display().to_string(),
        "listen": listen,
        "running": daemon.is_some(),
        "features": features,
    })
}

#[tokio::main]
async fn main() -> Result<()> {
    // Logs go to stderr: `mcp` uses stdout for the protocol.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let cli = Cli::parse();
    let home = home_dir(cli.home)?;
    let sock = home.join("bandito.sock");
    match cli.cmd {
        Cmd::Daemon { listen } => daemon(&home, &sock, listen).await,
        Cmd::Status => status(&sock).await,
        Cmd::Pair { json } => pair(&sock, json).await,
        Cmd::Info { json } => info(&home, &sock, json).await,
        Cmd::Service { cmd } => service_cmd(cmd, &home).await,
        Cmd::Mcp { agent } => bandito::crew::serve_stdio(sock, agent).await,
    }
}

async fn pair(sock: &Path, json: bool) -> Result<()> {
    let r = rpc::unix::call(sock, "pair.create", json!({})).await?;
    let code = r["code"].as_str().context("daemon returned no pairing code")?;
    let expires_in_ms = r["expires_in_ms"].as_i64().context("daemon returned no expiry")?;
    if json {
        println!("{}", pair_json(code, expires_in_ms));
        return Ok(());
    }
    println!(
        "Pairing code (valid {} min, one use):\n\n    {code}\n",
        expires_in_ms / 60_000
    );
    println!("Enter it in the Bandito app: Settings → Servers → Add server.");
    Ok(())
}

/// File in the data directory with the address the daemon listens on (`bandito info`).
const LISTEN_FILE: &str = "listen";

async fn info(home: &Path, sock: &Path, json: bool) -> Result<()> {
    let daemon = service::probe_daemon(sock).await;
    // The running daemon records its address; fall back to the default when it never ran.
    let listen = std::fs::read_to_string(home.join(LISTEN_FILE))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| service::DEFAULT_LISTEN.to_string());
    let info = info_json(rpc::VERSION, home, sock, &listen, daemon.as_ref());
    if json {
        println!("{info}");
        return Ok(());
    }
    println!("bandito {}", rpc::VERSION);
    println!("home    {}", home.display());
    println!("socket  {}", sock.display());
    println!("daemon  {}", if daemon.is_some() { "running" } else { "not running" });
    Ok(())
}

async fn service_cmd(cmd: ServiceCmd, home: &Path) -> Result<()> {
    let user_home = dirs::home_dir().context("no home directory")?;
    let paths = service::Paths::new(home, &user_home);
    match cmd {
        ServiceCmd::Install { listen, json, dry_run } => {
            let (user, uid) = service::current_user()?;
            let spec = service::InstallSpec {
                exe: std::env::current_exe()?
                    .canonicalize()
                    .context("resolve the path of the bandito binary")?,
                listen: listen.to_string(),
                // The unit runs the daemon with its default data dir; pass --home only when it differs.
                home_override: (home != user_home.join(".bandito")).then(|| home.to_path_buf()),
                path_env: std::env::var("PATH").unwrap_or_default(),
                user,
                uid,
            };
            let os = service::Os::current();
            let probe = service::probe(os);
            if dry_run {
                print!(
                    "{}",
                    service::describe(&service::install_plan(&spec, &paths, os, &probe))
                );
                return Ok(());
            }
            let out = service::install(&paths, &spec, os, &probe).await?;
            if json {
                let v = service::install_json(out.ok, out.mode, &spec.listen, &paths.socket, &out.warnings);
                println!("{v}");
            } else {
                for w in &out.warnings {
                    eprintln!("warning: {w}");
                }
                if out.ok {
                    println!("Bandito daemon is running ({}) on {}.", out.mode.as_str(), spec.listen);
                    println!("Next: `bandito pair`, then in the Bandito app: Add server.");
                }
            }
            if !out.ok {
                bail!("the daemon did not answer on {}", paths.socket.display());
            }
            Ok(())
        }
        ServiceCmd::Uninstall => {
            let present = service::Presence {
                unit: paths.unit_file.exists(),
                plist: paths.plist_file.exists(),
                pid_file: paths.pid_file.exists(),
            };
            if !(present.unit || present.plist || present.pid_file) {
                println!("Bandito service is not installed.");
                return Ok(());
            }
            let (_, uid) = service::current_user()?;
            let warnings = service::execute(&service::uninstall_plan(&paths, &present, uid))?;
            for w in &warnings {
                eprintln!("warning: {w}");
            }
            println!("Bandito service removed. Data in {} is kept.", home.display());
            Ok(())
        }
        ServiceCmd::Status { json } => {
            let st = service::status(&paths).await;
            if json {
                println!("{}", service::status_json(&st));
                return Ok(());
            }
            println!("installed  {}", if st.installed { "yes" } else { "no" });
            if let Some(mode) = st.mode {
                println!("mode       {}", mode.as_str());
            }
            println!("running    {}", if st.running { "yes" } else { "no" });
            if let Some(pid) = st.pid {
                println!("pid        {pid}");
            }
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
    let agents_root = home::default_agents_root(home);
    let created = home::backfill(&store, &agents_root);
    if created > 0 {
        tracing::info!(count = created, "created folders for agents that had none");
    }
    let hub = Hub::new(store);
    let mut runtimes = Runtimes::default();
    runtimes.insert(Arc::new(ClaudeRuntime::new()));
    runtimes.insert(Arc::new(CodexRuntime::new()));
    runtimes.insert(Arc::new(GrokRuntime::new()));
    // Each agent gets `bandito --home <home> mcp --agent <id>` as its crew MCP server.
    // If the binary was replaced while the daemon runs, its path is gone from disk
    // (Linux shows it with " (deleted)"): start agents without the crew instead of failing.
    let exe = std::env::current_exe()?;
    let mcp = if exe.exists() {
        Some((exe, vec!["--home".into(), home.display().to_string(), "mcp".into()]))
    } else {
        tracing::warn!(
            path = %exe.display(),
            "bandito binary is no longer on disk (updated while running?); agents start without the crew MCP server"
        );
        None
    };
    let sup = Supervisor::new(hub, runtimes, mcp);
    sup.recover()?;
    let app = App::new(sup.clone(), agents_root);

    let unix = rpc::unix::bind(sock)?;
    tokio::spawn(rpc::unix::run(app.clone(), unix));

    let tcp = tokio::net::TcpListener::bind(listen)
        .await
        .with_context(|| format!("listen on {listen}"))?;
    if let Err(e) = std::fs::write(home.join(LISTEN_FILE), tcp.local_addr()?.to_string()) {
        tracing::warn!("could not record the listen address: {e}");
    }
    let router = rpc::ws::router(app.clone());
    tokio::spawn(async move {
        if let Err(e) = axum::serve(tcp, router).await {
            tracing::error!("http server: {e}");
        }
    });

    bandito::scheduler::spawn_loop(sup.clone());
    // Stops server screens that nobody has used for 30 minutes (see docs/ARCHITECTURE.md#screen).
    app.screens.spawn_idle_reaper();

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

    {
        // Uploads abandoned for an hour lose their temp file.
        let app = app.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(600));
            loop {
                tick.tick().await;
                let files = app.files.clone();
                match tokio::task::spawn_blocking(move || files.sweep_uploads(Duration::from_secs(3600))).await {
                    Ok(0) => {}
                    Ok(n) => tracing::info!(count = n, "removed abandoned file uploads"),
                    Err(e) => tracing::warn!("sweep file uploads: {e}"),
                }
            }
        });
    }

    {
        // Host load: one sample every 10 s, kept for the 1 h and 24 h charts (see docs/ARCHITECTURE.md#host).
        let sampler = app.host.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(bandito::host::SAMPLE_INTERVAL);
            loop {
                tick.tick().await;
                let sampler = sampler.clone();
                if let Err(e) = tokio::task::spawn_blocking(move || sampler.sample_now()).await {
                    tracing::warn!("host sample failed: {e}");
                }
            }
        });
    }

    tracing::info!(version = rpc::VERSION, socket = %sock.display(), %listen, "bandito daemon is running");
    shutdown_signal().await;
    tracing::info!("shutting down");
    app.terminals.shutdown_all();
    app.screens.shutdown_all().await;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Cmd {
        Cli::try_parse_from(args).expect("parses").cmd
    }

    #[test]
    fn pair_takes_an_optional_json_flag() {
        assert!(matches!(parse(&["bandito", "pair"]), Cmd::Pair { json: false }));
        assert!(matches!(
            parse(&["bandito", "pair", "--json"]),
            Cmd::Pair { json: true }
        ));
    }

    #[test]
    fn info_takes_an_optional_json_flag() {
        assert!(matches!(parse(&["bandito", "info"]), Cmd::Info { json: false }));
        assert!(matches!(
            parse(&["bandito", "info", "--json"]),
            Cmd::Info { json: true }
        ));
    }

    #[test]
    fn service_install_defaults_to_loopback() {
        match parse(&["bandito", "service", "install"]) {
            Cmd::Service {
                cmd:
                    ServiceCmd::Install {
                        listen,
                        json: false,
                        dry_run: false,
                    },
            } => {
                assert_eq!(listen.to_string(), "127.0.0.1:7878");
            }
            _ => panic!("unexpected parse"),
        }
    }

    #[test]
    fn service_install_takes_listen_json_and_dry_run() {
        match parse(&[
            "bandito",
            "service",
            "install",
            "--listen",
            "0.0.0.0:7879",
            "--json",
            "--dry-run",
        ]) {
            Cmd::Service {
                cmd:
                    ServiceCmd::Install {
                        listen,
                        json: true,
                        dry_run: true,
                    },
            } => {
                assert_eq!(listen.port(), 7879);
                assert!(listen.ip().is_unspecified());
            }
            _ => panic!("unexpected parse"),
        }
    }

    #[test]
    fn service_install_rejects_a_bad_listen_address() {
        assert!(Cli::try_parse_from(["bandito", "service", "install", "--listen", "not-an-addr"]).is_err());
    }

    #[test]
    fn service_status_and_uninstall_parse() {
        assert!(matches!(
            parse(&["bandito", "service", "status", "--json"]),
            Cmd::Service {
                cmd: ServiceCmd::Status { json: true }
            }
        ));
        assert!(matches!(
            parse(&["bandito", "service", "uninstall"]),
            Cmd::Service {
                cmd: ServiceCmd::Uninstall
            }
        ));
    }

    #[test]
    fn global_home_flag_is_accepted_before_the_service_subcommand() {
        let cli = Cli::try_parse_from(["bandito", "--home", "/tmp/bd", "service", "status"]).unwrap();
        assert_eq!(cli.home, Some(PathBuf::from("/tmp/bd")));
    }

    #[test]
    fn pair_json_is_one_line_with_code_and_ttl() {
        let s = pair_json("otter-lava-mint-orbit-crane-fig", 600_000);
        assert!(!s.contains('\n'));
        assert_eq!(
            s,
            r#"{"code":"otter-lava-mint-orbit-crane-fig","expires_in_ms":600000}"#
        );
    }

    #[test]
    fn info_json_when_the_daemon_is_down() {
        let v = info_json(
            "0.1.0",
            Path::new("/h"),
            Path::new("/h/bandito.sock"),
            "127.0.0.1:7878",
            None,
        );
        assert_eq!(
            v,
            json!({
                "version": "0.1.0",
                "home": "/h",
                "socket": "/h/bandito.sock",
                "listen": "127.0.0.1:7878",
                "running": false,
                "features": [],
            })
        );
    }

    #[test]
    fn info_json_takes_features_from_daemon_info() {
        let daemon = json!({"version": "0.1.0", "features": ["terminals", "files"]});
        let v = info_json(
            "0.1.0",
            Path::new("/h"),
            Path::new("/h/bandito.sock"),
            "127.0.0.1:7878",
            Some(&daemon),
        );
        assert_eq!(v["running"], json!(true));
        assert_eq!(v["features"], json!(["terminals", "files"]));
    }
}
