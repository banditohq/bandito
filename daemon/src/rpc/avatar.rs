//! `agents.avatar_image_set|get|clear`: the picture of an agent's avatar, kept on disk by
//! [`crate::avatar`]. Owner and apps only. See docs/ARCHITECTURE.md#capabilities.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::event::{AgentChange, EventBody};
use crate::store::now_ms;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct IdParams {
    id: String,
}

#[derive(Deserialize)]
struct SetParams {
    id: String,
    data_base64: String,
}

pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    let store = &app.sup.hub().store;
    match method {
        "agents.avatar_image_set" => {
            let SetParams { id, data_base64 } = params(p)?;
            let agent = store
                .agent_get(&id)?
                .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?;
            if agent.avatar.is_none() {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    "set the avatar's color and face before its picture",
                ));
            }
            // Checked on the text first, so an oversized upload is refused before it is decoded.
            if data_base64.len() > crate::avatar::MAX_BYTES / 3 * 4 + 4 {
                return Err(RpcError::new(INVALID_PARAMS, "avatar picture is over 1 MB"));
            }
            let bytes = STANDARD
                .decode(data_base64.trim())
                .map_err(|_| RpcError::new(INVALID_PARAMS, "avatar picture is not base64"))?;
            if bytes.len() > crate::avatar::MAX_BYTES {
                return Err(RpcError::new(INVALID_PARAMS, "avatar picture is over 1 MB"));
            }
            if crate::avatar::sniff(&bytes).is_none() {
                return Err(RpcError::new(INVALID_PARAMS, "avatar picture must be PNG or JPEG"));
            }
            crate::avatar::write(&app.data_home, &id, &bytes)
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("{e:#}")))?;
            store.agent_set_avatar_image(&id, Some(now_ms()))?;
            changed(app, &id);
            ok(view(app, &id)?)
        }
        "agents.avatar_image_get" => {
            let IdParams { id } = params(p)?;
            if store.agent_get(&id)?.is_none() {
                return Err(RpcError::new(SERVER_ERROR, format!("no agent {id}")));
            }
            let found = crate::avatar::find(&app.data_home, &id);
            ok(match found {
                Some((path, mime)) => {
                    let bytes = std::fs::read(&path).map_err(|e| RpcError::new(SERVER_ERROR, e.to_string()))?;
                    json!({ "data_base64": STANDARD.encode(bytes), "mime": mime })
                }
                None => Value::Null,
            })
        }
        "agents.avatar_image_clear" => {
            let IdParams { id } = params(p)?;
            if store.agent_get(&id)?.is_none() {
                return Err(RpcError::new(SERVER_ERROR, format!("no agent {id}")));
            }
            crate::avatar::remove(&app.data_home, &id);
            store.agent_set_avatar_image(&id, None)?;
            changed(app, &id);
            ok(view(app, &id)?)
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

fn changed(app: &App, id: &str) {
    app.sup.hub().emit(
        id,
        EventBody::AgentChanged {
            action: AgentChange::Updated,
        },
    );
}

fn view(app: &App, id: &str) -> Result<Value, RpcError> {
    let agent = app
        .sup
        .hub()
        .store
        .agent_view(id)?
        .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {id}")))?;
    serde_json::to_value(agent).map_err(|e| RpcError::new(SERVER_ERROR, e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::super::{Peer, clean_avatar, dispatch, is_one_grapheme};
    use super::*;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{Avatar, NewAgent, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use std::sync::Arc;

    const PNG: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

    fn app_with_agent(name: &str) -> (Arc<App>, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                integrations: None,
                name: name.into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: "/tmp".into(),
                approval_mode: crate::store::ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap();
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let home = std::env::temp_dir().join(format!("bandito-avatar-rpc-{}", crate::store::new_id()));
        (App::new(sup, home), agent.id)
    }

    async fn call(app: &App, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    fn picture(bytes: &[u8]) -> Value {
        json!({ "data_base64": STANDARD.encode(bytes) })
    }

    async fn set_avatar(app: &App, id: &str, avatar: Value) {
        call(app, "agents.update", json!({ "id": id, "avatar": avatar }))
            .await
            .unwrap();
    }

    #[test]
    fn colors_are_names_or_hex_and_emoji_is_one_character() {
        let av = |color: &str, face: &str, emoji: Option<&str>| Avatar {
            color: color.into(),
            face: face.into(),
            emoji: emoji.map(String::from),
            image: true,
            image_rev: Some(5),
        };
        let ok = clean_avatar(av(" sky ", "dots", None)).unwrap();
        assert_eq!((ok.color.as_str(), ok.face.as_str()), ("sky", "dots"));
        assert_eq!(
            (ok.image, ok.image_rev),
            (false, None),
            "a picture is never set by avatar"
        );
        assert_eq!(clean_avatar(av("#ff00aa", "dots", None)).unwrap().color, "#FF00AA");
        for bad in ["#FFF", "#GG0000", "#ff00aa00", "#", "", "   "] {
            assert!(clean_avatar(av(bad, "dots", None)).is_err(), "color {bad:?}");
        }
        assert!(clean_avatar(av("sky", "", None)).is_err());
        assert_eq!(
            clean_avatar(av("sky", "dots", Some("🔥"))).unwrap().emoji.as_deref(),
            Some("🔥")
        );
        assert_eq!(clean_avatar(av("sky", "dots", Some(""))).unwrap().emoji, None);
        assert!(clean_avatar(av("sky", "dots", Some("ab"))).is_err());
    }

    #[test]
    fn one_grapheme_covers_marks_flags_and_zwj_sequences() {
        for one in ["a", "🔥", "👍🏽", "👨‍👩‍👧", "1\u{FE0F}\u{20E3}", "🇷🇺", "é", "❤\u{FE0F}"]
        {
            assert!(is_one_grapheme(one), "{one}");
        }
        for two in [
            "ab",
            "🇷🇺🇺🇸",
            "🔥🔥",
            "\u{200D}a",
            "a\u{200D}",
            "🇷🇺🇺🇸🇯🇵",
            "",
            "a\u{0301}b",
        ] {
            assert!(!is_one_grapheme(two), "{two:?}");
        }
    }

    #[tokio::test]
    async fn a_picture_needs_an_avatar_first_and_round_trips() {
        let (app, id) = app_with_agent("Forge");
        let no_avatar = call(
            &app,
            "agents.avatar_image_set",
            json!({ "id": id, "data_base64": STANDARD.encode(PNG) }),
        )
        .await
        .unwrap_err();
        assert_eq!(no_avatar.code, INVALID_PARAMS);

        set_avatar(&app, &id, json!({ "color": "sky", "face": "dots", "emoji": "🔥" })).await;
        let mut p = picture(PNG);
        p["id"] = json!(id);
        let view = call(&app, "agents.avatar_image_set", p).await.unwrap();
        assert_eq!(view["avatar"]["image"], json!(true));
        assert!(view["avatar"]["image_rev"].as_i64().is_some());
        assert_eq!(view["avatar"]["emoji"], json!("🔥"));

        let got = call(&app, "agents.avatar_image_get", json!({ "id": id }))
            .await
            .unwrap();
        assert_eq!(got, json!({ "data_base64": STANDARD.encode(PNG), "mime": "image/png" }));

        // A new name-and-face keeps the picture; `null` drops it and the file with it.
        set_avatar(&app, &id, json!({ "color": "#112233", "face": "cat" })).await;
        let kept = call(&app, "agents.get", json!({ "id": id })).await.unwrap();
        assert_eq!(kept["avatar"]["image"], json!(true));
        assert_eq!(kept["avatar"]["emoji"], Value::Null);
        set_avatar(&app, &id, Value::Null).await;
        assert!(crate::avatar::find(&app.data_home, &id).is_none());
        assert_eq!(
            call(&app, "agents.avatar_image_get", json!({ "id": id }))
                .await
                .unwrap(),
            Value::Null
        );

        set_avatar(&app, &id, json!({ "color": "sky", "face": "dots" })).await;
        call(
            &app,
            "agents.avatar_image_set",
            json!({ "id": id, "data_base64": STANDARD.encode(PNG) }),
        )
        .await
        .unwrap();
        let cleared = call(&app, "agents.avatar_image_clear", json!({ "id": id }))
            .await
            .unwrap();
        assert_ne!(cleared["avatar"]["image"], json!(true), "false is left out of the wire");
        assert!(crate::avatar::find(&app.data_home, &id).is_none());
        std::fs::remove_dir_all(&app.data_home).ok();
    }

    #[tokio::test]
    async fn bad_pictures_are_refused_and_delete_removes_the_file() {
        let (app, id) = app_with_agent("Forge");
        set_avatar(&app, &id, json!({ "color": "sky", "face": "dots" })).await;
        let refuse = |data: String| json!({ "id": id, "data_base64": data });
        for data in [
            STANDARD.encode(b"GIF89a"),
            "%%% not base64".to_string(),
            STANDARD.encode(vec![0u8; crate::avatar::MAX_BYTES + 1]),
        ] {
            let err = call(&app, "agents.avatar_image_set", refuse(data)).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS);
        }
        assert!(crate::avatar::find(&app.data_home, &id).is_none());

        let mut big = PNG.to_vec();
        big.resize(crate::avatar::MAX_BYTES, 0);
        call(&app, "agents.avatar_image_set", refuse(STANDARD.encode(&big)))
            .await
            .unwrap();
        call(&app, "agents.delete", json!({ "id": id })).await.unwrap();
        assert!(crate::avatar::find(&app.data_home, &id).is_none());
        std::fs::remove_dir_all(&app.data_home).ok();
    }

    #[tokio::test]
    async fn reading_a_picture_checks_the_agent_first() {
        let (app, _) = app_with_agent("Forge");
        // A file for an id no agent has: the read must not reach it.
        let stray = "ghost-agent";
        crate::avatar::write(&app.data_home, stray, PNG).unwrap();
        let err = call(&app, "agents.avatar_image_get", json!({ "id": stray }))
            .await
            .unwrap_err();
        assert_eq!(err.code, SERVER_ERROR);
        std::fs::remove_dir_all(&app.data_home).ok();
    }

    #[tokio::test]
    async fn agents_cannot_read_or_set_pictures() {
        let (app, id) = app_with_agent("Forge");
        let agent = Peer::Agent(id.clone());
        for method in [
            "agents.avatar_image_set",
            "agents.avatar_image_get",
            "agents.avatar_image_clear",
        ] {
            let err = dispatch(&app, &agent, method, json!({ "id": id })).await.unwrap_err();
            assert_eq!(err.code, crate::rpc::UNAUTHORIZED, "{method}");
        }
        std::fs::remove_dir_all(&app.data_home).ok();
    }
}
