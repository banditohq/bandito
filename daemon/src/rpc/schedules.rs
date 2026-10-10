//! Schedule methods shared by the owner's `schedules.*` and the agents' `schedules.agent.*` (the crew tools
//! `schedule_*`). An agent sees and changes only its own schedules. See docs/ARCHITECTURE.md#scheduler.

use super::{App, INVALID_PARAMS, RpcError, RpcResult, ok, params};
use crate::schedule_text;
use crate::scheduler;
use crate::store::{NewSchedule, Schedule, SchedulePatch};
use serde::Deserialize;
use serde_json::{Value, json};

/// Longest title, in characters.
const TITLE_CHARS: usize = 80;
/// Longest prompt an agent may schedule, in characters.
const AGENT_PROMPT_CHARS: usize = 4000;
/// Most schedules one agent may hold.
const AGENT_SCHEDULES: usize = 20;
/// The shortest gap between two runs of an agent's schedule.
const AGENT_MIN_GAP_MS: i64 = 5 * 60 * 1000;

/// What an agent sends to `schedules.agent.create`: exactly one of `every`, `at` (with optional `days`) or `cron`.
#[derive(Deserialize)]
pub struct AgentCreate {
    pub prompt: String,
    pub title: Option<String>,
    pub every: Option<String>,
    pub at: Option<String>,
    pub days: Option<Vec<String>>,
    pub cron: Option<String>,
}

#[derive(Deserialize)]
struct AgentId {
    id: String,
}

#[derive(Deserialize)]
struct AgentUpdate {
    id: String,
    paused: Option<bool>,
}

/// One schedule as the wire shows it: the stored fields, `next_run_at` computed from the cron now while the
/// schedule is enabled (the stored value when disabled, as before), and the cron in words (`human_en`, `human_ru`).
pub fn view(s: &Schedule, now: i64) -> Value {
    let next_run_at = if s.enabled {
        scheduler::next_run(&s.cron, &s.tz, now).ok().or(s.next_run_at)
    } else {
        s.next_run_at
    };
    let (human_en, human_ru) = schedule_text::describe(&s.cron);
    let mut v = serde_json::to_value(s).unwrap_or(Value::Null);
    v["next_run_at"] = json!(next_run_at);
    v["human_en"] = json!(human_en);
    v["human_ru"] = json!(human_ru);
    v
}

pub fn views(list: Vec<Schedule>) -> Value {
    let now = crate::store::now_ms();
    Value::Array(list.iter().map(|s| view(s, now)).collect())
}

/// A title as stored: trimmed, `None` when empty, at most [`TITLE_CHARS`] characters.
fn clean_title(title: Option<String>) -> Result<Option<String>, RpcError> {
    match title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) {
        Some(t) if t.chars().count() > TITLE_CHARS => Err(RpcError::new(
            INVALID_PARAMS,
            format!("title is longer than {TITLE_CHARS} characters"),
        )),
        other => Ok(other),
    }
}

/// `schedules.create`: the cron must be valid in its zone, and the prompt not empty.
pub fn create(app: &App, mut s: NewSchedule) -> RpcResult {
    let store = &app.sup.hub().store;
    if store.agent_get(&s.agent_id)?.is_none() {
        return Err(RpcError::new(super::SERVER_ERROR, format!("no agent {}", s.agent_id)));
    }
    if s.prompt.trim().is_empty() {
        return Err(RpcError::new(INVALID_PARAMS, "prompt is empty"));
    }
    s.title = clean_title(s.title)?;
    let next = scheduler::next_run(&s.cron, &s.tz, crate::store::now_ms())
        .map_err(|e| RpcError::new(INVALID_PARAMS, e.to_string()))?;
    let created = store.schedule_create(s, Some(next))?;
    ok(view(&created, crate::store::now_ms()))
}

