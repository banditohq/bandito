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

fn rig() -> (Arc<Store>, Flows) {
    (Arc::new(Store::open_in_memory().unwrap()), Flows::default())
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
    let st = status(&store, &id, late).unwrap();
    assert_eq!(st.status, "refresh_error");
    assert!(st.error.unwrap().contains("503"));
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
    let revoked = disconnect(&store, &done.integration, false).await.unwrap();
    assert!(!revoked);
    // Both tokens were offered, with the client, and nothing is left.
    let sent = fake.inner.lock().unwrap().revoked.clone();
    assert_eq!(sent.len(), 2);
    assert_eq!(sent[0]["token"], refresh_token);
    assert_eq!(sent[0]["token_type_hint"], "refresh_token");
    assert_eq!(sent[0]["client_id"], "client-1");
    assert_eq!(sent[1]["token"], access);
    assert_eq!(status(&store, &id, now_ms()).unwrap().status, "not_connected");
    // The tokens are gone; the registered client stays for the next sign-in.
    let left: Vec<String> = store.secret_list().unwrap().into_iter().map(|s| s.name).collect();
    assert_eq!(left, [crate::integrations::oauth_client_name(&id)]);
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
    assert!(disconnect(&store, &done.integration, false).await.unwrap());
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

// ---- renewal rhythm, atomic writes, failures that pass ----

fn refresh_grants(fake: &Fake) -> usize {
    fake.inner
        .lock()
        .unwrap()
        .token_requests
        .iter()
        .filter(|r| r["grant_type"] == "refresh_token")
        .count()
}

#[tokio::test]
async fn a_token_of_five_minutes_is_renewed_once_in_five_minutes_of_ticks() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    fake.set(|i| i.expires_in = 300);
    let now = now_ms();
    connect(&store, &flows, &fake, now).await;
    // The background tick runs every minute; the margin is ten minutes, but never more than half the life.
    for minute in 0..=5 {
        refresh_due(&store, now + minute * 60_000).await;
    }
    assert_eq!(refresh_grants(&fake), 1);
}

#[test]
fn the_margin_is_ten_minutes_or_half_the_life_whichever_is_less() {
    let stored = |life_s: i64| Stored {
        refresh_token: None,
        client_id: "c".into(),
        issuer: "i".into(),
        token_endpoint: "t".into(),
        revocation_endpoint: None,
        resource: "r".into(),
        scope: None,
        expires_at: Some(life_s * 1000),
        issued_at: Some(0),
        lifetime_ms: Some(life_s * 1000),
        needs_login: false,
    };
    let hour = stored(3600);
    assert!(!hour.due(BACKGROUND_SKEW_MS, 3_600_000 - 600_001));
    assert!(hour.due(BACKGROUND_SKEW_MS, 3_600_000 - 600_000));
    let short = stored(300);
    assert!(!short.due(BACKGROUND_SKEW_MS, 149_000));
    assert!(short.due(BACKGROUND_SKEW_MS, 150_000));
    // A session start asks with five minutes: a five-minute token is not renewed at every start.
    assert!(!short.due(SESSION_SKEW_MS, 100_000));
    // Old state without a life: the margin alone.
    let mut old = stored(3600);
    old.lifetime_ms = None;
    old.issued_at = None;
    assert!(old.due(BACKGROUND_SKEW_MS, 3_600_000 - 600_000));
    assert!(!old.due(BACKGROUND_SKEW_MS, 3_600_000 - 600_001));
    // No end: never due.
    old.expires_at = None;
    assert!(!old.due(BACKGROUND_SKEW_MS, i64::MAX / 2));
}

#[tokio::test]
async fn a_token_without_expires_in_is_long_lived_and_never_renewed_in_the_background() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    fake.set(|i| i.no_expires_in = true);
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let st = status(&store, &id, now).unwrap();
    assert_eq!((st.status, st.expires_at), ("connected", None));
    for hour in 0..72 {
        assert!(refresh_due(&store, now + hour * 3_600_000).await.is_empty());
    }
    assert_eq!(refresh_grants(&fake), 0);
    assert_eq!(status(&store, &id, now + 72 * 3_600_000).unwrap().status, "connected");
    // A 401 from the service still renews it (the refresh token is there).
    let stale = access_token(&store, &id).unwrap().unwrap();
    assert_eq!(
        refresh(&store, &id, Why::Rejected(stale), now).await.unwrap(),
        Outcome::Refreshed
    );
}

