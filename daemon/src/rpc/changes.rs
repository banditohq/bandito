//! `changes.*` JSON-RPC methods: what an agent changed in its folder, from the
//! checkpoints in `crate::checkpoint`. The methods look up the agent and its
//! checkpoints, then run the git work on the blocking pool. A bad id or path is
//! `INVALID_PARAMS`; a git or file failure is `CHANGES_ERROR` with `data.reason`.

use super::{App, CHANGES_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, ok, params};
use crate::checkpoint::{self, Error as CheckpointError};
use crate::store::{Agent, Checkpoint, CheckpointKind, Store};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ops::RangeInclusive;
use std::path::PathBuf;

const CHECKPOINTS_LIMIT: RangeInclusive<u32> = 1..=200;
const CHECKPOINTS_DEFAULT_LIMIT: u32 = 50;

/// Answers `changes.*` methods. `None` for any other method.
pub(super) async fn dispatch(app: &App, method: &str, p: Value) -> Option<RpcResult> {
    if !method.starts_with("changes.") {
        return None;
    }
    Some(call(app, method, p).await)
}

async fn call(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "changes.checkpoints" => {
            let p: CheckpointsParams = params(p)?;
            let agent = agent(app, &p.agent_id)?;
            let limit = p.limit.unwrap_or(CHECKPOINTS_DEFAULT_LIMIT);
            if !CHECKPOINTS_LIMIT.contains(&limit) {
                return Err(RpcError::new(INVALID_PARAMS, "limit must be between 1 and 200"));
            }
            let list = app.sup.hub().store.checkpoint_list(&agent.id, limit)?;
            ok(list.iter().map(checkpoint_json).collect::<Vec<_>>())
        }
        "changes.diff" => {
            let p: DiffParams = params(p)?;
            let store = &app.sup.hub().store;
            let agent = agent(app, &p.agent_id)?;
            let from = from_checkpoint(store, &agent, p.from.as_deref())?;
            let to = to_checkpoint(store, &agent, p.to.as_deref())?;
            let files = match (&from, dirs(&agent)) {
                (Some(from), Some((home, cwd))) => {
                    checkpoint::changes(&home, &cwd, &from.sha, to.as_ref().map(|c| c.sha.as_str()))
                        .await
                        .map_err(changes_error)?
                }
                _ => Vec::new(),
            };
            ok(json!({
                "from": from.map(|c| c.id),
                "to": to.map(|c| c.id),
                "files": files,
            }))
        }
        "changes.file" => {
            let p: FileParams = params(p)?;
            let store = &app.sup.hub().store;
            let agent = agent(app, &p.agent_id)?;
            let from = from_checkpoint(store, &agent, p.from.as_deref())?;
            let to = to_checkpoint(store, &agent, p.to.as_deref())?;
            let diff = match (&from, dirs(&agent)) {
                (Some(from), Some((home, cwd))) => {
                    checkpoint::file_diff(&home, &cwd, &from.sha, to.as_ref().map(|c| c.sha.as_str()), &p.path)
                        .await
                        .map_err(changes_error)?
                }
                _ => {
                    checkpoint::check_relative(&p.path).map_err(changes_error)?;
                    checkpoint::FileDiff {
                        diff: String::new(),
                        truncated: false,
                    }
                }
            };
            ok(json!({ "diff": diff.diff, "truncated": diff.truncated }))
        }
        "changes.restore" => {
            let p: RestoreParams = params(p)?;
            let store = &app.sup.hub().store;
            let agent = agent(app, &p.agent_id)?;
            let target = checkpoint_of(store, &agent, &p.checkpoint_id)?;
            let (home, cwd) = dirs(&agent).ok_or_else(|| RpcError::new(INVALID_PARAMS, "no checkpoint"))?;
            let restored = checkpoint::restore(&home, &cwd, &target.sha, p.paths.as_deref())
                .await
                .map_err(changes_error)?;
            let undo = store.checkpoint_add(
                &agent.id,
                &restored.undo.sha,
                &restored.undo.label,
                CheckpointKind::Restore,
                None,
            )?;
            ok(json!({ "restored": restored.paths, "undo_checkpoint_id": undo.id }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckpointsParams {
    agent_id: String,
    #[serde(default)]
    limit: Option<u32>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DiffParams {
    agent_id: String,
    #[serde(default)]
    from: Option<String>,
    #[serde(default)]
    to: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FileParams {
    agent_id: String,
    path: String,
    #[serde(default)]
    from: Option<String>,
    #[serde(default)]
    to: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RestoreParams {
    agent_id: String,
    checkpoint_id: String,
    #[serde(default)]
    paths: Option<Vec<String>>,
}

/// The agent named in the params.
fn agent(app: &App, id: &str) -> Result<Agent, RpcError> {
    app.sup
        .hub()
        .store
        .agent_get(id)?
        .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no agent {id}")))
}

/// The agent's home folder (where its shadow repository lives) and working folder.
/// `None` when the agent has no home folder, so it has no checkpoints.
fn dirs(agent: &Agent) -> Option<(PathBuf, PathBuf)> {
    Some((PathBuf::from(agent.home_dir.as_ref()?), PathBuf::from(&agent.cwd)))
}

/// A checkpoint of this agent by id. Another agent's checkpoint is "not found".
fn checkpoint_of(store: &Store, agent: &Agent, id: &str) -> Result<Checkpoint, RpcError> {
    match store.checkpoint_get(id)? {
        Some(cp) if cp.agent_id == agent.id => Ok(cp),
        _ => Err(RpcError::new(INVALID_PARAMS, format!("no checkpoint {id}"))),
    }
}

/// `from` as given, else the agent's last turn (its newest "before" checkpoint). `None` when there are none.
fn from_checkpoint(store: &Store, agent: &Agent, id: Option<&str>) -> Result<Option<Checkpoint>, RpcError> {
    match id {
        Some(id) => checkpoint_of(store, agent, id).map(Some),
        None => Ok(store.checkpoint_latest(&agent.id, CheckpointKind::Before)?),
    }
}

/// `to` as given; `None` means the working folder as it is now.
fn to_checkpoint(store: &Store, agent: &Agent, id: Option<&str>) -> Result<Option<Checkpoint>, RpcError> {
    id.map(|id| checkpoint_of(store, agent, id)).transpose()
}

fn checkpoint_json(c: &Checkpoint) -> Value {
    json!({
        "id": c.id,
        "sha": c.sha,
        "label": c.label,
        "kind": c.kind,
        "turn_id": c.turn_id,
        "created_at": c.created_at,
    })
}

/// Bad ids and paths are invalid params; git and file failures are `CHANGES_ERROR`.
fn changes_error(e: CheckpointError) -> RpcError {
    let reason = e.reason();
    let data = json!({ "reason": reason });
    match e {
        CheckpointError::InvalidPath(_) | CheckpointError::InvalidRevision(_) => {
            RpcError::with_data(INVALID_PARAMS, e.to_string(), data)
        }
        _ => RpcError::with_data(CHANGES_ERROR, e.to_string(), data),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::Hub;
    use crate::rpc::{Peer, dispatch};
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use std::path::Path;
    use std::sync::Arc;

    /// An app with one agent (Forge) working in `root/proj`, whose home folder is `root/home`.
    fn app_with_agent(root: &Path) -> (Arc<App>, String) {
        let proj = root.join("proj");
        let home = root.join("home");
        std::fs::create_dir_all(&proj).unwrap();
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(proj.join("a.txt"), "v1\n").unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: proj.display().to_string(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        store.agent_set_home(&agent.id, &home.display().to_string()).unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        (App::new(sup, root.join("agents")), agent.id)
    }

    /// Takes a "before" checkpoint of the agent's folder the way a turn does.
    async fn before_turn(app: &App, agent: &str, root: &Path) -> Checkpoint {
        let store = &app.sup.hub().store;
        let snap = checkpoint::snapshot(&root.join("home"), &root.join("proj"), "before: test")
            .await
            .unwrap()
            .unwrap();
        store
            .checkpoint_add(agent, &snap.sha, &snap.label, CheckpointKind::Before, Some("turn-1"))
            .unwrap()
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    #[tokio::test]
    async fn checkpoints_list_newest_first_with_a_limit() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        let first = before_turn(&app, &agent, root.path()).await;
        let second = before_turn(&app, &agent, root.path()).await;

        let v = call(&app, "changes.checkpoints", json!({ "agent_id": agent }))
            .await
            .unwrap();
        let list = v.as_array().unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], second.id);
        assert_eq!(list[1]["id"], first.id);
        assert_eq!(list[0]["kind"], "before");
        assert_eq!(list[0]["turn_id"], "turn-1");

        let v = call(&app, "changes.checkpoints", json!({ "agent_id": agent, "limit": 1 }))
            .await
            .unwrap();
        assert_eq!(v.as_array().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn checkpoints_limit_is_checked() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        for limit in [0, 201] {
            let err = call(
                &app,
                "changes.checkpoints",
                json!({ "agent_id": agent, "limit": limit }),
            )
            .await
            .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{limit}");
        }
    }

    #[tokio::test]
    async fn no_checkpoints_is_an_empty_answer_not_an_error() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        let v = call(&app, "changes.checkpoints", json!({ "agent_id": agent }))
            .await
            .unwrap();
        assert_eq!(v, json!([]));
        let v = call(&app, "changes.diff", json!({ "agent_id": agent })).await.unwrap();
        assert_eq!(v, json!({ "from": null, "to": null, "files": [] }));
    }

    #[tokio::test]
    async fn diff_defaults_to_the_last_turn_against_the_folder_now() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        let before = before_turn(&app, &agent, root.path()).await;
        std::fs::write(root.path().join("proj/a.txt"), "v2\n").unwrap();
        std::fs::write(root.path().join("proj/b.txt"), "new\n").unwrap();

        let v = call(&app, "changes.diff", json!({ "agent_id": agent })).await.unwrap();
        assert_eq!(v["from"], before.id);
        assert_eq!(v["to"], Value::Null);
        let files = v["files"].as_array().unwrap();
        assert_eq!(files.len(), 2, "{v}");
        let a = files.iter().find(|f| f["path"] == "a.txt").unwrap();
        assert_eq!(a["status"], "modified");
        assert_eq!((a["additions"].as_u64(), a["deletions"].as_u64()), (Some(1), Some(1)));
        let b = files.iter().find(|f| f["path"] == "b.txt").unwrap();
        assert_eq!(b["status"], "added");
    }

    #[tokio::test]
    async fn file_returns_the_diff_of_one_file() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        before_turn(&app, &agent, root.path()).await;
        std::fs::write(root.path().join("proj/a.txt"), "v2\n").unwrap();

        let v = call(&app, "changes.file", json!({ "agent_id": agent, "path": "a.txt" }))
            .await
            .unwrap();
        assert_eq!(v["truncated"], false);
        let diff = v["diff"].as_str().unwrap();
        assert!(diff.contains("-v1") && diff.contains("+v2"), "{diff}");
    }

    #[tokio::test]
    async fn restore_brings_files_back_and_records_an_undo_checkpoint() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        let before = before_turn(&app, &agent, root.path()).await;
        let proj = root.path().join("proj");
        std::fs::write(proj.join("a.txt"), "v2\n").unwrap();
        std::fs::write(proj.join("c.txt"), "c\n").unwrap();

        let v = call(
            &app,
            "changes.restore",
            json!({ "agent_id": agent, "checkpoint_id": before.id }),
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read_to_string(proj.join("a.txt")).unwrap(), "v1\n");
        assert!(!proj.join("c.txt").exists());
        let mut restored: Vec<&str> = v["restored"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| p.as_str().unwrap())
            .collect();
        restored.sort();
        assert_eq!(restored, ["a.txt", "c.txt"]);

        let undo_id = v["undo_checkpoint_id"].as_str().unwrap().to_string();
        let list = call(&app, "changes.checkpoints", json!({ "agent_id": agent }))
            .await
            .unwrap();
        let undo = list.as_array().unwrap().iter().find(|c| c["id"] == undo_id).unwrap();
        assert_eq!(undo["kind"], "restore");

        // The undo checkpoint can be applied back.
        call(
            &app,
            "changes.restore",
            json!({ "agent_id": agent, "checkpoint_id": undo_id }),
        )
        .await
        .unwrap();
        assert_eq!(std::fs::read_to_string(proj.join("a.txt")).unwrap(), "v2\n");
        assert_eq!(std::fs::read_to_string(proj.join("c.txt")).unwrap(), "c\n");
    }

    #[tokio::test]
    async fn restore_one_path_only() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        let before = before_turn(&app, &agent, root.path()).await;
        let proj = root.path().join("proj");
        std::fs::write(proj.join("a.txt"), "v2\n").unwrap();
        std::fs::write(proj.join("c.txt"), "c\n").unwrap();

        let v = call(
            &app,
            "changes.restore",
            json!({ "agent_id": agent, "checkpoint_id": before.id, "paths": ["a.txt"] }),
        )
        .await
        .unwrap();
        assert_eq!(v["restored"], json!(["a.txt"]));
        assert_eq!(std::fs::read_to_string(proj.join("a.txt")).unwrap(), "v1\n");
        assert!(proj.join("c.txt").exists(), "other files are left alone");
    }

    #[tokio::test]
    async fn unknown_agent_and_foreign_checkpoints_are_invalid_params() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        let before = before_turn(&app, &agent, root.path()).await;

        let err = call(&app, "changes.checkpoints", json!({ "agent_id": "nope" }))
            .await
            .unwrap_err();
        assert_eq!(err, RpcError::new(INVALID_PARAMS, "no agent nope"));

        let other = app
            .sup
            .hub()
            .store
            .agent_create(NewAgent {
                name: "Scout".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        let err = call(
            &app,
            "changes.restore",
            json!({ "agent_id": other.id, "checkpoint_id": before.id }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert_eq!(std::fs::read_to_string(root.path().join("proj/a.txt")).unwrap(), "v1\n");
    }

    #[tokio::test]
    async fn bad_paths_and_unknown_fields_are_refused() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        before_turn(&app, &agent, root.path()).await;

        let err = call(&app, "changes.file", json!({ "agent_id": agent, "path": "../x" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert_eq!(err.data.as_ref().unwrap()["reason"], "invalid_path");

        let err = call(&app, "changes.diff", json!({ "agent_id": agent, "bogus": 1 }))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
    }

    #[tokio::test]
    async fn a_missing_working_folder_is_a_changes_error() {
        let root = tempfile::tempdir().unwrap();
        let (app, agent) = app_with_agent(root.path());
        before_turn(&app, &agent, root.path()).await;
        std::fs::remove_dir_all(root.path().join("proj")).unwrap();

        let err = call(&app, "changes.diff", json!({ "agent_id": agent }))
            .await
            .unwrap_err();
        assert_eq!(err.code, CHANGES_ERROR);
        assert_eq!(err.data.as_ref().unwrap()["reason"], "missing_folder");
    }
}
