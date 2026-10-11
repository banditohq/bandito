//! The tests of the Telegram bot, against the fake Bot API (`fake.rs`): linking, the guard on unlinked chats and on
//! callbacks, approval cards, writing to agents, the answer modes, the token never showing, the text conversions, the
//! strings table, and the poll loop. No test reaches the real Telegram.

use super::api::{Api, ApiError, curl_argv, curl_config, scrub};
use super::fake::FakeTelegram;
use super::format::{format_answer, markdown_to_html, truncate_chars};
use super::strings::{self, LANGUAGES, tr};
use super::{Telegram, Timing, map_language};
use crate::event::{Decision, Event, EventBody, TurnStatus};
use crate::hub::Hub;
use crate::runtime::{ApprovalRequest, RuntimeKind, RuntimeOutput};
use crate::store::{ApprovalMode, ApprovalStatus, MemoryMode, NewAgent, Store, now_ms};
use crate::supervisor::testing::{Log, MockRuntime, Outs};
use crate::supervisor::{Inbound, Runtimes, Supervisor};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::broadcast;

const TOKEN: &str = "123456789:AAH_testtoken_0123456789abcdefghij_xyz";
const OWNER: i64 = 100;

fn fast() -> Timing {
    Timing::fast()
}

fn new_agent(store: &Store, name: &str, role: &str, mode: ApprovalMode) -> String {
    store
        .agent_create(NewAgent {
            use_personal_settings: false,
            avatar: None,
            capabilities: None,
            integrations: None,
            name: name.into(),
            role: role.into(),
            runtime: RuntimeKind::Claude,
            model: None,
            cwd: "/bandito-probe/u/app".into(),
            approval_mode: mode,
            system_prompt: None,
            effort: None,
            memory_mode: MemoryMode::Smart,
            context_budget: None,
            fallback_runtime: None,
            fallback_model: None,
        })
        .unwrap()
        .id
}

struct Rig {
    tg: Arc<Telegram>,
    fake: Arc<FakeTelegram>,
    sup: Arc<Supervisor>,
    store: Arc<Store>,
    log: Log,
    out: Outs,
    events: broadcast::Receiver<Event>,
    /// The agent `Forge`, which asks for every approval.
    agent: String,
}

async fn rig_with(timing: Timing) -> Rig {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let log: Log = Arc::default();
    let out: Outs = Arc::default();
    let mut rts = Runtimes::default();
    rts.insert(Arc::new(MockRuntime {
        log: log.clone(),
        out: out.clone(),
        spawns: Arc::default(),
    }));
    let hub = Hub::new(store.clone());
    let events = hub.subscribe();
    let sup = Supervisor::new(hub, rts, None);
    let tg = Telegram::with_base(sup.clone(), &fake.base, timing);
    tg.seed_for_test(TOKEN, "bandito_test_bot", "Bandito Test");
    let agent = new_agent(&store, "Forge", "builder", ApprovalMode::Always);
    Rig {
        tg,
        fake,
        sup,
        store,
        log,
        out,
        events,
        agent,
    }
}

async fn rig() -> Rig {
    rig_with(fast()).await
}

impl Rig {
    /// Links a chat the way a finished `/start <code>` does: private chat `id`, owned by user `id`.
    fn link(&self, chat: i64) {
        self.store.tg_chat_link(chat, chat, "Ann", "en", now_ms()).unwrap();
    }

    fn chat(&self, chat: i64) -> crate::store::TgChat {
        self.store.tg_chat_get(chat).unwrap().expect("chat is linked")
    }

    fn set_answers(&self, chat: i64, mode: &str) {
        self.store.tg_chat_update(chat, None, Some(mode)).unwrap();
    }

    /// Feeds the hub's events to the bot, as its listener would, up to the first one `pred` accepts.
    async fn feed_until(&mut self, pred: impl Fn(&EventBody) -> bool) -> Event {
        loop {
            let ev = tokio::time::timeout(Duration::from_secs(3), self.events.recv())
                .await
                .expect("timed out waiting for an event")
                .unwrap();
            self.tg.handle_event(ev.clone()).await;
            if pred(&ev.body) {
                return ev;
            }
        }
    }

    async fn push(&self, agent: &str, o: RuntimeOutput) {
        let tx = self.out.lock().unwrap().get(agent).cloned().expect("session spawned");
        tx.send(o).await.unwrap();
    }

    async fn wait_log_prefix(&self, prefix: &str) {
        for _ in 0..300 {
            if self.log.lock().unwrap().iter().any(|l| l.starts_with(prefix)) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("log never had {prefix:?}: {:?}", self.log.lock().unwrap());
    }

    fn sent_log(&self) -> Vec<String> {
        self.log
            .lock()
            .unwrap()
            .iter()
            .filter(|l| l.starts_with("send "))
            .cloned()
            .collect()
    }

    /// A pending approval of `agent` (which must run `ApprovalMode::Always`), and the event that announced it.
    async fn pending_approval(&mut self, command: &str) -> String {
        let agent = self.agent.clone();
        if !self.out.lock().unwrap().contains_key(&agent) {
            self.sup.send(&agent, Inbound::user("go")).await.unwrap();
            self.wait_log_prefix("send go").await;
        }
        self.push(&agent, approval("k1", command)).await;
        let ev = self
            .feed_until(|b| matches!(b, EventBody::ApprovalRequested { .. }))
            .await;
        let EventBody::ApprovalRequested { approval_id, .. } = ev.body else {
            unreachable!()
        };
        approval_id
    }

    /// The `sendMessage` bodies that carry an inline keyboard, sent to `chat`.
    fn cards(&self, chat: i64) -> Vec<Value> {
        self.fake
            .sent_to(chat)
            .into_iter()
            .filter(|b| b["reply_markup"]["inline_keyboard"].is_array())
            .collect()
    }
}

fn approval(key: &str, cmd: &str) -> RuntimeOutput {
    RuntimeOutput::Approval(ApprovalRequest {
        key: key.into(),
        call_id: format!("call-{key}"),
        tool: "Bash".into(),
        title: cmd.into(),
        command: Some(cmd.into()),
        diff: None,
        paths: vec![],
        input: json!({"command": cmd}),
    })
}

fn done() -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::TurnCompleted {
        turn_id: String::new(),
        status: TurnStatus::Ok,
        usage: None,
        cost_usd: None,
    })
}

fn assistant(text: &str) -> RuntimeOutput {
    RuntimeOutput::Event(EventBody::MessageAssistant { text: text.into() })
}

fn from(id: i64, lang: &str) -> Value {
    json!({ "id": id, "is_bot": false, "first_name": "Ann", "language_code": lang })
}

fn private_msg(chat: i64, user: i64, lang: &str, text: &str) -> Value {
    json!({ "message": {
        "message_id": 7, "from": from(user, lang), "date": 0,
        "chat": { "id": chat, "type": "private", "first_name": "Ann" },
        "text": text } })
}

fn msg(chat: i64, text: &str) -> Value {
    private_msg(chat, chat, "en", text)
}

fn reply_msg(chat: i64, reply_to: i64, text: &str) -> Value {
    let mut m = msg(chat, text);
    m["message"]["reply_to_message"] = json!({ "message_id": reply_to, "chat": { "id": chat, "type": "private" } });
    m
}

fn callback(chat: i64, user: i64, message_id: i64, data: &str) -> Value {
    json!({ "callback_query": {
        "id": format!("cb-{data}"), "from": from(user, "en"), "data": data,
        "message": { "message_id": message_id, "chat": { "id": chat, "type": "private" }, "date": 0 } } })
}

/// `(label, callback_data)` of every button of a message.
fn buttons(message: &Value) -> Vec<(String, String)> {
    message["reply_markup"]["inline_keyboard"]
        .as_array()
        .map(|rows| {
            rows.iter()
                .flat_map(|r| r.as_array().cloned().unwrap_or_default())
                .map(|b| {
                    (
                        b["text"].as_str().unwrap_or_default().to_string(),
                        b["callback_data"].as_str().unwrap_or_default().to_string(),
                    )
                })
                .collect()
        })
        .unwrap_or_default()
}

fn text_of(message: &Value) -> String {
    message["text"].as_str().unwrap_or_default().to_string()
}

fn link_code(rig: &Rig) -> String {
    rig.tg.link_start().unwrap()["code"].as_str().unwrap().to_string()
}

// ---- 1. linking ----

#[tokio::test]
async fn link_start_gives_an_eight_letter_code_and_a_deep_link() {
    let rig = rig().await;
    let reply = rig.tg.link_start().unwrap();
    let code = reply["code"].as_str().unwrap();
    assert_eq!(code.len(), 8);
    assert!(code.chars().all(|c| matches!(c, 'A'..='Z' | '2'..='7')), "{code}");
    assert_eq!(reply["url"], format!("https://t.me/bandito_test_bot?start={code}"));
    let expires = reply["expires_at"].as_i64().unwrap();
    let ten_minutes = 10 * 60 * 1000;
    assert!((expires - now_ms() - ten_minutes).abs() < 5_000, "{expires}");

    // A new call replaces the old code.
    let second = rig.tg.link_start().unwrap();
    assert_ne!(second["code"], reply["code"]);
    rig.tg
        .handle_update(msg(OWNER, &format!("/start {}", reply["code"].as_str().unwrap())))
        .await;
    assert!(
        rig.store.tg_chat_get(OWNER).unwrap().is_none(),
        "the replaced code still worked"
    );
    rig.tg
        .handle_update(msg(OWNER, &format!("/start {}", second["code"].as_str().unwrap())))
        .await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_some());
}

