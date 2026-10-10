//! `backups.*` JSON-RPC methods: the database copies in `<home>/backups`, a copy made now, and a restore that the
//! daemon applies at its next start. Owner and apps only. The logic is in `crate::backup`; see
//! docs/ARCHITECTURE.md#backups.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::backup::{self, BackupFile};
use crate::store::now_ms;
use crate::update::{self, Restart};
use serde::Deserialize;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// A restore waits this long, so the reply reaches the app first (as the restart after a self-update does).
const RESTART_AFTER_REPLY: Duration = Duration::from_secs(1);

/// Set while a restore waits for its restart. A second request is refused until the daemon is gone.
static RESTORE_PENDING: AtomicBool = AtomicBool::new(false);

#[derive(Deserialize)]
struct RestoreParams {
    name: String,
}

/// Answers `backups.*` methods. `rpc::dispatch` has already refused agents and anonymous peers.
pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "backups.list" => {
            let home = app.data_home.clone();
            let files = blocking(move || backup::copies(&home)).await?;
            ok(files.iter().map(backup_json).collect::<Vec<Value>>())
        }
        "backups.create" => {
            let home = app.data_home.clone();
            let file = blocking(move || backup::make_copy(&home, "manual", now_ms())).await?;
            ok(backup_json(&file))
        }
        "backups.restore" => {
            let RestoreParams { name } = params(p)?;
            restore(&app.data_home, name).await?;
            ok(json!({ "restarting": true }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// Checks the copy, asks the service manager to restart this daemon after the reply, and leaves the restore
/// marker for the new process. Refused when no service manager runs the daemon: nothing would start it again.
async fn restore(home: &Path, name: String) -> Result<(), RpcError> {
    // A bad name is the caller's mistake; a missing or damaged copy is the server's.
    backup::validate_name(&name).map_err(|e| RpcError::new(INVALID_PARAMS, format!("{e:#}")))?;
    let home = home.to_path_buf();
    {
        let (home, name) = (home.clone(), name.clone());
        blocking(move || backup::check_copy(&home, &name)).await?;
    }
    let exe = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("find the bandito binary: {e}")))?;
    let restart = update::restart_for(home.clone(), exe, Some(std::process::id()))
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("{e:#}")))?;
    if restart == Restart::Manual {
        return Err(RpcError::new(
            SERVER_ERROR,
            "no service manager runs this daemon: stop it, run `bandito backup restore <name>`, then start it",
        ));
    }
    if RESTORE_PENDING.swap(true, Ordering::SeqCst) {
        return Err(RpcError::new(
            SERVER_ERROR,
            "a restore is already waiting for the restart",
        ));
    }
    let marker = {
        let (home, name) = (home.clone(), name.clone());
        blocking(move || backup::request_restore(&home, &name)).await
    };
    if let Err(e) = marker {
        RESTORE_PENDING.store(false, Ordering::SeqCst);
        return Err(e);
    }
    tokio::spawn(async move {
        tokio::time::sleep(RESTART_AFTER_REPLY).await;
        let why = match tokio::task::spawn_blocking(move || update::run_restart(&restart)).await {
            Ok(Ok(())) => return,
            Ok(Err(e)) => format!("{e:#}"),
            Err(e) => e.to_string(),
        };
        tracing::error!("restart for the database restore failed: {why}");
        let _ = tokio::task::spawn_blocking(move || backup::clear_restore_request(&home)).await;
        RESTORE_PENDING.store(false, Ordering::SeqCst);
    });
    Ok(())
}

fn backup_json(file: &BackupFile) -> Value {
    json!({
        "name": file.name,
        "size": file.size,
        "created_at_ms": file.created_at_ms,
        "reason": file.reason,
    })
}

/// Runs blocking file work off the async threads; a failure becomes a server error with its message.
async fn blocking<T: Send + 'static>(work: impl FnOnce() -> anyhow::Result<T> + Send + 'static) -> Result<T, RpcError> {
    tokio::task::spawn_blocking(work)
        .await
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("backups stopped: {e}")))?
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("{e:#}")))
}

#[cfg(test)]
mod tests {
    use super::super::{Peer, dispatch, features};
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use std::sync::Arc;

    /// An app whose data folder is `home`, with a small database in it. Nothing outside `home` is touched.
    fn app_in(home: &Path) -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let conn = rusqlite::Connection::open(home.join("bandito.db")).unwrap();
        conn.execute_batch("CREATE TABLE t(v TEXT); INSERT INTO t(v) VALUES ('live');")
            .unwrap();
        drop(conn);
        App::new_in_home(sup, home.join("agents"), App::default_files(), home.to_path_buf())
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn code(r: RpcResult) -> i64 {
        r.unwrap_err().code
    }

    #[tokio::test]
    async fn list_is_empty_then_shows_a_manual_copy() {
        let home = tempfile::tempdir().unwrap();
        let app = app_in(home.path());
        assert_eq!(call(&app, "backups.list", json!({})).await.unwrap(), json!([]));

        let made = call(&app, "backups.create", json!({})).await.unwrap();
        assert_eq!(made["reason"], "manual");
        assert!(made["size"].as_u64().unwrap() > 0);
        assert!(made["name"].as_str().unwrap().ends_with("-manual.db"));
        assert!(made["created_at_ms"].as_i64().unwrap() > 0);

        let listed = call(&app, "backups.list", json!({})).await.unwrap();
        assert_eq!(listed.as_array().unwrap().len(), 1);
        assert_eq!(listed[0], made);
    }

    #[tokio::test]
    async fn restore_refuses_a_bad_name_as_invalid_params() {
        let home = tempfile::tempdir().unwrap();
        let app = app_in(home.path());
        let bad = call(&app, "backups.restore", json!({ "name": "../x.db" })).await;
        assert_eq!(code(bad), INVALID_PARAMS);
        let other = call(&app, "backups.restore", json!({ "name": "notes.txt" })).await;
        assert_eq!(code(other), INVALID_PARAMS);
        assert!(!backup::restore_marker(home.path()).exists());
    }

    #[tokio::test]
    async fn restore_refuses_a_missing_copy_and_writes_no_marker() {
        let home = tempfile::tempdir().unwrap();
        let app = app_in(home.path());
        let r = call(
            &app,
            "backups.restore",
            json!({ "name": "bandito-20270115-080000-start.db" }),
        )
        .await;
        assert_eq!(code(r), SERVER_ERROR);
        assert!(!backup::restore_marker(home.path()).exists());
    }

    #[tokio::test]
    async fn restore_needs_a_name() {
        let home = tempfile::tempdir().unwrap();
        let app = app_in(home.path());
        assert_eq!(code(call(&app, "backups.restore", json!({})).await), INVALID_PARAMS);
    }

    #[test]
    fn the_backups_feature_is_offered() {
        assert!(features().contains(&"backups"));
    }
}
