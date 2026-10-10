use super::fake::{Fake, query_of};
use super::*;
use crate::store::now_ms;
use std::collections::BTreeMap;
use std::io::Write;

fn draft(name: &str, url: &str) -> NewIntegration {
    NewIntegration {
        name: name.into(),
        kind: IntegrationKind::Http,
        command: None,
        args: vec![],
        url: Some(url.into()),
        env: BTreeMap::new(),
        headers: BTreeMap::new(),
        enabled: true,
        auth: IntegrationAuth::None,
    }
}

/// Begin, "open the browser", complete: the whole sign-in for a new integration.
async fn connect(store: &Store, flows: &Flows, fake: &Fake, now: i64) -> Completed {
    let begun = begin(
        store,
        flows,
        "dev1",
        Target::Draft(draft("notion", &fake.url())),
        None,
        now,
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    assert_eq!(state, begun.state);
    complete(store, flows, "dev1", &state, &code, None, now).await.unwrap()
}

fn rig() -> (Store, Flows) {
    (Store::open_in_memory().unwrap(), Flows::default())
}

/// A log writer the tests read back.
#[derive(Clone, Default)]
struct LogBuf(Arc<Mutex<Vec<u8>>>);

impl Write for LogBuf {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for LogBuf {
    type Writer = LogBuf;
    fn make_writer(&'a self) -> LogBuf {
        self.clone()
    }
}

impl LogBuf {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

#[tokio::test]
async fn the_whole_sign_in_stores_tokens_and_fills_the_header() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let done = connect(&store, &flows, &fake, now).await;
    assert!(done.created);
    let row = &done.integration;
    assert_eq!((row.name.as_str(), row.auth), ("notion", IntegrationAuth::Oauth));
    // Registration: a public native client with our redirect address.
    let reg = fake.inner.lock().unwrap().registrations.clone();
    assert_eq!(reg.len(), 1);
    assert_eq!(reg[0]["client_name"], "Bandito");
    assert_eq!(reg[0]["redirect_uris"], json!([REDIRECT_URI]));
    assert_eq!(reg[0]["token_endpoint_auth_method"], "none");
    assert_eq!(reg[0]["grant_types"], json!(["authorization_code", "refresh_token"]));
    // The code was traded with the verifier, the client, our redirect address and the resource.
    let request = fake.inner.lock().unwrap().token_requests[0].clone();
    assert_eq!(request["grant_type"], "authorization_code");
    assert_eq!(request["client_id"], "client-1");
    assert_eq!(request["redirect_uri"], REDIRECT_URI);
    assert_eq!(request["resource"], fake.base);
    assert!(request["code_verifier"].len() >= 43);
    // Tokens sit in secrets of no agent; the status is connected.
    let access = fake.inner.lock().unwrap().access.clone();
    assert_eq!(access_token(&store, &row.id).unwrap().as_deref(), Some(access.as_str()));
    for info in store.secret_list().unwrap() {
        assert!(info.agents.is_empty(), "{}", info.name);
    }
    let s = status(&store, &row.id, now).unwrap();
    assert_eq!(s.status, "connected");
    assert_eq!(s.scope.as_deref(), Some("read write"));
    assert!(s.expires_at.unwrap() > now + 3_000_000);
    // A session gets the header.
    let secrets: HashMap<String, String> = store.secrets_all().unwrap().into_iter().collect();
    let servers = crate::integrations::resolve(&[row], &secrets);
    match &servers[0].transport {
        crate::integrations::Transport::Http { headers, .. } => {
            assert_eq!(headers[0].value, format!("Bearer {access}"));
        }
        _ => panic!(),
    }
}

#[tokio::test]
async fn the_address_carries_pkce_state_resource_and_the_servers_scope() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let q = query_of(&begun.authorize_url);
    assert_eq!(q["scope"], "read write");
    assert_eq!(q["resource"], fake.base);
    assert_eq!(q["code_challenge_method"], "S256");
    assert_eq!(q["code_challenge"].len(), 43);
    assert_eq!(q["state"], begun.state);
    assert!(begun.state.len() >= 43);
    // Nothing of the verifier is in the address.
    assert!(!begun.authorize_url.contains("verifier"));
    // Two sign-ins never share a state.
    let again = begin(&store, &flows, "dev1", Target::Draft(draft("m", &fake.url())), None, 0)
        .await
        .unwrap();
    assert_ne!(again.state, begun.state);
}

#[tokio::test]
async fn a_wrong_state_is_refused_and_does_not_spend_the_real_one() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    let err = complete(&store, &flows, "dev1", "not-the-state", &code, None, 0)
        .await
        .err()
        .unwrap();
    assert!(err.to_string().contains("not waiting"), "{err:#}");
    assert!(fake.inner.lock().unwrap().token_requests.is_empty());
    complete(&store, &flows, "dev1", &state, &code, None, 0).await.unwrap();
}

