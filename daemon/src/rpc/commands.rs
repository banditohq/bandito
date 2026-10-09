//! `commands.*` JSON-RPC methods: the slash commands an agent can run, and installing
//! commands and skills on the server. The logic is in `crate::commands`.
//! See docs/ARCHITECTURE.md#commands.

use super::{
    AgentRef, App, COMMANDS_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, ok, params,
};
use crate::commands::{self, InstallError, InstallFile, InstallKind};
use crate::store::Agent;
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::PathBuf;

/// Answers `commands.*` methods. Unknown names get METHOD_NOT_FOUND.
pub(super) async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "commands.list" => {
            let AgentRef { agent_id } = params(p)?;
            let agent = agent_or_error(app, &agent_id)?;
            let home = dirs::home_dir();
            let cwd = PathBuf::from(&agent.cwd);
            let list = run(move || commands::discover(home.as_deref(), &cwd, agent.runtime)).await?;
            ok(list)
        }
        "commands.install" => {
            let p: InstallParams = params(p)?;
            let base = match p.scope {
                Scope::User => dirs::home_dir().ok_or_else(|| {
                    RpcError::with_data(
                        COMMANDS_ERROR,
                        "no home directory on the server",
                        json!({"reason": "no_home"}),
                    )
                })?,
                Scope::Project => {
                    let id = p
                        .agent_id
                        .ok_or_else(|| RpcError::new(INVALID_PARAMS, "project scope needs agent_id"))?;
                    PathBuf::from(agent_or_error(app, &id)?.cwd)
                }
            };
            let (kind, name, files, overwrite) = (p.kind, p.name, p.files, p.overwrite);
            let path = run(move || commands::install(&base, kind, &name, &files, overwrite))
                .await?
                .map_err(install_error)?;
            ok(json!({ "path": path }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

fn agent_or_error(app: &App, id: &str) -> Result<Agent, RpcError> {
    app.sup
        .hub()
        .store
        .agent_get(id)?
        .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))
}

/// File work runs on the blocking pool, as the `fs.*` methods do.
async fn run<T, F>(f: F) -> Result<T, RpcError>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("command task failed: {e}")))
}