#[tokio::test]
async fn link_start_needs_a_token() {
    let rig = rig().await;
    rig.store.secret_delete(super::TOKEN_SECRET).unwrap();
    let err = rig.tg.link_start().unwrap_err();
    assert_eq!(err.reason, "not_configured");
}

#[tokio::test]
async fn the_right_code_links_the_chat_once() {
    let mut rig = rig().await;
    let code = link_code(&rig);
    rig.tg
        .handle_update(private_msg(OWNER, OWNER, "ru-RU", &format!("/start {code}")))
        .await;
    let chat = rig.chat(OWNER);
    assert_eq!(chat.user_id, OWNER);
    assert_eq!(chat.language, "ru");
    assert!(chat.approvals);
    assert_eq!(chat.answers, "telegram");
    assert_eq!(chat.title, "Ann");
    // The greeting is in the chat's language and carries the help.
    let greeting = text_of(rig.fake.sent_to(OWNER).last().unwrap());
    assert!(greeting.contains(&tr("ru", "welcome", &[])), "{greeting}");
    assert!(greeting.contains(&tr("ru", "help", &[])), "{greeting}");
    // The app is told.
    let ev = rig.feed_until(|b| matches!(b, EventBody::TelegramChanged)).await;
    assert!(matches!(ev.body, EventBody::TelegramChanged));

    // The same code from another chat does nothing.
    rig.tg.handle_update(msg(200, &format!("/start {code}"))).await;
    assert!(rig.store.tg_chat_get(200).unwrap().is_none());
    assert_eq!(rig.store.tg_chat_list().unwrap().len(), 1);
    assert_eq!(
        text_of(rig.fake.sent_to(200).last().unwrap()),
        tr("en", "bad_code", &[])
    );
}

#[tokio::test]
async fn an_expired_code_does_not_link() {
    let rig = rig_with(Timing {
        link_ttl: Duration::ZERO,
        ..fast()
    })
    .await;
    let code = link_code(&rig);
    tokio::time::sleep(Duration::from_millis(5)).await;
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_none());
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "bad_code", &[])
    );
}

#[tokio::test]
async fn the_code_is_case_insensitive_and_wrong_codes_do_not_link() {
    let rig = rig().await;
    let code = link_code(&rig);
    rig.tg.handle_update(msg(OWNER, "/start AAAAAAAA")).await;
    rig.tg.handle_update(msg(OWNER, "/start")).await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_none());
    rig.tg
        .handle_update(msg(OWNER, &format!("/start {}", code.to_ascii_lowercase())))
        .await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_some());
}

#[tokio::test]
async fn ten_wrong_codes_burn_the_code() {
    let rig = rig().await;
    let code = link_code(&rig);
    for i in 0..10 {
        // A different chat each time, so no per-chat limit can be what stops the right code later.
        rig.tg.handle_update(msg(500 + i, "/start WRONGCOD")).await;
    }
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    assert!(
        rig.store.tg_chat_get(OWNER).unwrap().is_none(),
        "a burned code linked a chat"
    );
}

#[tokio::test]
async fn nine_wrong_codes_leave_the_code_alive() {
    let rig = rig().await;
    let code = link_code(&rig);
    for i in 0..9 {
        rig.tg.handle_update(msg(500 + i, "/start WRONGCOD")).await;
    }
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_some());
}

#[tokio::test]
async fn start_from_a_group_is_ignored_and_the_bot_leaves() {
    let rig = rig().await;
    let code = link_code(&rig);
    for kind in ["group", "supergroup", "channel"] {
        let update = json!({ "message": {
            "message_id": 1, "from": from(OWNER, "en"), "date": 0,
            "chat": { "id": -900, "type": kind, "title": "Team" },
            "text": format!("/start {code}") } });
        rig.tg.handle_update(update).await;
    }
    assert!(rig.store.tg_chat_list().unwrap().is_empty());
    assert!(rig.fake.sent_to(-900).is_empty(), "the bot answered in a group");
    let left = rig.fake.calls("leaveChat");
    assert!(!left.is_empty());
    assert!(left.iter().all(|b| b["chat_id"] == -900));
    // The code was not used up by the group.
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_some());
}

#[tokio::test]
async fn being_added_to_a_group_makes_the_bot_leave() {
    let rig = rig().await;
    let added = json!({ "my_chat_member": {
        "chat": { "id": -42, "type": "supergroup", "title": "Team" },
        "from": from(OWNER, "en"), "date": 0,
        "old_chat_member": { "status": "left", "user": { "id": 424242, "is_bot": true, "first_name": "B" } },
        "new_chat_member": { "status": "member", "user": { "id": 424242, "is_bot": true, "first_name": "B" } } } });
    rig.tg.handle_update(added).await;
    assert_eq!(rig.fake.calls("leaveChat").len(), 1);
    assert_eq!(rig.fake.calls("leaveChat")[0]["chat_id"], -42);

    // Being removed needs no answer.
    let removed = json!({ "my_chat_member": {
        "chat": { "id": -43, "type": "group", "title": "Team" },
        "from": from(OWNER, "en"), "date": 0,
        "old_chat_member": { "status": "member", "user": { "id": 424242, "is_bot": true, "first_name": "B" } },
        "new_chat_member": { "status": "kicked", "user": { "id": 424242, "is_bot": true, "first_name": "B" } } } });
    rig.tg.handle_update(removed).await;
    assert_eq!(rig.fake.calls("leaveChat").len(), 1);
}

#[tokio::test]
async fn a_sixth_chat_is_refused() {
    let rig = rig().await;
    for chat in 1..=5 {
        rig.link(chat);
    }
    let code = link_code(&rig);
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    assert_eq!(rig.store.tg_chat_list().unwrap().len(), 5);
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_none());
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "too_many_chats", &[])
    );

    // Once a chat is removed, the same code (not used up) works.
    rig.store.tg_chat_delete(5).unwrap();
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_some());
}

#[tokio::test]
async fn a_chat_that_is_not_the_users_own_cannot_link() {
    let rig = rig().await;
    let code = link_code(&rig);
    // A private chat whose id is not the sender's: not a real private chat.
    rig.tg
        .handle_update(private_msg(OWNER, 777, "en", &format!("/start {code}")))
        .await;
    assert!(rig.store.tg_chat_list().unwrap().is_empty());
}

#[tokio::test]
async fn start_without_a_code_in_a_linked_chat_shows_the_help() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "/start")).await;
    assert_eq!(text_of(rig.fake.sent_to(OWNER).last().unwrap()), tr("en", "help", &[]));
    // A code sent from a linked chat is not consumed.
    let code = link_code(&rig);
    rig.tg.handle_update(msg(OWNER, &format!("/start {code}"))).await;
    rig.tg.handle_update(msg(300, &format!("/start {code}"))).await;
    assert!(rig.store.tg_chat_get(300).unwrap().is_some());
}

// ---- 2. unlinked chats ----

#[tokio::test]
async fn an_unlinked_chat_gets_one_notice_an_hour_and_no_commands() {
    let rig = rig_with(Timing {
        notice_gap: Duration::from_millis(300),
        ..fast()
    })
    .await;
    new_agent(&rig.store, "Secret", "spy", ApprovalMode::Risky);
    let notice = tr("en", "not_linked", &[]);
    for text in ["/agents", "hello", "/approvals", "/status", "/ask forge hi", "/unlink"] {
        rig.tg.handle_update(msg(300, text)).await;
    }
    let sent = rig.fake.sent_to(300);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(text_of(&sent[0]), notice);
    assert!(!notice.contains("Secret"));
    assert!(
        rig.sent_log().is_empty(),
        "a command of an unlinked chat reached an agent"
    );
    // Later, the notice may come again.
    tokio::time::sleep(Duration::from_millis(350)).await;
    rig.tg.handle_update(msg(300, "hello?")).await;
    assert_eq!(rig.fake.sent_to(300).len(), 2);
    // Another chat has its own allowance.
    rig.tg.handle_update(msg(301, "hello")).await;
    assert_eq!(rig.fake.sent_to(301).len(), 1);
}

#[tokio::test]
async fn the_notice_uses_the_senders_language() {
    let rig = rig().await;
    rig.tg.handle_update(private_msg(300, 300, "de", "hallo")).await;
    assert_eq!(text_of(&rig.fake.sent_to(300)[0]), tr("de", "not_linked", &[]));
}

