//! `skills.*` JSON-RPC methods: the catalog of vendored skills, and installing or removing one for the daemon user or
//! for an agent's folder. The logic is in `crate::skills`. See docs/ARCHITECTURE.md#skills.

use super::{App, COMMANDS_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, ok, params};
use crate::commands::InstallError;
use crate::skills;
use crate::store::Agent;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

/// Answers `skills.*` methods, with the daemon user's home. Unknown names get METHOD_NOT_FOUND.
pub(super) async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    dispatch_in(app, dirs::home_dir(), method, p).await
}

/// [`dispatch`] with the daemon user's home given: tests pass a temporary folder, never the real home.
pub(super) async fn dispatch_in(app: &App, home: Option<PathBuf>, method: &str, p: Value) -> RpcResult {
    match method {
        "skills.catalog" => {
            let agents = app.sup.hub().store.agent_list()?;
            let view = run(move || catalog_view(home.as_deref(), &agents)).await?;
            ok(view)
        }
        "skills.install" => {
            let p: SkillParams = params(p)?;
            check_skill(&p.skill_id)?;
            let base = base_dir(app, home, p.scope, p.agent_id)?;
            let id = p.skill_id;
            let path = run(move || skills::install(&base, &id)).await?.map_err(install_error)?;
            ok(json!({ "path": path }))
        }
        "skills.remove" => {
            let p: SkillParams = params(p)?;
            check_skill(&p.skill_id)?;
            let base = base_dir(app, home, p.scope, p.agent_id)?;
            let id = p.skill_id;
            let path = run(move || skills::remove(&base, &id)).await?.map_err(install_error)?;
            ok(json!({ "path": path }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// Each catalog entry, with `installed: {user, projects}`: whether the skill is in the daemon user's folder, and the
/// ids of the agents whose folder has it.
fn catalog_view(home: Option<&Path>, agents: &[Agent]) -> Vec<Value> {
    let user: HashSet<String> = home.map(|h| skills::installed_in(Some(h), h)).unwrap_or_default();
    let per_agent: Vec<(&str, HashSet<String>)> = agents
        .iter()
        .map(|a| (a.id.as_str(), skills::installed_in(None, Path::new(&a.cwd))))
        .collect();
    skills::catalog()
        .into_iter()
        .map(|mut entry| {
            let id = entry.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
            let projects: Vec<&str> = per_agent
                .iter()
                .filter(|(_, ids)| ids.contains(&id))
                .map(|(agent, _)| *agent)
                .collect();
            entry["installed"] = json!({ "user": user.contains(&id), "projects": projects });
            entry
        })
        .collect()
}

/// The folder a skill goes into: the daemon user's home (`user`), or the folder of the agent (`project`).
fn base_dir(app: &App, home: Option<PathBuf>, scope: Scope, agent_id: Option<String>) -> Result<PathBuf, RpcError> {
    match scope {
        Scope::User => home.ok_or_else(|| {
            RpcError::with_data(
                COMMANDS_ERROR,
                "no home directory on the server",
                json!({"reason": "no_home"}),
            )
        }),
        Scope::Project => {
            let id = agent_id.ok_or_else(|| RpcError::new(INVALID_PARAMS, "project scope needs agent_id"))?;
            let agent = app
                .sup
                .hub()
                .store
                .agent_get(&id)?
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no agent {id}")))?;
            Ok(PathBuf::from(agent.cwd))
        }
    }
}

fn check_skill(id: &str) -> Result<(), RpcError> {
    if skills::is_catalog_id(id) {
        Ok(())
    } else {
        Err(RpcError::new(
            INVALID_PARAMS,
            format!("no skill {id} in the catalog: call skills.catalog for the ids"),
        ))
    }
}

/// File work runs on the blocking pool, as the `commands.*` methods do.
async fn run<T, F>(f: F) -> Result<T, RpcError>
where
    T: Send + 'static,
    F: FnOnce() -> T + Send + 'static,
{
    tokio::task::spawn_blocking(f)
        .await
        .map_err(|e| RpcError::new(super::SERVER_ERROR, format!("skill task failed: {e}")))
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
struct SkillParams {
    skill_id: String,
    scope: Scope,
    #[serde(default)]
    agent_id: Option<String>,
}

#[cfg(test)]
mod tests {
    use crate::hub::Hub;
    use crate::rpc::{App, COMMANDS_ERROR, INVALID_PARAMS, Peer, RpcResult, UNAUTHORIZED, dispatch, features};
    use crate::runtime::RuntimeKind;
    use crate::skills;
    use crate::store::{ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use serde_json::{Value, json};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use tempfile::TempDir;

    use super::dispatch_in;

    struct Rig {
        app: Arc<App>,
        store: Arc<Store>,
    }

    fn rig() -> Rig {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        let app = App::new(sup, PathBuf::from("unused-agents-root"));
        Rig { app, store }
    }

    /// A call as the owner's CLI would make it, with `home` as the daemon user's folder.
    async fn call(r: &Rig, home: &Path, method: &str, p: Value) -> RpcResult {
        dispatch_in(&r.app, Some(home.to_path_buf()), method, p).await
    }

    fn agent(store: &Store, cwd: &Path) -> String {
        store
            .agent_create(NewAgent {
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                integrations: None,
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: cwd.display().to_string(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
            .id
    }

    /// Every file under `dir` with its relative path, `/` separators.
    fn files_of(dir: &Path) -> Vec<String> {
        fn walk(dir: &Path, base: &Path, out: &mut Vec<String>) {
            for e in fs::read_dir(dir).unwrap() {
                let p = e.unwrap().path();
                if p.is_dir() {
                    walk(&p, base, out);
                } else {
                    out.push(p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/"));
                }
            }
        }
        let mut out = Vec::new();
        walk(dir, dir, &mut out);
        out.sort();
        out
    }

    fn source_dir(id: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("skills").join(id)
    }

    fn entry<'a>(list: &'a Value, id: &str) -> &'a Value {
        list.as_array().unwrap().iter().find(|e| e["id"] == id).unwrap()
    }

    #[test]
    fn skills_is_a_daemon_feature() {
        assert!(features().contains(&"skills"));
    }

    #[tokio::test]
    async fn catalog_lists_every_skill_and_follows_installs_and_removes() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        let id_agent = agent(&r.store, cwd.path());
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(list.as_array().unwrap().len(), skills::catalog().len());
        let e = entry(&list, "systematic-debugging");
        assert_eq!(e["installed"], json!({"user": false, "projects": []}));
        assert!(e.get("files").is_some(), "the file paths stay in the entry");

        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "systematic-debugging", "scope": "user"}),
        )
        .await
        .unwrap();
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "systematic-debugging", "scope": "project", "agent_id": id_agent}),
        )
        .await
        .unwrap();
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "systematic-debugging")["installed"],
            json!({"user": true, "projects": [id_agent]})
        );
        assert_eq!(
            entry(&list, "commit")["installed"],
            json!({"user": false, "projects": []})
        );

        call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "systematic-debugging", "scope": "user"}),
        )
        .await
        .unwrap();
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "systematic-debugging")["installed"],
            json!({"user": false, "projects": [id_agent]})
        );
    }

    #[tokio::test]
    async fn install_writes_the_bundled_bytes_byte_for_byte_for_user_and_project() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        let id_agent = agent(&r.store, cwd.path());
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        for e in list.as_array().unwrap() {
            let id = e["id"].as_str().unwrap();
            let reply = call(
                &r,
                home.path(),
                "skills.install",
                json!({"skill_id": id, "scope": "user"}),
            )
            .await
            .unwrap();
            assert_eq!(
                reply["path"],
                home.path().join(".claude/skills").join(id).display().to_string()
            );
            call(
                &r,
                home.path(),
                "skills.install",
                json!({"skill_id": id, "scope": "project", "agent_id": id_agent}),
            )
            .await
            .unwrap();
            let source = source_dir(id);
            let expected = files_of(&source);
            assert!(expected.contains(&"LICENSE".to_string()), "{id}: LICENSE is bundled");
            for base in [
                home.path().join(".claude/skills").join(id),
                cwd.path().join(".claude/skills").join(id),
            ] {
                assert_eq!(files_of(&base), expected, "{id}: same files");
                for rel in &expected {
                    assert_eq!(
                        fs::read(base.join(rel)).unwrap(),
                        fs::read(source.join(rel)).unwrap(),
                        "{id}/{rel}"
                    );
                }
            }
        }
    }

    #[tokio::test]
    async fn install_replaces_an_older_copy_as_a_whole() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let old = home.path().join(".claude/skills/commit");
        fs::create_dir_all(&old).unwrap();
        fs::write(old.join("OLD.md"), "stale").unwrap();
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        assert!(!old.join("OLD.md").exists());
        assert!(old.join("SKILL.md").is_file());
    }

    #[tokio::test]
    async fn remove_deletes_only_the_skill_folder() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let other = home.path().join(".claude/skills/someone-else");
        fs::create_dir_all(&other).unwrap();
        fs::write(other.join("SKILL.md"), "mine").unwrap();
        fs::write(home.path().join(".claude/skills/loose.txt"), "keep").unwrap();
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        assert!(!home.path().join(".claude/skills/commit").exists());
        assert_eq!(fs::read_to_string(other.join("SKILL.md")).unwrap(), "mine");
        assert_eq!(
            fs::read_to_string(home.path().join(".claude/skills/loose.txt")).unwrap(),
            "keep"
        );

        let err = call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(err.data.unwrap()["reason"], "not_installed");
    }

    #[tokio::test]
    async fn remove_refuses_a_folder_without_skill_md() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let folder = home.path().join(".claude/skills/commit");
        fs::create_dir_all(&folder).unwrap();
        fs::write(folder.join("notes.txt"), "not a skill").unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "not_a_skill_folder");
        assert!(folder.join("notes.txt").is_file());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn remove_never_follows_a_link() {
        use std::os::unix::fs::symlink;
        let r = rig();
        let home = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        fs::write(outside.path().join("SKILL.md"), "outside").unwrap();
        fs::write(outside.path().join("data.txt"), "outside").unwrap();
        let skills_dir = home.path().join(".claude/skills");
        fs::create_dir_all(&skills_dir).unwrap();

        // The skill folder itself is a link: refused, and the target stays.
        symlink(outside.path(), skills_dir.join("commit")).unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.data.unwrap()["reason"], "not_a_skill_folder");
        assert!(outside.path().join("data.txt").is_file());
        fs::remove_file(skills_dir.join("commit")).unwrap();

        // A real skill folder with a link inside: the folder goes, the link's target stays.
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        symlink(outside.path(), skills_dir.join("commit/outside")).unwrap();
        call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        assert!(!skills_dir.join("commit").exists());
        assert_eq!(fs::read_to_string(outside.path().join("data.txt")).unwrap(), "outside");
        assert_eq!(fs::read_to_string(outside.path().join("SKILL.md")).unwrap(), "outside");
    }

    #[tokio::test]
    async fn agents_cannot_list_install_or_remove_skills() {
        let r = rig();
        let agent = Peer::Agent("agent-a".into());
        let cases = [
            ("skills.catalog", json!({})),
            ("skills.install", json!({"skill_id": "commit", "scope": "user"})),
            ("skills.remove", json!({"skill_id": "commit", "scope": "user"})),
        ];
        for (method, p) in cases {
            let err = dispatch(&r.app, &agent, method, p).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
    }

    #[tokio::test]
    async fn unknown_skill_or_agent_is_invalid_params() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let cases = [
            ("skills.install", json!({"skill_id": "nope", "scope": "user"})),
            ("skills.remove", json!({"skill_id": "nope", "scope": "user"})),
            ("skills.remove", json!({"skill_id": "../commit", "scope": "user"})),
            (
                "skills.install",
                json!({"skill_id": "commit", "scope": "project", "agent_id": "nobody"}),
            ),
            ("skills.install", json!({"skill_id": "commit", "scope": "project"})),
            (
                "skills.remove",
                json!({"skill_id": "commit", "scope": "project", "agent_id": "nobody"}),
            ),
        ];
        for (method, p) in cases {
            let err = call(&r, home.path(), method, p.clone()).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{method} {p}");
        }
        assert!(
            !home.path().join(".claude/skills").exists(),
            "nothing is written for a refused call"
        );
        let err = call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "nope", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert!(err.message.contains("nope"));
    }
}
