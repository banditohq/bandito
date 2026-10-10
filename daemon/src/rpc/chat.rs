//! Chat methods: the forms an agent asks with, reactions on messages, and files attached to messages.
//! See docs/ARCHITECTURE.md#forms, #reactions and #replies-and-attachments.

use super::{App, INVALID_PARAMS, METHOD_NOT_FOUND, Peer, RpcError, RpcResult, SERVER_ERROR, ok, params};
use crate::attachments::{self, Attachment};
use crate::chat;
use crate::event::{EventBody, ReactionBy};
use crate::forms::{self, Outcome};
use crate::mentions::{self, Mention, MentionKind, Resolved};
use crate::store::{Agent, FormStatus};
use crate::supervisor::{APPROVAL_TTL_MS, FormReply};
use base64::Engine;
use serde::Deserialize;
use serde_json::{Value, json};
use std::time::Duration;

/// How long `forms.agent.ask` waits for the human: the approval TTL. The caller's socket waits as long.
pub const FORM_WAIT: Duration = Duration::from_millis(APPROVAL_TTL_MS as u64);

/// Most files attached to one message.
pub const MAX_ATTACHMENTS: usize = 20;

/// Serves the chat methods. Every name in the match is routed here by `rpc::dispatch`.
pub async fn dispatch(app: &App, _peer: &Peer, method: &str, p: Value) -> RpcResult {
    match method {
        "forms.agent.ask" => {
            let a: AskParams = params(p)?;
            let spec = forms::parse_spec(&a.form).map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
            let outcome = app
                .sup
                .ask_form(&a.agent_id, spec, FORM_WAIT)
                .await
                .map_err(|e| RpcError::new(SERVER_ERROR, format!("{e:#}")))?;
            ok(outcome.to_json())
        }
        "forms.answer" => {
            let a: AnswerParams = params(p)?;
            let store = &app.sup.hub().store;
            let form = store
                .form_get(&a.form_id)
                .map_err(server)?
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no form {}", a.form_id)))?;
            if form.status != FormStatus::Pending {
                return Err(RpcError::new(INVALID_PARAMS, "already_answered"));
            }
            let spec = forms::parse_spec(&form.spec).map_err(|e| RpcError::new(SERVER_ERROR, e))?;
            let outcome = match a.action.as_str() {
                "submit" => {
                    let values = forms::check_values(&spec, a.values.as_ref().unwrap_or(&Value::Null))
                        .map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
                    Outcome::Submit(values)
                }
                "reject" => {
                    let comment =
                        forms::check_comment(a.comment.as_ref()).map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
                    Outcome::Reject(comment)
                }
                other => {
                    return Err(RpcError::new(
                        INVALID_PARAMS,
                        format!("action must be submit or reject, got {other}"),
                    ));
                }
            };
            match app.sup.answer_form(&a.form_id, outcome).await.map_err(server)? {
                FormReply::Answered => ok(json!({})),
                FormReply::AlreadyAnswered => Err(RpcError::new(INVALID_PARAMS, "already_answered")),
                FormReply::Expired => Err(RpcError::new(INVALID_PARAMS, "expired")),
            }
        }
        "forms.list" => {
            let l: ListParams = params(p)?;
            let status = match l.status.as_deref() {
                None => None,
                Some(s) => Some(
                    FormStatus::parse(s).ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("unknown status {s}")))?,
                ),
            };
            let list = app
                .sup
                .hub()
                .store
                .form_list(l.agent_id.as_deref(), status)
                .map_err(server)?;
            ok(list
                .iter()
                .map(|f| {
                    json!({
                        "id": f.id,
                        "agent_id": f.agent_id,
                        "status": f.status.as_str(),
                        "spec": f.spec,
                        "answer": f.answer,
                        "created_at": f.created_at,
                        "answered_at": f.answered_at,
                    })
                })
                .collect::<Vec<_>>())
        }
        "messages.react" => {
            let r: ReactParams = params(p)?;
            let store = &app.sup.hub().store;
            require_message(app, &r.agent_id, r.seq)?;
            if let Some(e) = &r.emoji {
                chat::check_emoji(e).map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
            }
            store
                .reaction_set(&r.agent_id, r.seq, ReactionBy::User, r.emoji.as_deref())
                .map_err(server)?;
            app.sup.hub().emit(
                &r.agent_id,
                EventBody::Reaction {
                    seq: r.seq,
                    emoji: r.emoji,
                    by: ReactionBy::User,
                },
            );
            ok(json!({}))
        }
        "messages.agent.react" => {
            let r: AgentReactParams = params(p)?;
            let store = &app.sup.hub().store;
            let seq = match r.seq {
                Some(seq) => seq,
                None => store
                    .current_user_message_seq(&r.agent_id)
                    .map_err(server)?
                    .ok_or_else(|| RpcError::new(INVALID_PARAMS, "no message from the person to react to"))?,
            };
            require_message(app, &r.agent_id, seq)?;
            chat::check_emoji(&r.emoji).map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
            store
                .reaction_set(&r.agent_id, seq, ReactionBy::Agent, Some(&r.emoji))
                .map_err(server)?;
            app.sup.hub().emit(
                &r.agent_id,
                EventBody::Reaction {
                    seq,
                    emoji: Some(r.emoji),
                    by: ReactionBy::Agent,
                },
            );
            ok(json!({ "seq": seq }))
        }
        "attachments.upload" => {
            let u: UploadParams = params(p)?;
            let store = &app.sup.hub().store;
            let agent = store
                .agent_get(&u.agent_id)
                .map_err(server)?
                .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no agent {}", u.agent_id)))?;
            attachments::check_name(&u.name).map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
            // Base64 grows by a third: refuse an overlong text before decoding it.
            if u.data_base64.len() > attachments::MAX_BYTES / 3 * 4 + 4 {
                return Err(RpcError::new(INVALID_PARAMS, "file is larger than 20 MB"));
            }
            let bytes = base64::engine::general_purpose::STANDARD
                .decode(u.data_base64.as_bytes())
                .map_err(|_| RpcError::new(INVALID_PARAMS, "data_base64 is not base64"))?;
            if bytes.len() > attachments::MAX_BYTES {
                return Err(RpcError::new(INVALID_PARAMS, "file is larger than 20 MB"));
            }
            let day = chrono::Local::now().format("%Y-%m-%d").to_string();
            let dir = attachments::folder_for_today(&agent.cwd, agent.home_dir.as_deref(), &app.data_home, &day)
                .map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
            let (path, name) = attachments::save(&dir, &u.name, &bytes).map_err(|e| RpcError::new(SERVER_ERROR, e))?;
            ok(json!({
                "path": path.display().to_string(),
                "name": name,
                "size": bytes.len(),
                "mime": attachments::mime_of(&name),
            }))
        }
        _ => Err(RpcError::new(METHOD_NOT_FOUND, format!("unknown method {method}"))),
    }
}