/// `schedules.update`: the next run is recomputed only when the timing changes or the schedule is switched
/// on. A prompt edit or a switch off keeps `next_run_at`, so a run that is already due is not pushed back.
pub fn update(app: &App, id: &str, mut patch: SchedulePatch) -> RpcResult {
    let store = &app.sup.hub().store;
    let Some(cur) = store.schedule_get(id)? else {
        return Err(RpcError::new(super::SERVER_ERROR, format!("no schedule {id}")));
    };
    if patch.prompt.as_deref().is_some_and(|t| t.trim().is_empty()) {
        return Err(RpcError::new(INVALID_PARAMS, "prompt is empty"));
    }
    patch.title = match patch.title.take() {
        Some(t) => Some(clean_title(t)?),
        None => None,
    };
    let timing_changed =
        patch.cron.as_deref().is_some_and(|c| c != cur.cron) || patch.tz.as_deref().is_some_and(|z| z != cur.tz);
    let switched_on = patch.enabled == Some(true) && !cur.enabled;
    let next = if timing_changed || switched_on {
        let cron = patch.cron.as_deref().unwrap_or(&cur.cron);
        let tz = patch.tz.as_deref().unwrap_or(&cur.tz);
        crate::store::NextRun::Set(Some(
            scheduler::next_run(cron, tz, crate::store::now_ms())
                .map_err(|e| RpcError::new(INVALID_PARAMS, e.to_string()))?,
        ))
    } else {
        crate::store::NextRun::Keep
    };
    let updated = store.schedule_update(id, patch, next)?;
    ok(view(&updated, crate::store::now_ms()))
}

/// The agent's methods. `me` is the agent the session's token names; every id must be one of its schedules.
pub async fn agent_dispatch(app: &App, me: &str, method: &str, p: Value) -> RpcResult {
    let store = &app.sup.hub().store;
    let own = |id: &str| -> Result<(), RpcError> {
        match store.schedule_get(id)? {
            Some(s) if s.agent_id == me => Ok(()),
            _ => Err(RpcError::new(INVALID_PARAMS, format!("no schedule {id} of yours"))),
        }
    };
    match method {
        "schedules.agent.list" => ok(views(store.schedule_list(Some(me))?)),
        "schedules.agent.create" => {
            let a: AgentCreate = params(p)?;
            if a.prompt.chars().count() > AGENT_PROMPT_CHARS {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("prompt is longer than {AGENT_PROMPT_CHARS} characters"),
                ));
            }
            if store.schedule_list(Some(me))?.len() >= AGENT_SCHEDULES {
                return Err(RpcError::new(
                    INVALID_PARAMS,
                    format!("an agent can have at most {AGENT_SCHEDULES} schedules: delete one first"),
                ));
            }
            let cron = cron_from_forms(&a)?;
            let tz = schedule_text::local_zone();
            check_agent_interval(&cron, &tz)?;
            create(
                app,
                NewSchedule {
                    agent_id: me.to_string(),
                    cron,
                    tz,
                    prompt: a.prompt,
                    enabled: true,
                    title: a.title,
                },
            )
        }
        "schedules.agent.update" => {
            let AgentUpdate { id, paused } = params(p)?;
            own(&id)?;
            update(
                app,
                &id,
                SchedulePatch {
                    enabled: paused.map(|paused| !paused),
                    ..Default::default()
                },
            )
        }
        "schedules.agent.delete" => {
            let AgentId { id } = params(p)?;
            own(&id)?;
            ok(json!({ "deleted": store.schedule_delete(&id)? }))
        }
        _ => Err(RpcError::new(
            super::METHOD_NOT_FOUND,
            format!("unknown method {method}"),
        )),
    }
}

/// Refuses a cron whose runs come closer than [`AGENT_MIN_GAP_MS`]. Two consecutive firings are compared,
/// which covers every form (`every`, `at`, `cron`) and the zone's own rules.
fn check_agent_interval(cron: &str, tz: &str) -> Result<(), RpcError> {
    let now = crate::store::now_ms();
    let invalid = |e: anyhow::Error| RpcError::new(INVALID_PARAMS, format!("{e:#}"));
    let first = scheduler::next_run(cron, tz, now).map_err(invalid)?;
    let second = scheduler::next_run(cron, tz, first).map_err(invalid)?;
    let gap = second - first;
    if gap < AGENT_MIN_GAP_MS {
        let shown = if gap < 60_000 {
            format!("{} seconds", (gap / 1000).max(1))
        } else {
            format!("{} minutes", gap / 60_000)
        };
        return Err(RpcError::new(
            INVALID_PARAMS,
            format!("runs every {shown}: the shortest interval for an agent is 5 minutes"),
        ));
    }
    Ok(())
}

