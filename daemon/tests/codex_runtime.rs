//! Codex adapter against the fake CLI replaying `tests/fixtures/codex/*.jsonl`.

use bandito::event::{Decision, EventBody, TurnStatus};
use bandito::runtime::codex::CodexRuntime;
use bandito::runtime::{Runtime, RuntimeOutput, SpawnConfig, Spawned};
use std::path::PathBuf;
use std::time::Duration;

fn cfg(script: &str) -> SpawnConfig {
    SpawnConfig {
        agent_id: "a1".into(),
        cwd: std::env::temp_dir(),
        program: Some(PathBuf::from(env!("CARGO_BIN_EXE_fakecli"))),
        env: vec![(
            "FAKECLI_SCRIPT".into(),
            format!("{}/tests/fixtures/codex/{script}", env!("CARGO_MANIFEST_DIR")),
        )],
        ..Default::default()
    }
}

async fn spawn(c: SpawnConfig) -> Spawned {
    CodexRuntime::new().spawn(c).await.expect("spawn")
}

async fn next(s: &mut Spawned) -> RuntimeOutput {
    tokio::time::timeout(Duration::from_secs(5), s.output.recv())
        .await
        .expect("timed out waiting for runtime output")
        .expect("output channel closed")
}

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
async fn command_approval_flow() {
    let mut c = cfg("approve_command.jsonl");
    c.model = Some("gpt-5.5-codex".into());
    c.system_prompt = Some("You are Forge.".into());
    let mut s = spawn(c).await;
    // Sent before the thread exists: the adapter queues it.
    s.session.send("push it").await.unwrap();

    let before = until(&mut s, is_approval).await;
    assert!(before.contains(&RuntimeOutput::SessionId("thr-1".into())));
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::UsageLimits { runtime, windows })
            if runtime == "codex"
                && windows.iter().any(|w| w.name == "five_hour" && (w.utilization - 0.12).abs() < 1e-9 && w.resets_at == Some(1791543600))
                && windows.iter().any(|w| w.name == "seven_day" && (w.utilization - 0.40).abs() < 1e-9))));
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, title, .. })
            if call_id == "item-1" && tool == "shell" && title == "git push origin main")));
    // the user's own message is not echoed back as an event
    assert!(
        !before
            .iter()
            .any(|o| matches!(o, RuntimeOutput::Event(EventBody::MessageUser { .. })))
    );

    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.call_id, "item-1");
    assert_eq!(req.tool, "shell");
    assert_eq!(req.title, "git push origin main");
    assert_eq!(req.command.as_deref(), Some("git push origin main"));
    assert!(req.paths.is_empty());

    s.session.resolve(&req.key, Decision::Allow).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    // the server's own `serverRequest/resolved` after our answer is not a cancellation
    assert!(
        !after
            .iter()
            .any(|o| matches!(o, RuntimeOutput::ApprovalCancelled { .. }))
    );
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: true, output })
            if call_id == "item-1" && output == "Everything up-to-date\n")));
    let deltas: String = after
        .iter()
        .filter_map(|o| match o {
            RuntimeOutput::Event(EventBody::MessageDelta { text }) => Some(text.as_str()),
            _ => None,
        })
        .collect();
    assert_eq!(deltas, "Pushed.");
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageAssistant { text }) if text == "Pushed.")));
    let RuntimeOutput::Event(EventBody::TurnCompleted {
        turn_id,
        status,
        usage,
        cost_usd,
    }) = after.last().unwrap().clone()
    else {
        unreachable!()
    };
    assert_eq!(turn_id, "");
    assert_eq!(status, TurnStatus::Ok);
    let usage = usage.expect("usage from thread/tokenUsage/updated");
    assert_eq!(usage.input_tokens, 1200);
    assert_eq!(usage.output_tokens, 40);
    assert_eq!(cost_usd, None);
    s.session.shutdown().await;
}