/// The attachments of a message the person sends: each path must be a file in one of the agent's attachment
/// folders. Their name, size and mime type are read here.
pub fn attachments_for(app: &App, agent: &Agent, paths: &[String]) -> Result<Vec<Attachment>, RpcError> {
    if paths.len() > MAX_ATTACHMENTS {
        return Err(RpcError::new(
            INVALID_PARAMS,
            format!("at most {MAX_ATTACHMENTS} attachments per message"),
        ));
    }
    paths
        .iter()
        .map(|path| {
            if !attachments::is_agent_attachment(path, &agent.cwd, agent.home_dir.as_deref(), &app.data_home) {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("not an attachment of this agent: {path}"),
                ));
            }
            // The file as it really is: what the message carries is the real path.
            let real =
                std::fs::canonicalize(path).map_err(|e| RpcError::new(INVALID_PARAMS, format!("{path}: {e}")))?;
            let meta = std::fs::metadata(&real).map_err(|e| RpcError::new(INVALID_PARAMS, format!("{path}: {e}")))?;
            let name = real
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            Ok(Attachment {
                path: real.display().to_string(),
                mime: attachments::mime_of(&name).to_string(),
                name,
                size: meta.len(),
            })
        })
        .collect()
}

/// The mentions of a message the person sends, checked against this server: an integration must exist, be enabled
/// and be one the agent may use; an agent must exist; a file must be a real path inside the agent's folder (or its
/// own home) and never inside Bandito's data folder; a browser tab must be listed by the server's browser. Returns
/// the mentions as the thread keeps them (files by their real path) and the block the runtime reads.
pub async fn mentions_for(
    app: &App,
    agent: Option<&Agent>,
    list: &[Mention],
) -> Result<(Vec<Mention>, Option<String>), RpcError> {
    if list.is_empty() {
        return Ok((Vec::new(), None));
    }
    mentions::check_shape(list).map_err(|e| RpcError::new(INVALID_PARAMS, e))?;
    let agent = agent.ok_or_else(|| RpcError::new(INVALID_PARAMS, "no such agent"))?;
    let store = &app.sup.hub().store;
    let integrations = if list.iter().any(|m| m.kind == MentionKind::Integration) {
        store.integration_list().map_err(server)?
    } else {
        Vec::new()
    };
    let mut pages = None;
    let mut kept: Vec<Mention> = Vec::new();
    let mut resolved = Vec::new();
    for m in list {
        let id = m.id.trim();
        let (id, facts) = match m.kind {
            MentionKind::Integration => {
                let usable = crate::integrations::for_agent(&integrations, agent.integrations.as_deref());
                let found = usable.iter().find(|i| i.id == id).ok_or_else(|| {
                    RpcError::new(
                        INVALID_PARAMS,
                        format!("the agent cannot use the service {}", m.label.trim()),
                    )
                })?;
                (
                    found.id.clone(),
                    Resolved::Integration {
                        name: found.name.clone(),
                    },
                )
            }
            MentionKind::Agent => {
                let found = store
                    .agent_get(id)
                    .map_err(server)?
                    .ok_or_else(|| RpcError::new(INVALID_PARAMS, format!("no agent {}", m.label.trim())))?;
                (found.id.clone(), Resolved::Agent { name: found.name })
            }
            MentionKind::File => {
                let real = mentioned_file(app, agent, id)?;
                (real.clone(), Resolved::File { path: real })
            }
            MentionKind::BrowserTab => {
                if pages.is_none() {
                    pages = Some(
                        app.browser
                            .pages(crate::browser::DEFAULT_WORKSPACE)
                            .await
                            .map_err(|e| {
                                RpcError::new(
                                    INVALID_PARAMS,
                                    match e {
                                        crate::browser::BrowserError::NotRunning => "the browser is not running",
                                        _ => "could not read the browser's tabs",
                                    },
                                )
                            })?,
                    );
                }
                let tab = pages
                    .iter()
                    .flatten()
                    .find(|p| p.id == id)
                    .ok_or_else(|| RpcError::new(INVALID_PARAMS, "that browser tab is not open any more"))?;
                (
                    tab.id.clone(),
                    Resolved::BrowserTab {
                        url: tab.url.clone(),
                        title: tab.title.clone(),
                    },
                )
            }
        };
        // The same thing named twice is one mention.
        if kept.iter().any(|k| k.kind == m.kind && k.id == id) {
            continue;
        }
        kept.push(Mention {
            kind: m.kind,
            id,
            label: m.label.trim().to_string(),
        });
        resolved.push(facts);
    }
    Ok((kept, mentions::note(&resolved)))
}

