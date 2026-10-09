//! Claude Code adapter against the fake CLI replaying `tests/fixtures/claude/*.jsonl`.

use bandito::event::{Decision, EventBody, TurnStatus};
use bandito::runtime::claude::ClaudeRuntime;
use bandito::runtime::{Runtime, RuntimeOutput, SpawnConfig, Spawned};
use std::path::PathBuf;
use std::time::Duration;

fn fixture(name: &str) -> String {
    format!("{}/tests/fixtures/claude/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn cfg(script: &str, args_out: Option<&PathBuf>) -> SpawnConfig {
    let mut env = vec![("FAKECLI_SCRIPT".to_string(), fixture(script))];
    if let Some(p) = args_out {
        env.push(("FAKECLI_ARGS_OUT".to_string(), p.display().to_string()));
    }
    SpawnConfig {
        agent_id: "a1".into(),
        cwd: std::env::temp_dir(),
        program: Some(PathBuf::from(env!("CARGO_BIN_EXE_fakecli"))),
        env,
        ..Default::default()
    }
}

async fn next(s: &mut Spawned) -> RuntimeOutput {
    tokio::time::timeout(Duration::from_secs(5), s.output.recv())
        .await
        .expect("timed out waiting for runtime output")
        .expect("output channel closed")
}

/// Collect outputs until `stop` returns true for one (inclusive).
async fn until(s: &mut Spawned, stop: impl Fn(&RuntimeOutput) -> bool) -> Vec<RuntimeOutput> {
    let mut v = Vec::new();
    loop {
        let o = next(s).await;
        let done = stop(&o);
        v.push(o);
        if done {
            return v;
        }
    }
}

fn is_approval(o: &RuntimeOutput) -> bool {
    matches!(o, RuntimeOutput::Approval(_))
}

fn is_turn_end(o: &RuntimeOutput) -> bool {
    matches!(o, RuntimeOutput::Event(EventBody::TurnCompleted { .. }))
}

#[tokio::test]
async fn approve_flow_maps_every_message() {
    let mut s = ClaudeRuntime::new().spawn(cfg("approve.jsonl", None)).await.unwrap();
    s.session.send("Create b.txt").await.unwrap();

    let before = until(&mut s, is_approval).await;
    assert!(before.contains(&RuntimeOutput::SessionId("11111111-1111-4111-8111-111111111111".into())));
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, title, .. })
            if call_id == "toolu_1" && tool == "Bash" && title == "touch b.txt")));
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::UsageLimits { runtime, windows })
            if runtime == "claude" && windows.len() == 2
                && windows.iter().any(|w| w.name == "five_hour" && (w.utilization - 0.04).abs() < 1e-9 && w.resets_at == Some(1791543600)))));
    // thinking blocks produce nothing
    assert!(
        !before
            .iter()
            .any(|o| matches!(o, RuntimeOutput::Event(EventBody::MessageAssistant { text }) if text.is_empty()))
    );

    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "perm-1");
    assert_eq!(req.call_id, "toolu_1");
    assert_eq!(req.tool, "Bash");
    assert_eq!(req.title, "touch b.txt");
    assert_eq!(req.command.as_deref(), Some("touch b.txt"));
    assert_eq!(req.paths, vec!["/home/user/work/b.txt".to_string()]);

    s.session.resolve("perm-1", Decision::Allow).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: true, output })
            if call_id == "toolu_1" && output == "(Bash completed with no output)")));
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageAssistant { text }) if text == "Done: created b.txt.")));
    let RuntimeOutput::Event(EventBody::TurnCompleted {
        turn_id,
        status,
        usage,
        cost_usd,
    }) = after.last().unwrap().clone()
    else {
        unreachable!()
    };
    assert_eq!(turn_id, "", "the supervisor fills turn ids");
    assert_eq!(status, TurnStatus::Ok);
    let usage = usage.unwrap();
    assert_eq!(
        usage.input_tokens,
        4 + 26326 + 42827,
        "input counts cache reads and writes"
    );
    assert_eq!(usage.output_tokens, 113);
    assert!((cost_usd.unwrap() - 0.00575).abs() < 1e-9);

    s.session.shutdown().await;
}

