//! Integration check against a real Docker daemon: a container workspace runs commands inside
//! its container, and the container is removed afterwards.
//!
//! Skipped unless `BANDITO_WS_IT=1`. Run with:
//! `BANDITO_WS_IT=1 cargo test --test workspace_docker -- --ignored --nocapture`

use bandito::store::{Network, Workspace, WorkspaceKind};
use bandito::workspace::{WorkspaceManager, container_name, exec_command};
use std::path::{Path, PathBuf};

/// Removes the test container even when an assertion fails.
struct Cleanup(String);

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = std::process::Command::new("docker")
            .args(["rm", "-f", &self.0])
            .output();
    }
}

#[test]
#[ignore = "needs Docker; set BANDITO_WS_IT=1"]
fn echo_runs_inside_a_container_workspace() {
    if std::env::var("BANDITO_WS_IT").as_deref() != Ok("1") {
        eprintln!("skipped: set BANDITO_WS_IT=1 to run against Docker");
        return;
    }
    let build_dir = tempfile::tempdir().unwrap();
    let manager = WorkspaceManager::new(PathBuf::from("docker"), build_dir.path().join("build"));
    let ws = Workspace {
        id: format!("it-{}", std::process::id()),
        name: "IT".into(),
        kind: WorkspaceKind::Container,
        image: Some("alpine:3".into()),
        cpus: None,
        memory_mb: None,
        network: Network::Offline,
        mounts: Vec::new(),
        created_at: 0,
    };
    let _cleanup = Cleanup(container_name(&ws.id));
    let rt = tokio::runtime::Runtime::new().unwrap();

    rt.block_on(async {
        manager.ensure_running(&ws, &[]).await.expect("the container starts");
        let status = manager.status(&ws).await.expect("status");
        assert!(status.running, "{status:?}");
    });

    let spec = manager.spec(&ws);
    let root = Path::new("/");

    let out = exec_command(Some(&spec), "echo", &["hi".to_string()], &[], Some(root))
        .output()
        .expect("docker exec runs");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "hi\n");

    // An environment value reaches the process inside the container by name.
    let env = [("BANDITO_IT_VALUE".to_string(), "from-the-daemon".to_string())];
    let args = ["-c".to_string(), "echo $BANDITO_IT_VALUE".to_string()];
    let out = exec_command(Some(&spec), "sh", &args, &env, Some(root))
        .output()
        .expect("docker exec runs with env");
    assert_eq!(String::from_utf8_lossy(&out.stdout), "from-the-daemon\n");

    rt.block_on(async {
        manager.remove(&ws).await.expect("the container is removed");
        let status = manager.status(&ws).await.expect("status after remove");
        assert!(!status.running && status.container_id.is_none(), "{status:?}");
    });
}
