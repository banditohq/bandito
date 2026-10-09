use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "bandito", version, about = "Your AI crew. On your own server.")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the daemon in the foreground.
    Daemon,
    /// Show daemon and runtime status.
    Status,
    /// Create a one-time pairing code for the app.
    Pair,
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Daemon | Cmd::Status | Cmd::Pair => anyhow::bail!("not implemented yet"),
    }
}