/// The cron of an agent's request: exactly one of `every`, `at` (+ `days`), `cron`.
fn cron_from_forms(a: &AgentCreate) -> Result<String, RpcError> {
    let bad = |m: String| RpcError::new(INVALID_PARAMS, m);
    let given = [a.every.is_some(), a.at.is_some(), a.cron.is_some()]
        .iter()
        .filter(|g| **g)
        .count();
    if given != 1 {
        return Err(bad("give exactly one of every, at, cron".into()));
    }
    if a.days.is_some() && a.at.is_none() {
        return Err(bad("days goes with at".into()));
    }
    if let Some(every) = &a.every {
        schedule_text::cron_every(every).map_err(bad)
    } else if let Some(at) = &a.at {
        schedule_text::cron_at(at, a.days.as_deref()).map_err(bad)
    } else {
        Ok(a.cron.clone().unwrap_or_default())
    }
}

#[cfg(test)]
mod tests {
    use super::super::{INVALID_PARAMS, Peer, UNAUTHORIZED, dispatch};
    use super::*;
    use crate::hub::Hub;
    use crate::runtime::RuntimeKind;
    use crate::store::{NewAgent, Store};
    use crate::supervisor::{Runtimes, Supervisor};
    use std::sync::Arc;

    /// An app with two agents; returns their ids as `(forge, scout)`.
    fn two_agents() -> (Arc<App>, String, String) {
        let store = Arc::new(Store::open_in_memory().unwrap());
        let mut ids = Vec::new();
        for name in ["Forge", "Scout"] {
            let a = store
                .agent_create(NewAgent {
                    use_personal_settings: false,
                    avatar: None,
                    capabilities: None,
                    integrations: None,
                    name: name.into(),
                    role: String::new(),
                    runtime: RuntimeKind::Claude,
                    model: None,
                    cwd: "/tmp".into(),
                    approval_mode: crate::store::ApprovalMode::Risky,
                    system_prompt: None,
                    effort: None,
                    memory_mode: crate::store::MemoryMode::Smart,
                    context_budget: None,
                    fallback_runtime: None,
                    fallback_model: None,
                })
                .unwrap();
            ids.push(a.id);
        }
        let sup = Supervisor::new(Hub::new(store), Runtimes::default(), None);
        let home = std::env::temp_dir().join(format!("bandito-sched-agent-{}", crate::store::new_id()));
        (App::new(sup, home), ids.remove(0), ids.remove(0))
    }

    async fn as_agent(app: &App, agent: &str, method: &str, p: Value) -> RpcResult {
        dispatch(app, &Peer::Agent(agent.into()), method, p).await
    }

    #[tokio::test]
    async fn an_agent_makes_a_schedule_from_every_at_or_cron_and_sees_it_in_words() {
        let (app, forge, _) = two_agents();
        let made = as_agent(
            &app,
            &forge,
            "schedules.agent.create",
            json!({ "every": "15m", "prompt": "проверка", "title": "  Почта  " }),
        )
        .await
        .unwrap();
        assert_eq!(made["cron"], "*/15 * * * *");
        assert_eq!(made["agent_id"], forge.as_str(), "the agent is the one its token names");
        assert_eq!(made["title"], "Почта");
        assert_eq!(made["human_en"], "every 15 minutes");
        assert_eq!(made["human_ru"], "каждые 15 минут");
        assert!(made["next_run_at"].as_i64().is_some());

        let at = as_agent(
            &app,
            &forge,
            "schedules.agent.create",
            json!({ "at": "09:00", "days": ["mon", "tue", "wed", "thu", "fri"], "prompt": "отчёт" }),
        )
        .await
        .unwrap();
        assert_eq!(
            (at["cron"].as_str(), at["human_ru"].as_str()),
            (Some("0 9 * * 1-5"), Some("по будням в 09:00"))
        );
        assert_eq!(at["title"], Value::Null);

        let raw = as_agent(
            &app,
            &forge,
            "schedules.agent.create",
            json!({ "cron": "0 3 1 * *", "prompt": "раз в месяц" }),
        )
        .await
        .unwrap();
        assert_eq!(raw["human_en"], "0 3 1 * *", "an odd cron is shown as it is");
    }