#[tokio::test]
async fn deny_flow() {
    let mut s = ClaudeRuntime::new().spawn(cfg("deny.jsonl", None)).await.unwrap();
    s.session.send("push it").await.unwrap();
    let before = until(&mut s, is_approval).await;
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.title, "git push origin main");
    assert!(req.paths.is_empty());

    s.session.resolve(&req.key, Decision::Deny).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: false, output })
            if call_id == "toolu_9" && output == "Denied by the user in Bandito")));
    s.session.shutdown().await;
}

#[tokio::test]
async fn resolve_unknown_key_is_an_error() {
    let mut s = ClaudeRuntime::new().spawn(cfg("deny.jsonl", None)).await.unwrap();
    assert!(s.session.resolve("nope", Decision::Allow).await.is_err());
    s.session.shutdown().await;
}

#[tokio::test]
async fn deltas_and_interrupt() {
    let mut s = ClaudeRuntime::new()
        .spawn(cfg("stream_and_interrupt.jsonl", None))
        .await
        .unwrap();
    s.session.send("hi").await.unwrap();
    let mut deltas = String::new();
    while deltas != "Hello" {
        if let RuntimeOutput::Event(EventBody::MessageDelta { text }) = next(&mut s).await {
            deltas.push_str(&text);
        }
    }
    s.session.interrupt().await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    let RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) = after.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*status, TurnStatus::Interrupted);
    assert!(
        !after
            .iter()
            .any(|o| matches!(o, RuntimeOutput::Event(EventBody::MessageDelta { .. }))),
        "thinking deltas are dropped"
    );
    s.session.shutdown().await;
}

#[tokio::test]
async fn crash_reports_exit_and_stderr() {
    let mut s = ClaudeRuntime::new().spawn(cfg("crash.jsonl", None)).await.unwrap();
    let out = until(&mut s, |o| matches!(o, RuntimeOutput::Exited { .. })).await;
    let RuntimeOutput::Exited { code, stderr_tail } = out.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*code, Some(1));
    assert!(stderr_tail.contains("Please run /login"));
    // channel closes after Exited
    assert!(
        tokio::time::timeout(Duration::from_secs(5), s.output.recv())
            .await
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn passes_flags() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("deny.jsonl", Some(&args_out));
    c.model = Some("opus".into());
    c.system_prompt = Some("You are Forge.".into());
    c.resume = Some("sess-42".into());
    c.mcp = Some((
        PathBuf::from("/usr/local/bin/bandito"),
        vec!["mcp".into(), "--agent".into(), "a1".into()],
    ));
    let s = ClaudeRuntime::new().spawn(c).await.unwrap();
    // the fake writes args at startup; give it a moment
    for _ in 0..50 {
        if args_out.exists() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let args: Vec<String> = serde_json::from_str(&std::fs::read_to_string(&args_out).unwrap()).unwrap();
    let has = |pair: &[&str]| {
        args.windows(pair.len())
            .any(|w| w.iter().zip(pair).all(|(a, b)| a == b))
    };
    assert!(has(&["-p"]));
    assert!(has(&["--input-format", "stream-json"]));
    assert!(has(&["--output-format", "stream-json"]));
    assert!(has(&["--verbose"]));
    assert!(has(&["--include-partial-messages"]));
    assert!(has(&["--permission-prompt-tool", "stdio"]));
    assert!(has(&["--permission-mode", "default"]));
    assert!(has(&["--model", "opus"]));
    assert!(has(&["--append-system-prompt", "You are Forge."]));
    assert!(has(&["--resume", "sess-42"]));
    let i = args.iter().position(|a| a == "--mcp-config").expect("--mcp-config");
    let mcp: serde_json::Value = serde_json::from_str(&args[i + 1]).unwrap();
    assert_eq!(mcp["mcpServers"]["bandito"]["command"], "/usr/local/bin/bandito");
    assert_eq!(
        mcp["mcpServers"]["bandito"]["args"],
        serde_json::json!(["mcp", "--agent", "a1"])
    );
    s.session.shutdown().await;
}

#[tokio::test]
async fn status_reports_missing_binary() {
    let st = ClaudeRuntime::with_program("/nonexistent/claude").status().await;
    assert!(!st.installed);
    assert_eq!(st.version, None);
}