#[tokio::test]
async fn file_change_is_shown_as_a_diff_and_can_be_declined() {
    let mut s = spawn(cfg("file_change_deny.jsonl")).await;
    s.session.send("edit").await.unwrap();
    let before = until(&mut s, is_approval).await;
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, title, .. })
            if call_id == "fc-1" && tool == "apply_patch" && title == "Edit /home/user/work/src/lib.rs (+1 more)")));
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "req-7");
    assert_eq!(req.tool, "apply_patch");
    assert_eq!(req.command, None);
    assert_eq!(
        req.paths,
        vec!["/home/user/work/src/lib.rs".to_string(), "/etc/hosts".to_string()]
    );
    let diff = req.diff.expect("diff from the fileChange item");
    assert!(diff.contains("/home/user/work/src/lib.rs"));
    assert!(diff.contains("+new"));
    assert!(diff.contains("/etc/hosts"));

    s.session.resolve("req-7", Decision::Deny).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: false, output })
            if call_id == "fc-1" && output == "declined")));
    assert!(
        s.session.resolve("req-7", Decision::Allow).await.is_err(),
        "answered already"
    );
    s.session.shutdown().await;
}

#[tokio::test]
async fn interrupt_withdraws_the_pending_approval() {
    let mut s = spawn(cfg("interrupt_and_cancel.jsonl")).await;
    s.session.send("clean").await.unwrap();
    let before = until(&mut s, is_approval).await;
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "5");
    s.session.interrupt().await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.contains(&RuntimeOutput::ApprovalCancelled { key: "5".into() }));
    let RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) = after.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*status, TurnStatus::Interrupted);
    assert!(s.session.resolve("5", Decision::Allow).await.is_err());
    s.session.shutdown().await;
}

#[tokio::test]
async fn failed_turn_reports_the_error_once() {
    let mut s = spawn(cfg("not_logged_in.jsonl")).await;
    s.session.send("hi").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    let errors: Vec<&String> = out
        .iter()
        .filter_map(|o| match o {
            RuntimeOutput::Event(EventBody::Error { message }) => Some(message),
            _ => None,
        })
        .collect();
    assert_eq!(errors.len(), 1, "retry noise is not reported: {errors:?}");
    assert!(errors[0].contains("401 Unauthorized"));
    let RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) = out.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*status, TurnStatus::Error);
    s.session.shutdown().await;
}

#[tokio::test]
async fn resume_mcp_calls_and_unsupported_requests() {
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.resume = Some("thr-old".into());
    let mut s = spawn(c).await;
    s.session.send("go on").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert!(out.contains(&RuntimeOutput::SessionId("thr-old".into())));
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, title, .. })
            if call_id == "mcp-1" && tool == "bandito.crew_send" && title == "bandito.crew_send")));
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: true, output })
            if call_id == "mcp-1" && output == "sent to Scout")));
    s.session.shutdown().await;
}

#[tokio::test]
async fn passes_flags_for_model_and_mcp() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    c.resume = Some("thr-old".into());
    c.mcp = Some((
        PathBuf::from("/usr/local/bin/bandito"),
        vec!["mcp".into(), "--agent".into(), "a1".into()],
    ));
    let s = spawn(c).await;
    let mut args: Vec<String> = Vec::new();
    for _ in 0..50 {
        if let Ok(text) = std::fs::read_to_string(&args_out)
            && let Ok(v) = serde_json::from_str::<Vec<String>>(&text)
        {
            args = v;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(args[..2], ["app-server".to_string(), "--stdio".to_string()]);
    let has = |pair: &[&str]| {
        args.windows(pair.len())
            .any(|w| w.iter().zip(pair).all(|(a, b)| a == b))
    };
    assert!(has(&["-c", r#"mcp_servers.bandito.command="/usr/local/bin/bandito""#]));
    assert!(has(&["-c", r#"mcp_servers.bandito.args=["mcp","--agent","a1"]"#]));
    s.session.shutdown().await;
}

#[tokio::test]
async fn status_reports_missing_binary() {
    let st = CodexRuntime::with_program("/nonexistent/codex").status().await;
    assert!(!st.installed);
}
