//! Smoke test against the real `claude` CLI. Needs a logged-in Claude Code and
//! uses a little of the subscription, so it is ignored by default:
//!
//!     cargo test --test claude_live -- --ignored --nocapture

use bandito::event::{Decision, EventBody, TurnStatus};
use bandito::runtime::claude::ClaudeRuntime;
use bandito::runtime::{Runtime, RuntimeOutput, SpawnConfig};
use std::time::Duration;

#[tokio::test]
#[ignore]
async fn real_claude_runs_a_tool_after_approval() {
    let rt = ClaudeRuntime::new();
    let st = rt.status().await;
    assert!(st.installed, "claude is not installed");
    println!("claude {}", st.version.unwrap_or_default());

    let dir = tempfile::tempdir().unwrap();
    let mut s = rt
        .spawn(SpawnConfig {
            agent_id: "live".into(),
            cwd: dir.path().to_path_buf(),
            model: Some("haiku".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    s.session
        .send("Run the shell command `touch bandito.txt` with the Bash tool, then reply with the single word done.")
        .await
        .unwrap();

    let mut approved = false;
    let mut session_id = None;
    loop {
        let o = tokio::time::timeout(Duration::from_secs(120), s.output.recv())
            .await
            .expect("timed out")
            .expect("closed");
        println!("{o:?}");
        match o {
            RuntimeOutput::SessionId(id) => session_id = Some(id),
            RuntimeOutput::Approval(req) => {
                assert_eq!(req.tool, "Bash");
                assert!(req.command.as_deref().unwrap_or("").contains("touch bandito.txt"));
                s.session.resolve(&req.key, Decision::Allow).await.unwrap();
                approved = true;
            }
            RuntimeOutput::Event(EventBody::TurnCompleted { status, .. }) => {
                assert_eq!(status, TurnStatus::Ok);
                break;
            }
            RuntimeOutput::Exited { code, stderr_tail } => panic!("claude exited {code:?}: {stderr_tail}"),
            _ => {}
        }
    }
    assert!(approved, "expected a permission prompt for Bash");
    assert!(session_id.is_some());
    assert!(
        dir.path().join("bandito.txt").exists(),
        "the approved command did not run"
    );
    s.session.shutdown().await;
}