#[tokio::test]
async fn a_failed_write_of_the_rotated_state_leaves_the_old_sign_in_whole() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let access = store.secret_get(&oauth_access_name(&id)).unwrap();
    let state = store.secret_get(&oauth_state_name(&id)).unwrap();
    // The database takes the new access token but refuses the new state.
    store.exec_for_test(
        "CREATE TRIGGER refuse_state BEFORE UPDATE ON secrets WHEN NEW.name LIKE '%_STATE'
         BEGIN SELECT RAISE(ABORT, 'disk full'); END;",
    );
    let late = now + 3_600_000 - 60_000;
    let err = refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
        .await
        .err()
        .unwrap();
    assert!(format!("{err:#}").contains("could not store"), "{err:#}");
    assert_eq!(store.secret_get(&oauth_access_name(&id)).unwrap(), access);
    assert_eq!(store.secret_get(&oauth_state_name(&id)).unwrap(), state);
    assert_eq!(status(&store, &id, late).unwrap().status, "refresh_error");
}

#[tokio::test]
async fn a_failed_first_write_leaves_no_row_and_no_secret() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    store.exec_for_test(
        "CREATE TRIGGER refuse_client BEFORE INSERT ON secrets WHEN NEW.name LIKE '%_CLIENT'
         BEGIN SELECT RAISE(ABORT, 'disk full'); END;",
    );
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Draft(draft("notion", &fake.url())),
        None,
        now_ms(),
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    assert!(
        complete(&store, &flows, "dev1", &state, &code, None, now_ms())
            .await
            .is_err()
    );
    assert!(store.integration_list().unwrap().is_empty());
    assert!(store.secret_list().unwrap().is_empty());
}

#[tokio::test]
async fn only_invalid_grant_and_invalid_client_end_the_sign_in() {
    // (status, error, ends the sign-in)
    let cases: [(u16, &str, bool); 9] = [
        (400, "invalid_grant", true),
        (401, "invalid_client", true),
        (400, "invalid_request", false),
        (401, "invalid_token", false),
        (403, "invalid_grant", false),
        (403, "access_denied", false),
        (429, "slow_down", false),
        (500, "server_error", false),
        (503, "temporarily_unavailable", false),
    ];
    for (code, error, ends) in cases {
        let (store, flows) = rig();
        let fake = Fake::start().await;
        let now = now_ms();
        let id = connect(&store, &flows, &fake, now).await.integration.id;
        let access = store.secret_get(&oauth_access_name(&id)).unwrap();
        let state = store.secret_get(&oauth_state_name(&id)).unwrap();
        fake.set(|i| i.refresh_failure = Some((code, error.into())));
        let late = now + 3_600_000 - 60_000;
        let out = refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late).await;
        if ends {
            assert_eq!(out.unwrap(), Outcome::NeedsLogin, "{code} {error}");
            assert_eq!(status(&store, &id, late).unwrap().status, "needs_login");
        } else {
            assert!(out.is_err(), "{code} {error}");
            // Nothing stored was touched.
            assert_eq!(
                store.secret_get(&oauth_access_name(&id)).unwrap(),
                access,
                "{code} {error}"
            );
            assert_eq!(
                store.secret_get(&oauth_state_name(&id)).unwrap(),
                state,
                "{code} {error}"
            );
            assert_eq!(status(&store, &id, late).unwrap().status, "refresh_error");
        }
    }
}

#[tokio::test]
async fn an_unreachable_service_is_a_pause_and_not_a_sign_out() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    // The token address now leads to a closed port: the connection is refused.
    let mut stored = load_stored(&store, &id).unwrap().unwrap();
    stored.token_endpoint = "http://localhost:1/token".into();
    save_state(&store, &id, &stored).unwrap();
    let state = store.secret_get(&oauth_state_name(&id)).unwrap();
    let late = now + 3_600_000 - 60_000;
    assert!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .is_err()
    );
    assert_eq!(store.secret_get(&oauth_state_name(&id)).unwrap(), state);
    let st = status(&store, &id, late).unwrap();
    assert_eq!(st.status, "refresh_error");
    assert!(st.error.is_some_and(|e| e.chars().count() <= 160));
}