#[tokio::test]
async fn a_state_works_once() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    complete(&store, &flows, "dev1", &state, &code, None, 0).await.unwrap();
    let again = complete(&store, &flows, "dev1", &state, &code, None, 0).await;
    assert!(again.err().unwrap().to_string().contains("not waiting"));
    assert_eq!(fake.inner.lock().unwrap().token_requests.len(), 1);
}

#[tokio::test]
async fn a_failed_exchange_spends_the_state_too() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let (_code, state) = fake.authorize(&begun.authorize_url);
    // A code the service never issued.
    assert!(
        complete(&store, &flows, "dev1", &state, "forged", None, 0)
            .await
            .is_err()
    );
    let (code2, _) = fake.authorize(&begun.authorize_url);
    let again = complete(&store, &flows, "dev1", &state, &code2, None, 0).await;
    assert!(again.err().unwrap().to_string().contains("not waiting"));
    assert!(store.integration_list().unwrap().is_empty());
}

#[tokio::test]
async fn an_old_state_expires_after_ten_minutes() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Draft(draft("n", &fake.url())),
        None,
        1_000,
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    let late = 1_000 + FLOW_TTL_MS + 1;
    let err = complete(&store, &flows, "dev1", &state, &code, None, late)
        .await
        .err()
        .unwrap();
    assert!(err.to_string().contains("expired"), "{err:#}");
    assert!(fake.inner.lock().unwrap().token_requests.is_empty());
    assert!(store.integration_list().unwrap().is_empty());
    // Exactly at the limit it still works.
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Draft(draft("n", &fake.url())),
        None,
        1_000,
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    complete(&store, &flows, "dev1", &state, &code, None, 1_000 + FLOW_TTL_MS)
        .await
        .unwrap();
}

#[tokio::test]
async fn only_the_device_that_started_a_sign_in_can_finish_it() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(
        &store,
        &flows,
        "device:a",
        Target::Draft(draft("n", &fake.url())),
        None,
        0,
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    let err = complete(&store, &flows, "device:b", &state, &code, None, 0)
        .await
        .err()
        .unwrap();
    assert!(err.to_string().contains("another device"), "{err:#}");
    assert!(
        !flows.cancel(&state, "device:b"),
        "another device cannot cancel it either"
    );
    complete(&store, &flows, "device:a", &state, &code, None, 0)
        .await
        .unwrap();
}

#[tokio::test]
async fn a_cancelled_sign_in_cannot_be_finished() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    assert!(flows.cancel(&state, "dev1"));
    assert!(complete(&store, &flows, "dev1", &state, &code, None, 0).await.is_err());
}

#[tokio::test]
async fn an_answer_from_another_issuer_is_refused() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    let err = complete(&store, &flows, "dev1", &state, &code, Some("https://evil.example"), 0)
        .await
        .err()
        .unwrap();
    assert!(err.to_string().contains("another service"), "{err:#}");
    assert!(fake.inner.lock().unwrap().token_requests.is_empty());
}

#[tokio::test]
async fn a_name_taken_meanwhile_stops_the_sign_in_before_any_token_is_stored() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Draft(draft("notion", &fake.url())),
        None,
        0,
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    store
        .integration_create(draft("notion", "https://other.example/mcp"))
        .unwrap();
    let err = complete(&store, &flows, "dev1", &state, &code, None, 0)
        .await
        .err()
        .unwrap();
    assert!(err.to_string().contains("already exists"), "{err:#}");
    assert!(store.secret_list().unwrap().is_empty());
}

