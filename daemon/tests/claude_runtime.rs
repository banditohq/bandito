//! Claude Code adapter against the fake CLI replaying `tests/fixtures/claude/*.jsonl`.

use bandito::event::{Decision, EventBody, TurnStatus};
use bandito::runtime::claude::ClaudeRuntime;
use bandito::runtime::{Runtime, RuntimeOutput, SpawnConfig, Spawned};
use bandito::store::Effort;
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
    // the fake writes args at startup; poll until the file parses (it may be half-written)
    let mut parsed: Option<Vec<String>> = None;
    for _ in 0..50 {
        parsed = std::fs::read_to_string(&args_out)
            .ok()
            .and_then(|text| serde_json::from_str::<Vec<String>>(&text).ok());
        if parsed.is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let args = parsed.expect("args file written and parseable");
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

/// Argv of a fake CLI, read once it has written it (it does so at startup).
async fn written_args(path: &std::path::Path) -> Vec<String> {
    for _ in 0..250 {
        if let Some(args) = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| serde_json::from_str::<Vec<String>>(&text).ok())
        {
            return args;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("args file not written: {}", path.display());
}

fn position_of(args: &[String], flag: &str) -> usize {
    args.iter()
        .position(|a| a == flag)
        .unwrap_or_else(|| panic!("missing {flag} in {args:?}"))
}

#[tokio::test]
async fn passes_effort_and_extra_dirs() {
    let dir = tempfile::tempdir().unwrap();
    let args_out = dir.path().join("args.json");
    let mut c = cfg("deny.jsonl", Some(&args_out));
    c.model = Some("opus".into());
    c.effort = Some(Effort::High);
    c.system_prompt = Some("You are Forge.".into());
    c.extra_dirs = vec![
        PathBuf::from("/home/user/bandito/agents/forge"),
        PathBuf::from("/home/user/work/shop"),
    ];
    let s = ClaudeRuntime::new().spawn(c).await.unwrap();
    let args = written_args(&args_out).await;
    assert!(args.windows(2).any(|w| w == ["--effort", "high"]), "{args:?}");
    let dirs: Vec<&str> = args
        .windows(2)
        .filter(|w| w[0] == "--add-dir")
        .map(|w| w[1].as_str())
        .collect();
    assert_eq!(dirs, ["/home/user/bandito/agents/forge", "/home/user/work/shop"]);
    // Placed after --model and before --append-system-prompt.
    let model = position_of(&args, "--model");
    let effort = position_of(&args, "--effort");
    let add_dir = position_of(&args, "--add-dir");
    let prompt = position_of(&args, "--append-system-prompt");
    assert!(model < effort && effort < add_dir && add_dir < prompt, "{args:?}");
    s.session.shutdown().await;
}

#[tokio::test]
async fn effort_flag_carries_every_level() {
    let dir = tempfile::tempdir().unwrap();
    let levels = [
        (Effort::Low, "low"),
        (Effort::Medium, "medium"),
        (Effort::High, "high"),
        (Effort::Xhigh, "xhigh"),
        (Effort::Max, "max"),
    ];
    for (i, (effort, name)) in levels.into_iter().enumerate() {
        let args_out = dir.path().join(format!("args-{i}.json"));
        let mut c = cfg("deny.jsonl", Some(&args_out));
        c.effort = Some(effort);
        let s = ClaudeRuntime::new().spawn(c).await.unwrap();
        let args = written_args(&args_out).await;
        assert!(
            args.windows(2).any(|w| w[0] == "--effort" && w[1] == name),
            "{name}: {args:?}"
        );
        s.session.shutdown().await;
    }
}

#[tokio::test]
async fn status_reports_missing_binary() {
    let st = ClaudeRuntime::with_program("/nonexistent/claude").status().await;
    assert!(!st.installed);
    assert_eq!(st.version, None);
}

/// Spawn config for a fixture by absolute path (for scripts written at test time).
fn cfg_for_path(script: &std::path::Path, env: Vec<(String, String)>) -> SpawnConfig {
    let mut all = vec![("FAKECLI_SCRIPT".to_string(), script.display().to_string())];
    all.extend(env);
    SpawnConfig {
        agent_id: "a1".into(),
        cwd: std::env::temp_dir(),
        program: Some(PathBuf::from(env!("CARGO_BIN_EXE_fakecli"))),
        env: all,
        ..Default::default()
    }
}

#[tokio::test]
async fn cancelled_approval_cannot_be_answered() {
    let mut s = ClaudeRuntime::new().spawn(cfg("cancel.jsonl", None)).await.unwrap();
    s.session.send("go").await.unwrap();
    let before = until(&mut s, is_approval).await;
    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert_eq!(req.key, "perm-c");

    let cancelled = until(&mut s, |o| matches!(o, RuntimeOutput::ApprovalCancelled { .. })).await;
    assert_eq!(
        cancelled.last().unwrap(),
        &RuntimeOutput::ApprovalCancelled { key: "perm-c".into() }
    );
    assert!(s.session.resolve("perm-c", Decision::Allow).await.is_err());

    let rest = until(&mut s, is_turn_end).await;
    assert!(matches!(
        rest.last(),
        Some(RuntimeOutput::Event(EventBody::TurnCompleted {
            status: TurnStatus::Ok,
            ..
        }))
    ));
    s.session.shutdown().await;
}

#[tokio::test]
async fn unsupported_control_request_gets_an_error_reply() {
    let mut s = ClaudeRuntime::new()
        .spawn(cfg("unknown_control.jsonl", None))
        .await
        .unwrap();
    s.session.send("go").await.unwrap();
    // The fake only sends the result after it has read the error reply (its `expect`).
    let out = until(&mut s, is_turn_end).await;
    assert!(out.iter().all(|o| !is_approval(o)), "a hook request is not an approval");
    assert!(matches!(
        out.last(),
        Some(RuntimeOutput::Event(EventBody::TurnCompleted {
            status: TurnStatus::Ok,
            ..
        }))
    ));
    s.session.shutdown().await;
}

#[tokio::test]
async fn non_json_stdout_lines_are_skipped() {
    let mut s = ClaudeRuntime::new().spawn(cfg("not_json.jsonl", None)).await.unwrap();
    s.session.send("hi").await.unwrap();
    let out = until(&mut s, is_turn_end).await;
    assert!(out.contains(&RuntimeOutput::SessionId("55555555-5555-4555-8555-555555555555".into())));
    assert!(out.iter().any(|o| matches!(o,
        RuntimeOutput::Event(EventBody::MessageAssistant { text }) if text == "Hi there.")));
    s.session.shutdown().await;
}

#[tokio::test]
async fn big_write_is_clipped_in_events_but_answered_in_full() {
    let big = "w".repeat(100 * 1024);
    let dir = tempfile::tempdir().unwrap();
    let script = dir.path().join("write_big.jsonl");
    let steps = [
        serde_json::json!({"expect": {"type": "control_request", "request": {"subtype": "initialize"}}}),
        serde_json::json!({"send": {"type": "control_response", "response": {
            "subtype": "success", "request_id": "$last:/request_id", "response": {}}}}),
        serde_json::json!({"expect": {"type": "user"}}),
        serde_json::json!({"send": {"type": "system", "subtype": "init",
            "session_id": "66666666-6666-4666-8666-666666666666"}}),
        serde_json::json!({"send": {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "toolu_w", "name": "Write",
             "input": {"file_path": "/w/big.txt", "content": big}}]}}}),
        serde_json::json!({"send": {"type": "control_request", "request_id": "perm-w", "request": {
            "subtype": "can_use_tool", "tool_name": "Write", "tool_use_id": "toolu_w",
            "input": {"file_path": "/w/big.txt", "content": big}}}}),
        // The answer must echo the original input, not the clipped copy.
        serde_json::json!({"expect": {"type": "control_response", "response": {
            "subtype": "success", "request_id": "perm-w",
            "response": {"behavior": "allow", "updatedInput": {"file_path": "/w/big.txt", "content": big}}}}}),
        serde_json::json!({"send": {"type": "result", "subtype": "success", "is_error": false,
            "result": "Written.", "session_id": "66666666-6666-4666-8666-666666666666"}}),
    ];
    let text: String = steps.iter().map(|s| format!("{s}\n")).collect();
    std::fs::write(&script, text).unwrap();

    let mut s = ClaudeRuntime::new()
        .spawn(cfg_for_path(&script, Vec::new()))
        .await
        .unwrap();
    s.session.send("write it").await.unwrap();
    let before = until(&mut s, is_approval).await;

    let tool_input = before
        .iter()
        .find_map(|o| match o {
            RuntimeOutput::Event(EventBody::ToolCall { input, .. }) => Some(input.clone()),
            _ => None,
        })
        .expect("tool call event");
    let clipped = tool_input["content"].as_str().expect("content").len();
    assert!(clipped <= 4096 + 64, "tool call input clipped to {clipped} bytes");

    let RuntimeOutput::Approval(req) = before.last().unwrap().clone() else {
        unreachable!()
    };
    assert!(req.input["content"].as_str().expect("content").len() <= 4096 + 64);

    s.session.resolve(&req.key, Decision::Allow).await.unwrap();
    let after = until(&mut s, is_turn_end).await;
    assert!(matches!(
        after.last(),
        Some(RuntimeOutput::Event(EventBody::TurnCompleted {
            status: TurnStatus::Ok,
            ..
        }))
    ));
    s.session.shutdown().await;
}

