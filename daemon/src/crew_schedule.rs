//! The schedule tools of the crew MCP server: `schedule_list`, `schedule_create`, `schedule_delete`,
//! `schedule_pause`. They call the `schedules.agent.*` methods, which keep an agent to its own schedules, and
//! need no capability (a scheduled run still has only the capabilities the agent has then).
//! See docs/ARCHITECTURE.md#scheduler.

use crate::crew::CrewBackend;
use chrono::{DateTime, Utc};
use serde_json::{Value, json};

/// The tools, in the order `tools/list` gives them.
pub const SCHEDULE_TOOLS: [&str; 4] = ["schedule_list", "schedule_create", "schedule_delete", "schedule_pause"];

/// Longest prompt shown in a list line, in characters.
const SHOWN_CHARS: usize = 80;

pub fn tool_defs() -> Vec<Value> {
    vec![
        json!({
            "name": "schedule_list",
            "description": "List your scheduled runs: id, what they are for, on or paused, and the next run. Bandito starts you on the schedule, so cron and launchd are not needed.",
            "inputSchema": { "type": "object", "properties": {} },
        }),
        json!({
            "name": "schedule_create",
            "description": "Schedule a run of yourself: Bandito starts you with the prompt at the given times, in the server's time zone. For regular tasks (check the mail every 15 minutes and the like). Give exactly one of every, at (with optional days), or cron. every must be 5m to 60m, 1h to 12h, or 1d (at midnight).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "every": { "type": "string", "description": "Interval: 15m, 2h or 1d" },
                    "at": { "type": "string", "description": "Time of day as HH:MM" },
                    "days": {
                        "type": "array",
                        "items": { "type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] },
                        "description": "With at: the days; leave out for every day",
                    },
                    "cron": { "type": "string", "description": "A 5-field cron: minute hour day month weekday" },
                    "prompt": { "type": "string", "description": "What to do on each run" },
                    "title": { "type": "string", "description": "A short name for the list" },
                },
                "required": ["prompt"],
            },
        }),
        json!({
            "name": "schedule_delete",
            "description": "Delete one of your scheduled runs, by its id from schedule_list.",
            "inputSchema": {
                "type": "object",
                "properties": { "id": { "type": "string" } },
                "required": ["id"],
            },
        }),
        json!({
            "name": "schedule_pause",
            "description": "Pause or resume one of your scheduled runs, by its id. A paused run is skipped until it is resumed.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "id": { "type": "string" },
                    "paused": { "type": "boolean" },
                },
                "required": ["id", "paused"],
            },
        }),
    ]
}

/// Runs one schedule tool. `Err` is a tool error, shown to the agent.
pub async fn call(name: &str, args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    match name {
        "schedule_list" => list(backend).await,
        "schedule_create" => create(args, backend).await,
        "schedule_delete" => delete(args, backend).await,
        "schedule_pause" => pause(args, backend).await,
        other => Err(format!("unknown schedule tool {other}")),
    }
}

async fn list(backend: &dyn CrewBackend) -> Result<String, String> {
    let v = backend
        .schedules("schedules.agent.list", json!({}))
        .await
        .map_err(|e| format!("{e:#}"))?;
    let rows = v.as_array().cloned().unwrap_or_default();
    if rows.is_empty() {
        return Ok("You have no scheduled runs. Create one with schedule_create.".into());
    }
    let lines: Vec<String> = rows.iter().map(line).collect();
    Ok(lines.join("\n"))
}

async fn create(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let prompt = args
        .get("prompt")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "schedule_create needs \"prompt\"".to_string())?;
    let mut params = json!({ "prompt": prompt });
    for key in ["every", "at", "days", "cron", "title"] {
        if let Some(v) = args.get(key).filter(|v| !v.is_null()) {
            params[key] = v.clone();
        }
    }
    let v = backend
        .schedules("schedules.agent.create", params)
        .await
        .map_err(|e| format!("{e:#}"))?;
    Ok(format!(
        "Scheduled {}: {}. Next run: {}.",
        str_of(&v, "id"),
        str_of(&v, "human_en"),
        when(&v["next_run_at"])
    ))
}

async fn delete(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let id = id_arg(args, "schedule_delete")?;
    backend
        .schedules("schedules.agent.delete", json!({ "id": id }))
        .await
        .map_err(|e| format!("{e:#}"))?;
    Ok(format!("Deleted schedule {id}."))
}

async fn pause(args: &Value, backend: &dyn CrewBackend) -> Result<String, String> {
    let id = id_arg(args, "schedule_pause")?;
    let paused = args
        .get("paused")
        .and_then(Value::as_bool)
        .ok_or_else(|| "schedule_pause needs \"paused\" as true or false".to_string())?;
    backend
        .schedules("schedules.agent.update", json!({ "id": id, "paused": paused }))
        .await
        .map_err(|e| format!("{e:#}"))?;
    Ok(if paused {
        format!("Paused schedule {id}.")
    } else {
        format!("Resumed schedule {id}.")
    })
}

fn id_arg(args: &Value, tool: &str) -> Result<String, String> {
    args.get("id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .ok_or_else(|| format!("{tool} needs \"id\""))
}

/// One list line: `id | title or prompt | every 15 minutes | on, next 2026-10-10 15:00 UTC`.
fn line(s: &Value) -> String {
    let what = s
        .get("title")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| str_of(s, "prompt").chars().take(SHOWN_CHARS).collect());
    let state = if s.get("enabled").and_then(Value::as_bool).unwrap_or(true) {
        format!("on, next {}", when(&s["next_run_at"]))
    } else {
        "paused".to_string()
    };
    format!("{} | {} | {} | {}", str_of(s, "id"), what, str_of(s, "human_en"), state)
}

