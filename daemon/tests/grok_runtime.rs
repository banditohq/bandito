//! Grok adapter (ACP over stdio) against the fake CLI replaying `tests/fixtures/grok/*.jsonl`.

use bandito::event::{Decision, EventBody, TurnStatus};
use bandito::runtime::grok::GrokRuntime;
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
            format!("{}/tests/fixtures/grok/{script}", env!("CARGO_MANIFEST_DIR")),
        )],
        ..Default::default()
    }
}

async fn spawn(c: SpawnConfig) -> Spawned {
    GrokRuntime::new().spawn(c).await.expect("spawn")
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

fn texts(out: &[RuntimeOutput]) -> Vec<String> {
    out.iter()
        .filter_map(|o| match o {
            RuntimeOutput::Event(EventBody::MessageAssistant { text }) => Some(text.clone()),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn permission_flow_and_message_assembly() {
    let mut c = cfg("approve.jsonl");
    c.system_prompt = Some("You are Night Owl.".into());
    c.mcp = Some((
        PathBuf::from("/usr/local/bin/bandito"),
        vec!["mcp".into(), "--agent".into(), "a1".into()],
    ));
    let mut s = spawn(c).await;
    s.session.send("run the audit").await.unwrap();

    let before = until(&mut s, is_approval).await;
    assert!(before.contains(&RuntimeOutput::SessionId("sess-g1".into())));
    // text before a tool call is flushed as one message; thoughts are dropped
    assert_eq!(texts(&before), vec!["Running the audit.".to_string()]);
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageDelta { text }) if text == "Running ")));
    assert!(!before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageDelta { text }) if text == "thinking")));
    assert!(before.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, title, .. })
            if call_id == "call-1" && tool == "execute" && title == "cargo audit")));

    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "7");
    assert_eq!(req.call_id, "call-1");
    assert_eq!(req.tool, "execute");
    assert_eq!(req.title, "cargo audit");
    assert_eq!(req.command.as_deref(), Some("cargo audit"));

    s.session.resolve("7", Decision::Allow).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: true, output })
            if call_id == "call-1" && output == "0 vulnerabilities")));
    // in_progress updates are not results
    assert_eq!(
        after
            .iter()
            .filter(|o| matches!(o, RuntimeOutput::Event(EventBody::ToolResult { .. })))
            .count(),
        1
    );
    assert_eq!(
        texts(&after),
        vec!["Clean.".to_string()],
        "final text flushed before turn end"
    );
    let RuntimeOutput::Event(EventBody::TurnCompleted { turn_id, status, .. }) = after.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(turn_id, "");
    assert_eq!(*status, TurnStatus::Ok);
    s.session.shutdown().await;
}

#[tokio::test]
async fn edit_rejection_carries_paths_and_diff() {
    // No system prompt here: the text goes as is.
    let mut s = spawn(cfg("reject_edit.jsonl")).await;
    s.session.send("fix hosts").await.unwrap();
    let before = until(&mut s, is_approval).await;
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "p-1");
    assert_eq!(req.tool, "edit");
    assert_eq!(req.command, None);
    assert_eq!(req.paths, vec!["/etc/hosts".to_string()]);
    let diff = req.diff.expect("diff from content");
    assert!(diff.contains("/etc/hosts") && diff.contains("- a") && diff.contains("+ b"));

    s.session.resolve("p-1", Decision::Deny).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: false, output })
            if call_id == "call-2" && output == "Rejected by user")));
    s.session.shutdown().await;
}

#[tokio::test]
async fn interrupt_cancels_open_permission_requests() {
    let mut s = spawn(cfg("cancel.jsonl")).await;
    s.session.send("clean").await.unwrap();
    let before = until(&mut s, is_approval).await;
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "9");
    s.session.interrupt().await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(after.contains(&RuntimeOutput::ApprovalCancelled { key: "9".into() }));
    let RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) = after.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*status, TurnStatus::Interrupted);
    assert!(s.session.resolve("9", Decision::Allow).await.is_err());
    s.session.shutdown().await;
}

#[tokio::test]
async fn load_session_and_failed_prompt() {
    let mut c = cfg("rate_limited.jsonl");
    c.resume = Some("sess-old".into());
    let mut s = spawn(c).await;
    s.session.send("again").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert!(out.contains(&RuntimeOutput::SessionId("sess-old".into())));
    // history replayed by session/load is not shown again
    assert!(!out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageDelta { text } | EventBody::MessageAssistant { text })
            if text.contains("replayed"))));
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::Error { message })
            if message.contains("Rate limited") && message.contains("free usage"))));
    let RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) = out.last().unwrap() else {
        unreachable!()
    };
    assert_eq!(*status, TurnStatus::Error);
    s.session.shutdown().await;
}

#[tokio::test]
async fn passes_flags() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("reject_edit.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    c.model = Some("grok-4.7".into());
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
    assert_eq!(args, ["agent", "--no-leader", "--model", "grok-4.7", "stdio"]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn status_reports_missing_binary() {
    let st = GrokRuntime::with_program("/nonexistent/grok").status().await;
    assert!(!st.installed);
}
