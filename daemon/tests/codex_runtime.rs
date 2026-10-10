//! Codex adapter against the fake CLI replaying `tests/fixtures/codex/*.jsonl`.

use bandito::event::{Decision, EventBody, LimitWindow, Plan, TurnStatus};
use bandito::runtime::codex::CodexRuntime;
use bandito::runtime::{Runtime, RuntimeOutput, SpawnConfig, Spawned};
use bandito::store::Effort;
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
async fn turn_start_carries_the_effort() {
    let mut c = cfg("effort_turn.jsonl");
    c.effort = Some(Effort::Medium);
    let mut s = spawn(c).await;
    s.session.send("think about it").await.unwrap();
    // The fixture only answers turn/start when it carries "effort": "medium".
    let out = until(&mut s, is_turn_end).await;
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Ok]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn extra_dirs_become_one_writable_roots_override() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    c.extra_dirs = vec![PathBuf::from("/a"), PathBuf::from("/b")];
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
    let has = |pair: &[&str]| {
        args.windows(pair.len())
            .any(|w| w.iter().zip(pair).all(|(a, b)| a == b))
    };
    assert!(
        has(&["-c", r#"sandbox_workspace_write.writable_roots=["/a","/b"]"#]),
        "{args:?}"
    );
    assert_eq!(args.iter().filter(|a| a.contains("writable_roots")).count(), 1);
    s.session.shutdown().await;
}

/// A Codex runtime whose fake CLI replays `script` (from `tests/fixtures/codex/`) for a usage read.
fn usage_runtime(script: &str) -> CodexRuntime {
    CodexRuntime::with_program(env!("CARGO_BIN_EXE_fakecli")).with_env(vec![(
        "FAKECLI_SCRIPT".into(),
        format!("{}/tests/fixtures/codex/{script}", env!("CARGO_MANIFEST_DIR")),
    )])
}

#[tokio::test]
async fn refresh_usage_reads_the_rate_limits_without_a_turn() {
    let windows = usage_runtime("rate_limits_read.jsonl")
        .refresh_usage()
        .await
        .expect("usage read")
        .expect("codex can be asked for its limits");
    assert_eq!(
        windows,
        vec![
            LimitWindow {
                name: "five_hour".into(),
                utilization: 0.25,
                resets_at: Some(1791543600),
            },
            LimitWindow {
                name: "seven_day".into(),
                utilization: 0.6,
                resets_at: Some(1792026000),
            },
        ]
    );
}

#[tokio::test]
async fn refresh_usage_reports_a_refused_read() {
    let err = usage_runtime("rate_limits_read_error.jsonl")
        .refresh_usage()
        .await
        .expect_err("a refused read is an error");
    assert_eq!(err.to_string(), "codex: not logged in");
}

#[tokio::test]
async fn status_reports_missing_binary() {
    let st = CodexRuntime::with_program("/nonexistent/codex").status().await;
    assert!(!st.installed);
}

#[tokio::test]
async fn account_plan_reads_the_plan_without_a_turn() {
    let plan = usage_runtime("account_read_pro.jsonl")
        .account_plan()
        .await
        .expect("account read");
    assert_eq!(
        plan,
        Some(Plan {
            id: "pro".into(),
            label: "Pro".into(),
        })
    );
}

#[tokio::test]
async fn account_plan_is_none_when_the_read_is_refused() {
    let plan = usage_runtime("account_read_error.jsonl")
        .account_plan()
        .await
        .expect("a refused read is not an error for the plan");
    assert_eq!(plan, None);
}

#[tokio::test]
async fn account_plan_is_none_without_a_plan_type() {
    let plan = usage_runtime("account_read_no_plan.jsonl")
        .account_plan()
        .await
        .expect("account read");
    assert_eq!(plan, None);
}

fn is_session_id(o: &RuntimeOutput) -> bool {
    matches!(o, RuntimeOutput::SessionId(_))
}

fn is_message_delta(o: &RuntimeOutput) -> bool {
    matches!(o, RuntimeOutput::Event(EventBody::MessageDelta { .. }))
}

/// Messages of all `Error` events, in order.
fn error_messages(out: &[RuntimeOutput]) -> Vec<String> {
    out.iter()
        .filter_map(|o| match o {
            RuntimeOutput::Event(EventBody::Error { message }) => Some(message.clone()),
            _ => None,
        })
        .collect()
}

/// Status of every `TurnCompleted`, in order.
fn turn_statuses(out: &[RuntimeOutput]) -> Vec<TurnStatus> {
    out.iter()
        .filter_map(|o| match o {
            RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) => Some(*status),
            _ => None,
        })
        .collect()
}