#[tokio::test]
async fn a_user_who_is_not_the_linked_one_gets_the_notice_not_the_commands() {
    let rig = rig().await;
    rig.link(OWNER);
    // Same chat id, another sender (cannot happen in a private chat, but the check is on both).
    rig.tg.handle_update(private_msg(OWNER, 999, "en", "/agents")).await;
    let sent = rig.fake.sent_to(OWNER);
    assert!(sent.iter().all(|b| !text_of(b).contains("Forge")), "{sent:?}");
}

// ---- 3. callbacks ----

#[tokio::test]
async fn a_callback_from_the_wrong_user_or_chat_does_not_resolve_the_approval() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let id = rig.pending_approval("git push origin main").await;
    let card = rig.fake.last_message_id();

    // Right chat, wrong user.
    rig.tg
        .handle_update(callback(OWNER, 999, card, &format!("a:{id}:y")))
        .await;
    // A chat that is not linked at all.
    rig.tg
        .handle_update(callback(555, 555, card, &format!("a:{id}:y")))
        .await;
    // Right user id in a group chat.
    let in_group = json!({ "callback_query": {
        "id": "cb-g", "from": from(OWNER, "en"), "data": format!("a:{id}:y"),
        "message": { "message_id": card, "chat": { "id": -7, "type": "group" }, "date": 0 } } });
    rig.tg.handle_update(in_group).await;

    let stored = rig.store.approval_get(&id).unwrap().unwrap();
    assert_eq!(stored.status, ApprovalStatus::Pending);
    assert!(rig.fake.calls("editMessageText").is_empty());
    // Each press was answered, so the button stops spinning, but without a decision.
    assert_eq!(rig.fake.calls("answerCallbackQuery").len(), 3);
}

#[tokio::test]
async fn a_malformed_callback_is_answered_and_ignored() {
    let rig = rig().await;
    rig.link(OWNER);
    for data in ["", "a:", "a:x", "a:x:z", "zzz", "a::y", "s:", &"a:".repeat(40)] {
        rig.tg.handle_update(callback(OWNER, OWNER, 1, data)).await;
    }
    assert_eq!(rig.fake.calls("answerCallbackQuery").len(), 8);
    assert!(rig.sent_log().is_empty());
}

// ---- 4. approval cards ----

#[tokio::test]
async fn a_card_with_buttons_and_allow_from_telegram() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let id = rig.pending_approval("git push origin main").await;

    let cards = rig.cards(OWNER);
    assert_eq!(cards.len(), 1);
    let card = &cards[0];
    assert_eq!(card["parse_mode"], "HTML");
    let text = text_of(card);
    assert!(text.contains("<b>Forge</b>"), "{text}");
    assert!(text.contains("git push origin main"), "{text}");
    let keys = buttons(card);
    assert_eq!(
        keys,
        vec![
            (tr("en", "btn_allow", &[]), format!("a:{id}:y")),
            (tr("en", "btn_deny", &[]), format!("a:{id}:n")),
        ]
    );
    assert!(keys.iter().all(|(_, data)| data.len() <= 64));
    let message_id = rig.fake.last_message_id();

    rig.tg
        .handle_update(callback(OWNER, OWNER, message_id, &format!("a:{id}:y")))
        .await;

    let stored = rig.store.approval_get(&id).unwrap().unwrap();
    assert_eq!(stored.status, ApprovalStatus::Resolved);
    assert_eq!(stored.decision, Some(Decision::Allow));
    rig.wait_log_prefix("resolve k1 Allow").await;
    assert_eq!(rig.fake.calls("answerCallbackQuery").len(), 1);
    let edits = rig.fake.calls("editMessageText");
    assert_eq!(edits.len(), 1);
    assert_eq!(edits[0]["message_id"], message_id);
    assert_eq!(edits[0]["chat_id"], OWNER);
    assert!(
        text_of(&edits[0]).contains(&tr("en", "approval_allowed_tg", &[])),
        "{}",
        text_of(&edits[0])
    );
    assert!(buttons(&edits[0]).is_empty());
    assert_eq!(edits[0]["reply_markup"]["inline_keyboard"], json!([]));

    // The resolved event that follows does not edit the card a second time.
    rig.feed_until(|b| matches!(b, EventBody::ApprovalResolved { .. }))
        .await;
    assert_eq!(rig.fake.calls("editMessageText").len(), 1);
}

#[tokio::test]
async fn deny_from_telegram() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let id = rig.pending_approval("rm -rf build").await;
    rig.tg
        .handle_update(callback(OWNER, OWNER, rig.fake.last_message_id(), &format!("a:{id}:n")))
        .await;
    let stored = rig.store.approval_get(&id).unwrap().unwrap();
    assert_eq!(stored.decision, Some(Decision::Deny));
    let edits = rig.fake.calls("editMessageText");
    assert!(text_of(&edits[0]).contains(&tr("en", "approval_denied_tg", &[])));
}

#[tokio::test]
async fn an_approval_resolved_in_the_app_edits_the_card() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let id = rig.pending_approval("git push origin main").await;
    let card = rig.fake.last_message_id();

    rig.sup.resolve(&id, Decision::Allow, false).await.unwrap();
    rig.feed_until(|b| matches!(b, EventBody::ApprovalResolved { .. }))
        .await;

    let edits = rig.fake.calls("editMessageText");
    assert_eq!(edits.len(), 1);
    assert_eq!(edits[0]["message_id"], card);
    assert!(
        text_of(&edits[0]).contains(&tr("en", "approval_allowed_app", &[])),
        "{}",
        text_of(&edits[0])
    );
    assert_eq!(edits[0]["reply_markup"]["inline_keyboard"], json!([]));
}

#[tokio::test]
async fn a_second_press_says_the_approval_is_decided() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let id = rig.pending_approval("git push origin main").await;
    let card = rig.fake.last_message_id();
    rig.sup.resolve(&id, Decision::Deny, false).await.unwrap();

    rig.tg
        .handle_update(callback(OWNER, OWNER, card, &format!("a:{id}:y")))
        .await;
    let answers = rig.fake.calls("answerCallbackQuery");
    assert_eq!(answers.len(), 1);
    assert_eq!(answers[0]["text"], tr("en", "approval_already", &[]));
    // The decision stays what it was.
    let stored = rig.store.approval_get(&id).unwrap().unwrap();
    assert_eq!(stored.decision, Some(Decision::Deny));
    // An id that never existed is answered the same way.
    rig.tg
        .handle_update(callback(OWNER, OWNER, card, "a:no-such-approval:y"))
        .await;
    assert_eq!(
        rig.fake.calls("answerCallbackQuery")[1]["text"],
        tr("en", "approval_already", &[])
    );
}

#[tokio::test]
async fn a_chat_with_approvals_off_gets_no_card_and_cannot_decide() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.link(101);
    rig.store.tg_chat_update(101, Some(false), None).unwrap();
    let id = rig.pending_approval("git push origin main").await;
    assert_eq!(rig.cards(OWNER).len(), 1);
    assert!(rig.cards(101).is_empty());
    rig.tg.handle_update(callback(101, 101, 1, &format!("a:{id}:y"))).await;
    assert_eq!(
        rig.store.approval_get(&id).unwrap().unwrap().status,
        ApprovalStatus::Pending
    );
}

#[tokio::test]
async fn the_card_is_redacted_and_shortened() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.store
        .secret_set("DEPLOY_KEY", "sk-live-abcdef123456", &["*".into()])
        .unwrap();
    let long = format!("echo sk-live-abcdef123456 {}", "ж".repeat(900));
    rig.pending_approval(&long).await;
    let text = text_of(&rig.cards(OWNER)[0]);
    assert!(!text.contains("sk-live-abcdef123456"), "{text}");
    assert!(text.contains("••••DEPLOY_KEY"), "{text}");
    // The command is cut at 600 characters (the HTML around it is a few dozen more).
    assert!(text.chars().count() < 800, "{}", text.chars().count());
    assert!(!text.contains(&"ж".repeat(601)));
}

#[tokio::test]
async fn a_card_is_not_sent_for_an_approval_already_decided() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let id = rig.pending_approval("ls").await;
    rig.fake.clear_calls();
    // The same event again, after the approval was decided: no new card.
    rig.sup.resolve(&id, Decision::Allow, false).await.unwrap();
    let again = Event {
        seq: 0,
        agent_id: rig.agent.clone(),
        ts: now_ms(),
        body: EventBody::ApprovalRequested {
            approval_id: id.clone(),
            call_id: "call-k1".into(),
            tool: "Bash".into(),
            title: "ls".into(),
            command: Some("ls".into()),
            diff: None,
            reason: "always".into(),
        },
    };
    rig.tg.handle_event(again).await;
    assert!(rig.cards(OWNER).is_empty());
}

#[tokio::test]
async fn approvals_command_lists_the_waiting_ones_as_cards() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "/approvals")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "approvals_none", &[])
    );
    let id = rig.pending_approval("git push origin main").await;
    rig.fake.clear_calls();
    rig.tg.handle_update(msg(OWNER, "/approvals")).await;
    let cards = rig.cards(OWNER);
    assert_eq!(cards.len(), 1);
    assert!(buttons(&cards[0]).iter().any(|(_, d)| d == &format!("a:{id}:y")));
}