    #[tokio::test]
    async fn the_forms_are_checked_before_anything_is_stored() {
        let (app, forge, _) = two_agents();
        let bad = [
            json!({ "prompt": "x" }),
            json!({ "every": "15m", "at": "09:00", "prompt": "x" }),
            json!({ "every": "15m", "cron": "* * * * *", "prompt": "x" }),
            json!({ "at": "09:00", "days": ["funday"], "prompt": "x" }),
            json!({ "every": "15m", "days": ["mon"], "prompt": "x" }),
            json!({ "every": "7m", "prompt": "x" }),
            json!({ "every": "2m", "prompt": "x" }),
            json!({ "cron": "not a cron", "prompt": "x" }),
            json!({ "every": "15m", "prompt": "   " }),
            json!({ "every": "15m", "prompt": "x", "title": "é".repeat(81) }),
        ];
        for p in bad {
            let err = as_agent(&app, &forge, "schedules.agent.create", p.clone())
                .await
                .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{p}");
        }
        assert_eq!(
            as_agent(&app, &forge, "schedules.agent.list", json!({})).await.unwrap(),
            json!([])
        );
    }

    #[tokio::test]
    async fn an_agent_sees_and_changes_only_its_own_schedules() {
        let (app, forge, scout) = two_agents();
        let mine = as_agent(
            &app,
            &forge,
            "schedules.agent.create",
            json!({ "every": "1h", "prompt": "a" }),
        )
        .await
        .unwrap();
        let theirs = as_agent(
            &app,
            &scout,
            "schedules.agent.create",
            json!({ "every": "1h", "prompt": "b" }),
        )
        .await
        .unwrap();
        let (mine_id, theirs_id) = (mine["id"].as_str().unwrap(), theirs["id"].as_str().unwrap());

        let list = as_agent(&app, &forge, "schedules.agent.list", json!({})).await.unwrap();
        assert_eq!(list.as_array().map(Vec::len), Some(1));
        assert_eq!(list[0]["id"], mine_id);

        for (method, p) in [
            ("schedules.agent.update", json!({ "id": theirs_id, "paused": true })),
            ("schedules.agent.delete", json!({ "id": theirs_id })),
        ] {
            let err = as_agent(&app, &forge, method, p).await.unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{method}");
        }
        let still = app.sup.hub().store.schedule_get(theirs_id).unwrap();
        assert!(still.is_some_and(|s| s.enabled));

        let paused = as_agent(
            &app,
            &forge,
            "schedules.agent.update",
            json!({ "id": mine_id, "paused": true }),
        )
        .await
        .unwrap();
        assert_eq!(paused["enabled"], false);
        assert_eq!(
            paused["next_run_at"], mine["next_run_at"],
            "a pause keeps the stored next run"
        );
        let resumed = as_agent(
            &app,
            &forge,
            "schedules.agent.update",
            json!({ "id": mine_id, "paused": false }),
        )
        .await
        .unwrap();
        assert_eq!(resumed["enabled"], true);

        let deleted = as_agent(&app, &forge, "schedules.agent.delete", json!({ "id": mine_id }))
            .await
            .unwrap();
        assert_eq!(deleted, json!({ "deleted": true }));
    }