#[tokio::test]
async fn the_service_metadata_is_held_to_the_specification() {
    let (store, flows) = rig();
    // Another issuer than the one asked.
    let fake = Fake::start().await;
    fake.set(|i| i.issuer = Some("http://localhost:1".into()));
    let err = begin(&store, &flows, "d", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .err()
        .unwrap();
    assert!(format!("{err:#}").contains("issuer"), "{err:#}");
    // No PKCE in the metadata: no sign-in.
    let fake = Fake::start().await;
    fake.set(|i| i.no_pkce = true);
    let err = begin(&store, &flows, "d", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .err()
        .unwrap();
    assert!(format!("{err:#}").contains("PKCE"), "{err:#}");
    // Registration with another redirect address.
    let fake = Fake::start().await;
    fake.set(|i| i.registered_redirect = Some("https://evil.example/cb".into()));
    let err = begin(&store, &flows, "d", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .err()
        .unwrap();
    assert!(format!("{err:#}").contains("redirect"), "{err:#}");
    // Nothing was left waiting by any of them.
    assert!(flows.0.lock().unwrap().is_empty());
}

#[tokio::test]
async fn without_registration_a_client_id_is_needed_and_then_enough() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    fake.set(|i| i.no_registration = true);
    let err = begin(&store, &flows, "d", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .err()
        .unwrap();
    assert!(format!("{err:#}").contains("token instead"), "{err:#}");
    let begun = begin(
        &store,
        &flows,
        "d",
        Target::Draft(draft("n", &fake.url())),
        Some("static-client".into()),
        0,
    )
    .await
    .unwrap();
    assert_eq!(query_of(&begun.authorize_url)["client_id"], "static-client");
    assert!(fake.inner.lock().unwrap().registrations.is_empty());
}

#[tokio::test]
async fn a_sign_in_again_reuses_the_registered_client() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let done = connect(&store, &flows, &fake, now_ms()).await;
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Existing(done.integration.clone()),
        None,
        now_ms(),
    )
    .await
    .unwrap();
    assert_eq!(query_of(&begun.authorize_url)["client_id"], "client-1");
    assert_eq!(fake.inner.lock().unwrap().registrations.len(), 1);
    let (code, state) = fake.authorize(&begun.authorize_url);
    let again = complete(&store, &flows, "dev1", &state, &code, None, now_ms())
        .await
        .unwrap();
    assert!(!again.created);
    assert_eq!(again.integration.id, done.integration.id);
}

#[tokio::test]
async fn a_token_that_ends_soon_is_renewed_and_a_fresh_one_is_left_alone() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let first = fake.inner.lock().unwrap().access.clone();
    // An hour to go: nothing happens.
    let out = refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), now).await.unwrap();
    assert_eq!(out, Outcome::Unchanged);
    assert_eq!(fake.inner.lock().unwrap().token_requests.len(), 1);
    // Two minutes to go: renewed, and the service rotates the refresh token.
    let late = now + 3_600_000 - 120_000;
    let out = refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
        .await
        .unwrap();
    assert_eq!(out, Outcome::Refreshed);
    let second = fake.inner.lock().unwrap().access.clone();
    assert_ne!(first, second);
    assert_eq!(access_token(&store, &id).unwrap().as_deref(), Some(second.as_str()));
    let grants: Vec<String> = fake
        .inner
        .lock()
        .unwrap()
        .token_requests
        .iter()
        .map(|r| r["grant_type"].clone())
        .collect();
    assert_eq!(grants, ["authorization_code", "refresh_token"]);
    // The next renewal uses the rotated refresh token.
    let later = now + 2 * 3_600_000 - 120_000;
    assert_eq!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), later)
            .await
            .unwrap(),
        Outcome::Refreshed
    );
}