// ---- 5. writing to agents ----

#[tokio::test]
async fn ask_with_a_unique_prefix_messages_that_agent() {
    let rig = rig().await;
    rig.link(OWNER);
    let atlas = new_agent(&rig.store, "Atlas", "mapper", ApprovalMode::Risky);
    rig.tg.handle_update(msg(OWNER, "/ask atl  where is the map?")).await;
    rig.wait_log_prefix("send where is the map?").await;
    assert_eq!(rig.sent_log().len(), 1);
    assert!(rig.out.lock().unwrap().contains_key(&atlas));
    assert!(!rig.out.lock().unwrap().contains_key(&rig.agent));

    // Names are case-insensitive, and the exact name wins over a longer one it prefixes.
    rig.push(&atlas, done()).await;
    new_agent(&rig.store, "Atlas Prime", "boss", ApprovalMode::Risky);
    rig.tg.handle_update(msg(OWNER, "/ASK ATLAS again")).await;
    rig.wait_log_prefix("send again").await;
    assert_eq!(rig.sent_log().len(), 2);
}

#[tokio::test]
async fn ask_with_an_ambiguous_prefix_offers_buttons() {
    let rig = rig().await;
    rig.link(OWNER);
    let fox = new_agent(&rig.store, "Fox", "scout", ApprovalMode::Risky);
    rig.tg.handle_update(msg(OWNER, "/ask f hello there")).await;
    assert!(rig.sent_log().is_empty());
    let picker = rig.cards(OWNER).pop().expect("a picker");
    let keys = buttons(&picker);
    assert_eq!(keys.len(), 2);
    assert!(keys.iter().any(|(_, d)| d == &format!("s:{}", rig.agent)));
    assert!(keys.iter().any(|(_, d)| d == &format!("s:{fox}")));
    assert!(keys.iter().all(|(_, d)| d.len() <= 64));

    // Choosing one sends the held text and makes the agent current.
    rig.tg
        .handle_update(callback(OWNER, OWNER, rig.fake.last_message_id(), &format!("s:{fox}")))
        .await;
    rig.wait_log_prefix("send hello there").await;
    assert_eq!(rig.chat(OWNER).current_agent.as_deref(), Some(fox.as_str()));
    assert!(rig.out.lock().unwrap().contains_key(&fox));
}

#[tokio::test]
async fn ask_with_no_match_lists_every_agent() {
    let rig = rig().await;
    rig.link(OWNER);
    new_agent(&rig.store, "Fox", "scout", ApprovalMode::Risky);
    rig.tg.handle_update(msg(OWNER, "/ask zzz hi")).await;
    assert!(rig.sent_log().is_empty());
    assert_eq!(buttons(&rig.cards(OWNER).pop().unwrap()).len(), 2);
    // No text after the name: a hint, not a message.
    rig.tg.handle_update(msg(OWNER, "/ask fox")).await;
    assert!(rig.sent_log().is_empty());
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "ask_usage", &[])
    );
    rig.tg.handle_update(msg(OWNER, "/ask")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "ask_usage", &[])
    );
}

#[tokio::test]
async fn plain_text_without_a_current_agent_asks_which_one() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "build the thing")).await;
    assert!(rig.sent_log().is_empty());
    let picker = rig.cards(OWNER).pop().expect("a picker");
    assert_eq!(text_of(&picker), tr("en", "pick_agent", &[]));
    assert_eq!(
        buttons(&picker),
        vec![("Forge".to_string(), format!("s:{}", rig.agent))]
    );

    rig.tg
        .handle_update(callback(
            OWNER,
            OWNER,
            rig.fake.last_message_id(),
            &format!("s:{}", rig.agent),
        ))
        .await;
    rig.wait_log_prefix("send build the thing").await;
    assert_eq!(rig.chat(OWNER).current_agent.as_deref(), Some(rig.agent.as_str()));
    // The picker is edited into a plain line, with no buttons left.
    let edits = rig.fake.calls("editMessageText");
    assert_eq!(edits.len(), 1);
    assert_eq!(edits[0]["reply_markup"]["inline_keyboard"], json!([]));

    // Next plain text goes straight to the current agent.
    rig.push(&rig.agent, done()).await;
    rig.tg.handle_update(msg(OWNER, "and the other thing")).await;
    rig.wait_log_prefix("send and the other thing").await;
}

#[tokio::test]
async fn a_held_text_expires() {
    let rig = rig_with(Timing {
        pending_ttl: Duration::from_millis(50),
        ..fast()
    })
    .await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "old news")).await;
    tokio::time::sleep(Duration::from_millis(120)).await;
    rig.tg
        .handle_update(callback(
            OWNER,
            OWNER,
            rig.fake.last_message_id(),
            &format!("s:{}", rig.agent),
        ))
        .await;
    assert!(rig.sent_log().is_empty());
    assert_eq!(rig.chat(OWNER).current_agent.as_deref(), Some(rig.agent.as_str()));
    assert_eq!(
        rig.fake.calls("answerCallbackQuery").last().unwrap()["text"],
        tr("en", "pending_expired", &[])
    );
}

#[tokio::test]
async fn a_reply_to_an_answer_goes_to_that_agent() {
    let mut rig = rig().await;
    rig.link(OWNER);
    let fox = new_agent(&rig.store, "Fox", "scout", ApprovalMode::Risky);
    // Fox answers (an answer in the app, with the chat on `all`), and the message is remembered.
    rig.set_answers(OWNER, "all");
    rig.sup.send(&fox, Inbound::user("hi")).await.unwrap();
    rig.wait_log_prefix("send hi").await;
    rig.push(&fox, assistant("Here is the **plan**")).await;
    rig.push(&fox, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    let answer_id = rig.fake.last_message_id();
    rig.store.tg_chat_set_current(OWNER, Some(&rig.agent)).unwrap();

    rig.tg
        .handle_update(reply_msg(OWNER, answer_id, "make it shorter"))
        .await;
    rig.wait_log_prefix("send make it shorter").await;
    // It went to Fox, not to the current agent Forge.
    assert!(!rig.out.lock().unwrap().contains_key(&rig.agent));
    // A reply to something that is not ours falls back to the current agent.
    rig.tg.handle_update(reply_msg(OWNER, 31337, "who is this for")).await;
    rig.wait_log_prefix("send who is this for").await;
    assert!(rig.out.lock().unwrap().contains_key(&rig.agent));
}

#[tokio::test]
async fn a_reply_to_a_deleted_agent_says_so() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.set_answers(OWNER, "all");
    let fox = new_agent(&rig.store, "Fox", "scout", ApprovalMode::Risky);
    rig.sup.send(&fox, Inbound::user("hi")).await.unwrap();
    rig.wait_log_prefix("send hi").await;
    rig.push(&fox, assistant("hello")).await;
    rig.push(&fox, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    let answer_id = rig.fake.last_message_id();
    rig.store.agent_delete(&fox).unwrap();
    rig.tg.handle_update(reply_msg(OWNER, answer_id, "still there?")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "agent_gone", &[])
    );
}

#[tokio::test]
async fn a_current_agent_that_was_deleted_is_forgotten() {
    let rig = rig().await;
    rig.link(OWNER);
    let fox = new_agent(&rig.store, "Fox", "scout", ApprovalMode::Risky);
    rig.store.tg_chat_set_current(OWNER, Some(&fox)).unwrap();
    rig.store.agent_delete(&fox).unwrap();
    rig.tg.handle_update(msg(OWNER, "anyone?")).await;
    assert!(rig.sent_log().is_empty());
    assert_eq!(text_of(&rig.cards(OWNER).pop().unwrap()), tr("en", "pick_agent", &[]));
}

#[tokio::test]
async fn text_with_no_agents_says_so() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.store.agent_delete(&rig.agent).unwrap();
    rig.tg.handle_update(msg(OWNER, "hello")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "no_agents", &[])
    );
}

#[tokio::test]
async fn voice_photos_and_files_are_text_only() {
    let rig = rig().await;
    rig.link(OWNER);
    for key in ["voice", "photo", "document", "sticker"] {
        let mut m = msg(OWNER, "");
        m["message"].as_object_mut().unwrap().remove("text");
        m["message"][key] = json!({ "file_id": "x" });
        rig.tg.handle_update(m).await;
    }
    assert!(rig.sent_log().is_empty());
    let sent = rig.fake.sent_to(OWNER);
    assert_eq!(sent.len(), 4);
    assert!(sent.iter().all(|b| text_of(b) == tr("en", "text_only", &[])));
}

#[tokio::test]
async fn a_message_to_a_paused_agent_says_it_waits() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.store.tg_chat_set_current(OWNER, Some(&rig.agent)).unwrap();
    rig.sup.set_paused(&rig.agent, true).await.unwrap();
    rig.tg.handle_update(msg(OWNER, "later")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "agent_paused", &[("agent", "Forge")])
    );
}