#[test]
fn the_wait_after_a_failed_renewal_doubles_up_to_thirty_minutes() {
    let minutes: Vec<i64> = [1u32, 2, 3, 4, 5, 6, 7, 40, u32::MAX]
        .iter()
        .map(|f| backoff_ms(*f) / 60_000)
        .collect();
    assert_eq!(minutes, [1, 2, 4, 8, 16, 30, 30, 30, 30]);
}

#[tokio::test]
async fn failed_renewals_are_retried_with_backoff_and_a_success_ends_it() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    fake.set(|i| i.refresh_failure = Some((503, "temporarily_unavailable".into())));
    let t0 = now + 3_600_000 - 60_000;
    let tick = |secs: i64| refresh(&store, &id, Why::Expiring(BACKGROUND_SKEW_MS), t0 + secs * 1000);
    assert!(tick(0).await.is_err());
    assert_eq!(refresh_grants(&fake), 1);
    // One minute is the first wait.
    assert_eq!(tick(30).await.unwrap(), Outcome::Waiting);
    assert_eq!(refresh_grants(&fake), 1);
    assert!(tick(60).await.is_err());
    assert_eq!(refresh_grants(&fake), 2);
    // Then two minutes (until 60 + 120 = 180 s).
    assert_eq!(tick(179).await.unwrap(), Outcome::Waiting);
    assert!(tick(180).await.is_err());
    assert_eq!(refresh_grants(&fake), 3);
    // Then four minutes (until 420 s). The service is back by then.
    fake.set(|i| i.refresh_failure = None);
    assert_eq!(tick(419).await.unwrap(), Outcome::Waiting);
    assert_eq!(tick(420).await.unwrap(), Outcome::Refreshed);
    assert_eq!(refresh_grants(&fake), 4);
    assert_eq!(status(&store, &id, t0 + 420_000).unwrap().status, "connected");
    // A 401 from the service is tried at once, whatever the wait.
    fake.set(|i| i.refresh_failure = Some((500, "server_error".into())));
    let late = t0 + 420_000 + 3_600_000 - 60_000;
    assert!(
        refresh(&store, &id, Why::Expiring(BACKGROUND_SKEW_MS), late)
            .await
            .is_err()
    );
    let stale = access_token(&store, &id).unwrap().unwrap();
    let before = refresh_grants(&fake);
    assert!(refresh(&store, &id, Why::Rejected(stale), late + 1000).await.is_err());
    assert_eq!(refresh_grants(&fake), before + 1);
}

#[tokio::test]
async fn a_session_start_waits_for_the_renewals_a_short_time_and_all_together() {
    let (store, flows) = rig();
    let (fake_a, fake_b) = (Fake::start().await, Fake::start().await);
    let now = now_ms();
    let mut rows = Vec::new();
    for (name, fake) in [("one", &fake_a), ("two", &fake_b)] {
        let begun = begin(
            &store,
            &flows,
            "dev1",
            Target::Draft(draft(name, &fake.url())),
            None,
            now,
        )
        .await
        .unwrap();
        let (code, state) = fake.authorize(&begun.authorize_url);
        rows.push(
            complete(&store, &flows, "dev1", &state, &code, None, now)
                .await
                .unwrap()
                .integration,
        );
    }
    for fake in [&fake_a, &fake_b] {
        fake.set(|i| i.token_delay_ms = 1500);
    }
    let refs: Vec<&Integration> = rows.iter().collect();
    // The tokens end in a minute but are good: both are used as they are, and the wait is shared, not added up.
    let late = now + 3_600_000 - 60_000;
    let started = std::time::Instant::now();
    let skipped = ready_within(&store, &refs, late, Duration::from_millis(300)).await;
    let took = started.elapsed();
    assert!(skipped.is_empty(), "{skipped:?}");
    assert!(took < Duration::from_millis(550), "{took:?}");
    // Past their end they cannot be used: left out, as "the service did not answer in time".
    let after_end = now + 3_600_000 + 5_000;
    let mut skipped = ready_within(&store, &refs, after_end, Duration::from_millis(300)).await;
    skipped.sort();
    let mut want: Vec<(String, bool)> = rows.iter().map(|r| (r.id.clone(), false)).collect();
    want.sort();
    assert_eq!(skipped, want);
    // The renewals were not cancelled: they finish in the background.
    tokio::time::sleep(Duration::from_millis(2200)).await;
    assert!(refresh_grants(&fake_a) >= 1 && refresh_grants(&fake_b) >= 1);
    let renewed = access_token(&store, &rows[0].id).unwrap().unwrap();
    assert_eq!(renewed, fake_a.inner.lock().unwrap().access);
}

