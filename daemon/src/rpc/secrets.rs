//! `secrets.*` JSON-RPC methods. Values go in with `secrets.set` and never come
//! back: list and set answer with the name, the tail and the agents only.
//! See docs/ARCHITECTURE.md#secrets.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, ok, params};
use crate::store::{check_agents, check_name, check_value};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeSet;

#[derive(Deserialize)]
struct NameParams {
    name: String,
}

#[derive(Deserialize)]
struct SetParams {
    name: String,
    value: String,
    agents: Vec<String>,
}

pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    let store = &app.sup.hub().store;
    match method {
        "secrets.list" => ok(store.secret_list()?),
        "secrets.set" => {
            let p: SetParams = params(p)?;
            check_name(&p.name).map_err(invalid)?;
            check_value(&p.value).map_err(invalid)?;
            check_agents(&p.agents).map_err(invalid)?;
            let before = agents_of(app, &p.name)?;
            let info = store.secret_set(&p.name, &p.value, &p.agents)?;
            reload(app, &before, &p.agents).await?;
            ok(info)
        }
        "secrets.delete" => {
            let p: NameParams = params(p)?;
            check_name(&p.name).map_err(invalid)?;
            let before = agents_of(app, &p.name)?;
            let deleted = store.secret_delete(&p.name)?;
            if deleted {
                reload(app, &before, &[]).await?;
            }
            ok(json!({ "deleted": deleted }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

fn invalid(e: anyhow::Error) -> RpcError {
    RpcError::new(INVALID_PARAMS, format!("{e:#}"))
}

/// Agents the secret is given to now (empty if there is no such secret).
fn agents_of(app: &App, name: &str) -> Result<Vec<String>, RpcError> {
    let list = app.sup.hub().store.secret_list()?;
    Ok(list
        .into_iter()
        .find(|s| s.name == name)
        .map(|s| s.agents)
        .unwrap_or_default())
}

/// Restarts, from their next turn, the sessions that may hold a changed secret: the agents
/// it was given to before and after the change. `"*"` means every agent.
async fn reload(app: &App, before: &[String], after: &[String]) -> Result<(), RpcError> {
    let ids: Vec<String> = if before.iter().chain(after).any(|a| a == "*") {
        app.sup.hub().store.agent_list()?.into_iter().map(|a| a.id).collect()
    } else {
        before
            .iter()
            .chain(after)
            .cloned()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect()
    };
    for id in ids {
        app.sup.reload(&id, false).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::{App, FEATURES, INVALID_PARAMS, Peer, RpcResult, dispatch};
    use crate::event::{EventBody, TurnStatus};
    use crate::hub::Hub;
    use crate::runtime::{RuntimeKind, RuntimeOutput};
    use crate::store::{ApprovalMode, MemoryMode, NewAgent, Store};
    use crate::supervisor::testing::{Log, MockRuntime, Outs};
    use crate::supervisor::{Inbound, Runtimes, Supervisor};
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    struct Rig {
        app: Arc<App>,
        store: Arc<Store>,
        log: Log,
        out: Outs,
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
        let sup = Supervisor::new(Hub::new(store.clone()), rts, None);
        let app = App::new(sup, PathBuf::from("unused-agents-root"));
        Rig { app, store, log, out }
    }

    async fn call(app: &App, method: &str, p: serde_json::Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn new_agent(store: &Store, name: &str) -> String {
        store
            .agent_create(NewAgent {
                name: name.into(),
                role: "builder".into(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/home/u/app".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
            })
            .unwrap()
            .id
    }

    #[test]
    fn the_daemon_advertises_secrets() {
        assert!(FEATURES.contains(&"secrets"));
    }

    #[tokio::test]
    async fn set_list_delete_never_return_the_value() {
        let r = rig();
        let secret = "sk-live-0123456789abcdef";
        let set = call(
            &r.app,
            "secrets.set",
            json!({"name": "OPENAI_API_KEY", "value": secret, "agents": ["*"]}),
        )
        .await
        .unwrap();
        assert_eq!(set["name"], "OPENAI_API_KEY");
        assert_eq!(set["tail"], "cdef");
        assert!(set.get("value").is_none());

        let list = call(&r.app, "secrets.list", json!({})).await.unwrap();
        assert_eq!(list[0]["name"], "OPENAI_API_KEY");
        assert!(list[0].get("value").is_none());
        for answer in [&set, &list] {
            assert!(!answer.to_string().contains(secret), "value leaked: {answer}");
        }

        assert_eq!(
            call(&r.app, "secrets.delete", json!({"name": "OPENAI_API_KEY"}))
                .await
                .unwrap(),
            json!({"deleted": true})
        );
        assert_eq!(
            call(&r.app, "secrets.delete", json!({"name": "OPENAI_API_KEY"}))
                .await
                .unwrap(),
            json!({"deleted": false})
        );
        assert_eq!(call(&r.app, "secrets.list", json!({})).await.unwrap(), json!([]));
    }

    #[tokio::test]
    async fn invalid_input_is_invalid_params() {
        let r = rig();
        let cases = [
            (
                json!({"name": "lower", "value": "x-value-1", "agents": ["*"]}),
                "bad name",
            ),
            (
                json!({"name": "PATH", "value": "x-value-1", "agents": ["*"]}),
                "reserved name",
            ),
            (json!({"name": "OK_KEY", "value": "", "agents": ["*"]}), "empty value"),
            (
                json!({"name": "OK_KEY", "value": "x-value-1", "agents": ["*", "a"]}),
                "star with ids",
            ),
            (
                json!({"name": "OK_KEY", "value": "x-value-1", "agents": [""]}),
                "blank agent id",
            ),
            (json!({"name": "OK_KEY", "value": "x-value-1"}), "agents missing"),
        ];
        for (p, why) in cases {
            let err = call(&r.app, "secrets.set", p).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{why}");
        }
        let err = call(&r.app, "secrets.delete", json!({"name": "bad name"}))
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(r.store.secret_list().unwrap().is_empty(), "nothing stored on errors");
    }

    #[tokio::test]
    async fn set_closes_the_idle_sessions_it_affects() {
        let r = rig();
        let agent = new_agent(&r.store, "Forge");
        r.app.sup.send(&agent, Inbound::user("hi")).await.unwrap();
        for _ in 0..300 {
            if r.log.lock().unwrap().iter().any(|l| l == "send hi") {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        // Finish the turn, and wait until it is stored, so the session is idle.
        let tx = r.out.lock().unwrap().get(&agent).cloned().expect("session spawned");
        tx.send(RuntimeOutput::Event(EventBody::TurnCompleted {
            turn_id: "t1".into(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: None,
        }))
        .await
        .unwrap();
        for _ in 0..300 {
            if r.store
                .events_since(0, 100, None)
                .unwrap()
                .iter()
                .any(|e| e.body.to_parts().0 == "turn.completed")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }

        call(
            &r.app,
            "secrets.set",
            json!({"name": "OPENAI_API_KEY", "value": "sk-live-0123456789", "agents": ["*"]}),
        )
        .await
        .unwrap();
        assert!(
            r.log.lock().unwrap().iter().any(|l| l == "shutdown"),
            "the idle session closes so the next one gets the new secret: {:?}",
            r.log.lock().unwrap()
        );
    }
}