#[tokio::test]
async fn a_too_long_message_is_refused() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.store.tg_chat_set_current(OWNER, Some(&rig.agent)).unwrap();
    rig.tg.handle_update(msg(OWNER, &"x".repeat(101 * 1024))).await;
    assert!(rig.sent_log().is_empty());
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "message_too_long", &[])
    );
}

#[tokio::test]
async fn agents_command_lists_agents_with_role_and_status() {
    let rig = rig().await;
    rig.link(OWNER);
    new_agent(&rig.store, "Fox", "scout", ApprovalMode::Risky);
    rig.store.tg_chat_set_current(OWNER, Some(&rig.agent)).unwrap();
    rig.tg.handle_update(msg(OWNER, "/agents")).await;
    let list = rig.fake.sent_to(OWNER).pop().unwrap();
    let text = text_of(&list);
    assert!(text.contains("Forge") && text.contains("builder"), "{text}");
    assert!(text.contains("Fox") && text.contains("scout"), "{text}");
    let keys = buttons(&list);
    assert_eq!(keys.len(), 2);
    assert!(keys.iter().all(|(_, d)| d.starts_with("c:")));
    assert!(
        keys.iter()
            .any(|(label, d)| d == &format!("c:{}", rig.agent) && label.starts_with('✓'))
    );

    // Making one current needs no pending text.
    let fox = keys.iter().find(|(l, _)| l.contains("Fox")).unwrap().1.clone();
    rig.tg
        .handle_update(callback(OWNER, OWNER, rig.fake.last_message_id(), &fox))
        .await;
    assert_eq!(
        rig.chat(OWNER).current_agent.as_deref(),
        Some(fox.trim_start_matches("c:"))
    );
    assert!(rig.sent_log().is_empty());
}

#[tokio::test]
async fn status_command_reports_version_and_counts() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.pending_approval("git push origin main").await;
    // The agent shows as waiting for the person once its status event is stored.
    for _ in 0..300 {
        let status = rig.store.agent_view(&rig.agent).unwrap().unwrap().status;
        if status == Some(crate::event::AgentStatus::NeedsYou) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    rig.fake.clear_calls();
    rig.tg.handle_update(msg(OWNER, "/status")).await;
    let text = text_of(rig.fake.sent_to(OWNER).last().unwrap());
    assert!(text.contains(crate::rpc::VERSION), "{text}");
    let expected = tr(
        "en",
        "status_text",
        &[
            ("version", crate::rpc::VERSION),
            ("working", "0"),
            ("total", "1"),
            ("pending", "1"),
        ],
    );
    // The agent is waiting for the person, so it is not counted as working.
    assert_eq!(text, expected);
}

#[tokio::test]
async fn help_unknown_commands_and_the_bot_name_suffix() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "/help")).await;
    assert_eq!(text_of(rig.fake.sent_to(OWNER).last().unwrap()), tr("en", "help", &[]));
    rig.tg.handle_update(msg(OWNER, "/nonsense")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "unknown_command", &[])
    );
    rig.tg.handle_update(msg(OWNER, "/help@bandito_test_bot")).await;
    assert_eq!(rig.fake.sent_to(OWNER).len(), 3);
    // A command for another bot is not ours.
    rig.tg.handle_update(msg(OWNER, "/help@some_other_bot")).await;
    assert_eq!(rig.fake.sent_to(OWNER).len(), 3);
}

#[tokio::test]
async fn unlink_says_goodbye_and_forgets_the_chat() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "/unlink")).await;
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_none());
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "unlinked_bye", &[])
    );
    // The chat is a stranger now.
    rig.tg.handle_update(msg(OWNER, "/agents")).await;
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "not_linked", &[])
    );
}

#[tokio::test]
async fn the_language_follows_the_sender() {
    let rig = rig().await;
    rig.link(OWNER);
    for (code, want) in [
        ("ru", "ru"),
        ("de-AT", "de"),
        ("pt", "pt-BR"),
        ("pt-PT", "pt-BR"),
        ("zh-hans", "zh-Hans"),
        ("zh_TW", "zh-Hans"),
        ("ja", "ja"),
        ("sv", "en"),
    ] {
        assert_eq!(map_language(Some(code)), want, "{code}");
    }
    assert_eq!(map_language(None), "en");
    rig.tg.handle_update(private_msg(OWNER, OWNER, "fr", "/help")).await;
    assert_eq!(rig.chat(OWNER).language, "fr");
    assert_eq!(text_of(rig.fake.sent_to(OWNER).last().unwrap()), tr("fr", "help", &[]));
}

#[tokio::test]
async fn telegram_unlink_and_update_chat_from_the_app() {
    let rig = rig().await;
    rig.link(OWNER);
    let reply = rig.tg.update_chat(OWNER, Some(false), Some("all")).unwrap();
    assert!(reply["chats"][0]["approvals"] == json!(false));
    assert_eq!(reply["chats"][0]["answers"], "all");
    assert!(rig.tg.update_chat(OWNER, None, Some("sometimes")).is_err());
    assert!(rig.tg.update_chat(31337, Some(true), None).is_err());

    rig.tg.unlink(OWNER).await.unwrap();
    // The farewell went out before the chat was removed.
    assert_eq!(
        text_of(rig.fake.sent_to(OWNER).last().unwrap()),
        tr("en", "unlinked_bye", &[])
    );
    assert!(rig.store.tg_chat_get(OWNER).unwrap().is_none());
    assert!(rig.tg.unlink(OWNER).await.is_err());
}

// ---- 6. answer modes ----

#[tokio::test]
async fn answers_follow_the_chat_mode() {
    let mut rig = rig().await;
    for chat in [11, 12, 13] {
        rig.link(chat);
        rig.store.tg_chat_update(chat, Some(false), None).unwrap();
    }
    rig.set_answers(11, "telegram");
    rig.set_answers(12, "all");
    rig.set_answers(13, "none");

    // A turn started in the app: only the chat on `all` hears of it.
    rig.sup.send(&rig.agent, Inbound::user("from the app")).await.unwrap();
    rig.wait_log_prefix("send from the app").await;
    let forge = rig.agent.clone();
    rig.push(&forge, assistant("App **answer**")).await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    assert!(rig.fake.sent_to(11).is_empty());
    assert!(rig.fake.sent_to(13).is_empty());
    let got = rig.fake.sent_to(12);
    assert_eq!(got.len(), 1);
    assert_eq!(got[0]["parse_mode"], "HTML");
    assert_eq!(text_of(&got[0]), "<b>Forge</b>\nApp <b>answer</b>");

    // A turn started from chat 11: chat 11 (`telegram`) and chat 12 (`all`) hear of it; chat 13 never does.
    rig.fake.clear_calls();
    rig.store.tg_chat_set_current(11, Some(&forge)).unwrap();
    rig.tg.handle_update(msg(11, "from telegram")).await;
    rig.wait_log_prefix("send from telegram").await;
    rig.push(&forge, assistant("first thought")).await;
    rig.push(&forge, assistant("Telegram <answer> & more")).await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    for chat in [11, 12] {
        let got = rig.fake.sent_to(chat);
        assert_eq!(got.len(), 1, "chat {chat}: {got:?}");
        // Only the last message of the turn.
        assert_eq!(text_of(&got[0]), "<b>Forge</b>\nTelegram &lt;answer&gt; &amp; more");
    }
    assert!(rig.fake.sent_to(13).is_empty());
}

#[tokio::test]
async fn a_queued_telegram_message_is_still_recognised() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.store.tg_chat_update(OWNER, Some(false), None).unwrap();
    let forge = rig.agent.clone();
    rig.store.tg_chat_set_current(OWNER, Some(&forge)).unwrap();
    // The agent is busy with an app turn when the Telegram message comes in, so it waits in the queue.
    rig.sup.send(&forge, Inbound::user("busy")).await.unwrap();
    rig.wait_log_prefix("send busy").await;
    rig.tg.handle_update(msg(OWNER, "queued one")).await;
    rig.push(&forge, assistant("answer to busy")).await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    assert!(
        rig.fake.sent_to(OWNER).is_empty(),
        "the app turn leaked to a `telegram` chat"
    );
    rig.wait_log_prefix("send queued one").await;
    rig.push(&forge, assistant("answer to queued")).await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    let got = rig.fake.sent_to(OWNER);
    assert_eq!(got.len(), 1, "{got:?}");
    assert!(text_of(&got[0]).contains("answer to queued"));
}

#[tokio::test]
async fn a_turn_without_an_answer_sends_nothing() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.set_answers(OWNER, "all");
    let forge = rig.agent.clone();
    rig.sup.send(&forge, Inbound::user("quiet")).await.unwrap();
    rig.wait_log_prefix("send quiet").await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    assert!(rig.fake.sent_to(OWNER).is_empty());
}

