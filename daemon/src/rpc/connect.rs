//! Connect requests: an agent asks the person to connect a catalog service (`integrations.agent.request`), and the
//! person answers with the normal connection from the catalog or declines (`integrations.request_decline`).
//! A request ends as connected only when the connection that was started from its card finishes: the card's Connect
//! hands the request id to `oauth_begin`, `device_begin` or `integrations.add` (`connect_request_id`).
//! See docs/ARCHITECTURE.md#connect-requests.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::event::{AgentChange, ConnectEnd, EventBody, Source};
use crate::hub::Hub;
use crate::integrations;
use crate::store::{Integration, IntegrationAuth, now_ms};
use crate::supervisor::{Inbound, Supervisor};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::watch;

/// How long `integrations.agent.request` waits for the person: as long as a form does.
pub const WAIT: Duration = super::chat::FORM_WAIT;

/// The longest reason that is kept, in characters.
const REASON_CHARS: usize = 400;

/// How many similar ids an unknown-service error names.
const SIMILAR: usize = 5;

/// Most requests one agent may have waiting.
pub const MAX_PENDING: usize = 3;

/// How a request ended, as the waiting call tells the agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Ending {
    Declined,
    Expired,
    /// The service got connected, but the person keeps it off this agent.
    NotAllowed,
    Connected {
        integration: String,
    },
}

struct Open {
    agent_id: String,
    service: String,
    tx: watch::Sender<Option<Ending>>,
}

/// A connection started from a card: which request it closes when it succeeds, and whether it makes the row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bound {
    pub request_id: String,
    pub created: bool,
}

#[derive(Default)]
struct Tables {
    open: HashMap<String, Open>,
    /// Browser sign-ins in progress, by `oauth:<state>`.
    bound: HashMap<String, Bound>,
}

/// The requests that wait for the person, by request id. Lives as long as the daemon: after a restart no call waits
/// any more, and [`crate::supervisor::Supervisor::recover`] ends the cards that were left open.
#[derive(Clone, Default)]
pub struct Requests {
    tables: Arc<Mutex<Tables>>,
}

impl Requests {
    fn lock(&self) -> std::sync::MutexGuard<'_, Tables> {
        // A poisoned lock only means another thread panicked: the tables are still whole.
        self.tables.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The waiting request of this agent for this service, which a repeated ask joins; else a new one (`true`).
    /// Over [`MAX_PENDING`] waiting ones the agent gets `None`.
    fn join_or_begin(&self, agent_id: &str, service: &str) -> Option<(String, bool, watch::Receiver<Option<Ending>>)> {
        let mut t = self.lock();
        if let Some((id, open)) = t
            .open
            .iter()
            .find(|(_, o)| o.agent_id == agent_id && o.service == service)
        {
            return Some((id.clone(), false, open.tx.subscribe()));
        }
        if t.open.values().filter(|o| o.agent_id == agent_id).count() >= MAX_PENDING {
            return None;
        }
        let id = crate::store::new_id();
        let (tx, rx) = watch::channel(None);
        t.open.insert(
            id.clone(),
            Open {
                agent_id: agent_id.to_string(),
                service: service.to_string(),
                tx,
            },
        );
        Some((id, true, rx))
    }

    /// Takes a request out. Only one caller gets it: whoever ends a request does it once. The connections bound to
    /// it are forgotten.
    fn take(&self, id: &str) -> Option<Open> {
        let mut t = self.lock();
        let open = t.open.remove(id)?;
        t.bound.retain(|_, b| b.request_id != id);
        Some(open)
    }

    /// The agent and the service of a request that still waits.
    pub fn pending(&self, id: &str) -> Option<(String, String)> {
        self.lock()
            .open
            .get(id)
            .map(|o| (o.agent_id.clone(), o.service.clone()))
    }

    /// Remembers that a browser sign-in (`state`) was started from the card of a request.
    pub fn bind_oauth(&self, state: &str, bound: Bound) {
        self.lock().bound.insert(format!("oauth:{state}"), bound);
    }

    /// The card a browser sign-in was started from, once: the sign-in succeeded.
    pub fn take_oauth(&self, state: &str) -> Option<Bound> {
        self.lock().bound.remove(&format!("oauth:{state}"))
    }