/// `data.reason` is the stable code from `InstallError::reason`.
fn install_error(e: InstallError) -> RpcError {
    RpcError::with_data(COMMANDS_ERROR, e.message.clone(), json!({ "reason": e.reason }))
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
enum Scope {
    User,
    Project,
}

#[derive(Deserialize)]
struct InstallParams {
    scope: Scope,
    #[serde(default)]
    agent_id: Option<String>,
    kind: InstallKind,
    name: String,
    files: Vec<InstallFile>,
    #[serde(default)]
    overwrite: bool,
}

#[cfg(test)]
mod tests {
    use crate::event::EventBody;
    use crate::hub::Hub;
    use crate::rpc::{App, COMMANDS_ERROR, INVALID_PARAMS, Peer, RpcResult, SERVER_ERROR, dispatch};
    use crate::runtime::{Runtime, RuntimeKind, RuntimeStatus, SpawnConfig, Spawned};
    use crate::store::{ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::supervisor::testing::{Log, MockRuntime, Outs};
    use crate::supervisor::{Runtimes, Supervisor};
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;
    use serde_json::{Value, json};
    use std::fs;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;
    use tempfile::TempDir;

    /// The mock, reporting itself as Codex, so that a Codex agent gets a session.
    struct AsCodex(MockRuntime);

    #[async_trait::async_trait]
    impl Runtime for AsCodex {
        fn kind(&self) -> RuntimeKind {
            RuntimeKind::Codex
        }
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus {
                kind: RuntimeKind::Codex,
                installed: true,
                version: None,
                logged_in: None,
                detail: None,
            }
        }
        async fn spawn(&self, cfg: SpawnConfig) -> anyhow::Result<Spawned> {
            self.0.spawn(cfg).await
        }
    }

    struct Rig {
        app: Arc<App>,
        store: Arc<Store>,
        log: Log,
    }

    fn rig() -> Rig {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let log: Log = Arc::default();
        let out: Outs = Arc::default();
        let mut rts = Runtimes::default();
        rts.insert(Arc::new(MockRuntime {
            log: log.clone(),
            out: out.clone(),
            spawns: Arc::default(),
        }));
        rts.insert(Arc::new(AsCodex(MockRuntime {
            log: log.clone(),
            out: out.clone(),
            spawns: Arc::default(),
        })));
        let sup = Supervisor::new(Hub::new(store.clone()), rts, None);
        let app = App::new(sup, PathBuf::from("unused-agents-root"));
        Rig { app, store, log }
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn agent(store: &Store, name: &str, runtime: RuntimeKind, cwd: &str) -> String {
        store
            .agent_create(NewAgent {
                name: name.into(),
                role: String::new(),
                runtime,
                model: None,
                cwd: cwd.into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
            })
            .unwrap()
            .id
    }

    /// A project whose `.claude/commands/deploy.md` takes one argument.
    fn project_with_deploy() -> TempDir {
        let cwd = TempDir::new().unwrap();
        let dir = cwd.path().join(".claude/commands");
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("deploy.md"),
            "---\ndescription: Deploy\nargument-hint: <env>\n---\nDeploy to $1 now.\n",
        )
        .unwrap();
        cwd
    }

    async fn wait_for(log: &Log, line: &str) {
        for _ in 0..300 {
            if log.lock().unwrap().iter().any(|l| l == line) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("no `{line}` in the session log: {:?}", log.lock().unwrap());
    }

    /// `(text, command)` of every stored `message.user`, oldest first.
    fn user_messages(store: &Store, agent: &str) -> Vec<(String, Option<String>)> {
        store
            .events_since(0, 100, Some(agent))
            .unwrap()
            .into_iter()
            .filter_map(|e| match e.body {
                EventBody::MessageUser { text, command, .. } => Some((text, command)),
                _ => None,
            })
            .collect()
    }

    #[test]
    fn commands_is_a_daemon_feature() {
        assert!(crate::rpc::features().contains(&"commands"));
    }

    #[tokio::test]
    async fn claude_runs_its_own_commands_so_the_text_goes_as_typed() {
        let r = rig();
        let cwd = project_with_deploy();
        let id = agent(&r.store, "Forge", RuntimeKind::Claude, cwd.path().to_str().unwrap());
        call(&r.app, "agents.send", json!({"agent_id": id, "text": "/deploy prod"}))
            .await
            .unwrap();
        wait_for(&r.log, "send /deploy prod").await;
        assert_eq!(
            user_messages(&r.store, &id),
            vec![("/deploy prod".to_string(), Some("deploy".to_string()))]
        );
    }

    #[tokio::test]
    async fn codex_gets_the_expansion_and_the_thread_keeps_what_was_typed() {
        let r = rig();
        let cwd = project_with_deploy();
        let id = agent(&r.store, "Scout", RuntimeKind::Codex, cwd.path().to_str().unwrap());
        call(&r.app, "agents.send", json!({"agent_id": id, "text": "/deploy prod"}))
            .await
            .unwrap();
        wait_for(&r.log, "send Deploy to prod now.").await;
        assert!(
            !r.log.lock().unwrap().iter().any(|l| l == "send /deploy prod"),
            "the runtime must not get the bare command"
        );
        assert_eq!(
            user_messages(&r.store, &id),
            vec![("/deploy prod".to_string(), Some("deploy".to_string()))]
        );
    }

    #[tokio::test]
    async fn unknown_commands_go_as_typed_without_a_command_name() {
        let r = rig();
        let cwd = project_with_deploy();
        let id = agent(&r.store, "Scout", RuntimeKind::Codex, cwd.path().to_str().unwrap());
        call(&r.app, "agents.send", json!({"agent_id": id, "text": "/nope now"}))
            .await
            .unwrap();
        wait_for(&r.log, "send /nope now").await;
        assert_eq!(user_messages(&r.store, &id), vec![("/nope now".to_string(), None)]);
    }

    #[tokio::test]
    async fn list_puts_project_commands_first_and_carries_no_content() {
        let r = rig();
        let cwd = project_with_deploy();
        let id = agent(&r.store, "Forge", RuntimeKind::Claude, cwd.path().to_str().unwrap());
        let list = call(&r.app, "commands.list", json!({"agent_id": id})).await.unwrap();
        let first = &list[0];
        assert_eq!(first["name"], "deploy");
        assert_eq!(first["source"], "project");
        assert_eq!(first["description"], "Deploy");
        assert_eq!(first["args_hint"], "<env>");
        assert_eq!(first["runtime_native"], true);
        for c in list.as_array().unwrap() {
            assert!(c.get("content").is_none() && c.get("body").is_none());
        }

        let err = call(&r.app, "commands.list", json!({"agent_id": "nope"}))
            .await
            .unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
    }

    #[tokio::test]
    async fn install_writes_into_the_agents_folder_for_project_scope() {
        let r = rig();
        let cwd = TempDir::new().unwrap();
        let id = agent(&r.store, "Forge", RuntimeKind::Claude, cwd.path().to_str().unwrap());
        let params = json!({
            "scope": "project",
            "agent_id": id,
            "kind": "command",
            "name": "ship",
            "files": [{"path": "ship.md", "content": STANDARD.encode("Ship it")}],
        });
        call(&r.app, "commands.install", params.clone()).await.unwrap();
        assert_eq!(
            fs::read_to_string(cwd.path().join(".claude/commands/ship.md")).unwrap(),
            "Ship it"
        );

        let err = call(&r.app, "commands.install", params.clone()).await.unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(err.data.as_ref().unwrap()["reason"], "exists");

        let mut again = params.clone();
        again["overwrite"] = json!(true);
        call(&r.app, "commands.install", again).await.unwrap();

        let mut no_agent = params.clone();
        no_agent.as_object_mut().unwrap().remove("agent_id");
        let err = call(&r.app, "commands.install", no_agent).await.unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);

        let mut bad = params;
        bad["agent_id"] = json!("nope");
        let err = call(&r.app, "commands.install", bad).await.unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
    }
}
