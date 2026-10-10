//! The main agent's team tools: list the crew, hand out a task, follow it (see docs/ARCHITECTURE.md#lead-agent).
//! Only the main agent may call them; the daemon checks it here, whatever the crew server offered.

use crate::event::{EventBody, Source, TurnStatus};
use crate::redact::Redactor;
use crate::store::{Agent, Store};
use crate::supervisor::{MAX_TEAM_ASSIGNS_PER_TURN, Supervisor};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::time::Duration;

/// How long one `team_assign` with `wait` waits for the end of the other agent's turn. A longer task is followed
/// with `team_status`: the call ends with `running`, so no MCP client cuts it off and the main agent is not stuck.
pub const WAIT_LIMIT: Duration = Duration::from_secs(5 * 60);
/// How often the waiting call looks for new events of the agent.
const POLL: Duration = Duration::from_millis(250);
/// Longest reply handed back to the main agent, in characters.
const REPLY_CHARS: usize = 20_000;

/// The caller as the main agent, or the refusal.
fn require_lead(store: &Store, agent_id: &str) -> Result<Agent> {
    let agent = store
        .agent_get(agent_id)?
        .ok_or_else(|| anyhow!("no agent {agent_id}"))?;
    if !agent.lead {
        bail!("only the main agent of the crew can use the team tools");
    }
    Ok(agent)
}

/// An agent by id or by name (case does not matter).
fn resolve(store: &Store, key: &str) -> Result<Agent> {
    let key = key.trim();
    if key.is_empty() {
        bail!("no agent given");
    }
    if let Some(agent) = store.agent_get(key)? {
        return Ok(agent);
    }
    store
        .agent_by_name(key)?
        .ok_or_else(|| anyhow!("no agent '{key}' in this crew"))
}

/// The text with every secret of the server blanked out except those the main agent holds itself: what another agent
/// said may carry a value the main agent was never given.
fn redacted(store: &Store, lead_id: &str, text: &str) -> Result<String> {
    let own: std::collections::HashSet<String> = store
        .secrets_for_agent(lead_id)?
        .into_iter()
        .map(|(name, _)| name)
        .collect();
    let hidden = store.secrets_all()?.into_iter().filter(|(name, _)| !own.contains(name));
    Ok(Redactor::new(hidden).redact(text).chars().take(REPLY_CHARS).collect())
}

fn status_name(agent: &Agent) -> Value {
    serde_json::to_value(agent.status).unwrap_or(Value::Null)
}

fn last_message(store: &Store, lead_id: &str, agent: &Agent) -> Result<Value> {
    Ok(match &agent.last_message {
        Some(m) => json!({ "role": m.role, "text": redacted(store, lead_id, &m.text)?, "ts": m.ts }),
        None => Value::Null,
    })
}

/// `team_list`: every other agent with what the main agent needs to pick one.
pub fn list(store: &Store, lead_id: &str) -> Result<Value> {
    require_lead(store, lead_id)?;
    let mut members = Vec::new();
    for a in store.agent_list_view()?.into_iter().filter(|a| a.id != lead_id) {
        members.push(json!({
            "id": a.id,
            "name": a.name,
            "role": a.role,
            "runtime": a.runtime.as_str(),
            "model": a.model,
            "status": status_name(&a),
            "paused": a.paused,
            "last_message": last_message(store, lead_id, &a)?,
        }));
    }
    Ok(json!({ "agents": members }))
}

/// `team_status`: where one agent stands and its newest answer, in full.
pub fn status(store: &Store, lead_id: &str, key: &str) -> Result<Value> {
    require_lead(store, lead_id)?;
    let target = resolve(store, key)?;
    if target.id == lead_id {
        bail!("that is you: the team tools are for the other agents");
    }
    let view = store
        .agent_view(&target.id)?
        .ok_or_else(|| anyhow!("no agent {}", target.id))?;
    let reply = match store.last_assistant_message(&target.id)? {
        Some((ts, text)) => json!({ "text": redacted(store, lead_id, &text)?, "ts": ts }),
        None => Value::Null,
    };
    Ok(json!({
        "id": view.id,
        "name": view.name,
        "role": view.role,
        "status": status_name(&view),
        "paused": view.paused,
        "last_message": last_message(store, lead_id, &view)?,
        "last_reply": reply,
    }))
}

