//! `workspaces.*` RPC methods: where agents run (see docs/ARCHITECTURE.md#workspaces).

use super::{App, Id, METHOD_NOT_FOUND, RpcError, RpcResult, WORKSPACE_ERROR, double_option, ok, params};
use crate::store::{Mount, Network, NewWorkspace, SHARED_WORKSPACE, Store, Workspace, WorkspaceKind, WorkspacePatch};
use crate::workspace::{self, WorkspaceError, WorkspaceManager};
use serde::Deserialize;
use serde_json::{Value, json};

impl From<WorkspaceError> for RpcError {
    fn from(e: WorkspaceError) -> Self {
        RpcError::with_data(WORKSPACE_ERROR, e.to_string(), json!({ "reason": e.reason() }))
    }
}

#[derive(Deserialize)]
struct UpdateWorkspace {
    id: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(default, deserialize_with = "double_option")]
    image: Option<Option<String>>,
    #[serde(default, deserialize_with = "double_option")]
    cpus: Option<Option<f64>>,
    #[serde(default, deserialize_with = "double_option")]
    memory_mb: Option<Option<u32>>,
    #[serde(default)]
    network: Option<Network>,
    #[serde(default)]
    mounts: Option<Vec<Mount>>,
}

pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    let store = app.sup.hub().store.clone();
    let manager = app.sup.workspaces().clone();
    match method {
        "workspaces.list" => {
            let mut out = Vec::new();
            for w in store.workspace_list()? {
                out.push(view(&store, &manager, w).await?);
            }
            ok(out)
        }
        "workspaces.create" => {
            let n: NewWorkspace = params(p)?;
            ok(store.workspace_create(n)?)
        }
        "workspaces.update" => {
            let u: UpdateWorkspace = params(p)?;
            let patch = WorkspacePatch {
                name: u.name,
                image: u.image,
                cpus: u.cpus,
                memory_mb: u.memory_mb,
                network: u.network,
                mounts: u.mounts,
            };
            ok(store.workspace_update(&u.id, patch)?)
        }
        "workspaces.delete" => {
            let Id { id } = params(p)?;
            // A container of an empty workspace goes first; the store refuses the rest.
            if let Some(ws) = store.workspace_get(&id)?
                && ws.kind == WorkspaceKind::Container
                && store.workspace_agent_ids(&id)?.is_empty()
            {
                manager.remove(&ws).await?;
            }
            store.workspace_delete(&id)?;
            ok(json!({ "deleted": true }))
        }
        "workspaces.start" => {
            let Id { id } = params(p)?;
            let ws = container(&store, &id)?;
            let mounts = workspace::mounts_for(&store, &ws)?;
            manager.ensure_running(&ws, &mounts).await?;
            ok(manager.status(&ws).await?)
        }
        "workspaces.stop" => {
            let Id { id } = params(p)?;
            let ws = container(&store, &id)?;
            manager.stop(&ws).await?;
            ok(manager.status(&ws).await?)
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// A workspace that runs in a container. The shared one has none to start or stop.
fn container(store: &Store, id: &str) -> Result<Workspace, RpcError> {
    let ws = store
        .workspace_get(id)?
        .ok_or_else(|| WorkspaceError::NotFound(id.to_string()))?;
    if ws.kind != WorkspaceKind::Container {
        return Err(
            WorkspaceError::Invalid(format!("{SHARED_WORKSPACE} runs on the server, not in a container")).into(),
        );
    }
    Ok(ws)
}

/// The workspace with its agents and live status (`null` for the shared one, a
/// `running: false` with `error` when Docker cannot say).
async fn view(store: &Store, manager: &WorkspaceManager, w: Workspace) -> Result<Value, RpcError> {
    let agents = store.workspace_agent_ids(&w.id)?;
    let status = match w.kind {
        WorkspaceKind::Shared => Value::Null,
        WorkspaceKind::Container => match manager.status(&w).await {
            Ok(s) => json!(s),
            Err(e) => json!({ "running": false, "error": e.reason() }),
        },
    };
    let mut v = serde_json::to_value(&w).map_err(anyhow::Error::from)?;
    v["agents"] = json!(agents);
    v["status"] = status;
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::Hub;
    use crate::rpc::Peer;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use std::sync::Arc;

    fn app() -> (Arc<App>, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        (App::new(sup, dir.path().join("agents")), dir)
    }

    async fn call(app: &App, method: &str, p: Value) -> Result<Value, RpcError> {
        dispatch(app, method, p).await
    }

    async fn agent_call(app: &App, method: &str, p: Value) -> Result<Value, RpcError> {
        crate::rpc::dispatch(app, &Peer::Local, method, p).await
    }

    fn reason(err: &RpcError) -> String {
        assert_eq!(err.code, WORKSPACE_ERROR, "{err:?}");
        err.data.as_ref().unwrap()["reason"].as_str().unwrap().to_string()
    }

    fn container(name: &str) -> Value {
        json!({"name": name, "kind": "container", "cpus": 1.5, "memory_mb": 1024, "network": "none"})
    }

    #[tokio::test]
    async fn create_list_update_delete() {
        let (app, _dir) = app();
        let w = call(&app, "workspaces.create", container("Scout box")).await.unwrap();
        let id = w["id"].as_str().unwrap().to_string();
        assert_eq!(w["kind"], "container");
        assert_eq!(w["network"], "none");

        let list = call(&app, "workspaces.list", json!({})).await.unwrap();
        let items = list.as_array().unwrap();
        assert_eq!(items.len(), 2);
        let shared = items.iter().find(|x| x["id"] == "shared").unwrap();
        assert_eq!(shared["kind"], "shared");
        assert!(shared["agents"].as_array().unwrap().is_empty());

        let renamed = call(&app, "workspaces.update", json!({"id": id, "name": "Watch"}))
            .await
            .unwrap();
        assert_eq!(renamed["name"], "Watch");

        assert_eq!(
            call(&app, "workspaces.delete", json!({"id": id})).await.unwrap(),
            json!({"deleted": true})
        );
    }

    #[tokio::test]
    async fn delete_refuses_shared_and_a_workspace_with_agents() {
        let (app, _dir) = app();
        let err = call(&app, "workspaces.delete", json!({"id": "shared"}))
            .await
            .unwrap_err();
        assert_eq!(reason(&err), "builtin");

        let w = call(&app, "workspaces.create", container("Box")).await.unwrap();
        let id = w["id"].as_str().unwrap().to_string();
        let cwd = std::env::temp_dir().display().to_string();
        agent_call(
            &app,
            "agents.create",
            json!({"name": "Scout", "runtime": "claude", "cwd": cwd, "workspace_id": id}),
        )
        .await
        .unwrap();
        let err = call(&app, "workspaces.delete", json!({"id": id})).await.unwrap_err();
        assert_eq!(reason(&err), "not_empty");
    }

    #[tokio::test]
    async fn bad_settings_are_refused_with_a_reason() {
        let (app, _dir) = app();
        let relative = json!({"name": "Box", "kind": "container",
            "mounts": [{"host": "relative", "target": "/x"}]});
        assert_eq!(
            reason(&call(&app, "workspaces.create", relative).await.unwrap_err()),
            "invalid"
        );
        let no_cpus = json!({"name": "Box", "kind": "container", "cpus": 0});
        assert_eq!(
            reason(&call(&app, "workspaces.create", no_cpus).await.unwrap_err()),
            "invalid"
        );
        let limits_on_shared = json!({"id": "shared", "cpus": 2});
        assert_eq!(
            reason(&call(&app, "workspaces.update", limits_on_shared).await.unwrap_err()),
            "invalid"
        );
        let unknown = call(&app, "workspaces.update", json!({"id": "nope", "name": "x"}))
            .await
            .unwrap_err();
        assert_eq!(reason(&unknown), "not_found");
    }

    #[tokio::test]
    async fn agents_must_name_an_existing_workspace() {
        let (app, _dir) = app();
        let cwd = std::env::temp_dir().display().to_string();
        let err = agent_call(
            &app,
            "agents.create",
            json!({"name": "Scout", "runtime": "claude", "cwd": cwd, "workspace_id": "nope"}),
        )
        .await
        .unwrap_err();
        assert_eq!(reason(&err), "not_found");
    }

    #[tokio::test]
    async fn moving_an_agent_starts_a_new_chapter() {
        let (app, _dir) = app();
        let cwd = std::env::temp_dir().display().to_string();
        let agent = agent_call(
            &app,
            "agents.create",
            json!({"name": "Scout", "runtime": "claude", "cwd": cwd}),
        )
        .await
        .unwrap();
        let agent_id = agent["id"].as_str().unwrap().to_string();
        assert_eq!(agent["workspace_id"], "shared");
        let store = app.sup.hub().store.clone();
        store.agent_set_session(&agent_id, Some("sess-1")).unwrap();

        let w = call(&app, "workspaces.create", container("Box")).await.unwrap();
        let ws_id = w["id"].as_str().unwrap().to_string();
        let moved = agent_call(&app, "agents.update", json!({"id": agent_id, "workspace_id": ws_id}))
            .await
            .unwrap();
        assert_eq!(moved["workspace_id"], ws_id);
        let stored = store.agent_get(&agent_id).unwrap().unwrap();
        assert_eq!(stored.chapter, 2, "a new workspace is a new chapter");
        assert_eq!(stored.runtime_session_id, None);

        let err = agent_call(&app, "agents.update", json!({"id": agent_id, "workspace_id": "nope"}))
            .await
            .unwrap_err();
        assert_eq!(reason(&err), "not_found");
    }

    #[test]
    fn daemon_advertises_workspaces() {
        assert!(crate::rpc::features().contains(&"workspaces"));
    }
}