#[tokio::test]
async fn two_renewals_at_once_make_one_call() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let late = now + 3_600_000 - 60_000;
    let (a, b) = tokio::join!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late),
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late),
    );
    let mut outcomes = [a.unwrap(), b.unwrap()];
    outcomes.sort_by_key(|o| *o as u8);
    assert_eq!(outcomes, [Outcome::Unchanged, Outcome::Refreshed]);
    let refreshes = fake
        .inner
        .lock()
        .unwrap()
        .token_requests
        .iter()
        .filter(|r| r["grant_type"] == "refresh_token")
        .count();
    assert_eq!(refreshes, 1);
}

#[tokio::test]
async fn a_token_the_service_refused_is_renewed_once() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let stale = access_token(&store, &id).unwrap().unwrap();
    // A refusal of some other, older token changes nothing.
    assert_eq!(
        refresh(&store, &id, Why::Rejected("older".into()), now).await.unwrap(),
        Outcome::Unchanged
    );
    assert_eq!(
        refresh(&store, &id, Why::Rejected(stale.clone()), now).await.unwrap(),
        Outcome::Refreshed
    );
    // The same refusal reported again (a second caller) finds the token already renewed.
    assert_eq!(
        refresh(&store, &id, Why::Rejected(stale), now).await.unwrap(),
        Outcome::Unchanged
    );
    let refreshes = fake
        .inner
        .lock()
        .unwrap()
        .token_requests
        .iter()
        .filter(|r| r["grant_type"] == "refresh_token")
        .count();
    assert_eq!(refreshes, 1);
}

#[tokio::test]
async fn a_refused_refresh_token_means_sign_in_again_and_a_new_sign_in_fixes_it() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let done = connect(&store, &flows, &fake, now).await;
    let id = done.integration.id.clone();
    fake.set(|i| i.refresh_failure = Some((400, "invalid_grant".into())));
    let late = now + 3_600_000;
    assert_eq!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .unwrap(),
        Outcome::NeedsLogin
    );
    assert_eq!(status(&store, &id, late).unwrap().status, "needs_login");
    // No more calls while it is marked.
    let calls = fake.inner.lock().unwrap().token_requests.len();
    assert_eq!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .unwrap(),
        Outcome::NeedsLogin
    );
    assert_eq!(fake.inner.lock().unwrap().token_requests.len(), calls);
    // A session leaves it out and says why.
    let unusable = ready_for_session(&store, &[&done.integration], late).await;
    assert_eq!(unusable, vec![(id.clone(), true)]);
    // Signing in again clears the mark.
    fake.set(|i| i.refresh_failure = None);
    let begun = begin(&store, &flows, "dev1", Target::Existing(done.integration), None, late)
        .await
        .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    complete(&store, &flows, "dev1", &state, &code, None, late)
        .await
        .unwrap();
    assert_eq!(status(&store, &id, late).unwrap().status, "connected");
}

#[tokio::test]
async fn a_service_that_is_down_keeps_the_sign_in_as_it_was() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let done = connect(&store, &flows, &fake, now).await;
    let id = done.integration.id.clone();
    let before = access_token(&store, &id).unwrap();
    fake.set(|i| i.refresh_failure = Some((503, "temporarily_unavailable".into())));
    let late = now + 3_600_000 - 60_000;
    assert!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .is_err()
    );
    assert_eq!(access_token(&store, &id).unwrap(), before);
    assert_eq!(status(&store, &id, late).unwrap().status, "connected");
    // Still valid for a minute: the session starts with it. Past its end it is left out, without a prompt for the person.
    assert!(ready_for_session(&store, &[&done.integration], late).await.is_empty());
    let after_end = now + 3_600_000 + 1_000;
    assert_eq!(
        ready_for_session(&store, &[&done.integration], after_end).await,
        vec![(id, false)]
    );
}

