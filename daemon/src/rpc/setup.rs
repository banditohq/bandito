//! `setup.*` JSON-RPC methods: what this server lacks for its features, and installing it.
//! The logic is in `crate::setup`. See docs/ARCHITECTURE.md#setup.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, RpcError, RpcResult, SETUP_ERROR, ok, params};
use crate::setup::InstallError;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct InstallParams {
    components: Vec<String>,
}

#[derive(Deserialize)]
struct JobParams {
    job_id: String,
    #[serde(default)]
    from: u64,
}

/// Answers `setup.*` methods. `rpc::dispatch` has already refused anonymous peers.
pub async fn dispatch(app: &App, method: &str, p: Value) -> RpcResult {
    match method {
        "setup.status" => ok(app.setup.status().await),
        "setup.install" => {
            let InstallParams { components } = params(p)?;
            let job_id = app.setup.start_install(&components).map_err(install_error)?;
            ok(json!({ "job_id": job_id }))
        }
        "setup.job" => {
            let JobParams { job_id, from } = params(p)?;
            let snapshot = app.setup.job(&job_id, from).ok_or_else(|| {
                RpcError::with_data(SETUP_ERROR, "not_found: no such job", json!({ "reason": "not_found" }))
            })?;
            ok(snapshot)
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

fn install_error(e: InstallError) -> RpcError {
    match e {
        InstallError::Empty => RpcError::new(INVALID_PARAMS, "components is empty"),
        InstallError::UnknownComponent(id) => RpcError::new(INVALID_PARAMS, format!("unknown component {id}")),
        InstallError::Busy => RpcError::with_data(
            SETUP_ERROR,
            "busy: another install is running",
            json!({ "reason": "busy" }),
        ),
    }
}
