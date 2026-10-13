//! `relay.*` JSON-RPC methods (docs/RELAY.md): the owner's app turns Bandito Relay on with the registration it made at
//! bandito.dev, turns it off, and reads its status. Agents may not call them (they are not in `AGENT_METHODS`). The
//! relay secret is never in a reply.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RELAY_ERROR, RpcError, RpcResult, ok, params};
use crate::relay::{Config, RelayError};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct EnableParams {
    relay_url: String,
    sid: String,
    secret: String,
}

fn failure(e: RelayError) -> RpcError {
    RpcError::with_data(RELAY_ERROR, format!("{e}"), json!({ "reason": "relay_failed" }))
}

pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "relay.enable" => {
            let EnableParams {
                relay_url,
                sid,
                secret,
            } = params(p)?;
            let config = Config::validated(&relay_url, &sid, &secret).map_err(|m| RpcError::new(INVALID_PARAMS, m))?;
            ok(app.relay.enable(config).await.map_err(failure)?.to_json())
        }
        "relay.disable" => ok(app.relay.disable().await.map_err(failure)?.to_json()),
        "relay.status" => ok(app.relay.status().to_json()),
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}