#[tokio::test]
async fn a_client_registered_once_is_reused_after_a_disconnect_until_the_integration_goes() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let done = connect(&store, &flows, &fake, now_ms()).await;
    let id = done.integration.id.clone();
    disconnect(&store, &done.integration, false).await.unwrap();
    assert!(store.secret_get(&oauth_state_name(&id)).unwrap().is_none());
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
    // The registration is not among the tokens, and removing the integration deletes it.
    let (code, state) = fake.authorize(&begun.authorize_url);
    complete(&store, &flows, "dev1", &state, &code, None, now_ms())
        .await
        .unwrap();
    disconnect(&store, &done.integration, true).await.unwrap();
    assert!(store.secret_list().unwrap().is_empty());
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Existing(done.integration),
        None,
        now_ms(),
    )
    .await
    .unwrap();
    assert_eq!(query_of(&begun.authorize_url)["client_id"], "client-2");
}

// ---- addresses that lead to the person's own machine ----

#[test]
fn every_way_to_write_a_local_address_is_refused() {
    let remote = |s: &str| Url::parse(s).and_then(|u| check_remote_url(&u, "x", false));
    for bad in [
        // numbers written other than as a dotted quad
        "https://127.1/x",
        "https://0x7f.0.0.1/x",
        "https://0X7F.0.0.1/x",
        "https://0177.0.0.1/x",
        "https://2130706433/x",
        "https://0x7f000001/x",
        "https://017700000001/x",
        "https://127.0.1/x",
        "https://10.1/x",
        "https://1.2.3.0x4/x",
        "https://01.02.03.04/x",
        // the dotted quads that are local
        "https://127.0.0.1/x",
        "https://127.255.255.254/x",
        "https://0.0.0.0/x",
        "https://10.0.0.1/x",
        "https://172.31.255.255/x",
        "https://192.168.1.1/x",
        "https://169.254.169.254/x",
        "https://100.64.0.1/x",
        "https://100.127.255.255/x",
        "https://224.0.0.1/x",
        "https://239.255.255.250/x",
        "https://255.255.255.255/x",
        // the root dot and capitals do not change the name
        "https://localhost./x",
        "https://LOCALHOST/x",
        "https://127.0.0.1./x",
        "https://printer.local./x",
        "https://a.b.localhost/x",
        // IPv6, also with an IPv4 address inside
        "https://[::1]/x",
        "https://[0:0:0:0:0:0:0:1]/x",
        "https://[::]/x",
        "https://[fe80::1]/x",
        "https://[fd12:3456::1]/x",
        "https://[fc00::1]/x",
        "https://[ff02::1]/x",
        "https://[::ffff:127.0.0.1]/x",
        "https://[::ffff:7f00:1]/x",
        "https://[::ffff:10.0.0.1]/x",
        "https://[::ffff:a9fe:a9fe]/x",
        "https://[::127.0.0.1]/x",
        "https://[64:ff9b::7f00:1]/x",
        "https://[2002:7f00:1::]/x",
        "https://[2002:c0a8:101::1]/x",
    ] {
        assert!(remote(bad).is_err(), "{bad} must be refused");
    }
    for good in [
        "https://example.com/x",
        "https://Example.COM./x",
        "https://8.8.8.8/x",
        "https://1.1.1.1/x",
        "https://[2606:4700:4700::1111]/x",
        "https://[::ffff:8.8.8.8]/x",
        "https://mcp.linear.app/mcp",
        "https://100.63.255.255/x",
        "https://172.32.0.1/x",
    ] {
        assert!(remote(good).is_ok(), "{good} must pass");
    }
    // The root dot is cut: the host is kept in one spelling.
    assert_eq!(Url::parse("https://Example.COM./a").unwrap().host, "example.com");
    assert_eq!(Url::parse("https://[0:0:0:0:0:0:0:1]/a").unwrap().host, "[::1]");
    // Empty labels, a double dot and a bad IPv6 do not parse at all.
    for bad in [
        "https://a..b/",
        "https://.example.com/",
        "https://example.com../",
        "https://[::1%25en0]/",
        "https://[1::2::3]/",
    ] {
        assert!(Url::parse(bad).is_err(), "{bad}");
    }
}