#[tokio::test]
async fn disconnect_revokes_and_deletes_and_a_refused_revoke_does_not_stop_it() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let logs = LogBuf::default();
    let subscriber = tracing_subscriber::fmt()
        .with_writer(logs.clone())
        .with_ansi(false)
        .finish();
    let _log = tracing::subscriber::set_default(subscriber);
    let done = connect(&store, &flows, &fake, now_ms()).await;
    let id = done.integration.id.clone();
    let (access, refresh_token) = {
        let i = fake.inner.lock().unwrap();
        (i.access.clone(), i.refresh.clone())
    };
    fake.set(|i| i.revoke_status = 500);
    let revoked = disconnect(&store, &done.integration).await.unwrap();
    assert!(!revoked);
    // Both tokens were offered, with the client, and nothing is left.
    let sent = fake.inner.lock().unwrap().revoked.clone();
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[0]["token"], refresh_token);
    assert_eq!(sent[0]["token_type_hint"], "refresh_token");
    assert_eq!(sent[0]["client_id"], "client-1");
    assert_eq!(sent[1]["token"], access);
    assert_eq!(status(&store, &id, now_ms()).unwrap().status, "not_connected");
    assert!(store.secret_list().unwrap().is_empty());
    // The refusal went to the log, without a token in it.
    let text = logs.text();
    assert!(text.contains("revocation was refused"), "{text}");
    assert!(!text.contains(&access) && !text.contains(&refresh_token), "{text}");
}

#[tokio::test]
async fn a_working_revoke_is_reported() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let done = connect(&store, &flows, &fake, now_ms()).await;
    assert!(disconnect(&store, &done.integration).await.unwrap());
}

#[tokio::test]
async fn a_failed_exchange_names_no_code_no_verifier_and_no_token() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let begun = begin(&store, &flows, "dev1", Target::Draft(draft("n", &fake.url())), None, 0)
        .await
        .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    // The service repeats the code in its error text.
    fake.set(|i| i.token_status = Some((400, "invalid_request".into())));
    let err = format!(
        "{:#}",
        complete(&store, &flows, "dev1", &state, &code, None, 0)
            .await
            .err()
            .unwrap()
    );
    let verifier = fake.inner.lock().unwrap().token_requests[0]["code_verifier"].clone();
    assert!(err.contains("invalid_request"), "{err}");
    assert!(!err.contains(&code) && !err.contains(&verifier), "{err}");
    assert!(err.contains("••••CODE"), "{err}");
}

#[tokio::test]
async fn a_failed_renewal_names_no_token() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let (access, refresh_token) = {
        let i = fake.inner.lock().unwrap();
        (i.access.clone(), i.refresh.clone())
    };
    fake.set(|i| i.refresh_failure = Some((502, "bad_gateway".into())));
    let err = format!(
        "{:#}",
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), now + 3_600_000)
            .await
            .err()
            .unwrap()
    );
    assert!(!err.contains(&access) && !err.contains(&refresh_token), "{err}");
}

#[test]
fn addresses_of_the_service_must_be_https_and_public() {
    let remote = |s: &str| check_remote_url(&Url::parse(s).unwrap(), "x", false);
    assert!(remote("https://mcp.example.com/.well-known/oauth-authorization-server").is_ok());
    for bad in [
        "http://mcp.example.com/token",
        "https://localhost/token",
        "https://127.0.0.1/token",
        "https://10.1.2.3/token",
        "https://192.168.0.9/token",
        "https://172.16.0.1/token",
        "https://169.254.169.254/latest",
        "https://100.64.0.1/token",
        "https://[::1]/token",
        "https://[fe80::1]/token",
        "https://[fd00::1]/token",
        "https://[::ffff:10.0.0.1]/token",
        "https://printer.local/token",
        "https://intranet/token",
    ] {
        assert!(remote(bad).is_err(), "{bad}");
    }
    // The server's own address: https, or loopback http in tests only.
    assert!(check_server_url(&Url::parse("https://mcp.example.com/mcp").unwrap(), false).is_ok());
    assert!(check_server_url(&Url::parse("http://mcp.example.com/mcp").unwrap(), false).is_err());
    assert!(check_server_url(&Url::parse("http://localhost:1/mcp").unwrap(), false).is_err());
    assert!(check_server_url(&Url::parse("http://localhost:1/mcp").unwrap(), true).is_ok());
    assert!(check_server_url(&Url::parse("http://evil.example/mcp").unwrap(), true).is_err());
}

