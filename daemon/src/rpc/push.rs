//! `push.*` JSON-RPC methods (docs/ARCHITECTURE.md#push): a paired phone tells the daemon where to send push
//! notifications for it. Everything is tied to the device that calls (the token it connected with, also through the
//! phone listener or the relay); the owner's CLI is no device and gets `push_needs_device`. The key is never in a
//! reply and never logged. Agents may not call these (they are not in `AGENT_METHODS`).

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::push::PushKind;
use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};

const HANDLE_MAX: usize = 256;
const SERVER_REF_MAX: usize = 64;
const LANG_MAX: usize = 16;
const KEY_BYTES: usize = 32;

#[derive(Deserialize)]
struct RegisterParams {
    handle: String,
    /// Standard base64 of 32 bytes.
    key: String,
    #[serde(rename = "serverRef", alias = "server_ref")]
    server_ref: String,
    kinds: Vec<String>,
    #[serde(default)]
    lang: Option<String>,
}

fn invalid(message: &str) -> RpcError {
    RpcError::new(INVALID_PARAMS, format!("invalid params: {message}"))
}

/// The device that is calling, or `push_needs_device`.
fn caller(peer: &Peer) -> Result<&str, RpcError> {
    match peer {
        Peer::Device(device) => Ok(&device.id),
        _ => Err(RpcError::with_data(
            SERVER_ERROR,
            "push_needs_device: push belongs to a paired phone, so call it from the app",
            json!({ "reason": "push_needs_device" }),
        )),
    }
}

/// Text without control characters (they would end up in a header, a log line or the notification).
fn clean(s: &str) -> bool {
    !s.chars().any(char::is_control)
}

fn decode_key(text: &str) -> Result<Vec<u8>, RpcError> {
    use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD, URL_SAFE, URL_SAFE_NO_PAD};
    let text = text.trim();
    let bytes = [&STANDARD, &STANDARD_NO_PAD, &URL_SAFE, &URL_SAFE_NO_PAD]
        .iter()
        .find_map(|engine| engine.decode(text).ok())
        .ok_or_else(|| invalid("key is not base64"))?;
    if bytes.len() != KEY_BYTES {
        return Err(invalid("key must be 32 bytes"));
    }
    Ok(bytes)
}

pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    let store = &app.sup.hub().store;
    match method {
        "push.register" => {
            let device = caller(peer)?;
            let RegisterParams {
                handle,
                key,
                server_ref,
                kinds,
                lang,
            } = params(p)?;
            if handle.is_empty() || handle.chars().count() > HANDLE_MAX || !clean(&handle) {
                return Err(invalid("handle must be 1 to 256 characters"));
            }
            if server_ref.is_empty() || server_ref.chars().count() > SERVER_REF_MAX || !clean(&server_ref) {
                return Err(invalid("serverRef must be 1 to 64 characters"));
            }
            if let Some(lang) = &lang
                && (lang.is_empty()
                    || lang.len() > LANG_MAX
                    || !lang.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'))
            {
                return Err(invalid("lang must be a language code"));
            }
            let mut wanted = Vec::new();
            for name in &kinds {
                wanted.push(
                    PushKind::parse(name)
                        .ok_or_else(|| invalid("kinds are approval, question, done, error and connect"))?,
                );
            }
            if wanted.is_empty() {
                return Err(invalid("kinds must name at least one kind"));
            }
            let key = decode_key(&key)?;
            store
                .push_upsert(
                    device,
                    &handle,
                    &key,
                    &server_ref,
                    &PushKind::to_csv(&wanted),
                    lang.as_deref(),
                )
                .map_err(|e| {
                    // The usual cause is a device revoked while it was calling.
                    tracing::warn!("push.register: {e:#}");
                    RpcError::new(
                        SERVER_ERROR,
                        "could not save the push registration: pair this phone again",
                    )
                })?;
            tracing::info!(device, "push registered");
            ok(json!({ "ok": true }))
        }
        "push.unregister" => {
            let device = caller(peer)?;
            let removed = store
                .push_delete(device)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("could not remove the push registration: {e}")))?;
            if removed {
                tracing::info!(device, "push unregistered");
            }
            ok(json!({ "ok": true }))
        }
        "push.status" => {
            let device = caller(peer)?;
            let registered = store
                .push_get(device)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("could not read the push registration: {e}")))?
                .is_some();
            ok(json!({ "registered": registered }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::super::{Device, UNAUTHORIZED, dispatch as call};
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use base64::engine::general_purpose::STANDARD;
    use std::sync::Arc;

    fn app() -> (Arc<App>, Arc<Store>) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        (App::new(sup, std::env::temp_dir().join("bandito-push-tests")), store)
    }

    fn phone(store: &Store, token: &str) -> Peer {
        Peer::Device(store.device_add("iPhone", token).unwrap())
    }

    fn register(key: &[u8]) -> Value {
        json!({ "handle": "h-1", "key": STANDARD.encode(key), "serverRef": "home", "kinds": ["approval", "done"] })
    }

    #[tokio::test]
    async fn a_phone_registers_asks_and_unregisters() {
        let (app, store) = app();
        let me = phone(&store, "t1");
        let Peer::Device(Device { id, .. }) = &me else {
            unreachable!()
        };
        let status = async |peer: &Peer| call(&app, peer, "push.status", json!({})).await;
        assert_eq!(status(&me).await.unwrap(), json!({ "registered": false }));
        let reply = call(&app, &me, "push.register", register(&[5; 32])).await.unwrap();
        assert_eq!(reply, json!({ "ok": true }));
        assert!(
            !reply.to_string().contains(&STANDARD.encode([5; 32])),
            "the key is never sent back"
        );
        assert_eq!(status(&me).await.unwrap(), json!({ "registered": true }));
        let row = store.push_get(id).unwrap().unwrap();
        assert_eq!(row.key, vec![5; 32]);
        assert_eq!(
            (row.handle.as_str(), row.server_ref.as_str(), row.kinds.as_str()),
            ("h-1", "home", "approval,done")
        );
        // Twice is one row, with the new values; another phone has its own.
        let mut again = register(&[6; 32]);
        again["handle"] = json!("h-2");
        again["kinds"] = json!(["error", "error"]);
        call(&app, &me, "push.register", again).await.unwrap();
        assert_eq!(store.push_list().unwrap().len(), 1);
        let row = store.push_get(id).unwrap().unwrap();
        assert_eq!(
            (row.handle.as_str(), row.kinds.as_str(), row.key.clone()),
            ("h-2", "error", vec![6; 32])
        );
        let other = phone(&store, "t2");
        assert_eq!(status(&other).await.unwrap(), json!({ "registered": false }));
        call(&app, &other, "push.register", register(&[7; 32])).await.unwrap();
        assert_eq!(store.push_list().unwrap().len(), 2);
        // Unregister takes only the caller's row, and twice is fine.
        assert_eq!(
            call(&app, &me, "push.unregister", json!({})).await.unwrap(),
            json!({ "ok": true })
        );
        assert_eq!(
            call(&app, &me, "push.unregister", json!({})).await.unwrap(),
            json!({ "ok": true })
        );
        assert_eq!(status(&me).await.unwrap(), json!({ "registered": false }));
        assert_eq!(status(&other).await.unwrap(), json!({ "registered": true }));
    }

    #[tokio::test]
    async fn snake_case_server_ref_and_lang_are_accepted() {
        let (app, store) = app();
        let me = phone(&store, "t1");
        let mut p = register(&[1; 32]);
        p.as_object_mut().unwrap().remove("serverRef");
        p["server_ref"] = json!("home");
        p["lang"] = json!("ru");
        call(&app, &me, "push.register", p).await.unwrap();
        let Peer::Device(d) = &me else { unreachable!() };
        assert_eq!(store.push_get(&d.id).unwrap().unwrap().lang.as_deref(), Some("ru"));
    }

    #[tokio::test]
    async fn the_owners_cli_is_no_device() {
        let (app, _store) = app();
        for (method, p) in [
            ("push.register", register(&[1; 32])),
            ("push.unregister", json!({})),
            ("push.status", json!({})),
        ] {
            let err = call(&app, &Peer::Local, method, p).await.unwrap_err();
            assert!(
                err.message.starts_with("push_needs_device"),
                "{method}: {}",
                err.message
            );
            assert_eq!(err.data.unwrap()["reason"], "push_needs_device");
        }
    }

    #[tokio::test]
    async fn agents_and_strangers_are_refused() {
        let (app, store) = app();
        for peer in [Peer::Agent("a".into()), Peer::Anonymous("1.2.3.4".into(), None)] {
            let err = call(&app, &peer, "push.register", register(&[1; 32]))
                .await
                .unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED);
        }
        assert!(store.push_list().unwrap().is_empty());
    }

    #[tokio::test]
    async fn bad_params_write_nothing() {
        let (app, store) = app();
        let me = phone(&store, "t1");
        let with = |field: &str, value: Value| {
            let mut p = register(&[1; 32]);
            p[field] = value;
            p
        };
        let cases = [
            with("handle", json!("")),
            with("handle", json!("x".repeat(257))),
            with("handle", json!("a\nb")),
            with("key", json!(STANDARD.encode([1; 31]))),
            with("key", json!(STANDARD.encode([1; 33]))),
            with("key", json!("not base64!!")),
            with("key", json!("")),
            with("serverRef", json!("")),
            with("serverRef", json!("s".repeat(65))),
            with("kinds", json!([])),
            with("kinds", json!(["approval", "nonsense"])),
            with("kinds", json!("approval")),
            with("lang", json!("ru ru")),
            json!({}),
        ];
        for p in cases {
            let err = call(&app, &me, "push.register", p.clone()).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{p}");
        }
        assert!(store.push_list().unwrap().is_empty());
        // The limits themselves are fine.
        let mut edge = register(&[1; 32]);
        edge["handle"] = json!("x".repeat(256));
        edge["serverRef"] = json!("s".repeat(64));
        edge["kinds"] = json!(["approval", "question", "done", "error", "connect"]);
        call(&app, &me, "push.register", edge).await.unwrap();
        let Peer::Device(d) = &me else { unreachable!() };
        assert_eq!(
            store.push_get(&d.id).unwrap().unwrap().kinds,
            "approval,question,done,error,connect"
        );
    }

    #[tokio::test]
    async fn revoking_the_device_ends_its_push() {
        let (app, store) = app();
        let me = phone(&store, "t1");
        call(&app, &me, "push.register", register(&[1; 32])).await.unwrap();
        let Peer::Device(d) = &me else { unreachable!() };
        call(&app, &Peer::Local, "devices.revoke", json!({ "id": d.id }))
            .await
            .unwrap();
        assert!(store.push_list().unwrap().is_empty());
        // A call that raced the revoke is refused, not a half-written row.
        let err = call(&app, &me, "push.register", register(&[1; 32])).await.unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
        assert!(store.push_list().unwrap().is_empty());
    }
}