#[tokio::test]
async fn a_name_that_resolves_to_a_local_address_is_refused_before_any_request() {
    use std::net::IpAddr;
    let ip = |s: &str| s.parse::<IpAddr>().unwrap();
    let cases: [(&str, Vec<IpAddr>); 7] = [
        ("loop.test", vec![ip("127.0.0.1")]),
        ("private.test", vec![ip("10.1.2.3")]),
        ("linklocal.test", vec![ip("169.254.169.254")]),
        ("cgnat.test", vec![ip("100.64.0.9")]),
        ("ula.test", vec![ip("fd00::5")]),
        ("mapped.test", vec![ip("::ffff:192.168.0.1")]),
        // one local address among public ones is enough to refuse
        (
            "mixed.test",
            vec![ip("93.184.216.34"), ip("2606:2800:220:1::1"), ip("127.0.0.1")],
        ),
    ];
    for (name, addrs) in cases {
        fake_dns().lock().unwrap().insert(name.into(), addrs);
        let url = Url::parse(&format!("https://{name}/x")).unwrap();
        let err = send(Req::get(&url)).await.err().unwrap();
        assert!(format!("{err:#}").contains("local address"), "{name}: {err:#}");
    }
    // The same through discovery: a server whose name resolves to a local address cannot start a sign-in.
    fake_dns()
        .lock()
        .unwrap()
        .insert("rebind.test".into(), vec![ip("127.0.0.1")]);
    let (store, flows) = rig();
    let err = begin(
        &store,
        &flows,
        "dev1",
        Target::Draft(draft("evil", "https://rebind.test/mcp")),
        None,
        now_ms(),
    )
    .await
    .err()
    .unwrap();
    assert!(format!("{err:#}").contains("local address"), "{err:#}");
    // A name with no address at all is refused too.
    fake_dns().lock().unwrap().insert("nothing.test".into(), vec![]);
    let url = Url::parse("https://nothing.test/x").unwrap();
    assert!(send(Req::get(&url)).await.is_err());
}

#[tokio::test]
async fn the_connection_is_pinned_to_the_addresses_that_were_checked() {
    use std::net::IpAddr;
    let ip = |s: &str| s.parse::<IpAddr>().unwrap();
    fake_dns().lock().unwrap().insert(
        "pinned.test".into(),
        vec![ip("93.184.216.34"), ip("2606:2800:220:1::1")],
    );
    let url = Url::parse("https://pinned.test/token").unwrap();
    let pin = pin_address(&url).await.unwrap().unwrap();
    assert_eq!(pin, "pinned.test:443:93.184.216.34,[2606:2800:220:1::1]");
    let config = curl_config(&Req::get(&url), Some(&pin), false).unwrap();
    for line in [
        "globoff\n",
        "proto = \"=https\"\n",
        "resolve = \"pinned.test:443:93.184.216.34,[2606:2800:220:1::1]\"\n",
        "url = \"https://pinned.test/token\"\n",
    ] {
        assert!(config.contains(line), "{line:?} not in\n{config}");
    }
    assert!(!config.contains("location"), "no redirect is followed");
    // The port is part of the pin.
    let other = Url::parse("https://pinned.test:8443/x").unwrap();
    assert!(
        pin_address(&other)
            .await
            .unwrap()
            .unwrap()
            .starts_with("pinned.test:8443:")
    );
    // An IP literal needs no pin; a local one never gets there.
    let literal = Url::parse("https://8.8.8.8/x").unwrap();
    assert_eq!(pin_address(&literal).await.unwrap(), None);
    // Only tests let the loopback of the fake service pass unpinned over plain http.
    assert!(
        curl_config(&Req::get(&url), None, true)
            .unwrap()
            .contains("=https,http")
    );
}

// ---- second review ----

