//! The crew bridge (`bandito mcp`) runs as a child of a sandboxed agent session, so it must start under the
//! sandbox profile: the profile denies every read in the data folder except the session's own files. macOS only.
#![cfg(target_os = "macos")]

use bandito::runtime::sandbox::{SandboxPolicy, wrap};
use serde_json::json;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;

#[tokio::test]
async fn the_crew_bridge_starts_under_the_agent_sandbox() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let run = home.join("run");
    std::fs::create_dir_all(&run).unwrap();
    // The data folder the daemon made, and the session's own files, as the daemon writes them.
    let token = run.join("agent-test.token");
    std::fs::write(&token, "bat_test_token").unwrap();
    let config = run.join("agent-test.mcp.json");
    std::fs::write(&config, "{}").unwrap();
    let exe = PathBuf::from(env!("CARGO_BIN_EXE_bandito"));
    let policy = SandboxPolicy {
        home: home.clone(),
        user_home: dir.path().join("user"),
        exe: Some(exe.clone()),
        session_files: vec![token.clone(), config],
    };

    let mut cmd = Command::new(&exe);
    cmd.arg("--home")
        .arg(&home)
        .args(["mcp", "--agent", "agent-test", "--token-file"])
        .arg(&token);
    // Piped after wrapping: `wrap` builds a new command and keeps only the program, folder, env and arguments.
    let mut wrapped = wrap(cmd, Some(&policy)).unwrap();
    wrapped
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = wrapped.spawn().unwrap();

    // Claude sends `initialize` first. The bridge answers it without the daemon, so this needs no daemon.
    let request = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}
    });
    let mut stdin = child.stdin.take().unwrap();
    stdin.write_all(format!("{request}\n").as_bytes()).await.unwrap();
    stdin.flush().await.unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    let read = tokio::time::timeout(Duration::from_secs(20), stdout.read_line(&mut line)).await;
    let _ = child.kill().await;
    let mut stderr = String::new();
    if let Some(mut err) = child.stderr.take() {
        use tokio::io::AsyncReadExt;
        let _ = err.read_to_string(&mut stderr).await;
    }

    assert!(
        read.is_ok_and(|n| n.is_ok_and(|n| n > 0)),
        "the bridge gave no answer under the sandbox; stderr: {stderr}"
    );
    let answer: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(answer["result"]["serverInfo"]["name"], "bandito-crew", "{line}");
}
