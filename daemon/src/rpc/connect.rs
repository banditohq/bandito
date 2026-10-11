//! Connect requests: an agent asks the person to connect a catalog service (`integrations.agent.request`), and the
//! person answers with the normal connection from the catalog or declines (`integrations.request_decline`).
//! See docs/ARCHITECTURE.md#connect-requests.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::event::{AgentChange, ConnectEnd, EventBody, Source};
use crate::hub::Hub;
use crate::integrations::{self, Template};
use crate::store::{Integration, IntegrationAuth, now_ms};
use crate::supervisor::Inbound;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;

/// How long `integrations.agent.request` waits for the person: as long as a form does.
pub const WAIT: Duration = super::chat::FORM_WAIT;

/// How often a waiting request looks whether the service got connected, whatever way the person did it.
const POLL: Duration = Duration::from_millis(700);

/// The longest reason that is kept, in characters.
const REASON_CHARS: usize = 400;

/// How many similar ids an unknown-service error names.
const SIMILAR: usize = 5;

/// The requests that wait for the person, by request id. Lives as long as the daemon: after a restart no call waits
/// any more, and [`crate::supervisor::Supervisor::recover`] ends the cards that were left open.
#[derive(Clone, Default)]
pub struct Requests {
    open: Arc<Mutex<HashMap<String, Open>>>,
}

struct Open {
    decline: oneshot::Sender<()>,
}

impl Requests {
    fn begin(&self) -> (String, oneshot::Receiver<()>) {
        let id = crate::store::new_id();
        let (decline, wake) = oneshot::channel();
        self.lock().insert(id.clone(), Open { decline });
        (id, wake)
    }

    /// Takes a request out. Only one caller gets it: whoever ends a request does it once.
    fn take(&self, id: &str) -> Option<Open> {
        self.lock().remove(id)
    }

    /// The person declined: the request ends and the waiting call wakes. `false` when it was over already.
    pub fn decline(&self, id: &str) -> bool {
        match self.take(id) {
            Some(open) => {
                let _ = open.decline.send(());
                true
            }
            None => false,
        }
    }

    /// How many requests wait (for tests).
    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Open>> {
        // A poisoned lock only means another thread panicked: the map is still whole.
        self.open.lock().unwrap_or_else(|e| e.into_inner())
    }
}

/// Ends the request as expired when the call that waits for it goes away (the agent's connection closed).
struct ExpireOnDrop {
    requests: Requests,
    hub: Hub,
    agent_id: String,
    request_id: String,
    armed: bool,
}

impl Drop for ExpireOnDrop {
    fn drop(&mut self) {
        if self.armed && self.requests.take(&self.request_id).is_some() {
            ended(&self.hub, &self.agent_id, &self.request_id, ConnectEnd::Expired, None);
        }
    }
}

fn ended(hub: &Hub, agent_id: &str, request_id: &str, status: ConnectEnd, integration: Option<String>) {
    hub.emit(
        agent_id,
        EventBody::IntegrationRequestEnded {
            request_id: request_id.to_string(),
            status,
            integration,
        },
    );
}

#[derive(Deserialize)]
struct RequestParams {
    agent_id: String,
    service: String,
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Deserialize)]
struct DeclineParams {
    request_id: String,
}