    #[tokio::test]
    async fn owner_and_agents_keep_to_their_own_schedule_methods() {
        let (app, forge, _) = two_agents();
        let err = dispatch(&app, &Peer::Local, "schedules.agent.list", json!({}))
            .await
            .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED, "the owner's CLI may not speak as an agent");
        let err = as_agent(&app, &forge, "schedules.list", json!({})).await.unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED, "an agent may not list every schedule");
        let err = as_agent(&app, &forge, "schedules.run_now", json!({ "id": "x" }))
            .await
            .unwrap_err();
        assert_eq!(err.code, UNAUTHORIZED);
    }

    #[tokio::test]
    async fn owner_schedules_carry_the_title_and_the_words() {
        let (app, forge, _) = two_agents();
        let created = dispatch(
            &app,
            &Peer::Local,
            "schedules.create",
            json!({ "agent_id": forge, "cron": "0 0 * * *", "prompt": "p", "title": "Полночь" }),
        )
        .await
        .unwrap();
        assert_eq!(
            (created["title"].as_str(), created["human_en"].as_str()),
            (Some("Полночь"), Some("every day at 00:00"))
        );
        let id = created["id"].as_str().unwrap();
        let cleared = dispatch(
            &app,
            &Peer::Local,
            "schedules.update",
            json!({ "id": id, "title": null }),
        )
        .await
        .unwrap();
        assert_eq!(cleared["title"], Value::Null);
        let listed = dispatch(&app, &Peer::Local, "schedules.list", json!({ "agent_id": forge }))
            .await
            .unwrap();
        assert_eq!(listed[0]["human_ru"], "каждый день в 00:00");
    }

    #[tokio::test]
    async fn an_agent_cannot_schedule_runs_closer_than_five_minutes() {
        let (app, forge, _) = two_agents();
        for cron in ["* * * * *", "*/4 * * * *", "*/2 * * * *", "30 * * * * *"] {
            let err = as_agent(
                &app,
                &forge,
                "schedules.agent.create",
                json!({ "cron": cron, "prompt": "x" }),
            )
            .await
            .unwrap_err();
            assert_eq!(err.code, INVALID_PARAMS, "{cron}");
        }
        let too_often = as_agent(
            &app,
            &forge,
            "schedules.agent.create",
            json!({ "cron": "* * * * *", "prompt": "x" }),
        )
        .await
        .unwrap_err();
        assert!(too_often.message.contains("5 minutes"), "{}", too_often.message);
        for cron in ["*/5 * * * *", "0 * * * *", "0 9 * * 1-5"] {
            as_agent(
                &app,
                &forge,
                "schedules.agent.create",
                json!({ "cron": cron, "prompt": "x" }),
            )
            .await
            .unwrap_or_else(|e| panic!("{cron}: {}", e.message));
        }
    }

    #[tokio::test]
    async fn an_agent_holds_at_most_twenty_schedules_and_prompts_are_capped() {
        let (app, forge, scout) = two_agents();
        for i in 0..AGENT_SCHEDULES {
            as_agent(
                &app,
                &forge,
                "schedules.agent.create",
                json!({ "every": "1h", "prompt": format!("p{i}") }),
            )
            .await
            .unwrap();
        }
        let err = as_agent(
            &app,
            &forge,
            "schedules.agent.create",
            json!({ "every": "1h", "prompt": "one more" }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        assert!(err.message.contains("20"), "{}", err.message);
        // The count is per agent: the other one still has room.
        as_agent(
            &app,
            &scout,
            "schedules.agent.create",
            json!({ "every": "1h", "prompt": "fine" }),
        )
        .await
        .unwrap();

        let long = "я".repeat(AGENT_PROMPT_CHARS + 1);
        let err = as_agent(
            &app,
            &scout,
            "schedules.agent.create",
            json!({ "every": "1h", "prompt": long }),
        )
        .await
        .unwrap_err();
        assert_eq!(err.code, INVALID_PARAMS);
        let exact = "я".repeat(AGENT_PROMPT_CHARS);
        as_agent(
            &app,
            &scout,
            "schedules.agent.create",
            json!({ "every": "2h", "prompt": exact }),
        )
        .await
        .unwrap();
    }
}
