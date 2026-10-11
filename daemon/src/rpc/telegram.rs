//! `telegram.*` JSON-RPC methods: the app sets the bot's token, links chats and changes what a chat gets. Agents may
//! not call them (they are not in `AGENT_METHODS`). The token is never in a reply. A failure carries a stable code in
//! `error.data.reason` and as the first word of the message. See docs/ARCHITECTURE.md#telegram.

use super::{App, METHOD_NOT_FOUND, RpcError, RpcResult, TELEGRAM_ERROR, ok, params};
use crate::telegram::TgError;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct SetTokenParams {
    token: String,
}

#[derive(Deserialize)]
struct ChatParams {
    chat_id: i64,
}

#[derive(Deserialize)]
struct UpdateChatParams {
    chat_id: i64,
    #[serde(default)]
    approvals: Option<bool>,
    #[serde(default)]
    answers: Option<String>,
}

fn failure(e: TgError) -> RpcError {
    RpcError::with_data(
        TELEGRAM_ERROR,
        format!("{}: {}", e.reason, e.message),
        json!({ "reason": e.reason }),
    )
}

pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    let tg = &app.telegram;
    match method {
        "telegram.status" => ok(tg.status().map_err(failure)?),
        "telegram.set_token" => {
            let SetTokenParams { token } = params(p)?;
            ok(tg.set_token(&token).await.map_err(failure)?)
        }
        "telegram.remove_token" => ok(tg.remove_token().await.map_err(failure)?),
        "telegram.link_start" => ok(tg.link_start().map_err(failure)?),
        "telegram.unlink" => {
            let ChatParams { chat_id } = params(p)?;
            ok(tg.unlink(chat_id).await.map_err(failure)?)
        }
        "telegram.update_chat" => {
            let UpdateChatParams {
                chat_id,
                approvals,
                answers,
            } = params(p)?;
            ok(tg
                .update_chat(chat_id, approvals, answers.as_deref())
                .map_err(failure)?)
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::super::{App, Peer, UNAUTHORIZED, dispatch, features};
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use serde_json::json;
    use std::sync::Arc;

    fn app() -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, std::env::temp_dir().join("bandito-telegram-rpc-tests"))
    }

    async fn call(app: &App, method: &str, p: serde_json::Value) -> super::RpcResult {
        dispatch(app, &Peer::Local, method, p).await
    }

    #[test]
    fn the_daemon_advertises_telegram() {
        assert!(features().contains(&"telegram"));
    }

    #[tokio::test]
    async fn an_unconfigured_bot_answers_with_an_empty_status() {
        let app = app();
        let status = call(&app, "telegram.status", json!({})).await.unwrap();
        assert_eq!(
            status,
            json!({ "configured": false, "bot": null, "running": false, "last_error": null, "chats": [] })
        );
    }

    #[tokio::test]
    async fn failures_carry_their_code_as_data_and_as_the_first_word() {
        let app = app();
        let err = call(&app, "telegram.set_token", json!({ "token": "nope" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, super::TELEGRAM_ERROR);
        assert_eq!(err.data, Some(json!({ "reason": "invalid_token" })));
        assert!(err.message.starts_with("invalid_token"), "{}", err.message);
        let err = call(&app, "telegram.link_start", json!({})).await.unwrap_err();
        assert_eq!(err.data, Some(json!({ "reason": "not_configured" })));
        let err = call(&app, "telegram.unlink", json!({ "chat_id": 5 }))
            .await
            .unwrap_err();
        assert_eq!(err.data, Some(json!({ "reason": "no_such_chat" })));
        let err = call(&app, "telegram.update_chat", json!({ "chat_id": 5, "answers": "x" }))
            .await
            .unwrap_err();
        assert_eq!(err.data, Some(json!({ "reason": "invalid_params" })));
        // Missing params are the usual invalid-params error.
        let err = call(&app, "telegram.set_token", json!({})).await.unwrap_err();
        assert_eq!(err.code, super::super::INVALID_PARAMS);
        let err = call(&app, "telegram.nope", json!({})).await.unwrap_err();
        assert_eq!(err.code, super::METHOD_NOT_FOUND);
    }

    #[tokio::test]
    async fn agents_cannot_call_any_telegram_method() {
        let app = app();
        let agent = Peer::Agent("agent-a".into());
        for method in [
            "telegram.status",
            "telegram.set_token",
            "telegram.remove_token",
            "telegram.link_start",
            "telegram.unlink",
            "telegram.update_chat",
        ] {
            let err = dispatch(&app, &agent, method, json!({})).await.unwrap_err();
            assert_eq!(err.code, UNAUTHORIZED, "{method}");
        }
    }

    #[tokio::test]
    async fn the_token_secret_is_hidden_and_cannot_be_touched_from_the_secrets_calls() {
        let app = app();
        app.telegram
            .seed_for_test("123456789:AAH_testtoken_0123456789abcdefghij_xyz", "b_bot", "B");
        let list = call(&app, "secrets.list", json!({})).await.unwrap();
        assert_eq!(list, json!([]));
        let set = call(
            &app,
            "secrets.set",
            json!({ "name": crate::telegram::TOKEN_SECRET, "value": "x", "agents": ["*"] }),
        )
        .await
        .unwrap_err();
        assert_eq!(set.code, super::super::INVALID_PARAMS);
        let del = call(&app, "secrets.delete", json!({ "name": crate::telegram::TOKEN_SECRET }))
            .await
            .unwrap_err();
        assert_eq!(del.code, super::super::INVALID_PARAMS);
        let status = call(&app, "telegram.status", json!({})).await.unwrap().to_string();
        assert!(!status.contains("AAH_"), "{status}");
    }

    #[tokio::test]
    async fn safe_mode_refuses_the_bot() {
        let app = app();
        app.enter_safe_mode("test");
        let err = call(&app, "telegram.status", json!({})).await.unwrap_err();
        assert_eq!(err.code, super::super::SERVER_ERROR);
    }
}