fn str_of(v: &Value, key: &str) -> String {
    v.get(key).and_then(Value::as_str).unwrap_or_default().to_string()
}

/// A run time in UTC, or a dash when there is none.
fn when(ms: &Value) -> String {
    ms.as_i64()
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .map(|t| t.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_else(|| "—".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_line_says_what_when_and_state() {
        let s = json!({
            "id": "s1", "title": "Почта", "prompt": "check", "human_en": "every 15 minutes",
            "enabled": true, "next_run_at": 1_791_684_000_000i64,
        });
        assert_eq!(
            line(&s),
            "s1 | Почта | every 15 minutes | on, next 2026-10-11 02:00 UTC"
        );
        let paused = json!({ "id": "s2", "prompt": "x".repeat(100), "human_en": "every hour", "enabled": false });
        let text = line(&paused);
        assert!(text.ends_with("| every hour | paused"));
        assert_eq!(text.split(" | ").nth(1).map(|t| t.chars().count()), Some(SHOWN_CHARS));
    }

    #[test]
    fn every_tool_has_a_schema_and_the_names_match() {
        let defs = tool_defs();
        let names: Vec<&str> = defs.iter().filter_map(|t| t["name"].as_str()).collect();
        assert_eq!(names, SCHEDULE_TOOLS);
        assert!(defs.iter().all(|t| t["inputSchema"]["type"] == "object"));
    }

    /// A backend that records the schedules calls and answers with `reply`; the rest is unused here.
    struct Fake {
        calls: std::sync::Mutex<Vec<(String, Value)>>,
        reply: Value,
    }

    #[async_trait::async_trait]
    impl CrewBackend for Fake {
        async fn list(&self) -> anyhow::Result<Vec<crate::crew::CrewMember>> {
            Ok(vec![])
        }
        async fn send(&self, _to: &str, _message: &str) -> anyhow::Result<()> {
            Ok(())
        }
        async fn history_search(&self, _query: &str, _limit: u32) -> anyhow::Result<String> {
            Ok(String::new())
        }
        async fn history_day(&self, _date: &str) -> anyhow::Result<String> {
            Ok(String::new())
        }
        async fn browser(&self, _method: &str, _params: Value) -> anyhow::Result<Value> {
            Ok(json!({}))
        }
        async fn screen(&self, _method: &str, _params: Value) -> anyhow::Result<Value> {
            Ok(json!({}))
        }
        async fn schedules(&self, method: &str, params: Value) -> anyhow::Result<Value> {
            self.calls.lock().unwrap().push((method.to_string(), params));
            Ok(self.reply.clone())
        }
    }

    fn fake(reply: Value) -> Fake {
        Fake {
            calls: std::sync::Mutex::new(Vec::new()),
            reply,
        }
    }

    #[tokio::test]
    async fn create_forwards_the_forms_and_says_when_the_next_run_is() {
        let f = fake(json!({
            "id": "s9", "human_en": "weekdays at 09:00", "next_run_at": 1_791_684_000_000i64,
        }));
        let args =
            json!({ "at": "09:00", "days": ["mon", "tue"], "every": null, "prompt": " отчёт ", "title": "Утро" });
        let said = call("schedule_create", &args, &f).await.unwrap();
        assert_eq!(said, "Scheduled s9: weekdays at 09:00. Next run: 2026-10-11 02:00 UTC.");
        let calls = f.calls.lock().unwrap();
        assert_eq!(calls[0].0, "schedules.agent.create");
        assert_eq!(
            calls[0].1,
            json!({ "at": "09:00", "days": ["mon", "tue"], "prompt": "отчёт", "title": "Утро" })
        );
    }

    #[tokio::test]
    async fn create_without_a_prompt_is_a_tool_error_and_calls_nothing() {
        let f = fake(json!({}));
        for args in [json!({ "every": "15m" }), json!({ "every": "15m", "prompt": "  " })] {
            let err = call("schedule_create", &args, &f).await.unwrap_err();
            assert_eq!(err, "schedule_create needs \"prompt\"");
        }
        assert!(f.calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_names_each_schedule_and_says_when_there_are_none() {
        let f = fake(json!([]));
        assert_eq!(
            call("schedule_list", &json!({}), &f).await.unwrap(),
            "You have no scheduled runs. Create one with schedule_create."
        );
        let f = fake(
            json!([{ "id": "a", "prompt": "mail", "human_en": "every 15 minutes", "enabled": true, "next_run_at": 1_791_684_000_000i64 }]),
        );
        assert_eq!(
            call("schedule_list", &json!({}), &f).await.unwrap(),
            "a | mail | every 15 minutes | on, next 2026-10-11 02:00 UTC"
        );
    }

    #[tokio::test]
    async fn delete_and_pause_need_their_arguments() {
        let f = fake(json!({}));
        assert_eq!(
            call("schedule_delete", &json!({ "id": "a" }), &f).await.unwrap(),
            "Deleted schedule a."
        );
        assert_eq!(
            call("schedule_pause", &json!({ "id": "a", "paused": true }), &f)
                .await
                .unwrap(),
            "Paused schedule a."
        );
        assert_eq!(
            call("schedule_pause", &json!({ "id": "a", "paused": false }), &f)
                .await
                .unwrap(),
            "Resumed schedule a."
        );
        assert!(call("schedule_delete", &json!({}), &f).await.is_err());
        assert!(call("schedule_pause", &json!({ "id": "a" }), &f).await.is_err());
        let calls = f.calls.lock().unwrap();
        assert_eq!(
            calls[2],
            (
                "schedules.agent.update".to_string(),
                json!({ "id": "a", "paused": false })
            )
        );
    }
}