#[tokio::test]
async fn thread_start_error_ends_each_queued_turn_and_reports_the_error_once() {
    let mut s = spawn(cfg("thread_start_error.jsonl")).await;
    s.session.send("first").await.unwrap();
    s.session.send("second").await.unwrap();
    let mut out = until(&mut s, is_turn_end).await;
    out.extend(until(&mut s, is_turn_end).await);
    assert_eq!(error_messages(&out), vec!["codex: sandbox setup failed".to_string()]);
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Error, TurnStatus::Error]);
    assert!(!out.iter().any(is_session_id));
    s.session.shutdown().await;
}

#[tokio::test]
async fn initialize_error_ends_the_queued_turn() {
    let mut s = spawn(cfg("initialize_error.jsonl")).await;
    s.session.send("hello").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert_eq!(error_messages(&out), vec!["codex: server busy".to_string()]);
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Error]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn resume_failure_starts_a_new_thread_and_runs_the_queued_text() {
    let mut c = cfg("resume_fallback.jsonl");
    c.resume = Some("thr-gone".into());
    c.model = Some("gpt-5.5-codex".into());
    c.system_prompt = Some("You are Forge.".into());
    let mut s = spawn(c).await;
    s.session.send("go on").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert_eq!(
        error_messages(&out),
        vec!["codex could not resume the previous thread; started a new one".to_string()]
    );
    assert!(out.contains(&RuntimeOutput::SessionId("thr-new".into())));
    assert!(!out.contains(&RuntimeOutput::SessionId("thr-gone".into())));
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageDelta { text }) if text == "Back.")));
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Ok]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn interrupt_before_the_turn_id_is_sent_when_turn_start_answers() {
    let mut s = spawn(cfg("interrupt_turn_start_pending.jsonl")).await;
    until(&mut s, is_session_id).await;
    s.session.send("long task").await.unwrap();
    // turn/start is still unanswered here. The fixture only answers after a delay, so this is the pending path.
    s.session.interrupt().await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Interrupted]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn interrupt_uses_the_turn_id_from_turn_started() {
    let mut s = spawn(cfg("interrupt_on_turn_started.jsonl")).await;
    until(&mut s, is_session_id).await;
    s.session.send("long task").await.unwrap();
    // The delta is sent after turn/started, so the turn id is known once it arrives.
    until(&mut s, is_message_delta).await;
    s.session.interrupt().await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Interrupted]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn interrupt_before_the_thread_ends_the_queued_turns() {
    let mut s = spawn(cfg("interrupt_before_thread.jsonl")).await;
    s.session.send("first").await.unwrap();
    s.session.send("second").await.unwrap();
    s.session.interrupt().await.unwrap();
    // Reported with the CLI's next message, before anything else it says.
    let mut out = until(&mut s, is_turn_end).await;
    out.extend(until(&mut s, is_turn_end).await);
    assert_eq!(
        turn_statuses(&out),
        vec![TurnStatus::Interrupted, TurnStatus::Interrupted]
    );
    assert!(!out.iter().any(is_session_id));
    s.session.shutdown().await;
}

#[tokio::test]
async fn mcp_tool_that_reports_is_error_failed() {
    let mut s = spawn(cfg("mcp_is_error.jsonl")).await;
    s.session.send("send it").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolResult { call_id, ok: false, output })
            if call_id == "mcp-2" && output == "unknown recipient")));
    assert_eq!(turn_statuses(&out), vec![TurnStatus::Ok]);
    s.session.shutdown().await;
}