/// Poll until the fake CLI has written the pid of its background `sleep`.
#[cfg(unix)]
async fn wait_pid(path: &std::path::Path) -> u32 {
    for _ in 0..100 {
        let pid = std::fs::read_to_string(path)
            .ok()
            .and_then(|text| text.trim().parse::<u32>().ok());
        if let Some(pid) = pid {
            return pid;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("fake CLI did not report a pid");
}

/// True when no process with this pid exists any more. Zombies count as alive.
#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the pid exists; it sends nothing.
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

/// Wait up to 3 s for `pid` to disappear.
#[cfg(unix)]
async fn wait_gone(pid: u32) -> bool {
    for _ in 0..150 {
        if !process_alive(pid) {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    false
}

#[cfg(unix)]
#[tokio::test]
async fn shutdown_kills_the_whole_process_group() {
    let dir = tempfile::tempdir().unwrap();
    let pid_out = dir.path().join("pid");
    let env = vec![("FAKECLI_PID_OUT".to_string(), pid_out.display().to_string())];
    let script = PathBuf::from(fixture("spawn_sleep.jsonl"));
    let s = ClaudeRuntime::new().spawn(cfg_for_path(&script, env)).await.unwrap();
    let pid = wait_pid(&pid_out).await;
    assert!(process_alive(pid), "background child runs before shutdown");

    s.session.shutdown().await;
    assert!(wait_gone(pid).await, "background child {pid} survived shutdown");
}

#[cfg(unix)]
#[tokio::test]
async fn dropping_the_session_kills_the_child_tree() {
    let dir = tempfile::tempdir().unwrap();
    let pid_out = dir.path().join("pid");
    let env = vec![("FAKECLI_PID_OUT".to_string(), pid_out.display().to_string())];
    let script = PathBuf::from(fixture("spawn_sleep.jsonl"));
    let s = ClaudeRuntime::new().spawn(cfg_for_path(&script, env)).await.unwrap();
    let pid = wait_pid(&pid_out).await;
    assert!(process_alive(pid), "background child runs before drop");

    drop(s);
    assert!(wait_gone(pid).await, "background child {pid} survived the drop");
}
