//! Query plans and timings on a realistic database (docs/ARCHITECTURE.md#store-sqlite).
//!
//! The database is built in a temp folder through `Store::open`: 50 agents with uneven event counts, 300 000 events,
//! approvals, schedules, checkpoints, forms, reactions, rules, integrations, the call journal and Telegram rows.
//! Every hot statement of `daemon/src/store/*.rs` is listed in `queries()` with the same text (keep them in sync when a
//! query changes). The test fails when a statement scans a table with more than `BIG_ROWS` rows, directly or through
//! an alias. It prints a table «query → plan» and the timings of the hottest reads (run with `--nocapture`).

use bandito::store::Store;
use rusqlite::{Connection, params};
use std::path::Path;
use std::time::Instant;

const AGENTS: i64 = 50;
const EVENTS: i64 = 300_000;
const APPROVALS: i64 = 5_000;
const SCHEDULES: i64 = 2_000;
const CHECKPOINTS: i64 = 10_000;
const FORMS: i64 = 2_000;
const REACTIONS: i64 = 3_000;
const RULES: i64 = 500;
const INTEGRATIONS: i64 = 20;
const TOOL_CALLS: i64 = 20_000;
const TG_MESSAGES: i64 = 5_000;
const BIG_ROWS: i64 = 1_000;
const TIMING_RUNS: u32 = 100;
const DEBUG_LIMIT_MS: f64 = 50.0;
const TARGET_MS: f64 = 5.0;
const NOW_MS: i64 = 1_800_000_000_000;
const DAY_MS: i64 = 86_400_000;

const AGENT_COLS: &str = "id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at, effort, memory_mode, context_budget, home_dir, context_tokens, chapter, last_turn_at, fallback_runtime, fallback_model, active_runtime, workspace_id, paused, use_personal_settings, avatar_color, avatar_face, capabilities, avatar_emoji, avatar_image, avatar_image_rev, integrations, lead, template_id, migrated_to, migrated_at";
const APPROVAL_COLS: &str = "id, agent_id, call_id, tool, title, payload, status, decision, created_at, resolved_at";
const CHECKPOINT_COLS: &str = "id, agent_id, sha, label, kind, turn_id, created_at";
const FORM_COLS: &str = "id, agent_id, spec, status, answer, created_at, answered_at";
const SCHEDULE_COLS: &str = "id, agent_id, cron, tz, prompt, enabled, last_run_at, next_run_at, created_at, title";
const RULE_COLS: &str = "id, agent_id, pattern, action, created_at";
const WORKSPACE_COLS: &str = "id, name, kind, image, cpus, memory_mb, network, mounts, created_at";
const CHAT_COLS: &str = "chat_id, user_id, title, language, linked_at, approvals, answers, current_agent";
const EVENT_COLS: &str = "seq, agent_id, ts, kind, payload";
const LAST_MESSAGE_SQL: &str = "(SELECT json_array(kind, ts, substr(json_extract(payload, '$.text'), 1, 200)) FROM events \
    WHERE agent_id = agents.id AND kind IN ('message.user','message.assistant') \
    AND (kind <> 'message.user' OR json_extract(payload, '$.source') IS NOT 'system') \
    ORDER BY seq DESC LIMIT 1)";
const STATUS_SQL: &str = "(SELECT json_extract(payload, '$.status') FROM events \
    WHERE agent_id = agents.id AND kind = 'agent.status' ORDER BY seq DESC LIMIT 1)";
const PENDING_IDS_SQL: &str = "(SELECT json_group_array(id) FROM (SELECT id FROM approvals \
    WHERE agent_id = agents.id AND status = 'pending' ORDER BY created_at, id))";

/// The tables with more rows than `BIG_ROWS` after `populate`: a `SCAN` of any of them fails the test.
const BIG_TABLES: &[&str] = &[
    "events",
    "approvals",
    "schedules",
    "checkpoints",
    "forms",
    "reactions",
    "tool_calls",
    "telegram_messages",
];