#[tokio::test]
async fn a_client_the_service_rejects_is_forgotten_so_the_next_sign_in_registers_again() {
    // At renewal.
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let done = connect(&store, &flows, &fake, now).await;
    let id = done.integration.id.clone();
    assert!(
        store
            .secret_get(&crate::integrations::oauth_client_name(&id))
            .unwrap()
            .is_some()
    );
    fake.set(|i| i.refresh_failure = Some((401, "invalid_client".into())));
    let late = now + 3_600_000 - 60_000;
    assert_eq!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .unwrap(),
        Outcome::NeedsLogin
    );
    assert!(
        store
            .secret_get(&crate::integrations::oauth_client_name(&id))
            .unwrap()
            .is_none()
    );
    fake.set(|i| i.refresh_failure = None);
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Existing(done.integration.clone()),
        None,
        late,
    )
    .await
    .unwrap();
    assert_eq!(query_of(&begun.authorize_url)["client_id"], "client-2");
    assert_eq!(fake.inner.lock().unwrap().registrations.len(), 2);

    // At the exchange of the code. invalid_grant leaves the client alone, invalid_client does not.
    let (code, state) = fake.authorize(&begun.authorize_url);
    fake.set(|i| i.token_status = Some((400, "invalid_grant".into())));
    assert!(
        complete(&store, &flows, "dev1", &state, &code, None, late)
            .await
            .is_err()
    );
    // (the sign-in is spent; the client was saved by the first sign-in only when it succeeded)
    let begun = begin(
        &store,
        &flows,
        "dev1",
        Target::Existing(done.integration.clone()),
        None,
        late,
    )
    .await
    .unwrap();
    let (code, state) = fake.authorize(&begun.authorize_url);
    fake.set(|i| i.token_status = Some((401, "invalid_client".into())));
    assert!(
        complete(&store, &flows, "dev1", &state, &code, None, late)
            .await
            .is_err()
    );
    assert!(
        store
            .secret_get(&crate::integrations::oauth_client_name(&id))
            .unwrap()
            .is_none()
    );
}

#[tokio::test]
async fn a_renewal_the_database_refuses_twice_is_held_and_written_at_the_next_try() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let id = connect(&store, &flows, &fake, now).await.integration.id;
    let old_access = store.secret_get(&oauth_access_name(&id)).unwrap().unwrap();
    store.exec_for_test(
        "CREATE TRIGGER refuse_state BEFORE UPDATE ON secrets WHEN NEW.name LIKE '%_STATE'
         BEGIN SELECT RAISE(ABORT, 'disk full'); END;",
    );
    let late = now + 3_600_000 - 60_000;
    assert!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .is_err()
    );
    // The service rotated the refresh token; the new state is not lost.
    let new_access = fake.inner.lock().unwrap().access.clone();
    assert_ne!(new_access, old_access);
    assert_eq!(store.secret_get(&oauth_access_name(&id)).unwrap().unwrap(), old_access);
    assert_eq!(
        access_token(&store, &id).unwrap().unwrap(),
        new_access,
        "sessions use the held token"
    );
    let mut secrets = store.secrets_all().unwrap();
    overlay_held(&mut secrets);
    assert!(
        secrets
            .iter()
            .any(|(n, v)| *n == oauth_access_name(&id) && *v == new_access)
    );
    let st = status(&store, &id, late).unwrap();
    assert_eq!(st.status, "refresh_error");
    // The disk is back: the next try writes it, without asking the service again.
    store.exec_for_test("DROP TRIGGER refuse_state");
    let grants = refresh_grants(&fake);
    assert_eq!(
        refresh(&store, &id, Why::Expiring(BACKGROUND_SKEW_MS), late + 1000)
            .await
            .unwrap(),
        Outcome::Refreshed
    );
    assert_eq!(refresh_grants(&fake), grants);
    assert_eq!(store.secret_get(&oauth_access_name(&id)).unwrap().unwrap(), new_access);
    assert_eq!(status(&store, &id, late + 1000).unwrap().status, "connected");
    // And the rotated refresh token is the one that works.
    let later = late + 3_600_000 - 60_000;
    assert_eq!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), later)
            .await
            .unwrap(),
        Outcome::Refreshed
    );
}