#[tokio::test]
async fn an_integration_call_is_journaled_under_its_server_name() {
    let mut s = spawn(cfg("mcp_integration_call.jsonl")).await;
    s.session.send("make an issue").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    // The event keeps the runtime's name, `linear.create_issue`: only the journal reads the server name.
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, .. })
            if call_id == "mcp-3" && tool == "linear.create_issue")));

    let store = bandito::store::Store::open_in_memory().unwrap();
    let mut journal = bandito::call_journal::Journal::default();
    journal.set_servers(vec!["linear".into()]);
    for o in &out {
        match o {
            RuntimeOutput::Event(EventBody::ToolCall { call_id, tool, .. }) => {
                journal.started(&store, "a1", call_id, tool, 1_000)
            }
            RuntimeOutput::Event(EventBody::ToolResult { call_id, ok, output }) => {
                journal.finished(&store, call_id, *ok, output, 1_250)
            }
            _ => {}
        }
    }
    let filter = bandito::store::CallFilter {
        limit: 10,
        ..Default::default()
    };
    let rows = store.tool_calls_list(&filter, 1_000).unwrap();
    assert_eq!(rows.len(), 1);
    let row = &rows[0];
    assert_eq!(
        (row.integration.as_str(), row.tool.as_str()),
        ("linear", "create_issue")
    );
    assert_eq!(
        (row.ok, row.duration_ms, row.error.clone()),
        (Some(true), Some(250), None)
    );
    assert!(!format!("{row:?}").contains("ARGUMENT-SECRET"));
    s.session.shutdown().await;
}

#[tokio::test]
async fn turn_end_cancels_approvals_that_are_still_open() {
    let mut s = spawn(cfg("approval_open_at_turn_end.jsonl")).await;
    s.session.send("clean").await.unwrap();
    let before = until(&mut s, is_approval).await;
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "req-9");
    let after = until(&mut s, is_turn_end).await;
    let cancelled = after
        .iter()
        .position(|o| *o == RuntimeOutput::ApprovalCancelled { key: "req-9".into() });
    let ended = after.iter().position(is_turn_end);
    assert!(
        matches!((cancelled, ended), (Some(c), Some(e)) if c < e),
        "cancelled before the turn ends: {after:?}"
    );
    assert!(
        s.session.resolve("req-9", Decision::Allow).await.is_err(),
        "the turn already closed it"
    );
    s.session.shutdown().await;
}

#[tokio::test]
async fn the_crew_server_gets_the_token_file_and_no_token_in_argv() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let token_file = dir.path().join("agent-x.token");
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    c.mcp = Some((
        PathBuf::from("/usr/local/bin/bandito"),
        vec![
            "mcp".into(),
            "--agent".into(),
            "a1".into(),
            "--token-file".into(),
            token_file.display().to_string(),
        ],
    ));
    c.agent_token = Some("bat_secret_value".into());
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
    assert!(args.iter().all(|a| !a.contains("bat_")), "{args:?}");
    let expected = format!(
        r#"mcp_servers.bandito.args=["mcp","--agent","a1","--token-file","{}"]"#,
        token_file.display()
    );
    assert!(args.contains(&expected), "{args:?}");
    s.session.shutdown().await;
}

