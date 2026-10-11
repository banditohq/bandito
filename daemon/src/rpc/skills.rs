//! `skills.*` JSON-RPC methods: the catalog of vendored skills, and installing or removing one for the daemon user or
//! for an agent's folder. The logic is in `crate::skills`. See docs/ARCHITECTURE.md#skills.

use super::{App, COMMANDS_ERROR, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, ok, params};
use crate::commands::InstallError;
use crate::shared::{self, ShareError};
use crate::skills;
use crate::store::Agent;
use serde::Deserialize;
use serde_json::{Value, json};
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
        "skills.export" => {
            let p: ExportSkill = params(p)?;
            let base = base_dir(app, home, Scope::User, None)?;
            let (payload, skipped) = run(move || shared::skill_from_folder(&base, &p.name, p.license.as_deref()))
                .await?
                .map_err(share_error)?;
            ok(json!({ "payload": payload, "skipped": skipped }))
        }
        "skills.install_shared" => {
            let p: InstallShared = params(p)?;
            shared::check_share_id(&p.share_id).map_err(share_error)?;
            shared::check_version(p.version).map_err(share_error)?;
            let payload = shared::parse_skill(p.payload).map_err(share_error)?;
            let scope = if p.agent_id.is_some() {
                Scope::Project
            } else {
                Scope::User
            };
            let base = base_dir(app, home, scope, p.agent_id)?;
            let name = payload.name.clone();
            let (path, updated) = run(move || shared::install_shared(&base, &name, &p.share_id, p.version, &payload))
                .await?
                .map_err(share_error)?;
            ok(json!({ "path": path, "updated": updated }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// What a share call answers. A payload or parameter that is wrong is `INVALID_PARAMS` with `invalid: <field>`; a folder
/// or file that cannot be used is `COMMANDS_ERROR` with `data.reason` (see docs/ARCHITECTURE.md#sharing).
pub(super) fn share_error(e: ShareError) -> RpcError {
    match e {
        ShareError::Invalid(field) => {
            RpcError::with_data(INVALID_PARAMS, format!("invalid: {field}"), json!({ "field": field }))
        }
        ShareError::InvalidAt { field, path } => RpcError::with_data(
            INVALID_PARAMS,
            format!("invalid: {field}"),
            json!({ "field": field, "path": path }),
        ),
        ShareError::Refused { reason, message } => {
            RpcError::with_data(COMMANDS_ERROR, message, json!({ "reason": reason }))
        }
    }
}

/// Each catalog entry, with `installed: {user, projects}` (the folders Bandito installed: the daemon user's home, and
/// the ids of the agents whose folder has one), `conflicts: {user, projects}` (folders with the same name that Bandito
/// did not install, so an install would be refused) and `updates: {user, projects}` (the installs above whose commit
/// is not the catalog's: an update replaces them).
fn catalog_view(home: Option<&Path>, agents: &[Agent]) -> Vec<Value> {
    let folders: Vec<(&str, &Path)> = agents
        .iter()
        .map(|a| (a.id.as_str(), Path::new(a.cwd.as_str())))
        .collect();
    skills::catalog()
        .into_iter()
        .map(|mut entry| {
            let id = entry.get("id").and_then(Value::as_str).unwrap_or_default().to_string();
            let state = |base: &Path| skills::slot(base, &id);
            let user = home.map(state);
            let user_update = home.is_some_and(|h| skills::update_available(h, &id));
            let mut installed_projects = Vec::new();
            let mut conflict_projects = Vec::new();
            let mut update_projects = Vec::new();
            for (agent, cwd) in &folders {
                match state(cwd) {
                    skills::Slot::Ours => {
                        installed_projects.push(*agent);
                        if skills::update_available(cwd, &id) {
                            update_projects.push(*agent);
                        }
                    }
                    skills::Slot::Foreign => conflict_projects.push(*agent),
                    skills::Slot::Absent => {}
                }
            }
            entry["installed"] = json!({
                "user": user == Some(skills::Slot::Ours),
                "projects": installed_projects,
            });
            entry["conflicts"] = json!({
                "user": user == Some(skills::Slot::Foreign),
                "projects": conflict_projects,
            });
            entry["updates"] = json!({
                "user": user_update,
                "projects": update_projects,
            });
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

/// What `skills.export` takes: the folder's name under the daemon user's `.claude/skills`, and the owner's license.
#[derive(Deserialize)]
struct ExportSkill {
    name: String,
    #[serde(default)]
    license: Option<String>,
}

/// What `skills.install_shared` takes. The folder is the agent's when `agent_id` is given, else the daemon user's.
#[derive(Deserialize)]
struct InstallShared {
    share_id: String,
    version: u32,
    payload: Value,
    #[serde(default)]
    agent_id: Option<String>,
}

/// `skills.export` and `skills.install_shared` (see docs/ARCHITECTURE.md#sharing). The payload and folder rules are
/// tested in `crate::shared`; these tests cover the methods, their replies and their refusals.
#[cfg(test)]
mod share_tests {
    use crate::hub::Hub;
    use crate::rpc::{
        App, COMMANDS_ERROR, INVALID_PARAMS, Peer, RpcError, RpcResult, UNAUTHORIZED, dispatch, features,
    };
    use crate::runtime::RuntimeKind;
    use crate::shared::{self, SkillPayload};
    use crate::store::{ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use serde_json::{Value, json};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use tempfile::TempDir;

    use super::dispatch_in;

    const SHARE: &str = "AbCdEfGhIjKlMnOpQrStUv";
    const OTHER: &str = "ZyXwVuTsRqPoNmLkJiHgFe";

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

    fn skill_md() -> String {
        "---\nname: release-notes\ndescription: Writes release notes\n---\n\n# Release notes\n".to_string()
    }

    fn payload() -> Value {
        json!({
            "schema": 1,
            "name": "release-notes",
            "description": "Writes release notes",
            "license": "MIT",
            "files": {
                "SKILL.md": skill_md(),
                "scripts/run.sh": "#!/bin/sh\necho hi\n",
                "docs/notes.md": "details",
            },
            "executable": ["scripts/run.sh"],
        })
    }

    /// A folder the person made: not Bandito's, so it has no marker.
    fn own_folder(home: &Path, name: &str) -> PathBuf {
        let dir = home.join(".claude/skills").join(name);
        fs::create_dir_all(dir.join("scripts")).unwrap();
        fs::create_dir_all(dir.join("docs")).unwrap();
        fs::write(dir.join("SKILL.md"), skill_md()).unwrap();
        fs::write(dir.join("scripts/run.sh"), "#!/bin/sh\necho hi\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(dir.join("scripts/run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
        }
        fs::write(dir.join("docs/notes.md"), "details").unwrap();
        dir
    }

    fn reason(err: &RpcError) -> String {
        err.data.as_ref().unwrap()["reason"].as_str().unwrap().to_string()
    }

    #[cfg(unix)]
    fn mode_of(path: &Path) -> u32 {
        use std::os::unix::fs::PermissionsExt;
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    // ---- skills.export ----

    #[tokio::test]
    async fn skills_export_reads_a_users_folder_into_a_payload() {
        let r = rig();
        let home = TempDir::new().unwrap();
        own_folder(home.path(), "release-notes");
        let reply = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "release-notes", "license": "MIT"}),
        )
        .await
        .unwrap();
        let p: SkillPayload = serde_json::from_value(reply["payload"].clone()).unwrap();
        assert_eq!(p.name, "release-notes");
        assert_eq!(p.description, "Writes release notes");
        assert_eq!(p.license, "MIT");
        assert!(p.files.contains_key("docs/notes.md"));
        assert_eq!(p.executable, vec!["scripts/run.sh".to_string()]);
        assert!(
            shared::parse_skill(reply["payload"].clone()).is_ok(),
            "the export is a valid payload"
        );
    }

    #[tokio::test]
    async fn skills_export_refuses_a_catalog_install_and_needs_a_license() {
        let r = rig();
        let home = TempDir::new().unwrap();
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "commit", "license": "MIT"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(reason(&err), "catalog_skill");

        own_folder(home.path(), "release-notes");
        let err = call(&r, home.path(), "skills.export", json!({"name": "release-notes"}))
            .await
            .unwrap_err();
        assert_eq!(reason(&err), "license_required");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn skills_export_names_the_path_of_a_link() {
        use std::os::unix::fs::symlink;
        let r = rig();
        let home = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        fs::write(outside.path().join("secret.md"), "outside").unwrap();
        let dir = own_folder(home.path(), "release-notes");
        symlink(outside.path().join("secret.md"), dir.join("docs/link.md")).unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "release-notes", "license": "MIT"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(reason(&err), "unsafe_path");
        assert!(err.message.contains("docs/link.md"), "{}", err.message);
    }

    #[tokio::test]
    async fn skills_export_refuses_a_bad_name_and_a_missing_folder() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "../x", "license": "MIT"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        let err = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "nothing-here", "license": "MIT"}),
        )
        .await
        .unwrap_err();
        assert_eq!(reason(&err), "no_skill");
    }

    // ---- skills.install_shared ----

    #[tokio::test]
    async fn skills_install_shared_writes_the_skill_into_the_users_folder() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let reply = call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 1, "payload": payload()}),
        )
        .await
        .unwrap();
        let folder = home.path().join(".claude/skills/release-notes");
        assert_eq!(reply["path"], folder.display().to_string());
        assert_eq!(reply["updated"], false);
        assert_eq!(fs::read_to_string(folder.join("docs/notes.md")).unwrap(), "details");
        let marker: Value = serde_json::from_str(&fs::read_to_string(folder.join(".bandito-skill")).unwrap()).unwrap();
        assert_eq!(marker["source"], format!("shared:{SHARE}"));
        assert_eq!(marker["version"], 1);
        #[cfg(unix)]
        {
            assert_eq!(mode_of(&folder.join("scripts/run.sh")), 0o755);
            assert_eq!(mode_of(&folder.join("docs/notes.md")), 0o644);
        }
    }

    #[tokio::test]
    async fn skills_install_shared_goes_to_the_agents_folder_when_agent_id_is_given() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        let id = agent(&r.store, cwd.path());
        let reply = call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 1, "payload": payload(), "agent_id": id}),
        )
        .await
        .unwrap();
        assert_eq!(
            reply["path"],
            cwd.path().join(".claude/skills/release-notes").display().to_string()
        );
        assert!(
            !home.path().join(".claude/skills/release-notes").exists(),
            "the user's folder is not touched"
        );
    }

    #[tokio::test]
    async fn skills_install_shared_refuses_a_folder_that_is_not_its_own() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let folder = own_folder(home.path(), "release-notes");
        let err = call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 1, "payload": payload()}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(reason(&err), "exists_not_ours");
        assert_eq!(fs::read_to_string(folder.join("SKILL.md")).unwrap(), skill_md());
        assert!(!folder.join(".bandito-skill").exists());
    }

    #[tokio::test]
    async fn skills_install_shared_updates_its_own_copy_and_keeps_another_shares() {
        let r = rig();
        let home = TempDir::new().unwrap();
        call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 1, "payload": payload()}),
        )
        .await
        .unwrap();
        let again = call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 2, "payload": payload()}),
        )
        .await
        .unwrap();
        assert_eq!(again["updated"], true);
        let other = call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": OTHER, "version": 1, "payload": payload()}),
        )
        .await
        .unwrap_err();
        assert_eq!(reason(&other), "exists_not_ours");
    }

    #[tokio::test]
    async fn skills_install_shared_refuses_a_bad_request_before_writing() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let mut outside = payload();
        outside["executable"] = json!(["docs/notes.md"]);
        let cases = [
            json!({"share_id": SHARE, "version": 1, "payload": outside}),
            json!({"share_id": "short", "version": 1, "payload": payload()}),
            json!({"share_id": SHARE, "version": 0, "payload": payload()}),
            json!({"share_id": SHARE, "version": 1, "payload": payload(), "agent_id": "nobody"}),
        ];
        for p in cases {
            let err = call(&r, home.path(), "skills.install_shared", p.clone())
                .await
                .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{p}");
        }
        assert!(
            !home.path().join(".claude").exists(),
            "nothing is written for a refused call"
        );
    }

    #[tokio::test]
    async fn agents_cannot_export_or_install_shared_skills() {
        let r = rig();
        let agent_peer = Peer::Agent("agent-a".into());
        for (method, p) in [
            ("skills.export", json!({"name": "release-notes", "license": "MIT"})),
            (
                "skills.install_shared",
                json!({"share_id": SHARE, "version": 1, "payload": payload()}),
            ),
        ] {
            let err = dispatch(&r.app, &agent_peer, method, p).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
    }

    #[tokio::test]
    async fn skills_export_lists_the_dot_files_it_skipped() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let dir = own_folder(home.path(), "release-notes");
        fs::write(dir.join(".DS_Store"), "x").unwrap();
        let reply = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "release-notes", "license": "MIT"}),
        )
        .await
        .unwrap();
        assert_eq!(reply["skipped"], json!([".DS_Store"]));
        assert!(shared::parse_skill(reply["payload"].clone()).is_ok());
    }

    #[tokio::test]
    async fn skills_export_refuses_a_copy_of_a_shared_link() {
        let r = rig();
        let home = TempDir::new().unwrap();
        call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 1, "payload": payload()}),
        )
        .await
        .unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.export",
            json!({"name": "release-notes", "license": "MIT"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(reason(&err), "not_yours");
    }

    #[tokio::test]
    async fn skills_install_shared_names_the_path_that_collides() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let mut p = payload();
        p["files"]["Scripts/x"] = json!("x");
        let err = call(
            &r,
            home.path(),
            "skills.install_shared",
            json!({"share_id": SHARE, "version": 1, "payload": p}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert_eq!(err.message, "invalid: files");
        assert_eq!(err.data.as_ref().unwrap()["path"], "scripts/run.sh");
        assert!(!home.path().join(".claude").exists());
    }

    #[test]
    fn the_skills_share_feature_is_the_sharing_one() {
        assert!(features().contains(&"sharing"));
    }
}

#[cfg(test)]
mod tests {
    use crate::hub::Hub;
    use crate::rpc::{App, COMMANDS_ERROR, INVALID_PARAMS, Peer, RpcResult, UNAUTHORIZED, dispatch, features};
    use crate::runtime::RuntimeKind;
    use crate::skills::{self, MARKER};
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

    /// A folder the person made: not Bandito's, so it has no marker.
    fn own_folder(home: &Path, id: &str) -> PathBuf {
        let dir = home.join(".claude/skills").join(id);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), "mine").unwrap();
        fs::write(dir.join("notes.txt"), "mine").unwrap();
        dir
    }

    fn entry<'a>(list: &'a Value, id: &str) -> &'a Value {
        list.as_array().unwrap().iter().find(|e| e["id"] == id).unwrap()
    }

    fn reason(err: &crate::rpc::RpcError) -> String {
        err.data.as_ref().unwrap()["reason"].as_str().unwrap().to_string()
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
        assert_eq!(e["conflicts"], json!({"user": false, "projects": []}));
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
    async fn an_install_from_an_older_commit_is_flagged_per_folder_until_it_is_installed_again() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let cwd = TempDir::new().unwrap();
        let id_agent = agent(&r.store, cwd.path());
        let install = |scope: &str| {
            let mut p = json!({"skill_id": "commit", "scope": scope});
            if scope == "project" {
                p["agent_id"] = json!(id_agent);
            }
            p
        };
        call(&r, home.path(), "skills.install", install("user")).await.unwrap();
        call(&r, home.path(), "skills.install", install("project"))
            .await
            .unwrap();
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "commit")["updates"],
            json!({"user": false, "projects": []}),
            "a fresh install is current"
        );

        // Both markers name an older commit than the catalog's.
        for base in [home.path().to_path_buf(), cwd.path().to_path_buf()] {
            let marker = base.join(".claude/skills/commit").join(MARKER);
            fs::write(
                &marker,
                r#"{"id":"commit","commit":"0000000000000000000000000000000000000000"}"#,
            )
            .unwrap();
        }
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "commit")["installed"],
            json!({"user": true, "projects": [id_agent]}),
            "an old install still counts as installed"
        );
        assert_eq!(
            entry(&list, "commit")["updates"],
            json!({"user": true, "projects": [id_agent]})
        );
        assert_eq!(
            entry(&list, "systematic-debugging")["updates"],
            json!({"user": false, "projects": []}),
            "an entry without an install has no update"
        );

        call(&r, home.path(), "skills.install", install("project"))
            .await
            .unwrap();
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "commit")["updates"],
            json!({"user": true, "projects": []}),
            "only the folder that was installed again is current"
        );
        call(&r, home.path(), "skills.install", install("user")).await.unwrap();
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "commit")["updates"],
            json!({"user": false, "projects": []})
        );
    }

    #[tokio::test]
    async fn a_folder_that_is_not_ours_has_no_update() {
        let r = rig();
        let home = TempDir::new().unwrap();
        own_folder(home.path(), "commit");
        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "commit")["conflicts"],
            json!({"user": true, "projects": []})
        );
        assert_eq!(
            entry(&list, "commit")["updates"],
            json!({"user": false, "projects": []})
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
            let mut expected = files_of(&source);
            assert!(expected.contains(&"LICENSE".to_string()), "{id}: LICENSE is bundled");
            expected.push(MARKER.to_string());
            expected.sort();
            for base in [
                home.path().join(".claude/skills").join(id),
                cwd.path().join(".claude/skills").join(id),
            ] {
                assert_eq!(files_of(&base), expected, "{id}: same files, plus the marker");
                for rel in files_of(&source) {
                    assert_eq!(
                        fs::read(base.join(&rel)).unwrap(),
                        fs::read(source.join(&rel)).unwrap(),
                        "{id}/{rel}"
                    );
                }
                let marker: Value = serde_json::from_str(&fs::read_to_string(base.join(MARKER)).unwrap()).unwrap();
                assert_eq!(marker["id"], id);
                assert!(marker["commit"].as_str().unwrap().len() == 40);
            }
        }
    }

    #[tokio::test]
    async fn install_replaces_our_copy_as_a_whole_and_leaves_no_temporary_folder() {
        let r = rig();
        let home = TempDir::new().unwrap();
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        let folder = home.path().join(".claude/skills/commit");
        fs::write(folder.join("stale.md"), "old").unwrap();
        call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap();
        assert!(!folder.join("stale.md").exists());
        assert!(folder.join("SKILL.md").is_file());
        let names: Vec<String> = fs::read_dir(home.path().join(".claude/skills"))
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(names, vec!["commit".to_string()]);
    }

    #[tokio::test]
    async fn install_refuses_a_folder_that_is_not_ours() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let folder = own_folder(home.path(), "commit");
        let err = call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, COMMANDS_ERROR);
        assert_eq!(reason(&err), "exists_not_ours");
        assert_eq!(fs::read_to_string(folder.join("notes.txt")).unwrap(), "mine");
        assert!(!folder.join(MARKER).exists());

        let list = call(&r, home.path(), "skills.catalog", json!({})).await.unwrap();
        assert_eq!(
            entry(&list, "commit")["installed"],
            json!({"user": false, "projects": []})
        );
        assert_eq!(
            entry(&list, "commit")["conflicts"],
            json!({"user": true, "projects": []})
        );
    }

    #[tokio::test]
    async fn a_marker_naming_another_skill_is_not_ours() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let folder = own_folder(home.path(), "commit");
        fs::write(folder.join(MARKER), r#"{"id":"other","commit":"x"}"#).unwrap();
        let err = call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(reason(&err), "not_ours");
        assert!(folder.join("notes.txt").is_file());
    }

    #[tokio::test]
    async fn remove_deletes_only_our_folder() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let other = own_folder(home.path(), "someone-else");
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
        assert_eq!(reason(&err), "not_installed");
    }

    #[tokio::test]
    async fn remove_refuses_a_folder_that_is_not_ours() {
        let r = rig();
        let home = TempDir::new().unwrap();
        let folder = own_folder(home.path(), "commit");
        let err = call(
            &r,
            home.path(),
            "skills.remove",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(reason(&err), "not_ours");
        assert!(folder.join("SKILL.md").is_file() && folder.join("notes.txt").is_file());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn remove_never_follows_a_link() {
        use std::os::unix::fs::symlink;
        let r = rig();
        let home = TempDir::new().unwrap();
        let outside = TempDir::new().unwrap();
        fs::write(outside.path().join("SKILL.md"), "outside").unwrap();
        fs::write(outside.path().join(MARKER), r#"{"id":"commit","commit":"x"}"#).unwrap();
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
        assert_eq!(reason(&err), "unsafe_path");
        assert_eq!(fs::read_to_string(outside.path().join("data.txt")).unwrap(), "outside");
        let err = call(
            &r,
            home.path(),
            "skills.install",
            json!({"skill_id": "commit", "scope": "user"}),
        )
        .await
        .unwrap_err();
        assert_eq!(reason(&err), "unsafe_path");
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

    #[cfg(unix)]
    #[tokio::test]
    async fn install_never_writes_through_a_linked_claude_or_skills_folder() {
        use std::os::unix::fs::symlink;
        let r = rig();
        let outside = TempDir::new().unwrap();
        for linked in [".claude", ".claude/skills"] {
            let home = TempDir::new().unwrap();
            fs::create_dir_all(home.path().join(".claude")).unwrap();
            if linked == ".claude" {
                fs::remove_dir_all(home.path().join(".claude")).unwrap();
            }
            let link = home.path().join(linked);
            symlink(outside.path(), &link).unwrap();
            let err = call(
                &r,
                home.path(),
                "skills.install",
                json!({"skill_id": "commit", "scope": "user"}),
            )
            .await
            .unwrap_err();
            assert_eq!(reason(&err), "unsafe_path", "{linked}");
            assert!(
                fs::read_dir(outside.path()).unwrap().next().is_none(),
                "{linked}: nothing written"
            );
        }
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