#[tokio::test]
async fn disconnect_revokes_the_renewal_held_in_memory_not_the_dead_stored_one() {
    let (store, flows) = rig();
    let fake = Fake::start().await;
    let now = now_ms();
    let done = connect(&store, &flows, &fake, now).await;
    let id = done.integration.id.clone();
    let old_refresh = fake.inner.lock().unwrap().refresh.clone();
    store.exec_for_test(
        "CREATE TRIGGER refuse_state BEFORE UPDATE ON secrets WHEN NEW.name LIKE '%_STATE'
         BEGIN SELECT RAISE(ABORT, 'disk full'); END;",
    );
    let late = now + 3_600_000 - 60_000;
    assert!(
        refresh(&store, &id, Why::Expiring(SESSION_SKEW_MS), late)
            .await
            .is_err()
    );
    let (new_access, new_refresh) = {
        let inner = fake.inner.lock().unwrap();
        (inner.access.clone(), inner.refresh.clone())
    };
    assert_ne!(new_refresh, old_refresh, "the fake rotates refresh tokens");
    store.exec_for_test("DROP TRIGGER refuse_state");
    assert!(disconnect(&store, &done.integration, false).await.unwrap());
    let revoked: Vec<String> = fake
        .inner
        .lock()
        .unwrap()
        .revoked
        .iter()
        .filter_map(|f| f.get("token").cloned())
        .collect();
    assert!(revoked.contains(&new_refresh), "{revoked:?}");
    assert!(revoked.contains(&new_access), "{revoked:?}");
    assert!(
        access_token(&store, &id).unwrap().is_none(),
        "nothing is left after the disconnect"
    );
}

#[test]
fn curl_does_not_read_its_rc_file_or_a_proxy() {
    assert_eq!(CURL_ARGS[0], "-q", "-q must come first or curl reads ~/.curlrc");
    let url = Url::parse("https://pinned.test/x").unwrap();
    let config = curl_config(&Req::get(&url), None, false).unwrap();
    assert!(config.contains("noproxy = \"*\"\n"), "{config}");
}

#[tokio::test]
async fn the_probe_of_a_sign_in_row_gets_the_same_address_checks_and_pin() {
    use std::net::IpAddr;
    let ip = |s: &str| s.parse::<IpAddr>().unwrap();
    fake_dns()
        .lock()
        .unwrap()
        .insert("probe-local.test".into(), vec![ip("10.0.0.7")]);
    fake_dns()
        .lock()
        .unwrap()
        .insert("probe-public.test".into(), vec![ip("93.184.216.34")]);
    let err = guard_http("https://probe-local.test/mcp").await.err().unwrap();
    assert!(format!("{err:#}").contains("local address"), "{err:#}");
    assert!(
        guard_http("http://probe-public.test/mcp").await.is_err(),
        "plain http is refused"
    );
    assert!(guard_http("https://10.0.0.1/mcp").await.is_err());
    assert!(guard_http("https://0x7f.0.0.1/mcp").await.is_err());
    // The address is used in the spelling the pin is made for.
    let (url, lines) = guard_http("https://Probe-Public.test./mcp").await.unwrap();
    assert_eq!(url, "https://probe-public.test/mcp");
    for line in [
        "globoff\n",
        "noproxy = \"*\"\n",
        "proto = \"=https,http\"\n",
        "resolve = \"probe-public.test:443:93.184.216.34\"\n",
    ] {
        assert!(lines.contains(line), "{line:?} not in {lines}");
    }
}

#[test]
fn tunnel_and_relay_ranges_are_local_too() {
    let remote = |s: &str| Url::parse(s).and_then(|u| check_remote_url(&u, "x", false));
    for bad in [
        "https://192.88.99.1/x",
        "https://[2001::1]/x",
        "https://[2001:0:4136:e378:8000:63bf:3fff:fdd2]/x",
        "https://[2001:0:808:808::1]/x",
        "https://[64:ff9b:1::808:808]/x",
        "https://[64:ff9b:1::7f00:1]/x",
        "https://[64:ff9b::a00:1]/x",
        "https://[2002:a00:1::]/x",
    ] {
        assert!(remote(bad).is_err(), "{bad} must be refused");
    }
    for good in [
        "https://192.88.98.1/x",
        "https://[2001:4860:4860::8888]/x",
        "https://[64:ff9b::808:808]/x",
    ] {
        assert!(remote(good).is_ok(), "{good} must pass");
    }
}