#[tokio::test]
async fn long_answers_are_cut_with_a_pointer_to_the_app() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.set_answers(OWNER, "all");
    let forge = rig.agent.clone();
    rig.sup.send(&forge, Inbound::user("write a lot")).await.unwrap();
    rig.wait_log_prefix("send write a lot").await;
    rig.push(&forge, assistant(&"Я".repeat(5000))).await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    let text = text_of(&rig.fake.sent_to(OWNER)[0]);
    assert!(text.chars().count() <= 4096, "{}", text.chars().count());
    assert!(
        text.ends_with(&tr("en", "full_in_app", &[])),
        "{}",
        &text[text.len().saturating_sub(80)..]
    );
}

// ---- 7. the token never shows ----

#[test]
fn the_token_is_not_in_the_curl_arguments_or_the_status() {
    let args = curl_argv();
    assert_eq!(args, ["-q", "--config", "-"]);
    assert!(args.iter().all(|a| !a.contains(TOKEN) && !a.contains("bot")));

    // The token is in the configuration that goes to curl's standard input, nowhere else.
    let config = curl_config("https://api.telegram.org", TOKEN, "getMe", &json!({}), 10).unwrap();
    assert!(config.contains(&format!("https://api.telegram.org/bot{TOKEN}/getMe")));
    assert!(config.contains("proto = \"=https\""));
    assert!(!config.contains("=https,http"));
    // The body is on stdin too, and a body with a quote or a newline cannot start another option line.
    let tricky = json!({ "text": "a\"b\nurl = \"file:///etc/passwd\"" });
    let config = curl_config("https://api.telegram.org", TOKEN, "sendMessage", &tricky, 10).unwrap();
    assert_eq!(config.lines().filter(|l| l.starts_with("url")).count(), 1);
    assert!(!config.contains("file:///etc/passwd\"\n"));
    // A token with a control character is refused rather than split into lines.
    assert!(curl_config("https://api.telegram.org", "1\nurl=x", "getMe", &json!({}), 10).is_err());
}

#[test]
fn scrub_removes_the_token_and_anything_shaped_like_one() {
    let line = format!("curl: (6) Could not resolve host while fetching https://api.telegram.org/bot{TOKEN}/getMe");
    let clean = scrub(&line, TOKEN);
    assert!(!clean.contains(TOKEN) && !clean.contains("AAH_testtoken"), "{clean}");
    // A token of another shape (the old one, after a change) is caught by its form.
    let other = "failed: https://api.telegram.org/bot987654321:ZZZ_other_token_0123456789abcdefghij/sendMessage";
    let clean = scrub(other, TOKEN);
    assert!(!clean.contains("987654321") && !clean.contains("ZZZ_other"), "{clean}");
    assert!(clean.contains("api.telegram.org"));
    // Text with no token stays.
    assert_eq!(scrub("connection refused", TOKEN), "connection refused");
    // The bare token (no URL around it) goes too.
    assert!(!scrub(&format!("bad {TOKEN} bad"), TOKEN).contains("AAH_"));
}

#[tokio::test]
async fn errors_never_carry_the_token() {
    // Nothing listens here, so curl fails and says where it tried.
    let api = Api::with_base("http://127.0.0.1:1");
    let err = api.call(TOKEN, "getMe", json!({}), 5).await.unwrap_err();
    let ApiError::Network(message) = &err else {
        panic!("expected a network error, got {err:?}")
    };
    for text in [message.clone(), err.to_string(), format!("{err:?}")] {
        assert!(!text.contains(TOKEN) && !text.contains("AAH_testtoken"), "{text}");
    }

    // The fake's error texts are not echoed with a URL either.
    let fake = FakeTelegram::start("1111111:BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB").await;
    let api = Api::with_base(&fake.base);
    let err = api.call(TOKEN, "getMe", json!({}), 5).await.unwrap_err();
    assert!(matches!(err, ApiError::Unauthorized), "{err:?}");
    assert!(!err.to_string().contains("AAH_"));
}

#[tokio::test]
async fn the_token_goes_in_the_path_only() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.tg.handle_update(msg(OWNER, "/help")).await;
    for call in rig.fake.all_calls() {
        assert_eq!(call.bot, format!("bot{TOKEN}"));
        assert!(!call.body.to_string().contains(TOKEN), "{}", call.body);
    }
}

#[tokio::test]
async fn the_token_is_a_hidden_secret_for_no_agent() {
    let rig = rig().await;
    let hidden = rig
        .store
        .secret_list()
        .unwrap()
        .into_iter()
        .find(|s| s.name == super::TOKEN_SECRET)
        .expect("the token is kept as a secret");
    assert!(hidden.agents.is_empty());
    assert!(super::TOKEN_SECRET.starts_with(crate::integrations::TELEGRAM_SECRET_PREFIX));
    assert!(
        rig.store
            .secrets_for_agent(&rig.agent)
            .unwrap()
            .iter()
            .all(|(name, _)| name != super::TOKEN_SECRET)
    );
    let status = rig.tg.status().unwrap().to_string();
    assert!(!status.contains(TOKEN) && !status.contains("AAH_"), "{status}");
}

// ---- 8. text conversion ----

#[test]
fn markdown_is_escaped_and_converted() {
    assert_eq!(markdown_to_html("a < b & c > d"), "a &lt; b &amp; c &gt; d");
    assert_eq!(
        markdown_to_html("**жирный** и `код`"),
        "<b>жирный</b> и <code>код</code>"
    );
    assert_eq!(markdown_to_html("`a<b>&c`"), "<code>a&lt;b&gt;&amp;c</code>");
    assert_eq!(markdown_to_html("**<i>x</i>**"), "<b>&lt;i&gt;x&lt;/i&gt;</b>");
    assert_eq!(
        markdown_to_html("before\n```rust\nlet a = 1 < 2;\nlet b = \"**\";\n```\nafter **b**"),
        "before\n<pre>let a = 1 &lt; 2;\nlet b = \"**\";</pre>\nafter <b>b</b>"
    );
    // Code wins over bold, and bold does not reach into code.
    assert_eq!(markdown_to_html("`a**b**c`"), "<code>a**b**c</code>");
    assert_eq!(markdown_to_html("**a `b` c**"), "<b>a <code>b</code> c</b>");
    // Nothing open stays open: stray markers are plain text.
    assert_eq!(markdown_to_html("**abc"), "**abc");
    assert_eq!(markdown_to_html("`abc"), "`abc");
    assert_eq!(markdown_to_html("a ** b"), "a ** b");
    assert_eq!(markdown_to_html("****"), "****");
    assert_eq!(markdown_to_html("``"), "``");
    assert_eq!(markdown_to_html("```\nabc"), "<pre>abc</pre>");
    assert_eq!(markdown_to_html(""), "");
    // A bold or code span does not run across lines.
    assert_eq!(markdown_to_html("**a\nb**"), "**a\nb**");
}

#[test]
fn truncation_counts_characters_not_bytes() {
    assert_eq!(truncate_chars("жжжж😀😀", 5), "жжжж😀");
    assert_eq!(truncate_chars("жжжж😀😀", 6), "жжжж😀😀");
    assert_eq!(truncate_chars("жжжж😀😀", 100), "жжжж😀😀");
    assert_eq!(truncate_chars("abc", 0), "");
    assert_eq!(truncate_chars("", 3), "");
    assert!(truncate_chars(&"я".repeat(10_000), 4096).is_char_boundary(8192));
}

#[test]
fn an_answer_always_fits_in_one_message() {
    let notice = tr("en", "full_in_app", &[]);
    // Cyrillic, emoji and characters that grow when escaped, each far past the limit.
    for filler in ["ж", "😀", "<", "&", "`", "**x** "] {
        let text = filler.repeat(6000);
        let html = format_answer("Forge", &text, &notice);
        assert!(html.chars().count() <= 4096, "{filler}: {}", html.chars().count());
        assert!(html.starts_with("<b>Forge</b>\n"));
        assert!(html.ends_with(&notice), "{filler}");
        // No entity is cut in half, and every tag is closed.
        for (i, _) in html.match_indices('&') {
            let rest = &html[i..];
            assert!(
                rest.starts_with("&lt;") || rest.starts_with("&gt;") || rest.starts_with("&amp;"),
                "{filler}"
            );
        }
        assert_eq!(html.matches("<b>").count(), html.matches("</b>").count(), "{filler}");
        assert_eq!(
            html.matches("<code>").count(),
            html.matches("</code>").count(),
            "{filler}"
        );
        assert_eq!(
            html.matches("<pre>").count(),
            html.matches("</pre>").count(),
            "{filler}"
        );
    }
    // A fence cut in the middle is closed.
    let text = format!("```\n{}", "x".repeat(6000));
    let html = format_answer("Forge", &text, &notice);
    assert_eq!(html.matches("<pre>").count(), html.matches("</pre>").count());
    // A short answer is not touched and has no notice.
    assert_eq!(format_answer("Forge", "hi", &notice), "<b>Forge</b>\nhi");
    // The name is escaped.
    assert!(format_answer("A<B", "hi", &notice).starts_with("<b>A&lt;B</b>"));
}