    /// The sign-in was cancelled or ran out.
    pub fn forget_oauth(&self, state: &str) {
        self.lock().bound.remove(&format!("oauth:{state}"));
    }

    /// How many requests wait (for tests).
    pub fn len(&self) -> usize {
        self.lock().open.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// The last call that waited for a request went away: the request is taken out. `None` when others still wait,
    /// or it was over.
    fn abandon(&self, id: &str) -> Option<Open> {
        {
            let t = self.lock();
            // Our own receiver is still alive while this runs.
            if t.open.get(id)?.tx.receiver_count() > 1 {
                return None;
            }
        }
        self.take(id)
    }
}

fn end_status(ending: &Ending) -> ConnectEnd {
    match ending {
        Ending::Declined => ConnectEnd::Declined,
        Ending::Expired | Ending::NotAllowed => ConnectEnd::Expired,
        Ending::Connected { .. } => ConnectEnd::Connected,
    }
}

/// Ends a request that was taken out: the card closes in the feed, and the calls that wait wake.
fn finish(hub: &Hub, id: &str, open: Open, ending: Ending) {
    let integration = match &ending {
        Ending::Connected { integration } => Some(integration.clone()),
        _ => None,
    };
    hub.emit(
        &open.agent_id,
        EventBody::IntegrationRequestEnded {
            request_id: id.to_string(),
            status: end_status(&ending),
            integration,
        },
    );
    let _ = open.tx.send(Some(ending));
}

/// Ends the request as expired when the last call that waits for it goes away (the agent's connection closed).
struct ExpireOnDrop {
    requests: Requests,
    hub: Hub,
    request_id: String,
}

impl Drop for ExpireOnDrop {
    fn drop(&mut self) {
        if let Some(open) = self.requests.abandon(&self.request_id) {
            finish(&self.hub, &self.request_id, open, Ending::Expired);
        }
    }
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
            request(app, a, WAIT).await
        }
        "integrations.request_decline" => {
            let d: DeclineParams = params(p)?;
            match app.connects.take(&d.request_id) {
                Some(open) => {
                    finish(app.sup.hub(), &d.request_id, open, Ending::Declined);
                    ok(json!({}))
                }
                None => Err(RpcError::new(INVALID_PARAMS, "already_answered")),
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

/// Whether the row works: enabled, and signed in when it needs a sign-in.
pub fn works(app: &App, row: &Integration) -> Result<bool, RpcError> {
    if !row.enabled {
        return Ok(false);
    }
    let store = &app.sup.hub().store;
    Ok(match row.auth {
        IntegrationAuth::Oauth => {
            crate::mcp_oauth::status(store, &row.id, now_ms())
                .map_err(server)?
                .status
                == "connected"
        }
        IntegrationAuth::Device => {
            crate::mcp_oauth::device::status(store, &row.id).map_err(server)?.status == "connected"
        }
        IntegrationAuth::None => true,
    })
}

/// Whether the agent's list of integrations lets it use the row (`None` = every enabled one).
fn agent_has(app: &App, agent_id: &str, row_id: &str) -> Result<bool, RpcError> {
    let agent = app
        .sup
        .hub()
        .store
        .agent_get(agent_id)
        .map_err(server)?
        .ok_or_else(|| RpcError::new(SERVER_ERROR, format!("no agent {agent_id}")))?;
    Ok(agent.integrations.is_none_or(|ids| ids.iter().any(|i| i == row_id)))
}

/// Checks that a connection started with `connect_request_id` is for the service of that request. `Ok(false)`: the
/// request is over already (an old card): the connection goes on, and closes nothing.
pub fn check_bind(app: &App, request_id: &str, row: &Integration) -> Result<bool, RpcError> {
    let Some((_, service)) = app.connects.pending(request_id) else {
        return Ok(false);
    };
    let templates = integrations::catalog_templates();
    if integrations::template_id_of(row, &templates) != Some(service.as_str()) {
        return Err(RpcError::new(INVALID_PARAMS, "that request is for another service"));
    }
    Ok(true)
}

/// Gives the agent the integration the person just connected for it, and renews its session (from the next turn on).
async fn grant(sup: &Supervisor, agent_id: &str, integration_id: &str) -> anyhow::Result<()> {
    if sup.hub().store.agent_integration_add(agent_id, integration_id)? {
        sup.hub().emit(
            agent_id,
            EventBody::AgentChanged {
                action: AgentChange::Updated,
            },
        );
    }
    sup.reload(agent_id, None).await;
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
        via_button: false,
        schedule: None,
    }
}

/// The connection started from the card of `request_id` has succeeded with `row`: the agent gets the service and is
/// told. `created` is whether that connection made the row; a row that was there already stays off an agent whose
/// list leaves it out. Does nothing when the request is over.
pub async fn complete(sup: &Arc<Supervisor>, requests: &Requests, request_id: &str, row: &Integration, created: bool) {
    let Some(open) = requests.take(request_id) else {
        return;
    };
    let agent_id = open.agent_id.clone();
    let allowed = created
        || sup
            .hub()
            .store
            .agent_get(&agent_id)
            .ok()
            .flatten()
            .is_some_and(|a| a.integrations.is_none_or(|ids| ids.contains(&row.id)));
    let ending = if !allowed {
        Ending::NotAllowed
    } else {
        match grant(sup, &agent_id, &row.id).await {
            Ok(()) => Ending::Connected {
                integration: row.name.clone(),
            },
            Err(e) => {
                tracing::warn!(agent = agent_id, "grant after connect: {e:#}");
                Ending::Expired
            }
        }
    };
    let connected = matches!(ending, Ending::Connected { .. });
    finish(sup.hub(), request_id, open, ending);
    if connected {
        // The tools load with the next turn; a hidden message starts it once this one is over.
        if let Err(e) = sup.send(&agent_id, resume_message(&row.name)).await {
            tracing::warn!(agent = agent_id, "resume after connect: {e:#}");
        }
    }
}

fn answer(ending: &Ending, service: &str) -> Value {
    match ending {
        Ending::Declined => json!({ "status": "declined" }),
        Ending::Expired => json!({ "status": "expired" }),
        Ending::NotAllowed => json!({
            "status": "not_allowed",
            "service": service,
            "hint": "The person connected the service but keeps it off for you. Ask them to turn it on in your settings.",
        }),
        Ending::Connected { integration } => json!({
            "status": "connected",
            "integration": integration,
            "note": "Its tools load when your session restarts after this turn. Finish this turn with a one-line status; Bandito will message you to continue.",
        }),
    }
}

/// `integrations.agent.request`: see the module docs. `wait` is a parameter so that tests are quick.
async fn request(app: &App, a: RequestParams, wait: Duration) -> RpcResult {
    let hub = app.sup.hub().clone();
    if hub.store.agent_get(&a.agent_id).map_err(server)?.is_none() {
        return Err(RpcError::new(SERVER_ERROR, format!("no agent {}", a.agent_id)));
    }
    let (service, _name) = find_service(&a.service)?;
    let templates = integrations::catalog_templates();

    // The person's rows of this service. One that the agent's own list leaves out is the person's decision: no card,
    // and a connection made later does not change it.
    let rows: Vec<Integration> = hub
        .store
        .integration_list()
        .map_err(server)?
        .into_iter()
        .filter(|r| integrations::template_id_of(r, &templates) == Some(service.as_str()))
        .collect();
    for row in &rows {
        if !agent_has(app, &a.agent_id, &row.id)? {
            return ok(answer(&Ending::NotAllowed, &service));
        }
    }
    for row in &rows {
        if works(app, row)? {
            return ok(json!({ "status": "connected", "integration": row.name }));
        }
    }

    let reason: Option<String> = a
        .reason
        .as_deref()
        .map(|r| r.trim().chars().take(REASON_CHARS).collect::<String>())
        .filter(|r| !r.is_empty());
    let Some((request_id, fresh, mut rx)) = app.connects.join_or_begin(&a.agent_id, &service) else {
        return Err(RpcError::new(INVALID_PARAMS, "too_many_requests"));
    };
    let _guard = ExpireOnDrop {
        requests: app.connects.clone(),
        hub: hub.clone(),
        request_id: request_id.clone(),
    };
    if fresh {
        hub.emit(
            &a.agent_id,
            EventBody::IntegrationRequested {
                request_id: request_id.clone(),
                service: service.clone(),
                reason,
            },
        );
    }

    let deadline = tokio::time::Instant::now() + wait;
    loop {
        if let Some(ending) = rx.borrow().clone() {
            return ok(answer(&ending, &service));
        }
        tokio::select! {
            changed = rx.changed() => {
                if changed.is_err() {
                    return ok(answer(&Ending::Expired, &service));
                }
            }
            _ = tokio::time::sleep_until(deadline) => {
                match app.connects.take(&request_id) {
                    Some(open) => finish(&hub, &request_id, open, Ending::Expired),
                    // Another answer is being written: wait for it.
                    None => { let _ = rx.changed().await; }
                }
                let ending = rx.borrow().clone().unwrap_or(Ending::Expired);
                return ok(answer(&ending, &service));
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

    const LONG: Duration = Duration::from_secs(20);

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

    /// The rows the catalog's no-sign-in services would be added with.
    fn row_json(name: &str) -> Value {
        let arg = match name {
            "fetch" => "mcp-server-fetch",
            "time" => "mcp-server-time",
            _ => "mcp-server-git",
        };
        json!({ "name": name, "kind": "stdio", "command": "uvx", "args": [arg] })
    }

    fn add_row(app: &App, name: &str, enabled: bool) -> Integration {
        let mut row = row_json(name);
        row["enabled"] = json!(enabled);
        app.sup
            .hub()
            .store
            .integration_create(serde_json::from_value(row).unwrap())
            .unwrap()
    }

    async fn owner_add(app: &App, name: &str, request: Option<&str>) -> RpcResult {
        let mut row = row_json(name);
        if let Some(id) = request {
            row["connect_request_id"] = json!(id);
        }
        super::super::dispatch(app, &Peer::Local, "integrations.add", row).await
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

    /// An agent's call that waits, and the id of its card once the card is in the feed.
    async fn ask(
        app: &Arc<App>,
        agent: &str,
        service: &str,
        wait: Duration,
    ) -> (tokio::task::JoinHandle<RpcResult>, String) {
        let handle = {
            let app = app.clone();
            let p = params_for(agent, service);
            tokio::spawn(async move { request(&app, p, wait).await })
        };
        for _ in 0..500 {
            if let Some(card) = asked(app, agent).into_iter().find(|c| c.1 == service) {
                return (handle, card.0);
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("no card for {service}");
    }

    #[tokio::test]
    async fn a_service_already_connected_answers_at_once_without_a_card() {
        let app = app();
        let id = agent(&app, None);
        add_row(&app, "fetch", true);
        let got = request(&app, params_for(&id, "fetch"), LONG).await.unwrap();
        assert_eq!(got, json!({ "status": "connected", "integration": "fetch" }));
        assert!(asked(&app, &id).is_empty());
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn a_row_the_agents_list_leaves_out_is_not_allowed_whatever_state_it_is_in_and_names_the_catalog_id() {
        let app = app();
        let id = agent(&app, Some(vec![]));
        let row = add_row(&app, "fetch", true);
        let got = request(&app, params_for(&id, "fetch"), LONG).await.unwrap();
        assert_eq!(got["status"], "not_allowed");
        // The catalog id, not the name of the person's row.
        assert_eq!(got["service"], "fetch");
        assert!(got.get("integration").is_none());
        // Turned off for the agent on purpose, and turned off in general: the same, with no card.
        app.sup
            .hub()
            .store
            .integration_update(
                &row.id,
                crate::store::IntegrationPatch {
                    enabled: Some(false),
                    ..Default::default()
                },
            )
            .unwrap();
        let again = request(&app, params_for(&id, "fetch"), LONG).await.unwrap();
        assert_eq!(again["status"], "not_allowed");
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
        let err = request(&app, params_for(&id, "gi"), LONG).await.unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("github (GitHub)"), "{}", err.message);
        assert!(err.message.contains("gitlab"), "{}", err.message);
        let err = request(&app, params_for(&id, "no-such-thing"), LONG).await.unwrap_err();
        assert!(err.message.contains("the catalog has:"), "{}", err.message);
        assert!(asked(&app, &id).is_empty());
        // A name in any case finds its service.
        assert_eq!(find_service(" GitHub ").unwrap().0, "github");
    }

    #[tokio::test]
    async fn the_connection_started_from_the_card_ends_it_connected_and_gives_the_agent_access() {
        let app = app();
        let id = agent(&app, Some(vec![]));
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
        let cards = asked(&app, &id);
        assert_eq!(cards.len(), 1);
        assert_eq!(cards[0].2.as_deref(), Some("to read your issues"));

        let made = owner_add(&app, "fetch", Some(&request_id)).await.unwrap();
        let got = waiting.await.unwrap().unwrap();
        assert_eq!(got["status"], "connected");
        assert_eq!(got["integration"], "fetch");
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Connected, Some("fetch".into()))]);
        assert!(app.connects.is_empty());
        let after = app.sup.hub().store.agent_get(&id).unwrap().unwrap();
        assert_eq!(after.integrations, Some(vec![made["id"].as_str().unwrap().to_string()]));
    }

    #[tokio::test]
    async fn a_connection_made_elsewhere_neither_closes_the_card_nor_gives_access() {
        let app = app();
        let id = agent(&app, Some(vec![]));
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
        // The Marketplace adds the same service: no request id.
        owner_add(&app, "fetch", None).await.unwrap();
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(!waiting.is_finished());
        assert_eq!(app.connects.len(), 1);
        assert!(ends(&app, &id).is_empty());
        assert_eq!(
            app.sup.hub().store.agent_get(&id).unwrap().unwrap().integrations,
            Some(vec![])
        );
        // A card that was over (or never was) closes nothing either.
        owner_add(&app, "time", Some("no-such-request")).await.unwrap();
        assert_eq!(app.connects.len(), 1);
        let open = app.connects.take(&request_id).unwrap();
        finish(app.sup.hub(), &request_id, open, Ending::Declined);
        assert_eq!(waiting.await.unwrap().unwrap(), json!({ "status": "declined" }));
    }

    #[tokio::test]
    async fn a_connection_for_another_service_is_refused() {
        let app = app();
        let id = agent(&app, None);
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
        let err = owner_add(&app, "time", Some(&request_id)).await.unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(app.sup.hub().store.integration_list().unwrap().is_empty());
        assert!(!waiting.is_finished());
        waiting.abort();
    }

    #[tokio::test]
    async fn a_row_that_was_there_stays_off_an_agent_whose_list_leaves_it_out() {
        let app = app();
        let id = agent(&app, None);
        let row = add_row(&app, "fetch", false);
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
        // The person leaves the row off this agent while the card waits, then repairs the row from the card.
        app.sup
            .hub()
            .store
            .agent_update(
                &id,
                crate::store::AgentPatch {
                    integrations: Some(Some(vec![])),
                    ..Default::default()
                },
            )
            .unwrap();
        let sup = app.sup.clone();
        complete(&sup, &app.connects, &request_id, &row, false).await;
        let got = waiting.await.unwrap().unwrap();
        assert_eq!(got["status"], "not_allowed");
        assert_eq!(got["service"], "fetch");
        assert_eq!(
            app.sup.hub().store.agent_get(&id).unwrap().unwrap().integrations,
            Some(vec![])
        );
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Expired, None)]);
    }

    #[tokio::test]
    async fn a_grant_that_fails_expires_the_card_instead_of_claiming_it_connected() {
        let app = app();
        let id = agent(&app, Some(vec![]));
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
        // The agent is gone by the time the connection finishes.
        app.sup.hub().store.agent_delete(&id).unwrap();
        owner_add(&app, "fetch", Some(&request_id)).await.unwrap();
        assert_eq!(waiting.await.unwrap().unwrap(), json!({ "status": "expired" }));
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Expired, None)]);
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn declining_ends_declined_and_a_second_decline_is_refused() {
        let app = app();
        let id = agent(&app, None);
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
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
        let got = request(&app, params_for(&id, "fetch"), Duration::from_millis(80))
            .await
            .unwrap();
        assert_eq!(got, json!({ "status": "expired" }));
        assert_eq!(ends(&app, &id), vec![(ConnectEnd::Expired, None)]);
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn a_repeated_ask_joins_the_waiting_request_and_the_card_expires_with_its_last_call() {
        let app = app();
        let id = agent(&app, None);
        let (first, request_id) = ask(&app, &id, "fetch", LONG).await;
        let second = {
            let app = app.clone();
            let p = params_for(&id, "fetch");
            tokio::spawn(async move { request(&app, p, LONG).await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(asked(&app, &id).len(), 1, "one card for one service");
        assert_eq!(app.connects.len(), 1);
        // One call goes away: the other still waits for the card.
        first.abort();
        let _ = first.await;
        assert!(ends(&app, &id).is_empty());
        assert!(!second.is_finished());
        // The connection answers the call that is left.
        owner_add(&app, "fetch", Some(&request_id)).await.unwrap();
        assert_eq!(second.await.unwrap().unwrap()["status"], "connected");

        // And the last call that goes away expires a card.
        let (lone, _) = ask(&app, &id, "time", LONG).await;
        lone.abort();
        let _ = lone.await;
        assert_eq!(ends(&app, &id).last(), Some(&(ConnectEnd::Expired, None)));
        assert!(app.connects.is_empty());
    }

    #[tokio::test]
    async fn an_agent_may_have_three_requests_waiting_and_no_more() {
        let app = app();
        let id = agent(&app, None);
        let mut waits = Vec::new();
        for service in ["fetch", "time", "git"] {
            waits.push(ask(&app, &id, service, LONG).await.0);
        }
        let err = request(&app, params_for(&id, "memory"), LONG).await.unwrap_err();
        assert_eq!(err.message, "too_many_requests");
        assert_eq!(asked(&app, &id).len(), 3);
        // Asking again for a service that waits is no new request.
        let again = {
            let app = app.clone();
            let p = params_for(&id, "fetch");
            tokio::spawn(async move { request(&app, p, LONG).await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert_eq!(asked(&app, &id).len(), 3);
        again.abort();
        for w in waits {
            w.abort();
        }
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
        let err = super::super::dispatch(
            &app,
            &Peer::Local,
            "integrations.agent.request",
            json!({ "service": "fetch" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, super::super::UNAUTHORIZED);
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

    #[tokio::test]
    async fn turning_on_a_row_from_the_card_ends_it_connected_but_turning_it_on_elsewhere_does_not() {
        let app = app();
        let id = agent(&app, None);
        let row = add_row(&app, "fetch", false);
        let (waiting, request_id) = ask(&app, &id, "fetch", LONG).await;
        let owner = Peer::Local;
        // Elsewhere (no request id): the card stays.
        super::super::dispatch(
            &app,
            &owner,
            "integrations.update",
            json!({ "id": row.id, "enabled": true }),
        )
        .await
        .unwrap();
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(!waiting.is_finished());
        // From the card: a row that works closes it.
        super::super::dispatch(
            &app,
            &owner,
            "integrations.update",
            json!({ "id": row.id, "enabled": true, "connect_request_id": request_id }),
        )
        .await
        .unwrap();
        assert_eq!(waiting.await.unwrap().unwrap()["status"], "connected");
    }

    #[test]
    fn a_sign_in_started_from_a_card_is_remembered_until_it_is_used_cancelled_or_its_request_ends() {
        let r = Requests::default();
        let (id, _, _rx) = r.join_or_begin("a", "linear").unwrap();
        let bound = Bound {
            request_id: id.clone(),
            created: true,
        };
        r.bind_oauth("s1", bound.clone());
        r.bind_oauth("s2", bound.clone());
        r.bind_oauth("s3", bound.clone());
        assert_eq!(r.take_oauth("s1"), Some(bound));
        assert_eq!(r.take_oauth("s1"), None);
        r.forget_oauth("s2");
        assert_eq!(r.take_oauth("s2"), None);
        // The request ends: what was bound to it goes.
        assert!(r.take(&id).is_some());
        assert_eq!(r.take_oauth("s3"), None);
    }

    #[test]
    fn a_restart_ends_the_cards_that_were_left_open() {
        let app = app();
        let id = agent(&app, None);
        let hub = app.sup.hub();
        for (rid, service) in [("r1", "fetch"), ("r2", "github")] {
            hub.emit(
                &id,
                EventBody::IntegrationRequested {
                    request_id: rid.into(),
                    service: service.into(),
                    reason: None,
                },
            );
        }
        hub.emit(
            &id,
            EventBody::IntegrationRequestEnded {
                request_id: "r2".into(),
                status: ConnectEnd::Declined,
                integration: None,
            },
        );
        assert_eq!(
            hub.store.connect_requests_unresolved().unwrap(),
            vec![(id.clone(), "r1".to_string())]
        );
        app.sup.recover().unwrap();
        assert!(hub.store.connect_requests_unresolved().unwrap().is_empty());
        assert!(ends(&app, &id).contains(&(ConnectEnd::Expired, None)));
    }
}
