//! `server.settings_get` and `server.settings_set`: the server settings the owner changes from the apps
//! (docs/ARCHITECTURE.md#server-settings). Owner and apps only: `rpc::allowed` refuses agents and anonymous peers.
//! The rules and the defaults are in `crate::server_settings`, the storage in `store/server_settings.rs`.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, ok};
use crate::event::EventBody;
use crate::server_settings::{self, Invalid, ServerSettings};
use serde_json::{Map, Value, json};

/// Answers the `server.settings_*` methods. `rpc::dispatch` has already refused agents and anonymous peers.
pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    let hub = app.sup.hub();
    match method {
        "server.settings_get" => ok(reply(app, &hub.store.server_settings()?)),
        "server.settings_set" => {
            let patch = patch_object(p)?;
            // Every value is checked before anything is written: a refused patch changes nothing.
            let changes = server_settings::check_patch(&patch).map_err(invalid_error)?;
            hub.store.server_settings_write(&changes)?;
            if !changes.is_empty() {
                // A changed limit reaches the waiting agents now, not at their next message.
                hub.turns().wake();
                let keys = changes.iter().map(|(key, _)| key.to_string()).collect();
                // The phone listener follows its settings now; a failure (a port in use) is in the reply's `phone`.
                if changes
                    .iter()
                    .any(|(key, _)| matches!(*key, server_settings::PHONE_ACCESS | server_settings::PHONE_PORT))
                {
                    app.phone.apply().await;
                }
                hub.emit("", EventBody::ServerSettingsChanged { keys });
            }
            ok(reply(app, &hub.store.server_settings()?))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// What both methods reply: the settings as they apply, the defaults, and what the phone listener is doing.
fn reply(app: &App, settings: &ServerSettings) -> Value {
    json!({
        "settings": settings.to_json(),
        "defaults": server_settings::defaults_json(),
        "phone": app.phone.status_json(),
    })
}

/// The patch of `server.settings_set`: an object of setting names and values. No params is an empty patch.
fn patch_object(p: Value) -> Result<Map<String, Value>, RpcError> {
    match p {
        Value::Null => Ok(Map::new()),
        Value::Object(map) => Ok(map),
        _ => Err(RpcError::new(
            INVALID_PARAMS,
            "invalid params: expected an object of server settings",
        )),
    }
}

/// The refusal of a bad setting: `data.reason` is `invalid` and `data.field` names the setting.
fn invalid_error(e: Invalid) -> RpcError {
    RpcError {
        code: INVALID_PARAMS,
        message: format!("invalid server setting {}: {}", e.field, e.reason),
        data: Some(json!({ "reason": "invalid", "field": e.field })),
    }
}

#[cfg(test)]
mod tests {
    use super::super::{Peer, allowed, dispatch};
    use super::*;
    use crate::hub::Hub;
    use crate::store::{Device, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use std::path::PathBuf;
    use std::sync::Arc;

    /// An app over an in-memory store, with no runtimes.
    fn app() -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, PathBuf::from("unused-agents-root"))
    }

    fn owner() -> Peer {
        Peer::Local
    }

    fn device() -> Peer {
        Peer::Device(Device {
            id: "dev".into(),
            name: "phone".into(),
            created_at: 0,
            last_seen_at: None,
        })
    }

    #[tokio::test]
    async fn get_shows_the_defaults_before_anything_is_set() {
        let app = app();
        let got = dispatch(&app, &owner(), "server.settings_get", json!({}))
            .await
            .unwrap();
        assert_eq!(got["settings"], server_settings::defaults_json());
        assert_eq!(got["defaults"], server_settings::defaults_json());
    }

    #[tokio::test]
    async fn set_writes_a_valid_patch_and_replies_like_get() {
        let app = app();
        let mut events = app.sup.hub().subscribe();
        let set = dispatch(
            &app,
            &owner(),
            "server.settings_set",
            json!({"screen_idle_minutes": 60, "auto_update": "off"}),
        )
        .await
        .unwrap();
        assert_eq!(set["settings"]["screen_idle_minutes"], json!(60));
        assert_eq!(set["settings"]["auto_update"], json!("off"));
        assert_eq!(set["defaults"]["screen_idle_minutes"], json!(30));
        let got = dispatch(&app, &owner(), "server.settings_get", json!({}))
            .await
            .unwrap();
        assert_eq!(got, set);
        let ev = events.try_recv().expect("the change is broadcast");
        assert_eq!(ev.agent_id, "");
        assert_eq!(ev.seq, 0, "the change is not stored");
        let EventBody::ServerSettingsChanged { mut keys } = ev.body else {
            panic!("the event is server.settings_changed");
        };
        keys.sort();
        assert_eq!(keys, vec!["auto_update".to_string(), "screen_idle_minutes".to_string()]);
    }

    #[tokio::test]
    async fn a_refused_patch_writes_nothing_and_names_the_field() {
        let app = app();
        let mut events = app.sup.hub().subscribe();
        for (params, field) in [
            (json!({"screen_idle_minutes": 60, "backup_keep": 2}), "backup_keep"),
            (json!({"screen_idle_minutes": 60, "bogus": true}), "bogus"),
            (json!({"update_channel": "beta"}), "update_channel"),
        ] {
            let err = dispatch(&app, &owner(), "server.settings_set", params)
                .await
                .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS);
            assert_eq!(err.data.as_ref().unwrap()["reason"], json!("invalid"));
            assert_eq!(err.data.as_ref().unwrap()["field"], json!(field));
            assert!(err.message.contains(field), "{}", err.message);
        }
        let got = dispatch(&app, &owner(), "server.settings_get", json!({}))
            .await
            .unwrap();
        assert_eq!(
            got["settings"],
            server_settings::defaults_json(),
            "not even the valid part is written"
        );
        assert!(events.try_recv().is_err(), "a refused patch sends no event");
    }

    #[tokio::test]
    async fn a_non_object_patch_is_refused() {
        let app = app();
        let err = dispatch(&app, &owner(), "server.settings_set", json!([1, 2]))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
    }

    #[tokio::test]
    async fn an_empty_patch_changes_nothing_and_sends_nothing() {
        let app = app();
        let mut events = app.sup.hub().subscribe();
        let got = dispatch(&app, &owner(), "server.settings_set", json!({}))
            .await
            .unwrap();
        assert_eq!(got["settings"], server_settings::defaults_json());
        assert!(events.try_recv().is_err());
    }

    #[test]
    fn the_owner_and_apps_may_call_it_and_agents_and_strangers_may_not() {
        for method in ["server.settings_get", "server.settings_set"] {
            assert!(allowed(&owner(), method), "{method}");
            assert!(allowed(&device(), method), "{method}");
            assert!(
                !allowed(&Peer::Agent("agent-1".into()), method),
                "agents are refused: {method}"
            );
            assert!(
                !allowed(&Peer::Anonymous("1.2.3.4".into(), None), method),
                "anonymous is refused: {method}"
            );
        }
    }

    #[tokio::test]
    async fn a_new_agent_takes_the_default_approval_mode_unless_the_call_sets_one() {
        // The agents' folders are under a temp folder of this test, removed with it.
        let root = tempfile::tempdir().unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        let app = App::new(sup, root.path().join("agents"));
        dispatch(
            &app,
            &owner(),
            "server.settings_set",
            json!({"default_approval_mode": "always"}),
        )
        .await
        .unwrap();
        let cwd = root.path().display().to_string();
        let by_default = dispatch(
            &app,
            &owner(),
            "agents.create",
            json!({"name": "Forge", "runtime": "claude", "cwd": cwd}),
        )
        .await
        .unwrap();
        let id = by_default["id"].as_str().unwrap().to_string();
        assert_eq!(store.agent_get(&id).unwrap().unwrap().approval_mode.as_str(), "always");
        let explicit = dispatch(
            &app,
            &owner(),
            "agents.create",
            json!({"name": "Ledger", "runtime": "claude", "cwd": cwd, "approval_mode": "never"}),
        )
        .await
        .unwrap();
        let id = explicit["id"].as_str().unwrap().to_string();
        assert_eq!(store.agent_get(&id).unwrap().unwrap().approval_mode.as_str(), "never");
    }

    #[tokio::test]
    async fn an_unknown_method_in_the_family_is_not_found() {
        let app = app();
        let err = dispatch(&app, &owner(), "server.settings_nope", json!({}))
            .await
            .unwrap_err();
        assert_eq!(err.code, METHOD_NOT_FOUND);
    }
}