/// `team_assign`: the task goes to the agent as a crew message from the main agent. With `wait`, the call
/// returns when the agent's turn on it ends, with its last answer; without, as soon as the task is delivered.
pub async fn assign(sup: &Supervisor, lead_id: &str, to: &str, task: &str, wait: bool) -> Result<Value> {
    assign_within(sup, lead_id, to, task, wait.then_some(WAIT_LIMIT)).await
}

/// [`assign`] with the longest wait given (`None`: do not wait).
pub(crate) async fn assign_within(
    sup: &Supervisor,
    lead_id: &str,
    to: &str,
    task: &str,
    wait_limit: Option<Duration>,
) -> Result<Value> {
    let store = &sup.hub().store;
    let lead = require_lead(store, lead_id)?;
    let target = resolve(store, to)?;
    if target.id == lead.id {
        bail!("the main agent can't assign a task to itself");
    }
    if task.trim().is_empty() {
        bail!("the task is empty");
    }
    let after = store.last_seq()?;
    // The same path as `crew_send`: the loop limits, the redaction and the sender mark are all there.
    sup.crew_send_limited(&lead.id, &target.name, task, MAX_TEAM_ASSIGNS_PER_TURN)
        .await?;
    let mut out = json!({ "to": target.name, "to_id": target.id, "status": "sent" });
    let Some(wait_limit) = wait_limit else {
        return Ok(out);
    };
    if target.paused {
        // A paused agent holds the message; waiting would only run out the clock.
        out["status"] = json!("paused");
        return Ok(out);
    }
    let (status, reply) = wait_for_reply(store, &lead, &target, after, wait_limit).await?;
    out["status"] = json!(status);
    if status == "running" {
        // Not finished: no answer yet to hand over. The main agent looks again with `team_status`.
        out["hint"] = json!("вызовите team_status позже");
        return Ok(out);
    }
    out["reply"] = match reply {
        Some(text) => json!(redacted(store, lead_id, &text)?),
        None => Value::Null,
    };
    Ok(out)
}