// ---- 9. strings ----

fn placeholders(text: &str) -> BTreeSet<String> {
    let mut found = BTreeSet::new();
    let mut rest = text;
    while let Some(open) = rest.find('{') {
        let Some(close) = rest[open..].find('}') else { break };
        found.insert(rest[open + 1..open + close].to_string());
        rest = &rest[open + close + 1..];
    }
    found
}

#[test]
fn every_string_is_in_all_nine_languages_with_the_same_placeholders() {
    assert_eq!(
        LANGUAGES,
        ["en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans"]
    );
    let table: Value = serde_json::from_str(include_str!("../telegram_strings.json")).unwrap();
    let table = table.as_object().expect("the table is an object of keys");
    assert!(table.len() >= 30, "only {} strings", table.len());
    for (key, langs) in table {
        let langs = langs.as_object().unwrap_or_else(|| panic!("{key} is not an object"));
        let names: BTreeSet<&str> = langs.keys().map(String::as_str).collect();
        let want: BTreeSet<&str> = LANGUAGES.iter().copied().collect();
        assert_eq!(names, want, "{key}: languages differ");
        let english = placeholders(langs["en"].as_str().unwrap());
        for lang in LANGUAGES {
            let text = langs[lang]
                .as_str()
                .unwrap_or_else(|| panic!("{key}.{lang} is not a string"));
            assert!(!text.trim().is_empty(), "{key}.{lang} is empty");
            assert_eq!(placeholders(text), english, "{key}.{lang}: placeholders differ");
            assert!(text.chars().count() <= 1500, "{key}.{lang} is very long");
            // The texts are sent as HTML: nothing in them may look like markup.
            assert!(!text.contains(['<', '>', '&']), "{key}.{lang} holds markup characters");
        }
    }
}

#[test]
fn the_tone_rules_of_the_languages_hold() {
    let table: Value = serde_json::from_str(include_str!("../telegram_strings.json")).unwrap();
    for (key, langs) in table.as_object().unwrap() {
        let de = langs["de"].as_str().unwrap().to_lowercase();
        assert!(
            ![" du ", " dein", " dich ", " dir "]
                .iter()
                .any(|w| format!(" {de} ").contains(w)),
            "{key}.de is not formal"
        );
        let fr = langs["fr"].as_str().unwrap().to_lowercase();
        assert!(
            ![" tu ", " ton ", " ta ", " tes "]
                .iter()
                .any(|w| format!(" {fr} ").contains(w)),
            "{key}.fr says tu"
        );
        let zh = langs["zh-Hans"].as_str().unwrap();
        assert!(
            !zh.contains("智能体") && !zh.contains("助手"),
            "{key}.zh uses another word for agents"
        );
    }
    assert!(tr("zh-Hans", "help", &[]).contains("代理"));
}

#[test]
fn texts_fill_their_placeholders_and_fall_back_to_english() {
    assert_eq!(
        tr("en", "agent_paused", &[("agent", "Forge")]),
        tr("en", "agent_paused", &[("agent", "Forge")])
    );
    assert!(tr("en", "agent_paused", &[("agent", "Forge")]).contains("Forge"));
    assert!(!tr("ru", "agent_paused", &[("agent", "Forge")]).contains('{'));
    assert_eq!(tr("xx", "help", &[]), tr("en", "help", &[]));
    // An unknown key shows itself rather than nothing.
    assert_eq!(tr("en", "no_such_key", &[]), "no_such_key");
    assert!(strings::has_key("help"));
    // A value that looks like a placeholder is not filled in a second time.
    assert!(tr("en", "agent_paused", &[("agent", "{agent}")]).contains("{agent}"));
}

#[test]
fn every_string_the_code_asks_for_exists_and_none_is_unused() {
    let sources = [
        include_str!("mod.rs"),
        include_str!("handlers.rs"),
        include_str!("events.rs"),
    ];
    // What the code asks for: the first literal after the comma of a `tr(lang, "key"` or `say(chat, "key"` call.
    let mut asked = BTreeSet::new();
    // Every literal that names a key of the table, wherever it is (a `match` arm returns a key too).
    let mut named = BTreeSet::new();
    let table: Value = serde_json::from_str(include_str!("../telegram_strings.json")).unwrap();
    let keys: BTreeSet<String> = table.as_object().unwrap().keys().cloned().collect();
    for source in sources {
        for opener in ["tr(", "say("] {
            for (at, _) in source.match_indices(opener) {
                let before = source[..at].chars().last().unwrap_or(' ');
                if before.is_ascii_alphanumeric() || before == '_' {
                    continue;
                }
                let rest = &source[at..];
                let Some(comma) = rest.find(", \"") else { continue };
                // The literal must be the call's own second argument, not a later one.
                if comma > 40 || rest[..comma].contains([';', '"', '{']) {
                    continue;
                }
                let after = &rest[comma + 3..];
                if let Some(end) = after.find('"') {
                    let key = &after[..end];
                    if key.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
                        asked.insert(key.to_string());
                    }
                }
            }
        }
        for part in source.split('"').skip(1).step_by(2) {
            if keys.contains(part) {
                named.insert(part.to_string());
            }
        }
    }
    assert!(asked.len() >= 20, "found only {asked:?}");
    for key in &asked {
        assert!(
            strings::has_key(key),
            "the code asks for the string {key}, which the table lacks"
        );
    }
    for key in &keys {
        assert!(
            named.contains(key),
            "the string {key} is in the table but nothing names it"
        );
    }
}

// ---- the sending side ----

#[tokio::test]
async fn messages_to_one_chat_are_spaced() {
    let rig = rig_with(Timing {
        send_gap: Duration::from_millis(150),
        ..fast()
    })
    .await;
    rig.link(OWNER);
    rig.link(2);
    for _ in 0..3 {
        rig.tg.handle_update(msg(OWNER, "/help")).await;
    }
    rig.tg.handle_update(msg(2, "/help")).await;
    let calls = rig.fake.calls_full("sendMessage");
    let mine: Vec<_> = calls.iter().filter(|c| c.body["chat_id"] == OWNER).collect();
    assert_eq!(mine.len(), 3);
    for pair in mine.windows(2) {
        let gap = pair[1].at - pair[0].at;
        assert!(gap >= Duration::from_millis(140), "{gap:?}");
    }
}

#[tokio::test]
async fn a_rate_limited_send_is_retried_after_the_wait() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.fake
        .fail_next("sendMessage", 429, "Too Many Requests: retry after 1", Some(1));
    rig.tg.handle_update(msg(OWNER, "/help")).await;
    assert_eq!(rig.fake.calls("sendMessage").len(), 2);
}

#[tokio::test]
async fn html_that_telegram_rejects_is_sent_again_as_plain_text() {
    let mut rig = rig().await;
    rig.link(OWNER);
    rig.set_answers(OWNER, "all");
    let forge = rig.agent.clone();
    rig.sup.send(&forge, Inbound::user("x")).await.unwrap();
    rig.wait_log_prefix("send x").await;
    rig.fake.fail_next(
        "sendMessage",
        400,
        "Bad Request: can't parse entities: Unsupported start tag",
        None,
    );
    rig.push(&forge, assistant("Use **bold** & <tags>")).await;
    rig.push(&forge, done()).await;
    rig.feed_until(|b| matches!(b, EventBody::TurnCompleted { .. })).await;
    let sent = rig.fake.sent_to(OWNER);
    assert_eq!(sent.len(), 2);
    assert!(sent[1].get("parse_mode").is_none());
    let plain = text_of(&sent[1]);
    assert!(!plain.contains("<b>") && !plain.contains("&lt;"), "{plain}");
    assert!(
        plain.contains("Forge") && plain.contains("bold") && plain.contains("<tags>"),
        "{plain}"
    );
}

#[tokio::test]
async fn an_error_from_one_chat_does_not_stop_the_others() {
    let mut rig = rig().await;
    rig.link(11);
    rig.link(12);
    // The bot was blocked in chat 11: Telegram says so, and chat 12 still gets its card.
    rig.fake
        .fail_next("sendMessage", 403, "Forbidden: bot was blocked by the user", None);
    let id = rig.pending_approval("ls").await;
    // Both were tried (the fake records the refused call too), and one card is kept.
    assert_eq!(rig.fake.sent_to(11).len() + rig.fake.sent_to(12).len(), 2);
    assert_eq!(rig.store.tg_msgs_for_ref("approval", &id).unwrap().len(), 1);
}

// ---- the poll loop and the token calls ----

