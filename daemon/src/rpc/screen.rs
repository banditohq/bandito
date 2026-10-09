//! `screen.*` JSON-RPC methods: the server's virtual desktop (see docs/ARCHITECTURE.md#screen).
//! Paired apps use `screen.start|status|stop|control`. The crew MCP servers on the server use
//! `screen.agent.*`, which only the local socket may call.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SCREEN_ERROR, UNAUTHORIZED, ok, params};
use crate::screen::{
    AgentAction, Button, Controller, DEFAULT_HEIGHT, DEFAULT_SCROLL, DEFAULT_WIDTH, DEFAULT_WORKSPACE, Direction,
    MAX_SCROLL, ScreenError, validate_workspace,
};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct WorkspaceParams {
    workspace: Option<String>,
}

#[derive(Deserialize)]
struct StartParams {
    workspace: Option<String>,
    width: Option<u32>,
    height: Option<u32>,
}

#[derive(Deserialize)]
struct ControlParams {
    workspace: Option<String>,
    holder: String,
}

#[derive(Deserialize)]
struct ClickParams {
    x: u32,
    y: u32,
    button: Option<String>,
    #[serde(default)]
    double: bool,
}

#[derive(Deserialize)]
struct PointParams {
    x: u32,
    y: u32,
}

#[derive(Deserialize)]
struct TextParams {
    text: String,
}

#[derive(Deserialize)]
struct KeysParams {
    keys: String,
}

#[derive(Deserialize)]
struct ScrollParams {
    direction: String,
    amount: Option<u32>,
}

#[derive(Deserialize)]
struct LaunchParams {
    command: String,
}