/// The real path of a file the person mentioned. It must be absolute and plain (no `.` or `..`), exist, lie in the
/// server's file roots, and be inside the agent's folder or its own home. Bandito's data folder is closed except for
/// the agent's own home in it.
fn mentioned_file(app: &App, agent: &Agent, raw: &str) -> Result<String, RpcError> {
    let bad = |m: String| RpcError::new(INVALID_PARAMS, m);
    // `Path::components` hides a `.` in the middle, so the segments are read from the text.
    if !raw.starts_with('/') || raw.split('/').any(|segment| segment == "." || segment == "..") {
        return Err(bad(format!("not a plain absolute path: {raw}")));
    }
    let real = app
        .files
        .resolve(raw)
        .map_err(|_| bad(format!("not a file this agent can use: {raw}")))?;
    // The file as it really is: a link that points out of the folder does not pass for a file inside it.
    let real = std::fs::canonicalize(&real).map_err(|_| bad(format!("no such file: {raw}")))?;
    let canon = |p: &str| p.starts_with('/').then(|| std::fs::canonicalize(p).ok()).flatten();
    let data = std::fs::canonicalize(&app.data_home).unwrap_or_else(|_| app.data_home.clone());
    let in_cwd = canon(&agent.cwd).is_some_and(|cwd| real.starts_with(&cwd) && !real.starts_with(&data));
    let in_home = agent
        .home_dir
        .as_deref()
        .and_then(canon)
        .is_some_and(|home| real.starts_with(&home));
    if !(in_cwd || in_home) {
        return Err(bad(format!("not inside this agent's folder: {raw}")));
    }
    Ok(real.display().to_string())
}

/// The message `seq` of the agent must be a message (the person's or the agent's) for a reaction or a reply.
fn require_message(app: &App, agent_id: &str, seq: i64) -> Result<(), RpcError> {
    let event = app.sup.hub().store.event_at(agent_id, seq).map_err(server)?;
    match event.map(|e| e.body) {
        Some(EventBody::MessageUser { .. } | EventBody::MessageAssistant { .. }) => Ok(()),
        _ => Err(RpcError::new(
            INVALID_PARAMS,
            format!("no message {seq} in this thread"),
        )),
    }
}

fn server(e: anyhow::Error) -> RpcError {
    RpcError::new(SERVER_ERROR, format!("{e:#}"))
}

#[derive(Deserialize)]
struct AskParams {
    agent_id: String,
    /// The form as the agent wrote it to `ask_form`.
    form: Value,
}

#[derive(Deserialize)]
struct AnswerParams {
    form_id: String,
    action: String,
    #[serde(default)]
    values: Option<Value>,
    #[serde(default)]
    comment: Option<Value>,
}

#[derive(Deserialize)]
struct ListParams {
    #[serde(default)]
    agent_id: Option<String>,
    #[serde(default)]
    status: Option<String>,
}

#[derive(Deserialize)]
struct ReactParams {
    agent_id: String,
    seq: i64,
    #[serde(default)]
    emoji: Option<String>,
}

#[derive(Deserialize)]
struct AgentReactParams {
    agent_id: String,
    #[serde(default)]
    seq: Option<i64>,
    emoji: String,
}

#[derive(Deserialize)]
struct UploadParams {
    agent_id: String,
    name: String,
    data_base64: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{EventBody, Source};
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, NewAgent, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::time::Duration;