#[tokio::test]
async fn setting_a_token_checks_it_and_starts_polling() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());

    assert_eq!(
        tg.status().unwrap(),
        json!({ "configured": false, "bot": null, "running": false, "last_error": null, "chats": [] })
    );
    // Not the right shape: refused before any request.
    for bad in [
        "",
        "abc",
        "123:short",
        "12345:has space in it 0123456789abcdefghijkl",
        "123456789:AAH\n0123456789abcdefghijklmnop",
    ] {
        let err = tg.set_token(bad).await.unwrap_err();
        assert_eq!(err.reason, "invalid_token", "{bad:?}");
    }
    assert!(fake.all_calls().is_empty());
    // The right shape, but Telegram does not know it.
    let err = tg
        .set_token("999999999:ZZZ_unknown_token_0123456789abcdefghij")
        .await
        .unwrap_err();
    assert_eq!(err.reason, "invalid_token");
    assert!(!err.message.contains("ZZZ_unknown"));
    assert!(store.secret_get(super::TOKEN_SECRET).unwrap().is_none());

    let status = tg.set_token(TOKEN).await.unwrap();
    assert_eq!(status["configured"], true);
    assert_eq!(
        status["bot"],
        json!({ "username": "bandito_test_bot", "name": "Bandito Test" })
    );
    assert_eq!(status["last_error"], Value::Null);
    assert_eq!(store.secret_get(super::TOKEN_SECRET).unwrap().as_deref(), Some(TOKEN));
    // The poll starts by dropping any webhook, then polls with the long timeout and the right updates.
    fake.wait_calls("deleteWebhook", 1).await;
    let polls = fake.wait_calls("getUpdates", 1).await;
    assert_eq!(
        polls[0]["allowed_updates"],
        json!(["message", "callback_query", "my_chat_member"])
    );
    let all = fake.all_calls();
    let webhook = all.iter().position(|c| c.method == "deleteWebhook").unwrap();
    let first_poll = all.iter().position(|c| c.method == "getUpdates").unwrap();
    assert!(webhook < first_poll);
    assert_eq!(tg.status().unwrap()["running"], true);

    // The same token again does no harm: no second poller, the same answer.
    let again = tg.set_token(TOKEN).await.unwrap();
    assert_eq!(again["configured"], true);
    assert_eq!(again["running"], true);
    tg.stop_for_test().await;
}

#[tokio::test]
async fn polled_updates_are_handled_and_the_offset_is_kept() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());
    tg.set_token(TOKEN).await.unwrap();

    let code = tg.link_start().unwrap()["code"].as_str().unwrap().to_string();
    let id = fake.push_update(msg(OWNER, &format!("/start {code}")));
    for _ in 0..300 {
        if store.tg_chat_get(OWNER).unwrap().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(store.tg_chat_get(OWNER).unwrap().is_some());
    for _ in 0..300 {
        if store.tg_state_get("offset").unwrap().as_deref() == Some(&(id + 1).to_string()) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(store.tg_state_get("offset").unwrap(), Some((id + 1).to_string()));
    // The next poll asks from the saved offset.
    for _ in 0..300 {
        if fake.calls("getUpdates").iter().any(|p| p["offset"] == id + 1) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let polls = fake.calls("getUpdates");
    assert!(polls.iter().any(|p| p["offset"] == id + 1), "{polls:?}");
    tg.stop_for_test().await;

    // A restart resumes from the saved offset, not from zero.
    fake.clear_calls();
    let again = Telegram::with_base(
        Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None),
        &fake.base,
        fast(),
    );
    again.start();
    let polls = fake.wait_calls("getUpdates", 1).await;
    assert_eq!(polls[0]["offset"], id + 1);
    again.stop_for_test().await;
}

#[tokio::test]
async fn a_conflict_is_reported_and_polling_goes_on() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());
    fake.fail_next(
        "getUpdates",
        409,
        "Conflict: terminated by other getUpdates request",
        None,
    );
    tg.set_token(TOKEN).await.unwrap();
    wait_for(|| tg.status().unwrap()["last_error"] == "conflict").await;
    assert_eq!(tg.status().unwrap()["running"], true);
    // After the wait it polls again, and the error clears with the first good answer.
    wait_for(|| tg.status().unwrap()["last_error"].is_null()).await;
    tg.stop_for_test().await;
}

#[tokio::test]
async fn an_unauthorized_token_stops_polling() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());
    fake.fail_next("getUpdates", 401, "Unauthorized", None);
    tg.set_token(TOKEN).await.unwrap();
    wait_for(|| tg.status().unwrap()["last_error"] == "unauthorized").await;
    wait_for(|| tg.status().unwrap()["running"] == false).await;
    let polls = fake.calls("getUpdates").len();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(fake.calls("getUpdates").len(), polls, "polling went on after a 401");
    // The token stays configured: the person fixes it with a new one.
    assert_eq!(tg.status().unwrap()["configured"], true);
}

#[tokio::test]
async fn a_network_failure_backs_off_and_recovers() {
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    // Nothing listens on port 1.
    let tg = Telegram::with_base(sup, "http://127.0.0.1:1", fast());
    tg.seed_for_test(TOKEN, "bandito_test_bot", "Bandito Test");
    tg.start();
    wait_for(|| tg.status().unwrap()["last_error"] == "network").await;
    assert_eq!(tg.status().unwrap()["running"], true);
    assert!(!tg.status().unwrap().to_string().contains("AAH_"));
    tg.stop_for_test().await;
}

#[tokio::test]
async fn a_rate_limited_poll_waits_and_goes_on() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());
    fake.fail_next("getUpdates", 429, "Too Many Requests: retry after 1", Some(1));
    tg.set_token(TOKEN).await.unwrap();
    fake.wait_calls("getUpdates", 2).await;
    assert!(tg.status().unwrap()["last_error"].is_null());
    tg.stop_for_test().await;
}

#[tokio::test]
async fn removing_the_token_forgets_everything() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());
    tg.set_token(TOKEN).await.unwrap();
    store.tg_chat_link(OWNER, OWNER, "Ann", "en", now_ms()).unwrap();
    store.tg_msg_add(OWNER, 5, "agent", "answer", "agent").unwrap();
    store.tg_state_set("offset", "77").unwrap();

    let status = tg.remove_token().await.unwrap();
    assert_eq!(
        status,
        json!({ "configured": false, "bot": null, "running": false, "last_error": null, "chats": [] })
    );
    assert!(store.secret_get(super::TOKEN_SECRET).unwrap().is_none());
    assert!(store.tg_chat_list().unwrap().is_empty());
    assert!(store.tg_msg_get(OWNER, 5).unwrap().is_none());
    assert!(store.tg_state_get("offset").unwrap().is_none());
    // Removing again is fine; and a poll in flight does not bring anything back.
    tg.remove_token().await.unwrap();
    let polls = fake.calls("getUpdates").len();
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert!(fake.calls("getUpdates").len() <= polls + 1);
}

#[tokio::test]
async fn another_bot_starts_clean() {
    let fake = FakeTelegram::start(TOKEN).await;
    let store = Arc::new(Store::open_in_memory().unwrap());
    let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
    let tg = Telegram::with_base(sup, &fake.base, fast());
    tg.set_token(TOKEN).await.unwrap();
    store.tg_chat_link(OWNER, OWNER, "Ann", "en", now_ms()).unwrap();
    store.tg_state_set("offset", "77").unwrap();
    // A second token the fake also accepts.
    let other = "555555555:CCC_other_token_0123456789abcdefghijkl";
    fake.add_token(other);
    let status = tg.set_token(other).await.unwrap();
    assert_eq!(status["chats"], json!([]));
    assert!(store.tg_state_get("offset").unwrap().is_none());
    assert_eq!(store.secret_get(super::TOKEN_SECRET).unwrap().as_deref(), Some(other));
    tg.stop_for_test().await;
}

#[tokio::test]
async fn status_lists_the_chats() {
    let rig = rig().await;
    rig.link(OWNER);
    rig.store.tg_chat_update(OWNER, Some(false), Some("all")).unwrap();
    let status = rig.tg.status().unwrap();
    assert_eq!(status["configured"], true);
    assert_eq!(status["bot"]["username"], "bandito_test_bot");
    let chat = &status["chats"][0];
    assert_eq!(chat["chat_id"], OWNER);
    assert_eq!(chat["title"], "Ann");
    assert_eq!(chat["language"], "en");
    assert_eq!(chat["approvals"], false);
    assert_eq!(chat["answers"], "all");
    assert!(chat["linked_at"].as_i64().unwrap() > 0);
    let keys: BTreeSet<&str> = chat.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(
        keys,
        BTreeSet::from(["chat_id", "title", "language", "linked_at", "approvals", "answers"])
    );
}

#[tokio::test]
async fn old_message_rows_are_pruned() {
    let rig = rig().await;
    rig.store.tg_msg_add(OWNER, 1, "a", "answer", "a").unwrap();
    let week = 7 * 24 * 3600 * 1000;
    assert_eq!(rig.store.tg_msgs_prune(now_ms() - week).unwrap(), 0);
    assert_eq!(rig.store.tg_msgs_prune(now_ms() + 1000).unwrap(), 1);
    assert!(rig.store.tg_msg_get(OWNER, 1).unwrap().is_none());
}

async fn wait_for(cond: impl Fn() -> bool) {
    for _ in 0..500 {
        if cond() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("the condition never came true");
}