/// Argv that Codex was started with, read once the fake has written it.
async fn codex_argv(c: SpawnConfig, args_out: &std::path::Path) -> Vec<String> {
    let s = spawn(c).await;
    let mut args: Vec<String> = Vec::new();
    for _ in 0..50 {
        if let Ok(text) = std::fs::read_to_string(args_out)
            && let Ok(v) = serde_json::from_str::<Vec<String>>(&text)
        {
            args = v;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    s.session.shutdown().await;
    args
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn codex_runs_under_the_sandbox_with_its_own_sandbox_off() {
    use bandito::runtime::sandbox::SandboxPolicy;
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    c.agent_token = Some("bat_secret_value".into());
    c.sandbox = Some(SandboxPolicy {
        home: dir.path().join(".bandito"),
        user_home: dir.path().join("home"),
        exe: None,
        session_files: Vec::new(),
    });
    let args = codex_argv(c, &args_out).await;
    assert!(
        args.iter().any(|a| a == r#"sandbox_mode="danger-full-access""#),
        "{args:?}"
    );
    assert!(args.iter().all(|a| !a.contains("bat_")), "{args:?}");
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn codex_without_a_sandbox_keeps_its_own_settings() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    let args = codex_argv(c, &args_out).await;
    assert!(args.iter().all(|a| !a.contains("sandbox_mode")), "{args:?}");
}

#[cfg(not(target_os = "macos"))]
#[tokio::test]
async fn codex_keeps_its_own_sandbox_where_there_is_no_macos_sandbox() {
    use bandito::runtime::sandbox::SandboxPolicy;
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("resume_and_unknown_request.jsonl");
    c.env.push(("FAKECLI_ARGS_OUT".into(), args_out.display().to_string()));
    c.sandbox = Some(SandboxPolicy {
        home: dir.path().join(".bandito"),
        user_home: dir.path().join("home"),
        exe: None,
        session_files: Vec::new(),
    });
    let args = codex_argv(c, &args_out).await;
    assert!(args.iter().all(|a| !a.contains("sandbox_mode")), "{args:?}");
}

// Login probe: `codex login status` against tests/fixtures/login/fake-cli.sh (see claude_runtime.rs).

fn login_cli() -> String {
    format!("{}/tests/fixtures/login/fake-cli.sh", env!("CARGO_MANIFEST_DIR"))
}

fn login_runtime(calls: &std::path::Path, answer: &[(&str, &str)]) -> CodexRuntime {
    let mut env = vec![("FAKE_CALLS".to_string(), calls.display().to_string())];
    env.extend(answer.iter().map(|(k, v)| (k.to_string(), v.to_string())));
    CodexRuntime::with_program(&login_cli()).with_env(env)
}

fn probes(calls: &std::path::Path) -> usize {
    std::fs::read_to_string(calls).map(|s| s.lines().count()).unwrap_or(0)
}

#[tokio::test]
async fn status_is_logged_in_when_login_status_exits_zero() {
    let dir = tempfile::tempdir().unwrap();
    let calls = dir.path().join("calls");
    let rt = login_runtime(&calls, &[("FAKE_OUT", "Logged in using ChatGPT")]);
    let st = rt.status().await;
    assert!(st.installed);
    assert_eq!(st.logged_in, Some(true));
    assert_eq!(std::fs::read_to_string(&calls).unwrap().trim(), "login status");
}

#[tokio::test]
async fn status_is_logged_out_on_not_logged_in_from_either_stream() {
    let dir = tempfile::tempdir().unwrap();
    let on_stdout = login_runtime(
        &dir.path().join("a"),
        &[("FAKE_OUT", "Not logged in"), ("FAKE_CODE", "1")],
    );
    assert_eq!(on_stdout.status().await.logged_in, Some(false));
    let on_stderr = login_runtime(
        &dir.path().join("b"),
        &[("FAKE_ERR", "Error: Not logged in"), ("FAKE_CODE", "1")],
    );
    assert_eq!(on_stderr.status().await.logged_in, Some(false));
}

#[tokio::test]
async fn status_is_unknown_for_other_failures_and_garbage() {
    let dir = tempfile::tempdir().unwrap();
    let other = login_runtime(
        &dir.path().join("a"),
        &[("FAKE_ERR", "network down"), ("FAKE_CODE", "1")],
    );
    assert_eq!(other.status().await.logged_in, None);
    let wrong_code = login_runtime(
        &dir.path().join("b"),
        &[("FAKE_OUT", "Not logged in"), ("FAKE_CODE", "2")],
    );
    assert_eq!(wrong_code.status().await.logged_in, None);
}

#[tokio::test]
async fn status_is_unknown_when_login_status_hangs() {
    let dir = tempfile::tempdir().unwrap();
    let rt = login_runtime(&dir.path().join("calls"), &[("FAKE_SLEEP", "30")]);
    let started = std::time::Instant::now();
    assert_eq!(rt.status().await.logged_in, None);
    assert!(
        started.elapsed() < std::time::Duration::from_secs(15),
        "the probe has a 5 s limit"
    );
}

#[tokio::test]
async fn status_is_unknown_without_the_cli() {
    let st = CodexRuntime::with_program("/nonexistent/codex").status().await;
    assert_eq!(st.logged_in, None);
}

#[tokio::test]
async fn status_asks_the_cli_once_a_minute_even_when_called_at_once() {
    let dir = tempfile::tempdir().unwrap();
    let calls = dir.path().join("calls");
    let rt = login_runtime(&calls, &[("FAKE_OUT", "Logged in")]);
    let (a, b) = tokio::join!(rt.status(), rt.status());
    assert_eq!([a.logged_in, b.logged_in], [Some(true); 2]);
    assert_eq!(probes(&calls), 1);
    rt.status().await;
    assert_eq!(probes(&calls), 1, "the answer is reused within 60 s");
}