pub async fn dispatch(app: &App, _peer: &Peer, method: &str, p: Value) -> RpcResult {
    match method {
        "integrations.agent.request" => {
            let a: RequestParams = params(p)?;
            request(app, a, WAIT, POLL).await
        }
        "integrations.request_decline" => {
            let d: DeclineParams = params(p)?;
            if app.connects.decline(&d.request_id) {
                ok(json!({}))
            } else {
                Err(RpcError::new(INVALID_PARAMS, "already_answered"))
            }
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

fn server(e: anyhow::Error) -> RpcError {
    RpcError::new(SERVER_ERROR, format!("{e:#}"))
}

/// The catalog entry the agent means: its id, else its id or name in any case. Unknown: an error that lists similar ids.
fn find_service(raw: &str) -> Result<(String, String), RpcError> {
    #[derive(Deserialize)]
    struct Entry {
        id: String,
        name: String,
    }
    let entries: Vec<Entry> = serde_json::from_str(include_str!("../integrations_catalog.json"))
        .map_err(|e| RpcError::new(SERVER_ERROR, format!("catalog: {e}")))?;
    let wanted = raw.trim();
    if let Some(e) = entries.iter().find(|e| e.id == wanted) {
        return Ok((e.id.clone(), e.name.clone()));
    }
    let low = wanted.to_lowercase();
    if !low.is_empty()
        && let Some(e) = entries
            .iter()
            .find(|e| e.id.to_lowercase() == low || e.name.to_lowercase() == low)
    {
        return Ok((e.id.clone(), e.name.clone()));
    }
    let similar: Vec<String> = entries
        .iter()
        .filter(|e| {
            let (id, name) = (e.id.to_lowercase(), e.name.to_lowercase());
            !low.is_empty() && (id.contains(&low) || name.contains(&low) || (id.len() >= 3 && low.contains(&id)))
        })
        .take(SIMILAR)
        .map(|e| format!("{} ({})", e.id, e.name))
        .collect();
    let shown = wanted.chars().take(60).collect::<String>();
    let message = if similar.is_empty() {
        let all: Vec<&str> = entries.iter().map(|e| e.id.as_str()).collect();
        format!("unknown service \"{shown}\"; the catalog has: {}", all.join(", "))
    } else {
        format!("unknown service \"{shown}\"; similar: {}", similar.join(", "))
    };
    Err(RpcError::new(INVALID_PARAMS, message))
}

/// The integration of the service that works: made from its template, enabled, and signed in when it needs a sign-in.
fn ready_row(app: &App, templates: &[Template], service: &str) -> Result<Option<Integration>, RpcError> {
    let store = &app.sup.hub().store;
    let now = now_ms();
    for row in store.integration_list().map_err(server)? {
        if !row.enabled || integrations::template_id_of(&row, templates) != Some(service) {
            continue;
        }
        if row.auth == IntegrationAuth::Oauth
            && crate::mcp_oauth::status(store, &row.id, now).map_err(server)?.status != "connected"
        {
            continue;
        }
        return Ok(Some(row));
    }
    Ok(None)
}

/// Whether the agent's list of integrations lets it use the row (`None` = every enabled one).
fn agent_has(app: &App, agent_id: &str, row: &Integration) -> Result<bool, RpcError> {
    let agent = app
        .sup
        .hub()
        .store
        .agent_get(agent_id)
        .map_err(server)?
        .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {agent_id}")))?;
    Ok(agent.integrations.is_none_or(|ids| ids.contains(&row.id)))
}

/// Gives the agent the integration the person just connected for it, and renews its session (from the next turn on).
async fn grant(app: &App, agent_id: &str, row: &Integration) -> Result<(), RpcError> {
    let store = &app.sup.hub().store;
    if let Some(agent) = store.agent_get(agent_id).map_err(server)?
        && let Some(mut ids) = agent.integrations
        && !ids.contains(&row.id)
    {
        ids.push(row.id.clone());
        let patch = crate::store::AgentPatch {
            integrations: Some(Some(ids)),
            ..Default::default()
        };
        store.agent_update(agent_id, patch).map_err(server)?;
        app.sup.hub().emit(
            agent_id,
            EventBody::AgentChanged {
                action: AgentChange::Updated,
            },
        );
    }
    app.sup.reload(agent_id, None).await;
    Ok(())
}

/// What the agent is told once the new tools can load: it is sent as a hidden message, which waits for the turn that
/// is running to end and starts the next one with the renewed session.
fn resume_message(name: &str) -> Inbound {
    Inbound {
        text: format!(
            "Bandito: {name} is connected now and its tools are loaded in this session. Continue with what you were doing."
        ),
        source: Source::System,
        from_agent: None,
        hops: 0,
        chain: None,
        typed: None,
        command: None,
        reply_to: None,
        attachments: Vec::new(),
        mentions: Vec::new(),
    }
}

/// `integrations.agent.request`: see the module docs. `wait` and `poll` are parameters so that tests are quick.
async fn request(app: &App, a: RequestParams, wait: Duration, poll: Duration) -> RpcResult {
    let hub = app.sup.hub().clone();
    if hub.store.agent_get(&a.agent_id).map_err(server)?.is_none() {
        return Err(RpcError::new(SERVER_ERROR, format!("no agent {}", a.agent_id)));
    }
    let (service, _name) = find_service(&a.service)?;
    let templates = integrations::catalog_templates();

    if let Some(row) = ready_row(app, &templates, &service)? {
        return if agent_has(app, &a.agent_id, &row)? {
            ok(json!({ "status": "connected", "integration": row.name }))
        } else {
            // The person has the service but did not give it to this agent: an agent does not widen its own access.
            ok(json!({
                "status": "not_allowed",
                "integration": row.name,
                "hint": "The person has this service connected but has not turned it on for you. Ask them to enable it in your settings.",
            }))
        };
    }

    let reason: Option<String> = a
        .reason
        .as_deref()
        .map(|r| r.trim().chars().take(REASON_CHARS).collect::<String>())
        .filter(|r| !r.is_empty());
    let (request_id, mut declined) = app.connects.begin();
    let mut guard = ExpireOnDrop {
        requests: app.connects.clone(),
        hub: hub.clone(),
        agent_id: a.agent_id.clone(),
        request_id: request_id.clone(),
        armed: true,
    };
    hub.emit(
        &a.agent_id,
        EventBody::IntegrationRequested {
            request_id: request_id.clone(),
            service: service.clone(),
            reason,
        },
    );

    let deadline = tokio::time::Instant::now() + wait;
    loop {
        tokio::select! {
            _ = &mut declined => {
                // `decline` took the request out already; the call ends it in the feed.
                guard.armed = false;
                ended(&hub, &a.agent_id, &request_id, ConnectEnd::Declined, None);
                return ok(json!({ "status": "declined" }));
            }
            _ = tokio::time::sleep_until(deadline) => {
                if app.connects.take(&request_id).is_none() {
                    // Declined in the same instant: that answer stands.
                    guard.armed = false;
                    ended(&hub, &a.agent_id, &request_id, ConnectEnd::Declined, None);
                    return ok(json!({ "status": "declined" }));
                }
                guard.armed = false;
                ended(&hub, &a.agent_id, &request_id, ConnectEnd::Expired, None);
                return ok(json!({ "status": "expired" }));
            }
            _ = tokio::time::sleep(poll) => {
                let Some(row) = ready_row(app, &templates, &service)? else { continue };
                if app.connects.take(&request_id).is_none() {
                    guard.armed = false;
                    ended(&hub, &a.agent_id, &request_id, ConnectEnd::Declined, None);
                    return ok(json!({ "status": "declined" }));
                }
                guard.armed = false;
                grant(app, &a.agent_id, &row).await?;
                ended(&hub, &a.agent_id, &request_id, ConnectEnd::Connected, Some(row.name.clone()));
                // The tools load with the next turn; a hidden message starts it once this one is over.
                if let Err(e) = app.sup.send(&a.agent_id, resume_message(&row.name)).await {
                    tracing::warn!(agent = a.agent_id, "resume after connect: {e:#}");
                }
                return ok(json!({
                    "status": "connected",
                    "integration": row.name,
                    "note": "Its tools load when your session restarts after this turn. Finish this turn with a one-line status; Bandito will message you to continue.",
                }));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::Event;
    use crate::store::NewAgent;
    use std::time::Duration;

    const QUICK: Duration = Duration::from_millis(20);

    fn app() -> Arc<App> {
        use crate::store::Store;
        use crate::supervisor::{Runtimes, Supervisor};
        let sup = Supervisor::new(
            Hub::new(Arc::new(Store::open_in_memory().unwrap())),
            Runtimes::default(),
            None,
        );
        App::new(
            sup,
            std::env::temp_dir().join(format!("bandito-connect-{}", crate::store::new_id())),
        )
    }

    fn agent(app: &App, integrations: Option<Vec<String>>) -> String {
        let store = &app.sup.hub().store;
        let made = store
            .agent_create(serde_json::from_value::<NewAgent>(json!({ "name": "Scout", "runtime": "claude" })).unwrap())
            .unwrap();
        if integrations.is_some() {
            let patch = crate::store::AgentPatch {
                integrations: Some(integrations),
                ..Default::default()
            };
            store.agent_update(&made.id, patch).unwrap();
        }
        made.id
    }

    fn params_for(agent: &str, service: &str) -> RequestParams {
        RequestParams {
            agent_id: agent.into(),
            service: service.into(),
            reason: Some("to read your issues".into()),
        }
    }

    fn add_fetch(app: &App) -> Integration {
        // `fetch` is a catalog id with no sign-in: a row with that name counts as connected.
        app.sup
            .hub()
            .store
            .integration_create(
                serde_json::from_value(
                    json!({ "name": "fetch", "kind": "stdio", "command": "uvx", "args": ["mcp-server-fetch"] }),
                )
                .unwrap(),
            )
            .unwrap()
    }

    fn events(app: &App, agent: &str) -> Vec<Event> {
        app.sup.hub().store.events_since(0, 1000, Some(agent)).unwrap()
    }

    fn ends(app: &App, agent: &str) -> Vec<(ConnectEnd, Option<String>)> {
        events(app, agent)
            .into_iter()
            .filter_map(|e| match e.body {
                EventBody::IntegrationRequestEnded {
                    status, integration, ..
                } => Some((status, integration)),
                _ => None,
            })
            .collect()
    }

    fn asked(app: &App, agent: &str) -> Vec<(String, String, Option<String>)> {
        events(app, agent)
            .into_iter()
            .filter_map(|e| match e.body {
                EventBody::IntegrationRequested {
                    request_id,
                    service,
                    reason,
                } => Some((request_id, service, reason)),
                _ => None,
            })
            .collect()
    }

    #[tokio::test]
    async fn a_service_already_connected_answers_at_once_without_a_card() {
        let app = app();
        let id = agent(&app, None);
        add_fetch(&app);
        let got = request(&app, params_for(&id, "fetch"), Duration::from_secs(5), QUICK)
            .await
            .unwrap();
        assert_eq!(got, json!({ "status": "connected", "integration": "fetch" }));
        assert!(asked(&app, &id).is_empty());
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn a_connected_service_the_agent_may_not_use_is_not_handed_over() {
        let app = app();
        let id = agent(&app, Some(vec![]));
        add_fetch(&app);
        let got = request(&app, params_for(&id, "fetch"), Duration::from_secs(5), QUICK)
            .await
            .unwrap();
        assert_eq!(got["status"], "not_allowed");
        assert!(asked(&app, &id).is_empty());
        assert_eq!(
            app.sup.hub().store.agent_get(&id).unwrap().unwrap().integrations,
            Some(vec![])
        );
    }

    #[tokio::test]
    async fn an_unknown_id_is_an_error_with_similar_ones() {
        let app = app();
        let id = agent(&app, None);
        let err = request(&app, params_for(&id, "gi"), Duration::from_secs(1), QUICK)
            .await
            .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("github (GitHub)"), "{}", err.message);
        assert!(err.message.contains("gitlab"), "{}", err.message);
        let err = request(&app, params_for(&id, "no-such-thing"), Duration::from_secs(1), QUICK)
            .await
            .unwrap_err();
        assert!(err.message.contains("the catalog has:"), "{}", err.message);
        assert!(asked(&app, &id).is_empty());
        // A name in any case finds its service.
        assert_eq!(find_service(" GitHub ").unwrap().0, "github");
    }

    #[tokio::test]
    async fn connecting_the_template_while_it_waits_ends_connected_and_gives_the_agent_access() {
        let app = app();
        let id = agent(&app, Some(vec![]));
        let waiting = {
            let app = app.clone();
            let id = id.clone();
            tokio::spawn(async move { request(&app, params_for(&id, "fetch"), Duration::from_secs(10), QUICK).await })
        };
        // The card is in the feed while the call waits.
        for _ in 0..200 {
            if !asked(&app, &id).is_empty() {
                break;
            }
            tokio::time::sleep(QUICK).await;
        }
        let cards = asked(&app, &id);
        assert_eq!(cards.len(), 1);
        assert_eq!(
            (cards[0].1.as_str(), cards[0].2.as_deref()),
            ("fetch", Some("to read your issues"))
        );
        assert_eq!(app.connects.len(), 1);

        let row = add_fetch(&app);
        let got = waiting.await.unwrap().unwrap();
        assert_eq!(got["status"], "connected");
        assert_eq!(got["integration"], "fetch");
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Connected, Some("fetch".into()))]);
        assert!(app.connects.is_empty());
        let after = app.sup.hub().store.agent_get(&id).unwrap().unwrap();
        assert_eq!(after.integrations, Some(vec![row.id]));
    }

    #[tokio::test]
    async fn declining_ends_declined_and_a_second_decline_is_refused() {
        let app = app();
        let id = agent(&app, None);
        let waiting = {
            let app = app.clone();
            let id = id.clone();
            tokio::spawn(async move { request(&app, params_for(&id, "fetch"), Duration::from_secs(10), QUICK).await })
        };
        let mut card = None;
        for _ in 0..200 {
            card = asked(&app, &id).pop();
            if card.is_some() {
                break;
            }
            tokio::time::sleep(QUICK).await;
        }
        let request_id = card.unwrap().0;
        let owner = Peer::Local;
        dispatch(
            &app,
            &owner,
            "integrations.request_decline",
            json!({ "request_id": request_id }),
        )
        .await
        .unwrap();
        assert_eq!(waiting.await.unwrap().unwrap(), json!({ "status": "declined" }));
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Declined, None)]);
        let again = dispatch(
            &app,
            &owner,
            "integrations.request_decline",
            json!({ "request_id": request_id }),
        )
        .await
        .unwrap_err();
        assert_eq!(again.message, "already_answered");
    }

    #[tokio::test]
    async fn no_answer_in_time_expires() {
        let app = app();
        let id = agent(&app, None);
        let got = request(&app, params_for(&id, "fetch"), Duration::from_millis(80), QUICK)
            .await
            .unwrap();
        assert_eq!(got, json!({ "status": "expired" }));
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Expired, None)]);
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn a_call_that_goes_away_expires_its_card() {
        let app = app();
        let id = agent(&app, None);
        let waiting = {
            let app = app.clone();
            let id = id.clone();
            tokio::spawn(async move { request(&app, params_for(&id, "fetch"), Duration::from_secs(60), QUICK).await })
        };
        for _ in 0..200 {
            if !asked(&app, &id).is_empty() {
                break;
            }
            tokio::time::sleep(QUICK).await;
        }
        waiting.abort();
        let _ = waiting.await;
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Expired, None)]);
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn agents_may_only_ask_and_the_owner_may_only_decline() {
        let app = app();
        let id = agent(&app, None);
        let me = Peer::Agent(id.clone());
        let err = super::super::dispatch(&app, &me, "integrations.request_decline", json!({ "request_id": "x" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, super::super::UNAUTHORIZED);
        for peer in [Peer::Local] {
            let err = super::super::dispatch(&app, &peer, "integrations.agent.request", json!({ "service": "fetch" }))
                .await
                .unwrap_err();
            assert_eq!(err.code, super::super::UNAUTHORIZED);
        }
        // An agent cannot ask as another agent.
        let err = super::super::dispatch(
            &app,
            &me,
            "integrations.agent.request",
            json!({ "agent_id": "someone-else", "service": "fetch" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, super::super::UNAUTHORIZED);
    }

    #[test]
    fn a_restart_ends_the_cards_that_were_left_open() {
        let app = app();
        let id = agent(&app, None);
        let hub = app.sup.hub();
        hub.emit(
            &id,
            EventBody::IntegrationRequested {
                request_id: "r1".into(),
                service: "fetch".into(),
                reason: None,
            },
        );
        hub.emit(
            &id,
            EventBody::IntegrationRequested {
                request_id: "r2".into(),
                service: "github".into(),
                reason: None,
            },
        );
        ended(hub, &id, "r2", ConnectEnd::Declined, None);
        assert_eq!(
            hub.store.connect_requests_unresolved().unwrap(),
            vec![(id.clone(), "r1".to_string())]
        );
        app.sup.recover().unwrap();
        assert!(hub.store.connect_requests_unresolved().unwrap().is_empty());
        assert!(ends(&app, &id).contains(&(ConnectEnd::Expired, None)));
    }
}