/// Statements that read a whole table on purpose. Each one is bounded, so its cost stops growing with the history:
/// the call journal is capped at `MAX_ROWS` (20 000) and kept 30 days, and the two unfiltered lists return every row,
/// so their scan is the size of the answer. Anything else over `BIG_ROWS` fails the test.
const BOUNDED_SCANS: &[(&str, &str)] = &[
    (
        "tool_calls count (prune)",
        "COUNT over the capped call journal (at most 20 000 rows), once per 200 recorded calls",
    ),
    (
        "tool_call_stats",
        "aggregate over the 30-day retention window of the capped call journal",
    ),
    (
        "tool_calls prune (cap)",
        "oldest rows beyond the cap: an ordered index walk that stops after LIMIT rows",
    ),
    ("form_list (all)", "returns every form, so the scan is the answer"),
    (
        "schedule_list (all)",
        "returns every schedule, so the scan is the answer",
    ),
];

/// Deterministic generator, so every run builds the same database.
struct Rng(u64);

impl Rng {
    fn next_u64(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn unit(&mut self) -> f64 {
        (self.next_u64() % 1_000_000) as f64 / 1_000_000.0
    }
}

fn agent_id(i: i64) -> String {
    format!("agent-{i:02}")
}

/// Fills the database at `path` (already migrated by `Store::open`) through a raw connection, in one transaction.
fn populate(path: &Path) {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch("BEGIN").unwrap();
    for i in 0..AGENTS {
        conn.execute(
            "INSERT INTO agents (id, name, runtime, cwd, created_at, updated_at) VALUES (?1, ?2, 'claude', '/work', ?3, ?3)",
            params![agent_id(i), format!("Agent {i:02}"), 1_000 + i],
        )
        .unwrap();
    }
    let mut rng = Rng(0x9E37_79B9_7F4A_7C15);
    let base_ts = NOW_MS - 40 * DAY_MS;
    {
        let mut ins = conn
            .prepare("INSERT INTO events (agent_id, ts, kind, payload) VALUES (?1, ?2, ?3, ?4)")
            .unwrap();
        for n in 0..EVENTS {
            // Skewed towards the first agents: agent 0 gets about a quarter of the events, the last ones a handful.
            let u = rng.unit();
            let a = ((AGENTS as f64) * u * u * u) as i64;
            let ts = base_ts + n * 10_000;
            let k = rng.next_u64() % 100;
            let (kind, payload) = match k {
                0..=19 => {
                    let queued = k.is_multiple_of(5);
                    (
                        "message.user",
                        format!(r#"{{"text":"question {n}","source":"user","queued":{queued}}}"#),
                    )
                }
                20..=29 => ("message.user", format!(r#"{{"text":"note {n}","source":"system"}}"#)),
                30..=49 => (
                    "message.assistant",
                    format!(r#"{{"text":"answer {n} with some text"}}"#),
                ),
                50..=59 => (
                    "turn.started",
                    format!(
                        r#"{{"turn_id":"t{n}","source":"user","message_seq":{},"reactions_until":{ts}}}"#,
                        n - 1
                    ),
                ),
                60..=74 => (
                    "tool.call",
                    format!(r#"{{"call_id":"c{n}","tool":"search","title":"Search","input":{{}}}}"#),
                ),
                75..=86 => {
                    let status = if n % 3 == 0 { "working" } else { "idle" };
                    ("agent.status", format!(r#"{{"status":"{status}"}}"#))
                }
                87..=90 => (
                    "approval.requested",
                    format!(
                        r#"{{"approval_id":"apr-{n}","call_id":"c{n}","tool":"Bash","title":"run","reason":"risky"}}"#
                    ),
                ),
                91..=93 => (
                    "integration_requested",
                    format!(r#"{{"request_id":"r{n}","service":"github"}}"#),
                ),
                94..=95 => (
                    "integration_request_ended",
                    format!(r#"{{"request_id":"r{}","status":"connected"}}"#, n - 1),
                ),
                96..=97 => ("message.dropped", format!(r#"{{"seq":{n},"reason":"queue"}}"#)),
                _ => (
                    "tool.result",
                    format!(r#"{{"call_id":"c{n}","ok":true,"output":"ok"}}"#),
                ),
            };
            ins.execute(params![agent_id(a), ts, kind, payload]).unwrap();
        }
    }
    for i in 0..APPROVALS {
        let status = if i % 50 == 0 { "pending" } else { "resolved" };
        conn.execute(
            "INSERT INTO approvals (id, agent_id, call_id, tool, title, payload, status, created_at)
             VALUES (?1, ?2, ?3, 'Bash', 'run', '{}', ?4, ?5)",
            params![
                format!("apr-{i:05}"),
                agent_id(i % AGENTS),
                format!("call-{i}"),
                status,
                base_ts + i * 60_000
            ],
        )
        .unwrap();
    }
    for i in 0..SCHEDULES {
        conn.execute(
            "INSERT INTO schedules (id, agent_id, cron, tz, prompt, enabled, next_run_at, created_at)
             VALUES (?1, ?2, '0 9 * * *', 'UTC', 'report', ?3, ?4, ?5)",
            params![
                format!("sch-{i:05}"),
                agent_id(i % AGENTS),
                i64::from(i % 10 != 0),
                NOW_MS - 3_600_000 + i * 90_000,
                base_ts + i
            ],
        )
        .unwrap();
    }
    for i in 0..CHECKPOINTS {
        conn.execute(
            "INSERT INTO checkpoints (id, agent_id, sha, label, kind, created_at) VALUES (?1, ?2, ?3, 'turn', 'turn', ?4)",
            params![format!("ck-{i:05}"), agent_id(i % AGENTS), format!("{i:040x}"), base_ts + i * 1_000],
        )
        .unwrap();
    }
    for i in 0..FORMS {
        let status = if i % 4 == 0 { "pending" } else { "submitted" };
        conn.execute(
            "INSERT INTO forms (id, agent_id, spec, status, created_at) VALUES (?1, ?2, '{}', ?3, ?4)",
            params![format!("fm-{i:05}"), agent_id(i % AGENTS), status, base_ts + i * 1_000],
        )
        .unwrap();
    }
    for i in 0..REACTIONS {
        let by = if i % 2 == 0 { "user" } else { "agent" };
        conn.execute(
            "INSERT INTO reactions (agent_id, seq, by, emoji, at) VALUES (?1, ?2, ?3, 'ok', ?4)",
            params![agent_id(i % AGENTS), i + 1, by, base_ts + i * 1_000],
        )
        .unwrap();
    }
    for i in 0..RULES {
        let agent = if i % 2 == 0 { None } else { Some(agent_id(i % AGENTS)) };
        conn.execute(
            "INSERT INTO rules (id, agent_id, pattern, action, created_at) VALUES (?1, ?2, ?3, 'allow', ?4)",
            params![format!("rule-{i:04}"), agent, format!("pattern {i}"), base_ts + i],
        )
        .unwrap();
    }
    for i in 0..INTEGRATIONS {
        conn.execute(
            "INSERT INTO integrations (id, name, kind, url, headers, enabled, created_at, auth, tool_mode, tool_overrides)
             VALUES (?1, ?2, 'http', 'https://example.test/mcp', '{}', 1, ?3, 'none', 'all', '{}')",
            params![format!("int-{i:02}"), format!("integration {i:02}"), base_ts + i],
        )
        .unwrap();
        for t in 0..10 {
            conn.execute(
                "INSERT INTO integration_tools (integration_id, name, seen_at) VALUES (?1, ?2, ?3)",
                params![format!("int-{i:02}"), format!("tool{t}"), base_ts],
            )
            .unwrap();
        }
    }
    for i in 0..TOOL_CALLS {
        conn.execute(
            "INSERT INTO tool_calls (at_ms, agent_id, integration, tool, duration_ms, ok, decision)
             VALUES (?1, ?2, ?3, 'search', 120, ?4, 'allow')",
            params![
                NOW_MS - i * 170_000,
                agent_id(i % AGENTS),
                format!("int-{:02}", i % INTEGRATIONS),
                i64::from(i % 13 != 0)
            ],
        )
        .unwrap();
    }
    for i in 0..20 {
        conn.execute(
            "INSERT INTO telegram_chats (chat_id, user_id, title, linked_at) VALUES (?1, ?1, 'chat', ?2)",
            params![1_000 + i, base_ts + i],
        )
        .unwrap();
    }
    for i in 0..TG_MESSAGES {
        conn.execute(
            "INSERT INTO telegram_messages (chat_id, message_id, agent_id, kind, ref_id, created_at)
             VALUES (?1, ?2, ?3, 'answer', ?4, ?5)",
            params![
                1_000 + i % 20,
                i,
                agent_id(i % AGENTS),
                format!("ref-{i}"),
                base_ts + i * 1_000
            ],
        )
        .unwrap();
    }
    for i in 0..5 {
        conn.execute(
            "INSERT INTO usage_limits (runtime, windows, updated_at) VALUES (?1, '[]', ?2)",
            params![format!("runtime-{i}"), base_ts],
        )
        .unwrap();
    }
    conn.execute(
        "INSERT INTO workspaces (id, name, kind, network, mounts, created_at) VALUES ('ws-1', 'Box', 'container', 'none', '[]', 1)",
        [],
    )
    .unwrap();
    conn.execute_batch("COMMIT").unwrap();
}

/// Every hot statement of the store, with the text it has in `daemon/src/store/*.rs`.
fn queries() -> Vec<(&'static str, String)> {
    let q: Vec<(&'static str, String)> = vec![
        // mod.rs: events
        ("events_since (all)", format!("SELECT {EVENT_COLS} FROM events WHERE seq > ?1 ORDER BY seq LIMIT ?2")),
        ("events_since (agent)", format!("SELECT {EVENT_COLS} FROM events WHERE agent_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3")),
        ("events_page (latest)", format!("SELECT {EVENT_COLS} FROM events WHERE agent_id = ?1 ORDER BY seq DESC LIMIT ?2")),
        ("events_page (before)", format!("SELECT {EVENT_COLS} FROM events WHERE agent_id = ?1 AND seq < ?2 ORDER BY seq DESC LIMIT ?3")),
        ("last_seq", "SELECT COALESCE(MAX(seq), 0) FROM events".into()),
        ("event_at", format!("SELECT {EVENT_COLS} FROM events WHERE agent_id = ?1 AND seq = ?2")),
        ("current_user_message_seq", "SELECT seq, json_extract(payload, '$.message_seq') FROM events WHERE agent_id = ?1 AND kind = 'turn.started' AND json_extract(payload, '$.source') = 'user' ORDER BY seq DESC LIMIT 1".into()),
        ("current_user_message_seq (not queued)", "SELECT seq FROM events WHERE agent_id = ?1 AND kind = 'message.user' AND json_extract(payload, '$.source') = 'user' AND COALESCE(json_extract(payload, '$.queued'), 0) = 0 AND seq > ?2 ORDER BY seq ASC LIMIT 1".into()),
        ("user_reactions_mark", "SELECT COALESCE(json_extract(payload, '$.reactions_until'), ts) FROM events WHERE agent_id = ?1 AND kind = 'turn.started' AND json_extract(payload, '$.source') = 'user' ORDER BY seq DESC LIMIT 1".into()),
        ("queued_messages_unresolved", "SELECT e.agent_id, e.seq FROM events e WHERE e.kind = 'message.user' AND json_extract(e.payload, '$.queued') = 1 AND NOT EXISTS (SELECT 1 FROM events t WHERE t.agent_id = e.agent_id AND t.seq > e.seq AND ((t.kind = 'turn.started' AND json_extract(t.payload, '$.message_seq') = e.seq) OR (t.kind = 'message.dropped' AND json_extract(t.payload, '$.seq') = e.seq))) ORDER BY e.seq".into()),
        ("connect_requests_unresolved", "SELECT e.agent_id, json_extract(e.payload, '$.request_id') FROM events e WHERE e.kind = 'integration_requested' AND NOT EXISTS (SELECT 1 FROM events t WHERE t.agent_id = e.agent_id AND t.seq > e.seq AND t.kind = 'integration_request_ended' AND json_extract(t.payload, '$.request_id') = json_extract(e.payload, '$.request_id')) ORDER BY e.seq".into()),
        // history.rs
        ("history_search", format!("SELECT {EVENT_COLS} FROM events WHERE agent_id = ?1 AND kind IN ('message.user','message.assistant') AND (kind <> 'message.user' OR json_extract(payload, '$.source') IS NOT 'system') AND json_extract(payload, '$.text') LIKE ?2 ESCAPE '\\' ORDER BY seq DESC LIMIT ?3")),
        ("history_range", format!("SELECT {EVENT_COLS} FROM events WHERE agent_id = ?1 AND kind IN ('message.user','message.assistant') AND (kind <> 'message.user' OR json_extract(payload, '$.source') IS NOT 'system') AND ts >= ?2 AND ts < ?3 ORDER BY ts, seq LIMIT ?4")),
        // agents.rs
        ("agent_view / agent_list_view", format!("SELECT {AGENT_COLS}, {LAST_MESSAGE_SQL}, {STATUS_SQL}, {PENDING_IDS_SQL} FROM agents ORDER BY created_at")),
        ("agent_get", format!("SELECT {AGENT_COLS} FROM agents WHERE id = ?1")),
        ("agent_by_name", format!("SELECT {AGENT_COLS} FROM agents WHERE lower(name) = lower(?1)")),
        ("agent_list", format!("SELECT {AGENT_COLS} FROM agents ORDER BY created_at")),
        ("agent_lead", format!("SELECT {AGENT_COLS} FROM agents WHERE lead = 1")),
        ("agent last assistant message", "SELECT ts, json_extract(payload, '$.text') FROM events WHERE agent_id = ?1 AND kind = 'message.assistant' ORDER BY seq DESC LIMIT 1".into()),
        ("agent delete: approvals", "DELETE FROM approvals WHERE agent_id = ?1".into()),
        // approvals.rs
        ("approval_get", format!("SELECT {APPROVAL_COLS} FROM approvals WHERE id = ?1")),
        ("approval_list_pending", format!("SELECT {APPROVAL_COLS} FROM approvals WHERE status = 'pending' AND (?1 IS NULL OR agent_id = ?1) ORDER BY created_at, id")),
        ("approval_resolve", "UPDATE approvals SET status='resolved', decision=?2, resolved_at=?3 WHERE id=?1 AND status='pending'".into()),
        ("approval_expire (older than)", format!("SELECT {APPROVAL_COLS} FROM approvals WHERE status = 'pending' AND created_at < ?1 ORDER BY created_at, id")),
        // checkpoints.rs
        ("checkpoint_list", format!("SELECT {CHECKPOINT_COLS} FROM checkpoints WHERE agent_id = ?1 ORDER BY created_at DESC, rowid DESC LIMIT ?2")),
        ("checkpoint_latest", format!("SELECT {CHECKPOINT_COLS} FROM checkpoints WHERE agent_id = ?1 AND kind = ?2 ORDER BY created_at DESC, rowid DESC LIMIT 1")),
        ("checkpoint_get", format!("SELECT {CHECKPOINT_COLS} FROM checkpoints WHERE id = ?1")),
        // forms.rs
        ("form_get", format!("SELECT {FORM_COLS} FROM forms WHERE id = ?1")),
        ("form_list (all)", format!("SELECT {FORM_COLS} FROM forms ORDER BY created_at DESC, id DESC")),
        ("form_list (agent)", format!("SELECT {FORM_COLS} FROM forms WHERE agent_id = ? ORDER BY created_at DESC, id DESC")),
        ("form_list (status)", format!("SELECT {FORM_COLS} FROM forms WHERE status = ? ORDER BY created_at DESC, id DESC")),
        ("form_list (agent, status)", format!("SELECT {FORM_COLS} FROM forms WHERE agent_id = ? AND status = ? ORDER BY created_at DESC, id DESC")),
        ("form_answer", "UPDATE forms SET status = ?2, answer = ?3, answered_at = ?4 WHERE id = ?1 AND status = 'pending'".into()),
        ("form_expire (agent)", format!("SELECT {FORM_COLS} FROM forms WHERE status = 'pending' AND agent_id = ?1 ORDER BY created_at, id")),
        // schedules.rs
        ("schedule_get", format!("SELECT {SCHEDULE_COLS} FROM schedules WHERE id = ?1")),
        ("schedule_list (all)", format!("SELECT {SCHEDULE_COLS} FROM schedules ORDER BY created_at, id")),
        ("schedule_list (agent)", format!("SELECT {SCHEDULE_COLS} FROM schedules WHERE agent_id = ?1 ORDER BY created_at, id")),
        ("schedule_due", format!("SELECT {SCHEDULE_COLS} FROM schedules WHERE enabled = 1 AND next_run_at <= ?1 ORDER BY next_run_at, id")),
        ("schedule_claim", "UPDATE schedules SET last_run_at = ?2, next_run_at = ?3 WHERE id = ?1 AND enabled = 1 AND next_run_at = ?2".into()),
        ("schedule delete (agent)", "DELETE FROM schedules WHERE agent_id=?1".into()),
        // reactions.rs
        ("reactions_on", "SELECT agent_id, seq, by, emoji, at FROM reactions WHERE agent_id = ?1 AND seq = ?2 ORDER BY by".into()),
        ("user_reactions_between", "SELECT agent_id, seq, by, emoji, at FROM reactions WHERE agent_id = ?1 AND by = 'user' AND at > ?2 AND at <= ?3 ORDER BY at, seq".into()),
        ("reaction delete (agent)", "DELETE FROM reactions WHERE agent_id=?1".into()),
        // rules.rs
        ("rule_list (agent)", format!("SELECT {RULE_COLS} FROM rules WHERE agent_id = ?1 ORDER BY created_at DESC, id DESC")),
        ("rule_list (global)", format!("SELECT {RULE_COLS} FROM rules WHERE agent_id IS NULL ORDER BY created_at DESC, id DESC")),
        ("rule_find", format!("SELECT {RULE_COLS} FROM rules WHERE agent_id IS ?1 AND pattern = ?2 ORDER BY created_at, id LIMIT 1")),
        // integrations.rs
        ("integration_list", "SELECT id, name, kind, url, enabled, created_at FROM integrations ORDER BY created_at, id".into()),
        ("integration_tools", "SELECT name, title, description, read_only, destructive, input_schema, seen_at FROM integration_tools WHERE integration_id = ?1 ORDER BY name".into()),
        // tool_calls.rs
        ("tool_calls_list", "SELECT id, at_ms, agent_id, integration, tool, duration_ms, ok, error, decision FROM tool_calls WHERE at_ms >= ?5 AND (?1 IS NULL OR integration = ?1) AND (?2 IS NULL OR agent_id = ?2) AND id < ?3 ORDER BY id DESC LIMIT ?4".into()),
        ("tool_call_stats", "SELECT integration, SUM(CASE WHEN at_ms >= ?1 THEN 1 ELSE 0 END), SUM(CASE WHEN at_ms >= ?1 AND ok = 0 THEN 1 ELSE 0 END), SUM(CASE WHEN at_ms >= ?2 THEN 1 ELSE 0 END), MAX(at_ms) FROM tool_calls WHERE at_ms >= ?3 GROUP BY integration ORDER BY MAX(at_ms) DESC, integration".into()),
        ("tool_calls count (prune)", "SELECT COUNT(*) FROM tool_calls".into()),
        ("tool_calls prune (age)", "DELETE FROM tool_calls WHERE at_ms < ?1".into()),
        ("tool_calls prune (cap)", "DELETE FROM tool_calls WHERE id IN (SELECT id FROM tool_calls ORDER BY at_ms, id LIMIT ?1)".into()),
        // telegram.rs
        ("tg_msg_get", "SELECT chat_id, message_id, agent_id, kind, ref_id, created_at FROM telegram_messages WHERE chat_id = ?1 AND message_id = ?2".into()),
        ("tg_msgs_for_ref", "SELECT chat_id, message_id, agent_id, kind, ref_id, created_at FROM telegram_messages WHERE kind = ?1 AND ref_id = ?2 ORDER BY created_at".into()),
        ("tg_msgs_prune", "DELETE FROM telegram_messages WHERE created_at < ?1".into()),
        ("tg_chat_list", format!("SELECT {CHAT_COLS} FROM telegram_chats ORDER BY linked_at, chat_id")),
        // workspaces.rs, usage.rs, auth.rs, secrets.rs
        ("workspace_list", format!("SELECT {WORKSPACE_COLS} FROM workspaces ORDER BY created_at, id")),
        ("workspace_agent_ids", "SELECT id FROM agents WHERE workspace_id = ?1 ORDER BY created_at".into()),
        ("usage_list", "SELECT runtime, windows, updated_at, plan FROM usage_limits ORDER BY runtime".into()),
        ("device_touch", "UPDATE devices SET last_seen_at = ?2 WHERE token_hash = ?1 RETURNING id, name, created_at, last_seen_at".into()),
        ("pairing_check", "SELECT EXISTS(SELECT 1 FROM pairing WHERE code_hash = ?1 AND expires_at > ?2)".into()),
        ("secret delete", "DELETE FROM secrets WHERE name = ?1".into()),
    ];
    q
}

/// The plan lines of `sql`, from `EXPLAIN QUERY PLAN` (parameters unbound: the plan does not depend on their values).
fn plan(conn: &Connection, sql: &str) -> Vec<String> {
    let mut stmt = conn
        .prepare(&format!("EXPLAIN QUERY PLAN {sql}"))
        .unwrap_or_else(|e| panic!("cannot explain `{sql}`: {e}"));
    let nulls: Vec<Option<i64>> = vec![None; stmt.parameter_count()];
    let rows = stmt
        .query_map(rusqlite::params_from_iter(nulls), |r| r.get::<_, String>(3))
        .unwrap();
    rows.collect::<rusqlite::Result<Vec<_>>>().unwrap()
}

/// The table a `SCAN` line reads: the table itself, or the table behind an alias written next to it in `sql`
/// (`FROM events e`, `JOIN events AS t`). Returns `None` for scans of subqueries and constant rows.
fn scanned_table(line: &str, sql: &str) -> Option<String> {
    let object = line.strip_prefix("SCAN ")?.split_whitespace().next()?.to_string();
    if BIG_TABLES.contains(&object.as_str()) {
        return Some(object);
    }
    let words: Vec<&str> = sql
        .split(|c: char| c.is_whitespace() || c == '(' || c == ')' || c == ',')
        .filter(|w| !w.is_empty())
        .collect();
    for pair in words.windows(2) {
        if pair[1] == object && BIG_TABLES.contains(&pair[0]) {
            return Some(pair[0].to_string());
        }
    }
    for triple in words.windows(3) {
        if triple[1].eq_ignore_ascii_case("AS") && triple[2] == object && BIG_TABLES.contains(&triple[0]) {
            return Some(triple[0].to_string());
        }
    }
    None
}

fn avg_ms(runs: u32, mut f: impl FnMut()) -> f64 {
    for _ in 0..3 {
        f();
    }
    let started = Instant::now();
    for _ in 0..runs {
        f();
    }
    started.elapsed().as_secs_f64() * 1000.0 / f64::from(runs)
}

#[test]
fn hot_queries_do_not_scan_big_tables_and_stay_fast() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("bandito.db");
    drop(Store::open(&path).unwrap());
    populate(&path);

    let conn = Connection::open(&path).unwrap();
    let counts: Vec<(String, i64)> = BIG_TABLES
        .iter()
        .map(|t| {
            let n: i64 = conn
                .query_row(&format!("SELECT COUNT(*) FROM {t}"), [], |r| r.get(0))
                .unwrap();
            (t.to_string(), n)
        })
        .collect();
    println!(
        "rows: {}",
        counts
            .iter()
            .map(|(t, n)| format!("{t}={n}"))
            .collect::<Vec<_>>()
            .join(", ")
    );
    assert_eq!(counts.iter().find(|(t, _)| t == "events").unwrap().1, EVENTS);

    let mut failures = Vec::new();
    println!("\n{:<40} | plan", "query");
    for (name, sql) in queries() {
        let lines = plan(&conn, &sql);
        println!("{:<40} | {}", name, lines.join(" ; "));
        for line in &lines {
            if let Some(table) = scanned_table(line, &sql) {
                let rows = counts.iter().find(|(t, _)| *t == table).map(|(_, n)| *n).unwrap_or(0);
                let bounded = BOUNDED_SCANS.iter().any(|(n, _)| *n == name);
                if rows > BIG_ROWS && !bounded {
                    failures.push(format!("{name}: `{line}` ({rows} rows)"));
                }
            }
        }
    }

    let timing_failures = timings(&path);
    assert!(failures.is_empty(), "big-table scans:\n{}", failures.join("\n"));
    assert!(
        timing_failures.is_empty(),
        "slow reads:\n{}",
        timing_failures.join("\n")
    );
}

/// Times the hottest reads through the public store API on the populated database. Prints every timing and returns
/// the reads that are over the debug limit.
fn timings(path: &Path) -> Vec<String> {
    let store = Store::open(path).unwrap();
    let last = store.last_seq().unwrap();
    let busiest = agent_id(0);
    let mut results: Vec<(&str, f64)> = Vec::new();

    results.push((
        "events.since agent, after=last-10000, limit 100",
        avg_ms(TIMING_RUNS, || {
            store.events_since(last - 10_000, 100, Some(&busiest)).unwrap();
        }),
    ));
    results.push((
        "events.since agent, after=0 (cold client), limit 100",
        avg_ms(TIMING_RUNS, || {
            store.events_since(0, 100, Some(&agent_id(AGENTS - 1))).unwrap();
        }),
    ));
    results.push((
        "agents.list (view, 50 agents)",
        avg_ms(TIMING_RUNS, || {
            store.agent_list_view().unwrap();
        }),
    ));
    results.push((
        "approvals.list pending (all)",
        avg_ms(TIMING_RUNS, || {
            store.approval_list_pending(None).unwrap();
        }),
    ));
    results.push((
        "history paged, busiest agent, 50 per page",
        avg_ms(TIMING_RUNS, || {
            store.events_page(&busiest, Some(last / 2), 50).unwrap();
        }),
    ));
    results.push((
        "schedules.due",
        avg_ms(TIMING_RUNS, || {
            store.schedule_due(NOW_MS).unwrap();
        }),
    ));
    results.push((
        "tool calls list, newest 50",
        avg_ms(TIMING_RUNS, || {
            store
                .tool_calls_list(
                    &bandito::store::CallFilter {
                        integration: None,
                        agent_id: None,
                        before: None,
                        limit: 50,
                    },
                    NOW_MS,
                )
                .unwrap();
        }),
    ));

    println!(
        "\n{:<50} | avg ms ({TIMING_RUNS} runs, debug={})",
        "read",
        cfg!(debug_assertions)
    );
    for (name, ms) in &results {
        let verdict = if *ms < TARGET_MS { "under 5 ms" } else { "over 5 ms" };
        println!("{name:<50} | {ms:>8.3}  {verdict}");
    }
    results
        .iter()
        .filter(|(_, ms)| *ms >= DEBUG_LIMIT_MS)
        .map(|(name, ms)| format!("{name}: {ms:.1} ms on average, limit {DEBUG_LIMIT_MS} ms"))
        .collect()
}