#[test]
fn addresses_with_user_names_fragments_or_control_characters_do_not_parse() {
    for bad in [
        "https://user@example.com/",
        "https://example.com/#frag",
        "https://exa mple.com/",
        "https://example.com/\n",
        "ftp://example.com/",
        "example.com",
        "https://",
        "https://example.com:99999/",
    ] {
        assert!(Url::parse(bad).is_err(), "{bad:?}");
    }
    let u = Url::parse("HTTPS://Example.COM:8443/a/b?x=1").err();
    assert!(u.is_some(), "the scheme is lower case");
    let u = Url::parse("https://Example.COM:8443/a/b?x=1").unwrap();
    assert_eq!(
        (u.host.as_str(), u.port, u.path.as_str(), u.query.as_deref()),
        ("example.com", Some(8443), "/a/b", Some("x=1"))
    );
    assert_eq!(u.origin(), "https://example.com:8443");
}

#[test]
fn the_metadata_must_describe_the_server_asked_about() {
    let server = Url::parse("https://mcp.example.com/mcp").unwrap();
    let covers = |r: &str| resource_covers(&Url::parse(r).unwrap(), &server);
    assert!(covers("https://mcp.example.com"));
    assert!(covers("https://mcp.example.com/"));
    assert!(covers("https://mcp.example.com/mcp"));
    assert!(!covers("https://mcp.example.com/other"));
    assert!(!covers("https://mcp.example.com/mc"));
    assert!(!covers("https://evil.example/mcp"));
    assert!(!covers("http://mcp.example.com"));
}

#[test]
fn a_challenge_gives_its_parameters() {
    let header = r#"Bearer realm="OAuth", error="invalid_token", resource_metadata="https://x.example/.well-known/oauth-protected-resource/mcp", scope="read write""#;
    let p = challenge_params(header);
    let get = |k: &str| p.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
    assert_eq!(
        get("resource_metadata"),
        Some("https://x.example/.well-known/oauth-protected-resource/mcp")
    );
    assert_eq!(get("scope"), Some("read write"));
    assert_eq!(get("realm"), Some("OAuth"));
    assert!(challenge_params("Bearer").is_empty());
    assert_eq!(
        challenge_params("Bearer a=b, c=\"d\\\"e\"")
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect::<Vec<_>>(),
        [("a", "b"), ("c", "d\"e")]
    );
}

#[test]
fn a_request_value_cannot_start_another_config_line() {
    assert!(quote("a\nurl = \"file:///etc/passwd\"").is_err());
    assert!(quote("a\rb").is_err());
    assert_eq!(quote("a\"b\\c").unwrap(), "\"a\\\"b\\\\c\"");
}

#[test]
fn interim_answers_are_skipped_when_reading_a_response() {
    let raw =
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer a=\"b\"\r\n\r\n{\"x\":1}";
    let r = parse_response(raw).unwrap();
    assert_eq!(r.status, 401);
    assert_eq!(
        r.headers_named("www-authenticate").collect::<Vec<_>>(),
        ["Bearer a=\"b\""]
    );
    assert_eq!(r.body, "{\"x\":1}");
}

#[test]
fn waiting_sign_ins_are_capped_and_the_oldest_goes_first() {
    let flows = Flows::default();
    let flow = |at: i64| Flow {
        device: "d".into(),
        integration_id: None,
        draft: None,
        url: String::new(),
        verifier: String::new(),
        client_id: String::new(),
        issuer: String::new(),
        token_endpoint: String::new(),
        revocation_endpoint: None,
        resource: String::new(),
        scope: None,
        created_at: at,
    };
    for i in 0..(MAX_FLOWS as i64 + 5) {
        flows.insert(format!("s{i}"), flow(i), i);
    }
    let map = flows.0.lock().unwrap();
    assert_eq!(map.len(), MAX_FLOWS);
    assert!(!map.contains_key("s0") && map.contains_key(&format!("s{}", MAX_FLOWS as i64 + 4)));
}