    struct Fixture {
        app: Arc<App>,
        store: Arc<Store>,
        agent: String,
        cwd: PathBuf,
        root: PathBuf,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn fixture() -> Fixture {
        let root = std::env::temp_dir().join(format!("bandito-chat-rpc-{}", crate::store::new_id()));
        let cwd = root.join("project");
        std::fs::create_dir_all(&cwd).unwrap();
        let store = Arc::new(Store::open_in_memory().unwrap());
        let agent = store
            .agent_create(NewAgent {
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                integrations: None,
                name: "Forge".into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: cwd.display().to_string(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
            .id;
        let sup = Supervisor::new(Hub::new(store.clone()), Runtimes::default(), None);
        let app = App::new_in_home(sup, root.join("agents"), App::default_files(), root.join("data"));
        Fixture {
            app,
            store,
            agent,
            cwd,
            root,
        }
    }

    fn form_spec() -> Value {
        json!({
            "title": "Who are you?",
            "kind": "question",
            "fields": [
                { "id": "name", "label": "Name", "type": "text", "required": true },
                { "id": "color", "label": "Color", "type": "choice", "options": ["red", "blue"] },
            ],
        })
    }

    /// The spec as the store keeps it: checked, and written back the way `forms::FormSpec` serializes.
    fn stored(spec: Value) -> Value {
        serde_json::to_value(forms::parse_spec(&spec).unwrap()).unwrap()
    }

    async fn call(f: &Fixture, peer: &Peer, method: &str, p: Value) -> RpcResult {
        crate::rpc::dispatch(&f.app, peer, method, p).await
    }

    fn code_and_message(e: RpcError) -> (i64, String) {
        (e.code, e.message)
    }

    #[tokio::test]
    async fn a_form_is_answered_once_and_the_answer_is_checked() {
        let f = fixture();
        let form = f.store.form_create(&f.agent, &stored(form_spec())).unwrap();
        let answer = |values: Value| json!({ "form_id": form.id, "action": "submit", "values": values });

        // A wrong value is refused and the form stays open.
        let e = call(
            &f,
            &Peer::Local,
            "forms.answer",
            answer(json!({ "name": "Ann", "color": "green" })),
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
        assert!(e.message.contains("not one of the options"), "{}", e.message);
        assert_eq!(f.store.form_get(&form.id).unwrap().unwrap().status, FormStatus::Pending);

        // A missing required field is refused.
        let e = call(&f, &Peer::Local, "forms.answer", answer(json!({ "color": "red" })))
            .await
            .unwrap_err();
        assert_eq!(e.message, "field \"name\" is required");

        let ok_answer = answer(json!({ "name": "Ann", "color": "blue" }));
        call(&f, &Peer::Local, "forms.answer", ok_answer.clone()).await.unwrap();
        let stored = f.store.form_get(&form.id).unwrap().unwrap();
        assert_eq!(stored.status, FormStatus::Submitted);
        assert_eq!(
            stored.answer.unwrap()["values"],
            json!({ "name": "Ann", "color": "blue" })
        );

        // The second answer is refused as already answered.
        let e = call(&f, &Peer::Local, "forms.answer", ok_answer).await.unwrap_err();
        assert_eq!(e.message, "already_answered");
    }

    #[tokio::test]
    async fn a_reject_takes_a_comment_and_an_unknown_action_is_refused() {
        let f = fixture();
        let form = f.store.form_create(&f.agent, &stored(form_spec())).unwrap();
        let e = call(
            &f,
            &Peer::Local,
            "forms.answer",
            json!({ "form_id": form.id, "action": "maybe" }),
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("submit or reject"), "{}", e.message);
        call(
            &f,
            &Peer::Local,
            "forms.answer",
            json!({ "form_id": form.id, "action": "reject", "comment": "not now" }),
        )
        .await
        .unwrap();
        let stored = f.store.form_get(&form.id).unwrap().unwrap();
        assert_eq!(stored.status, FormStatus::Rejected);
        assert_eq!(
            stored.answer.unwrap(),
            json!({ "action": "reject", "comment": "not now" })
        );
        let e = call(
            &f,
            &Peer::Local,
            "forms.answer",
            json!({ "form_id": "nope", "action": "submit" }),
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("no form nope"));
    }

    #[tokio::test]
    async fn a_form_expires_when_the_agent_connection_closes_while_it_waits() {
        let f = fixture();
        let (in_tx, in_rx) = tokio::sync::mpsc::channel::<String>(8);
        let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<String>(8);
        let served = tokio::spawn(crate::rpc::serve(
            f.app.clone(),
            Peer::Agent(f.agent.clone()),
            in_rx,
            out_tx,
        ));
        let ask = json!({ "jsonrpc": "2.0", "id": 1, "method": "forms.agent.ask", "params": { "form": form_spec() } });
        in_tx.send(ask.to_string()).await.unwrap();
        let mut pending = Vec::new();
        for _ in 0..200 {
            pending = f.store.form_list(Some(&f.agent), Some(FormStatus::Pending)).unwrap();
            if !pending.is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(pending.len(), 1, "the form waits");
        // While it waits, another request is refused as busy, and the call stays open.
        in_tx
            .send(json!({ "jsonrpc": "2.0", "id": 2, "method": "daemon.hello" }).to_string())
            .await
            .unwrap();
        let busy: Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        assert_eq!(busy["id"], 2);
        assert!(busy["error"]["message"].as_str().unwrap().starts_with("busy"), "{busy}");
        // The agent's connection closes: the call goes, and the form expires.
        drop(in_tx);
        tokio::time::timeout(Duration::from_secs(5), served)
            .await
            .unwrap()
            .unwrap();
        let mut status = FormStatus::Pending;
        for _ in 0..200 {
            status = f.store.form_list(Some(&f.agent), None).unwrap()[0].status;
            if status != FormStatus::Pending {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert_eq!(status, FormStatus::Expired);
    }

    #[tokio::test]
    async fn new_chapter_is_the_owners_and_needs_an_agent_it_knows() {
        let f = fixture();
        assert!(!crate::rpc::allowed(
            &Peer::Agent(f.agent.clone()),
            "agents.new_chapter"
        ));
        assert!(crate::rpc::allowed(&Peer::Local, "agents.new_chapter"));
        let err = call(&f, &Peer::Local, "agents.new_chapter", json!({ "id": "no-such-agent" }))
            .await
            .unwrap_err();
        assert!(err.message.contains("no agent no-such-agent"), "{}", err.message);
        call(&f, &Peer::Local, "agents.new_chapter", json!({ "id": f.agent }))
            .await
            .unwrap();
        let chapter = f.store.agent_get(&f.agent).unwrap().unwrap().chapter;
        assert_eq!(chapter, 2);
    }

    #[tokio::test]
    async fn forms_are_asked_by_agents_and_answered_by_people_only() {
        let f = fixture();
        let agent = Peer::Agent(f.agent.clone());
        assert!(crate::rpc::allowed(&agent, "forms.agent.ask"));
        assert!(!crate::rpc::allowed(&agent, "forms.answer"));
        assert!(!crate::rpc::allowed(&agent, "forms.list"));
        assert!(!crate::rpc::allowed(&agent, "attachments.upload"));
        assert!(!crate::rpc::allowed(&agent, "messages.react"));
        assert!(!crate::rpc::allowed(&Peer::Local, "forms.agent.ask"));
        assert!(!crate::rpc::allowed(&Peer::Local, "messages.agent.react"));
        assert!(crate::rpc::allowed(&Peer::Local, "forms.answer"));
        assert!(crate::rpc::allowed(&Peer::Local, "forms.list"));
        assert!(crate::rpc::allowed(&Peer::Local, "messages.react"));
        // A bad spec is refused before anything is stored, with the reason.
        let e = call(
            &f,
            &agent,
            "forms.agent.ask",
            json!({ "agent_id": f.agent, "form": { "title": "x", "kind": "question", "fields": [] } }),
        )
        .await
        .unwrap_err();
        assert!(e.message.starts_with("fields needs 1 to 20"), "{}", e.message);
        assert!(f.store.form_list(None, None).unwrap().is_empty());
    }

    #[tokio::test]
    async fn forms_list_filters_by_status() {
        let f = fixture();
        let spec = stored(form_spec());
        let open = f.store.form_create(&f.agent, &spec).unwrap();
        let done = f.store.form_create(&f.agent, &spec).unwrap();
        f.store
            .form_answer(&done.id, FormStatus::Rejected, &json!({ "action": "reject" }))
            .unwrap();
        let pending = call(&f, &Peer::Local, "forms.list", json!({ "status": "pending" }))
            .await
            .unwrap();
        let list = pending.as_array().unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0]["id"], open.id);
        assert_eq!(list[0]["spec"]["title"], "Who are you?");
        let e = call(&f, &Peer::Local, "forms.list", json!({ "status": "later" }))
            .await
            .unwrap_err();
        assert!(e.message.contains("unknown status"));
    }

    #[tokio::test]
    async fn a_person_puts_one_reaction_per_message_and_takes_it_off() {
        let f = fixture();
        let seq = f
            .store
            .append_event(
                &f.agent,
                EventBody::MessageAssistant {
                    text: "Готово".into()
                },
            )
            .unwrap()
            .seq;
        call(
            &f,
            &Peer::Local,
            "messages.react",
            json!({ "agent_id": f.agent, "seq": seq, "emoji": "👍" }),
        )
        .await
        .unwrap();
        call(
            &f,
            &Peer::Local,
            "messages.react",
            json!({ "agent_id": f.agent, "seq": seq, "emoji": "👀" }),
        )
        .await
        .unwrap();
        let on = f.store.reactions_on(&f.agent, seq).unwrap();
        assert_eq!(on.len(), 1);
        assert_eq!(on[0].emoji, "👀");
        // The reaction is in the thread as an event.
        let events = f.store.events_page(&f.agent, None, 50).unwrap();
        assert!(events.iter().any(|e| matches!(&e.body, EventBody::Reaction { seq: s, emoji: Some(x), by: ReactionBy::User } if *s == seq && x == "👀")));
        call(
            &f,
            &Peer::Local,
            "messages.react",
            json!({ "agent_id": f.agent, "seq": seq, "emoji": null }),
        )
        .await
        .unwrap();
        assert!(f.store.reactions_on(&f.agent, seq).unwrap().is_empty());
        let events = f.store.events_page(&f.agent, None, 50).unwrap();
        assert!(
            events
                .iter()
                .any(|e| matches!(&e.body, EventBody::Reaction { emoji: None, .. }))
        );
    }

    #[tokio::test]
    async fn reactions_check_the_emoji_and_the_message() {
        let f = fixture();
        let seq = f
            .store
            .append_event(&f.agent, EventBody::MessageAssistant { text: "x".into() })
            .unwrap()
            .seq;
        let e = call(
            &f,
            &Peer::Local,
            "messages.react",
            json!({ "agent_id": f.agent, "seq": seq, "emoji": "ok" }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
        let e = call(
            &f,
            &Peer::Local,
            "messages.react",
            json!({ "agent_id": f.agent, "seq": 9999, "emoji": "👍" }),
        )
        .await
        .unwrap_err();
        assert_eq!(
            code_and_message(e),
            (INVALID_PARAMS, "no message 9999 in this thread".into())
        );
        // Only messages react: a turn event is not a message.
        let turn = f
            .store
            .append_event(
                &f.agent,
                EventBody::TurnStarted {
                    turn_id: "t".into(),
                    source: Source::User,
                    reactions_until: None,
                    message_seq: None,
                },
            )
            .unwrap()
            .seq;
        assert!(
            call(
                &f,
                &Peer::Local,
                "messages.react",
                json!({ "agent_id": f.agent, "seq": turn, "emoji": "👍" })
            )
            .await
            .is_err()
        );
    }

    #[tokio::test]
    async fn the_agent_reacts_to_the_last_message_of_the_person_by_default() {
        let f = fixture();
        let agent = Peer::Agent(f.agent.clone());
        let e = call(
            &f,
            &agent,
            "messages.agent.react",
            json!({ "agent_id": f.agent, "emoji": "👀" }),
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("no message from the person"), "{}", e.message);
        let first = f
            .store
            .append_event(
                &f.agent,
                EventBody::MessageUser {
                    text: "first".into(),
                    source: Source::User,
                    from_agent: None,
                    command: None,
                    reply_to: None,
                    attachments: Vec::new(),
                    mentions: Vec::new(),
                    queued: false,
                },
            )
            .unwrap()
            .seq;
        f.store
            .append_event(&f.agent, EventBody::MessageAssistant { text: "ok".into() })
            .unwrap();
        let r = call(
            &f,
            &agent,
            "messages.agent.react",
            json!({ "agent_id": f.agent, "emoji": "👀" }),
        )
        .await
        .unwrap();
        assert_eq!(r["seq"], first);
        let on = f.store.reactions_on(&f.agent, first).unwrap();
        assert_eq!(on[0].by, ReactionBy::Agent);
        // A bad emoji is refused, and the agent cannot react to another agent's message.
        let e = call(
            &f,
            &agent,
            "messages.agent.react",
            json!({ "agent_id": f.agent, "seq": first, "emoji": "two words" }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
    }

    #[tokio::test]
    async fn the_agent_reacts_to_the_message_of_its_turn_not_to_one_waiting_behind_it() {
        let f = fixture();
        let agent = Peer::Agent(f.agent.clone());
        let user = |text: &str, queued| EventBody::MessageUser {
            text: text.into(),
            source: Source::User,
            from_agent: None,
            command: None,
            reply_to: None,
            attachments: Vec::new(),
            mentions: Vec::new(),
            queued,
        };
        let turn = |message_seq| EventBody::TurnStarted {
            turn_id: "t".into(),
            source: Source::User,
            reactions_until: None,
            message_seq,
        };
        // A is answered now; B arrived during the turn and waits.
        f.store.append_event(&f.agent, turn(None)).unwrap();
        let a = f.store.append_event(&f.agent, user("A", false)).unwrap().seq;
        let b = f.store.append_event(&f.agent, user("B", true)).unwrap().seq;
        let r = call(
            &f,
            &agent,
            "messages.agent.react",
            json!({ "agent_id": f.agent, "emoji": "👀" }),
        )
        .await
        .unwrap();
        assert_eq!(r["seq"], a);
        // B's turn begins: it names B, so B is what the agent answers.
        f.store.append_event(&f.agent, turn(Some(b))).unwrap();
        let r = call(
            &f,
            &agent,
            "messages.agent.react",
            json!({ "agent_id": f.agent, "emoji": "👀" }),
        )
        .await
        .unwrap();
        assert_eq!(r["seq"], b);
    }

    #[tokio::test]
    async fn attachments_are_saved_in_the_project_folder_under_free_names() {
        let f = fixture();
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"png-bytes");
        let up = |name: &str| json!({ "agent_id": f.agent, "name": name, "data_base64": b64 });
        let first = call(&f, &Peer::Local, "attachments.upload", up("photo.png"))
            .await
            .unwrap();
        assert_eq!(first["name"], "photo.png");
        assert_eq!(first["size"], 9);
        assert_eq!(first["mime"], "image/png");
        let path = PathBuf::from(first["path"].as_str().unwrap());
        assert!(
            path.starts_with(f.cwd.join(".bandito").join("attachments")),
            "{}",
            path.display()
        );
        assert_eq!(std::fs::read(&path).unwrap(), b"png-bytes");
        let second = call(&f, &Peer::Local, "attachments.upload", up("photo.png"))
            .await
            .unwrap();
        assert_eq!(second["name"], "photo (2).png");
        assert!(PathBuf::from(second["path"].as_str().unwrap()).exists());
    }

    #[tokio::test]
    async fn attachments_with_bad_names_or_content_are_refused() {
        let f = fixture();
        let b64 = base64::engine::general_purpose::STANDARD.encode(b"x");
        for name in ["../escape.txt", "a/b.txt", "..", "", "x\u{0007}.txt"] {
            let e = call(
                &f,
                &Peer::Local,
                "attachments.upload",
                json!({ "agent_id": f.agent, "name": name, "data_base64": b64 }),
            )
            .await
            .unwrap_err();
            assert_eq!(e.code, INVALID_PARAMS, "{name:?}");
        }
        let e = call(
            &f,
            &Peer::Local,
            "attachments.upload",
            json!({ "agent_id": f.agent, "name": "a.txt", "data_base64": "%%%" }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.message, "data_base64 is not base64");
        let e = call(
            &f,
            &Peer::Local,
            "attachments.upload",
            json!({ "agent_id": "no-such-agent", "name": "a.txt", "data_base64": b64 }),
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("no agent"));
        assert!(
            !f.cwd.join(".bandito").exists()
                || std::fs::read_dir(f.cwd.join(".bandito").join("attachments"))
                    .map(|d| d.count() == 0)
                    .unwrap_or(true)
        );
    }

    #[tokio::test]
    async fn an_attachment_over_20_mb_is_refused() {
        let f = fixture();
        let big = vec![0u8; attachments::MAX_BYTES + 1];
        let b64 = base64::engine::general_purpose::STANDARD.encode(&big);
        let e = call(
            &f,
            &Peer::Local,
            "attachments.upload",
            json!({ "agent_id": f.agent, "name": "big.bin", "data_base64": b64 }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.message, "file is larger than 20 MB");
    }

    #[tokio::test]
    async fn a_message_can_only_carry_its_own_attachments_and_reply_to_its_own_thread() {
        let f = fixture();
        let dir = f.cwd.join(".bandito").join("attachments").join("2026-10-10");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("doc.pdf"), b"%PDF").unwrap();
        let inside = dir.join("doc.pdf").display().to_string();
        let agent = f.store.agent_get(&f.agent).unwrap().unwrap();
        let found = attachments_for(&f.app, &agent, std::slice::from_ref(&inside)).unwrap();
        assert_eq!(found[0].name, "doc.pdf");
        assert_eq!(found[0].mime, "application/pdf");
        assert_eq!(found[0].size, 4);
        let e = attachments_for(&f.app, &agent, &["/etc/passwd".to_string()]).unwrap_err();
        assert!(e.message.contains("not an attachment of this agent"));
        let outside = f.cwd.join("secret.txt");
        std::fs::write(&outside, b"s").unwrap();
        assert!(attachments_for(&f.app, &agent, &[outside.display().to_string()]).is_err());
        let too_many: Vec<String> = (0..21).map(|i| format!("{inside}{i}")).collect();
        assert!(attachments_for(&f.app, &agent, &too_many).is_err());

        // A reply must name a message of the same agent.
        let e = call(
            &f,
            &Peer::Local,
            "agents.send",
            json!({ "agent_id": f.agent, "text": "hi", "reply_to": 42 }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.message, "no message 42 in this thread");
        let e = call(
            &f,
            &Peer::Local,
            "agents.send",
            json!({ "agent_id": f.agent, "text": "hi", "attachments": ["/etc/hosts"] }),
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("not an attachment"), "{}", e.message);

        // Files alone pass the empty-text check; without files an empty message is still refused.
        let e = call(
            &f,
            &Peer::Local,
            "agents.send",
            json!({ "agent_id": f.agent, "text": "  " }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.message, "message is empty");
        let e = call(
            &f,
            &Peer::Local,
            "agents.send",
            json!({ "agent_id": f.agent, "text": "", "attachments": ["/etc/hosts"] }),
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("not an attachment"), "{}", e.message);
    }

    fn extra_agent(f: &Fixture, name: &str, integrations: Option<Vec<String>>) -> String {
        f.store
            .agent_create(NewAgent {
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                integrations,
                name: name.into(),
                role: String::new(),
                runtime: RuntimeKind::Claude,
                model: None,
                cwd: f.cwd.display().to_string(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: crate::store::MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
            })
            .unwrap()
            .id
    }

    fn integration(f: &Fixture, name: &str, enabled: bool) -> String {
        f.store
            .integration_create(crate::store::NewIntegration {
                name: name.into(),
                kind: crate::store::IntegrationKind::Http,
                command: None,
                args: Vec::new(),
                url: Some("https://mcp.example.com/mcp".into()),
                env: Default::default(),
                headers: Default::default(),
                enabled,
                auth: Default::default(),
            })
            .unwrap()
            .id
    }

    fn mention(kind: MentionKind, id: &str, label: &str) -> Mention {
        Mention {
            kind,
            id: id.into(),
            label: label.into(),
        }
    }

    #[tokio::test]
    async fn mentions_are_checked_and_become_the_mentioned_block() {
        let f = fixture();
        let linear = integration(&f, "linear", true);
        let scout = extra_agent(&f, "Scout", None);
        std::fs::create_dir_all(f.cwd.join("src")).unwrap();
        std::fs::write(f.cwd.join("src/main.rs"), b"fn main() {}").unwrap();
        let agent = f.store.agent_get(&f.agent).unwrap().unwrap();
        let file = f.cwd.join("src/main.rs").canonicalize().unwrap().display().to_string();
        let list = vec![
            mention(MentionKind::Integration, &linear, "Linear"),
            mention(MentionKind::Agent, &scout, "Scout"),
            mention(MentionKind::File, &file, "main.rs"),
            // The same thing twice counts once.
            mention(MentionKind::Agent, &scout, "Scout"),
        ];
        let (kept, note) = mentions_for(&f.app, Some(&agent), &list).await.unwrap();
        assert_eq!(kept.len(), 3);
        assert_eq!(kept[2].id, file);
        assert_eq!(
            note.unwrap(),
            format!(
                "Mentioned:\n\
                 - linear (a connected service): use its tools (prefix mcp__linear__) for this request\n\
                 - @Scout is a teammate; hand this to them with crew_send if it belongs to them\n\
                 - file: {file}"
            )
        );
        // No mentions, no block.
        assert_eq!(
            mentions_for(&f.app, Some(&agent), &[]).await.unwrap(),
            (Vec::new(), None)
        );
    }

    #[tokio::test]
    async fn an_integration_the_agent_cannot_use_is_refused() {
        let f = fixture();
        let off = integration(&f, "linear", false);
        let agent = f.store.agent_get(&f.agent).unwrap().unwrap();
        // Disabled.
        let e = mentions_for(
            &f.app,
            Some(&agent),
            &[mention(MentionKind::Integration, &off, "Linear")],
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
        // Unknown.
        assert!(
            mentions_for(
                &f.app,
                Some(&agent),
                &[mention(MentionKind::Integration, "nope", "Linear")]
            )
            .await
            .is_err()
        );
        // Enabled, but not in this agent's list.
        let on = integration(&f, "fetch", true);
        let limited = extra_agent(&f, "Limited", Some(Vec::new()));
        let limited = f.store.agent_get(&limited).unwrap().unwrap();
        assert!(
            mentions_for(
                &f.app,
                Some(&limited),
                &[mention(MentionKind::Integration, &on, "Fetch")]
            )
            .await
            .is_err()
        );
        assert!(
            mentions_for(&f.app, Some(&agent), &[mention(MentionKind::Integration, &on, "Fetch")])
                .await
                .is_ok()
        );
    }

    #[tokio::test]
    async fn files_outside_the_agents_folder_are_refused() {
        let f = fixture();
        let agent = f.store.agent_get(&f.agent).unwrap().unwrap();
        let outside = f.root.join("secret.txt");
        std::fs::write(&outside, b"s").unwrap();
        std::fs::write(f.cwd.join("ok.txt"), b"ok").unwrap();
        let ask = |path: String| {
            let agent = agent.clone();
            let app = f.app.clone();
            async move { mentions_for(&app, Some(&agent), &[mention(MentionKind::File, &path, "x")]).await }
        };
        assert!(ask(f.cwd.join("ok.txt").display().to_string()).await.is_ok());
        for bad in [
            outside.display().to_string(),
            format!("{}/../secret.txt", f.cwd.display()),
            format!("{}/./ok.txt", f.cwd.display()),
            "ok.txt".to_string(),
            f.cwd.join("missing.txt").display().to_string(),
            "/etc/hosts".to_string(),
        ] {
            let e = ask(bad.clone()).await.unwrap_err();
            assert_eq!(e.code, INVALID_PARAMS, "{bad}");
        }
        // A link in the folder that points out of it.
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(&outside, f.cwd.join("link.txt")).unwrap();
            assert!(ask(f.cwd.join("link.txt").display().to_string()).await.is_err());
        }
    }

    #[tokio::test]
    async fn agents_and_tabs_must_exist() {
        let f = fixture();
        let agent = f.store.agent_get(&f.agent).unwrap().unwrap();
        assert!(
            mentions_for(&f.app, Some(&agent), &[mention(MentionKind::Agent, "ghost", "Ghost")])
                .await
                .is_err()
        );
        // The server's browser is not running in a test.
        let e = mentions_for(
            &f.app,
            Some(&agent),
            &[mention(MentionKind::BrowserTab, "ABC123", "Docs")],
        )
        .await
        .unwrap_err();
        assert!(e.message.contains("browser"), "{}", e.message);
        // A bad shape never reaches the lookups.
        let e = mentions_for(&f.app, Some(&agent), &[mention(MentionKind::Agent, "a", "")])
            .await
            .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
    }

    #[tokio::test]
    async fn agents_send_refuses_a_bad_mention_and_sends_nothing() {
        let f = fixture();
        assert!(crate::rpc::features().contains(&"mentions"));
        let e = call(
            &f,
            &Peer::Local,
            "agents.send",
            json!({ "agent_id": f.agent, "text": "see @Ghost",
                    "mentions": [{ "kind": "agent", "id": "ghost", "label": "Ghost" }] }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
        assert!(f.store.events_page(&f.agent, None, 10).unwrap().is_empty());
        // An unknown kind is a bad parameter, not a skipped mention.
        let e = call(
            &f,
            &Peer::Local,
            "agents.send",
            json!({ "agent_id": f.agent, "text": "hi",
                    "mentions": [{ "kind": "web", "id": "x", "label": "X" }] }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, INVALID_PARAMS);
    }
}