/// Answers `screen.*` methods. `rpc::dispatch` has already refused anonymous peers.
pub async fn dispatch(app: &App, peer: &Peer, method: &str, p: Value) -> RpcResult {
    let screens = &app.screens;
    match method {
        "screen.start" => {
            let r: StartParams = params(p)?;
            let status = screens
                .start(
                    &workspace_or_default(r.workspace)?,
                    r.width.unwrap_or(DEFAULT_WIDTH),
                    r.height.unwrap_or(DEFAULT_HEIGHT),
                )
                .await
                .map_err(screen_error)?;
            ok(status)
        }
        "screen.status" => {
            let r: WorkspaceParams = params(p)?;
            let status = screens
                .status(&workspace_or_default(r.workspace)?)
                .await
                .map_err(screen_error)?;
            ok(status)
        }
        "screen.stop" => {
            let r: WorkspaceParams = params(p)?;
            screens
                .stop(&workspace_or_default(r.workspace)?)
                .await
                .map_err(screen_error)?;
            ok(json!({}))
        }
        "screen.control" => {
            let r: ControlParams = params(p)?;
            let holder = parse_holder(&r.holder)?;
            let status = screens
                .control(&workspace_or_default(r.workspace)?, holder)
                .await
                .map_err(screen_error)?;
            ok(status)
        }
        _ if method.starts_with("screen.agent.") => {
            if !matches!(peer, Peer::Agent(_)) {
                return Err(RpcError::new(
                    UNAUTHORIZED,
                    "screen agent calls only come from agents on the server",
                ));
            }
            let action = parse_action(method, &p)?;
            let result = screens
                .agent_action(DEFAULT_WORKSPACE, action)
                .await
                .map_err(screen_error)?;
            ok(result)
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// The workspace a call names, or `shared`. A bad name is `INVALID_PARAMS`.
fn workspace_or_default(workspace: Option<String>) -> Result<String, RpcError> {
    let name = workspace.unwrap_or_else(|| DEFAULT_WORKSPACE.to_string());
    validate_workspace(&name).map_err(screen_error)?;
    Ok(name)
}

fn invalid(message: &str) -> RpcError {
    RpcError::new(INVALID_PARAMS, message)
}

/// Turns the parameters of one `screen.agent.*` call into an action. Bad values are `INVALID_PARAMS`.
pub fn parse_action(method: &str, p: &Value) -> Result<AgentAction, RpcError> {
    let name = method.strip_prefix("screen.agent.").unwrap_or("");
    Ok(match name {
        "screenshot" => AgentAction::Screenshot,
        "click" => {
            let r: ClickParams = params(p.clone())?;
            AgentAction::Click {
                x: r.x,
                y: r.y,
                button: parse_button(r.button.as_deref())?,
                double: r.double,
            }
        }
        "move" => {
            let r: PointParams = params(p.clone())?;
            AgentAction::Move { x: r.x, y: r.y }
        }
        "type" => {
            let r: TextParams = params(p.clone())?;
            if r.text.is_empty() {
                return Err(invalid("text must not be empty"));
            }
            AgentAction::Type { text: r.text }
        }
        "key" => {
            let r: KeysParams = params(p.clone())?;
            let keys = r.keys.trim();
            if keys.is_empty() {
                return Err(invalid("keys must not be empty"));
            }
            AgentAction::Key { keys: keys.to_string() }
        }
        "scroll" => {
            let r: ScrollParams = params(p.clone())?;
            let amount = r.amount.unwrap_or(DEFAULT_SCROLL);
            if !(1..=MAX_SCROLL).contains(&amount) {
                return Err(invalid("amount must be from 1 to 20"));
            }
            AgentAction::Scroll {
                direction: parse_direction(&r.direction)?,
                amount,
            }
        }
        "launch" => {
            let r: LaunchParams = params(p.clone())?;
            let command = r.command.trim();
            if command.is_empty() {
                return Err(invalid("command must not be empty"));
            }
            AgentAction::Launch {
                command: command.to_string(),
            }
        }
        _ => return Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    })
}

fn parse_button(button: Option<&str>) -> Result<Button, RpcError> {
    match button {
        None | Some("left") => Ok(Button::Left),
        Some("middle") => Ok(Button::Middle),
        Some("right") => Ok(Button::Right),
        Some(_) => Err(invalid("button must be left, right or middle")),
    }
}

fn parse_direction(direction: &str) -> Result<Direction, RpcError> {
    match direction {
        "up" => Ok(Direction::Up),
        "down" => Ok(Direction::Down),
        "left" => Ok(Direction::Left),
        "right" => Ok(Direction::Right),
        _ => Err(invalid("direction must be up, down, left or right")),
    }
}

/// A failed screen call as an RPC error: `SCREEN_ERROR` with `data.reason`, or `INVALID_PARAMS`.
pub fn screen_error(e: ScreenError) -> RpcError {
    let message = e.to_string();
    let data = match &e {
        ScreenError::InvalidArgs(_) => return RpcError::new(INVALID_PARAMS, message),
        ScreenError::MissingComponent(component) => {
            json!({ "reason": "missing_component", "component": component })
        }
        other => json!({ "reason": other.reason() }),
    };
    RpcError::with_data(SCREEN_ERROR, message, data)
}

/// `user`, `agent` or `none` (nobody), as sent in `screen.control`.
pub fn parse_holder(s: &str) -> Result<Option<Controller>, RpcError> {
    match s {
        "user" => Ok(Some(Controller::User)),
        "agent" => Ok(Some(Controller::Agent)),
        "none" => Ok(None),
        _ => Err(invalid("holder must be user, agent or none")),
    }
}

#[cfg(test)]
mod tests {
    use super::super::features;
    use super::*;
    use crate::hub::Hub;
    use crate::store::Store;
    use crate::supervisor::{Runtimes, Supervisor};
    use serde_json::json;
    use std::sync::Arc;

    fn app() -> Arc<App> {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        App::new(sup, std::env::temp_dir().join("bandito-screen-rpc-tests"))
    }

    #[test]
    fn agent_calls_read_each_tool_and_its_defaults() {
        assert_eq!(
            parse_action("screen.agent.screenshot", &json!({})).unwrap(),
            AgentAction::Screenshot
        );
        assert_eq!(
            parse_action("screen.agent.click", &json!({"x": 3, "y": 4})).unwrap(),
            AgentAction::Click {
                x: 3,
                y: 4,
                button: Button::Left,
                double: false
            }
        );
        assert_eq!(
            parse_action(
                "screen.agent.click",
                &json!({"x": 3, "y": 4, "button": "right", "double": true})
            )
            .unwrap(),
            AgentAction::Click {
                x: 3,
                y: 4,
                button: Button::Right,
                double: true
            }
        );
        assert_eq!(
            parse_action("screen.agent.move", &json!({"x": 1, "y": 2})).unwrap(),
            AgentAction::Move { x: 1, y: 2 }
        );
        assert_eq!(
            parse_action("screen.agent.type", &json!({"text": "hi"})).unwrap(),
            AgentAction::Type { text: "hi".into() }
        );
        assert_eq!(
            parse_action("screen.agent.key", &json!({"keys": "ctrl+l"})).unwrap(),
            AgentAction::Key { keys: "ctrl+l".into() }
        );
        assert_eq!(
            parse_action("screen.agent.scroll", &json!({"direction": "up"})).unwrap(),
            AgentAction::Scroll {
                direction: Direction::Up,
                amount: DEFAULT_SCROLL
            }
        );
        assert_eq!(
            parse_action("screen.agent.scroll", &json!({"direction": "left", "amount": 20})).unwrap(),
            AgentAction::Scroll {
                direction: Direction::Left,
                amount: MAX_SCROLL
            }
        );
        assert_eq!(
            parse_action("screen.agent.launch", &json!({"command": "firefox"})).unwrap(),
            AgentAction::Launch {
                command: "firefox".into()
            }
        );
    }

    #[test]
    fn bad_agent_calls_are_invalid_params() {
        for (method, p) in [
            ("screen.agent.click", json!({"x": 3})),
            ("screen.agent.click", json!({"x": -1, "y": 2})),
            ("screen.agent.click", json!({"x": 1, "y": 2, "button": "wheel"})),
            ("screen.agent.move", json!({"x": "1", "y": 2})),
            ("screen.agent.type", json!({"text": ""})),
            ("screen.agent.key", json!({"keys": "  "})),
            ("screen.agent.scroll", json!({"direction": "diagonal"})),
            ("screen.agent.scroll", json!({"direction": "up", "amount": 0})),
            (
                "screen.agent.scroll",
                json!({"direction": "up", "amount": MAX_SCROLL + 1}),
            ),
            ("screen.agent.launch", json!({"command": ""})),
        ] {
            let err = parse_action(method, &p).unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{method} {p}");
        }
        let err = parse_action("screen.agent.fly", &json!({})).unwrap_err();
        assert_eq!(err.code, METHOD_NOT_FOUND);
    }

    #[test]
    fn screen_errors_carry_a_reason_and_the_screen_code() {
        let e = screen_error(ScreenError::Unsupported);
        assert_eq!(e.code, SCREEN_ERROR);
        assert_eq!(e.data, Some(json!({"reason": "unsupported"})));

        let e = screen_error(ScreenError::MissingComponent("xdotool"));
        assert_eq!(e.code, SCREEN_ERROR);
        assert_eq!(
            e.data,
            Some(json!({"reason": "missing_component", "component": "xdotool"}))
        );

        let e = screen_error(ScreenError::StartFailed("Xvfb exited".into()));
        assert_eq!(e.code, SCREEN_ERROR);
        assert_eq!(e.data, Some(json!({"reason": "start_failed"})));
        assert!(e.message.contains("Xvfb exited"), "{}", e.message);

        let e = screen_error(ScreenError::UserControls);
        assert_eq!(e.code, SCREEN_ERROR);
        assert_eq!(e.data, Some(json!({"reason": "user_controls"})));
        assert_eq!(
            e.message,
            "The user is controlling the screen. Wait or ask them to hand it back."
        );

        let e = screen_error(ScreenError::InvalidArgs("workspace is empty".into()));
        assert_eq!(e.code, INVALID_PARAMS);
    }

    #[test]
    fn holder_is_user_agent_or_none() {
        assert_eq!(parse_holder("user").unwrap(), Some(Controller::User));
        assert_eq!(parse_holder("agent").unwrap(), Some(Controller::Agent));
        assert_eq!(parse_holder("none").unwrap(), None);
        assert_eq!(parse_holder("me").unwrap_err().code, INVALID_PARAMS);
    }

    #[test]
    fn screen_feature_is_offered_on_linux_only() {
        assert_eq!(features().contains(&"screen"), cfg!(target_os = "linux"));
        assert!(features().contains(&"host"));
    }

    #[test]
    fn default_screen_size_and_workspace() {
        assert_eq!((DEFAULT_WIDTH, DEFAULT_HEIGHT), (1600, 1000));
        assert_eq!(DEFAULT_WORKSPACE, "shared");
        assert!(validate_workspace(DEFAULT_WORKSPACE).is_ok());
    }

    #[cfg(not(target_os = "linux"))]
    #[tokio::test]
    async fn screen_methods_say_unsupported_off_linux() {
        let err = dispatch(&app(), &Peer::Local, "screen.status", json!({}))
            .await
            .unwrap_err();
        assert_eq!(err.code, SCREEN_ERROR);
        assert_eq!(err.data, Some(json!({"reason": "unsupported"})));
        let err = dispatch(
            &app(),
            &Peer::Agent("agent-a".into()),
            "screen.agent.screenshot",
            json!({}),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, SCREEN_ERROR);
    }

    #[tokio::test]
    async fn unknown_screen_method_is_not_found() {
        let err = dispatch(&app(), &Peer::Local, "screen.fly", json!({}))
            .await
            .unwrap_err();
        assert_eq!(err.code, METHOD_NOT_FOUND);
    }
}