/// Watches the agent's events after `after` for the turn that takes the main agent's message, and gives the status
/// that ended it with the last answer of the turn. `running` when `limit` runs out first, or `paused` when the agent was
/// paused while the message was still waiting.
async fn wait_for_reply(
    store: &Store,
    lead: &Agent,
    target: &Agent,
    after: i64,
    limit: Duration,
) -> Result<(&'static str, Option<String>)> {
    let deadline = tokio::time::Instant::now() + limit;
    let mut cursor = after;
    let mut taken = false;
    // The seq of the main agent's message when it was shown while it waited: the turn that names it takes it.
    let mut waiting: Option<i64> = None;
    let mut reply: Option<String> = None;
    loop {
        let batch = store.events_since(cursor, 500, Some(&target.id))?;
        let full = batch.len() >= 500;
        for event in batch {
            cursor = event.seq;
            match event.body {
                EventBody::MessageUser {
                    source: Source::Crew,
                    from_agent: Some(from),
                    queued,
                    ..
                } if !taken && waiting.is_none() && from.eq_ignore_ascii_case(&lead.name) => {
                    if queued {
                        waiting = Some(event.seq);
                    } else {
                        taken = true;
                    }
                }
                EventBody::TurnStarted {
                    message_seq: Some(seq), ..
                } if !taken && waiting == Some(seq) => taken = true,
                // The message will not get a turn: nothing to wait for.
                EventBody::MessageDropped { seq, .. } if !taken && waiting == Some(seq) => {
                    return Ok(("error", None));
                }
                EventBody::MessageAssistant { text } if taken => reply = Some(text),
                EventBody::TurnCompleted { status, .. } if taken => {
                    let name = match status {
                        TurnStatus::Ok => "completed",
                        TurnStatus::Error => "error",
                        TurnStatus::Interrupted => "interrupted",
                    };
                    return Ok((name, reply));
                }
                _ => {}
            }
        }
        if full {
            continue;
        }
        let Some(now) = store.agent_get(&target.id)? else {
            bail!("{} was deleted while the task ran", target.name);
        };
        // Paused while the message waits: the turn will not start until the owner resumes it.
        if !taken && now.paused {
            return Ok(("paused", None));
        }
        if tokio::time::Instant::now() >= deadline {
            return Ok(("running", reply));
        }
        tokio::time::sleep(POLL).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{ApprovalMode, MemoryMode, NewAgent};
    use crate::supervisor::Runtimes;
    use std::sync::Arc;

    fn add(store: &Store, name: &str) -> Agent {
        store
            .agent_create(NewAgent {
                name: name.into(),
                role: "builder".into(),
                runtime: RuntimeKind::Claude,
                model: Some("haiku".into()),
                cwd: "/tmp".into(),
                approval_mode: ApprovalMode::Risky,
                system_prompt: None,
                effort: None,
                memory_mode: MemoryMode::Smart,
                context_budget: None,
                fallback_runtime: None,
                fallback_model: None,
                use_personal_settings: false,
                avatar: None,
                capabilities: None,
                integrations: None,
            })
            .unwrap()
    }

    fn sup(store: Arc<Store>) -> Arc<Supervisor> {
        Supervisor::new(Hub::new(store), Runtimes::default(), None)
    }

    #[test]
    fn only_the_main_agent_may_use_the_team_tools() {
        let store = Store::open_in_memory().unwrap();
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        for who in [&scout.id, &"nobody".to_string()] {
            assert!(list(&store, who).is_err());
            assert!(status(&store, who, "Boss").is_err());
        }
        let err = list(&store, &scout.id).unwrap_err().to_string();
        assert!(err.contains("only the main agent"), "{err}");
        let members = list(&store, &boss.id).unwrap();
        let names: Vec<&str> = members["agents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|a| a["name"].as_str().unwrap())
            .collect();
        assert_eq!(names, ["Scout"]);
        assert_eq!(members["agents"][0]["model"], json!("haiku"));
    }

    #[tokio::test]
    async fn assign_is_refused_for_a_plain_agent_and_reaches_no_one() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        let sup = sup(store.clone());
        let err = assign(&sup, &scout.id, "Boss", "do it", false).await.unwrap_err();
        assert!(err.to_string().contains("only the main agent"), "{err}");
        assert_eq!(store.last_seq().unwrap(), 0);
        let err = assign(&sup, &boss.id, "Boss", "do it", false).await.unwrap_err();
        assert!(err.to_string().contains("itself"), "{err}");
        let err = assign(&sup, &boss.id, "Nobody", "do it", false).await.unwrap_err();
        assert!(err.to_string().contains("no agent 'Nobody'"), "{err}");
        let err = assign(&sup, &boss.id, "Scout", "  ", false).await.unwrap_err();
        assert!(err.to_string().contains("empty"), "{err}");
    }

    #[test]
    fn status_gives_the_last_reply_in_full() {
        let store = Store::open_in_memory().unwrap();
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        let long = "x".repeat(500);
        store
            .append_event(&scout.id, EventBody::MessageAssistant { text: long.clone() })
            .unwrap();
        let s = status(&store, &boss.id, &scout.id).unwrap();
        assert_eq!(s["last_reply"]["text"], json!(long));
        // The list preview is cut short, the status is not.
        let l = list(&store, &boss.id).unwrap();
        assert_eq!(l["agents"][0]["last_message"]["text"].as_str().unwrap().len(), 200);
        assert!(status(&store, &boss.id, "Boss").is_err());
    }

    #[test]
    fn the_secrets_of_the_other_agent_stay_out_of_what_the_main_agent_reads() {
        let store = Store::open_in_memory().unwrap();
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        store
            .secret_set("TOKEN", "hunter2-hunter2", std::slice::from_ref(&scout.id))
            .unwrap();
        store
            .append_event(
                &scout.id,
                EventBody::MessageAssistant {
                    text: "key is hunter2-hunter2".into(),
                },
            )
            .unwrap();
        let s = status(&store, &boss.id, "scout").unwrap();
        assert!(!s["last_reply"]["text"].as_str().unwrap().contains("hunter2"), "{s}");
        let l = list(&store, &boss.id).unwrap();
        assert!(!l.to_string().contains("hunter2"), "{l}");
    }

    #[tokio::test]
    async fn wait_returns_the_answer_of_the_turn_that_took_the_task() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        let after = store.last_seq().unwrap();
        let emit = |body| {
            store.append_event(&scout.id, body).unwrap();
        };
        // An older turn, a message of the human and the main agent's own task, then the answer.
        emit(EventBody::MessageAssistant { text: "old".into() });
        emit(EventBody::TurnCompleted {
            turn_id: "t0".into(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: None,
        });
        emit(EventBody::MessageUser {
            text: "count".into(),
            source: Source::Crew,
            from_agent: Some("boss".into()),
            command: None,
            reply_to: None,
            attachments: Vec::new(),
            mentions: Vec::new(),
            queued: false,
        });
        emit(EventBody::MessageAssistant {
            text: "thinking".into(),
        });
        emit(EventBody::MessageAssistant { text: "391".into() });
        emit(EventBody::TurnCompleted {
            turn_id: "t1".into(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: None,
        });
        let (status, reply) = wait_for_reply(&store, &boss, &scout, after, Duration::from_secs(5))
            .await
            .unwrap();
        // The answer before the task is not the answer to it.
        assert_eq!((status, reply.as_deref()), ("completed", Some("391")));
    }

    fn crew_task(queued: bool) -> EventBody {
        EventBody::MessageUser {
            text: "count".into(),
            source: Source::Crew,
            from_agent: Some("Boss".into()),
            command: None,
            reply_to: None,
            attachments: Vec::new(),
            mentions: Vec::new(),
            queued,
        }
    }

    fn turn_end(id: &str) -> EventBody {
        EventBody::TurnCompleted {
            turn_id: id.into(),
            status: TurnStatus::Ok,
            usage: None,
            cost_usd: None,
        }
    }

    #[tokio::test]
    async fn a_task_queued_behind_another_turn_does_not_return_that_turns_answer() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        let after = store.last_seq().unwrap();
        let emit = |body| store.append_event(&scout.id, body).unwrap();
        // The scout is busy with a turn of the human; the task waits behind it.
        emit(EventBody::TurnStarted {
            turn_id: "other".into(),
            source: Source::User,
            reactions_until: None,
            message_seq: None,
        });
        let task = emit(crew_task(true)).seq;
        emit(EventBody::MessageAssistant {
            text: "answer to someone else".into(),
        });
        emit(turn_end("other"));
        emit(EventBody::TurnStarted {
            turn_id: "mine".into(),
            source: Source::Crew,
            reactions_until: None,
            message_seq: Some(task),
        });
        emit(EventBody::MessageAssistant { text: "391".into() });
        emit(turn_end("mine"));
        let (status, reply) = wait_for_reply(&store, &boss, &scout, after, Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!((status, reply.as_deref()), ("completed", Some("391")));
    }

    #[tokio::test]
    async fn a_queued_task_that_is_dropped_ends_the_wait() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        let after = store.last_seq().unwrap();
        let task = store.append_event(&scout.id, crew_task(true)).unwrap().seq;
        store
            .append_event(
                &scout.id,
                EventBody::MessageDropped {
                    seq: task,
                    reason: "crash".into(),
                },
            )
            .unwrap();
        let (status, reply) = wait_for_reply(&store, &boss, &scout, after, Duration::from_secs(5))
            .await
            .unwrap();
        assert_eq!((status, reply), ("error", None));
    }

    #[tokio::test]
    async fn wait_follows_a_turn_that_ends_later_and_gives_up_at_the_limit() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_lead(&boss.id, true).unwrap();
        let after = store.last_seq().unwrap();
        let writer = {
            let store = store.clone();
            let scout = scout.id.clone();
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(400)).await;
                store
                    .append_event(
                        &scout,
                        EventBody::MessageUser {
                            text: "count".into(),
                            source: Source::Crew,
                            from_agent: Some("Boss".into()),
                            command: None,
                            reply_to: None,
                            attachments: Vec::new(),
                            mentions: Vec::new(),
                            queued: false,
                        },
                    )
                    .unwrap();
                store
                    .append_event(&scout, EventBody::MessageAssistant { text: "done".into() })
                    .unwrap();
                store
                    .append_event(
                        &scout,
                        EventBody::TurnCompleted {
                            turn_id: "t".into(),
                            status: TurnStatus::Interrupted,
                            usage: None,
                            cost_usd: None,
                        },
                    )
                    .unwrap();
            })
        };
        let (status, reply) = wait_for_reply(&store, &boss, &scout, after, Duration::from_secs(5))
            .await
            .unwrap();
        writer.await.unwrap();
        assert_eq!((status, reply.as_deref()), ("interrupted", Some("done")));

        // A limit of nothing ends the wait after one look: the agent is still working.
        let (status, reply) = wait_for_reply(&store, &boss, &scout, store.last_seq().unwrap(), Duration::ZERO)
            .await
            .unwrap();
        assert_eq!((status, reply), ("running", None));
    }

    #[tokio::test]
    async fn wait_ends_at_once_when_the_agent_is_paused_before_it_takes_the_task() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_set_paused(&scout.id, true).unwrap();
        let (status, reply) = wait_for_reply(&store, &boss, &scout, 0, Duration::from_secs(60))
            .await
            .unwrap();
        assert_eq!((status, reply), ("paused", None));
    }

    #[tokio::test]
    async fn a_pause_during_the_wait_ends_it() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        let waiting = {
            let (store, boss, scout) = (store.clone(), boss.clone(), scout.clone());
            tokio::spawn(async move { wait_for_reply(&store, &boss, &scout, 0, Duration::from_secs(60)).await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        store.agent_set_paused(&scout.id, true).unwrap();
        let (status, reply) = tokio::time::timeout(Duration::from_secs(30), waiting)
            .await
            .expect("the wait ended")
            .unwrap()
            .unwrap();
        assert_eq!((status, reply), ("paused", None));
    }

    #[test]
    fn what_the_main_agent_reads_is_redacted_with_every_secret_it_does_not_hold() {
        let store = Store::open_in_memory().unwrap();
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        let other = add(&store, "Other");
        store.agent_set_lead(&boss.id, true).unwrap();
        // One secret is the scout's, one another agent's, one the main agent holds itself.
        store
            .secret_set("SCOUT_KEY", "scout-secret-value", std::slice::from_ref(&scout.id))
            .unwrap();
        store
            .secret_set("OTHER_KEY", "other-secret-value", std::slice::from_ref(&other.id))
            .unwrap();
        store
            .secret_set("BOSS_KEY", "boss-secret-value", std::slice::from_ref(&boss.id))
            .unwrap();
        let text = "scout-secret-value other-secret-value boss-secret-value";
        let out = redacted(&store, &boss.id, text).unwrap();
        assert!(
            !out.contains("scout-secret-value") && !out.contains("other-secret-value"),
            "{out}"
        );
        assert!(out.contains("boss-secret-value"), "{out}");
    }

    #[tokio::test]
    async fn wait_stops_when_the_agent_is_deleted() {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let boss = add(&store, "Boss");
        let scout = add(&store, "Scout");
        store.agent_delete(&scout.id).unwrap();
        let err = wait_for_reply(&store, &boss, &scout, 0, Duration::from_secs(5))
            .await
            .unwrap_err();
        assert!(err.to_string().contains("was deleted"), "{err}");
    }
}
