//! The call journal: one row per `mcp__<integration>__<tool>` call an agent made (see docs/ARCHITECTURE.md#call-journal).
//! Rules that decide what is recorded are in [`crate::call_journal`]; this file stores and reads rows. Arguments and
//! results are never stored.

use super::Store;
use anyhow::Result;
use rusqlite::{Connection, Row, params};
use serde::Serialize;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

/// Rows older than this are removed when a call is recorded.
pub const RETENTION_MS: i64 = 30 * DAY_MS;

/// Most rows kept; when more, the oldest (by `at_ms`) are removed when a call is recorded.
pub const MAX_ROWS: i64 = 20_000;

/// Characters of an error text that are kept.
pub const ERROR_MAX_CHARS: usize = 300;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ToolCall {
    pub id: i64,
    /// Unix milliseconds of the start of the call.
    pub at_ms: i64,
    pub agent_id: String,
    pub integration: String,
    /// The tool's name in the integration (without the `mcp__<integration>__` prefix).
    pub tool: String,
    /// `null` until the result comes (or when it never does).
    pub duration_ms: Option<i64>,
    /// `null` until the result comes.
    pub ok: Option<bool>,
    /// The start of the error text of a failed call, at most 300 characters.
    pub error: Option<String>,
    /// `allowed`, `asked` or `denied` when the policy judged the call; `null` when it did not.
    pub decision: Option<String>,
}

/// Filters of `integrations.calls`. `before` is the `id` of the last row of the previous page.
#[derive(Debug, Clone, Default)]
pub struct CallFilter {
    pub integration: Option<String>,
    pub agent_id: Option<String>,
    pub before: Option<i64>,
    pub limit: i64,
}

/// One integration in `integrations.call_stats`. `errors` are the calls that failed (`ok` false), not those without a
/// result.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CallStats {
    pub integration: String,
    pub calls_24h: i64,
    pub errors_24h: i64,
    pub calls_7d: i64,
    /// Unix milliseconds of the newest call.
    pub last_at: i64,
}

fn clip(text: &str, max_chars: usize) -> String {
    text.chars().take(max_chars).collect()
}

/// Removes rows older than the retention, then the oldest rows beyond the cap.
fn prune(conn: &Connection, now: i64) -> Result<()> {
    conn.execute("DELETE FROM tool_calls WHERE at_ms < ?1", params![now - RETENTION_MS])?;
    let rows: i64 = conn.query_row("SELECT COUNT(*) FROM tool_calls", [], |r| r.get(0))?;
    if rows > MAX_ROWS {
        conn.execute(
            "DELETE FROM tool_calls WHERE id IN (
                 SELECT id FROM tool_calls ORDER BY at_ms, id LIMIT ?1)",
            params![rows - MAX_ROWS],
        )?;
    }
    Ok(())
}

fn row_to_call(row: &Row) -> rusqlite::Result<ToolCall> {
    Ok(ToolCall {
        id: row.get(0)?,
        at_ms: row.get(1)?,
        agent_id: row.get(2)?,
        integration: row.get(3)?,
        tool: row.get(4)?,
        duration_ms: row.get(5)?,
        ok: row.get::<_, Option<i64>>(6)?.map(|v| v != 0),
        error: row.get(7)?,
        decision: row.get(8)?,
    })
}

impl Store {
    /// Record the start of a call and return its id. Prunes the journal (see [`prune`]) after the insert.
    pub fn tool_call_start(
        &self,
        agent_id: &str,
        integration: &str,
        tool: &str,
        decision: Option<&str>,
        at_ms: i64,
    ) -> Result<i64> {
        let conn = self.conn();
        conn.execute(
            "INSERT INTO tool_calls (at_ms, agent_id, integration, tool, decision) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![at_ms, agent_id, integration, tool, decision],
        )?;
        let id = conn.last_insert_rowid();
        prune(&conn, at_ms)?;
        Ok(id)
    }

    /// Record the result of a call: its duration, and for a failure its error text. A success keeps no text, and
    /// a blank error is not kept.
    pub fn tool_call_finish(&self, id: i64, duration_ms: i64, ok: bool, error: Option<&str>) -> Result<()> {
        let error = error
            .filter(|_| !ok)
            .map(str::trim)
            .filter(|e| !e.is_empty())
            .map(|e| clip(e, ERROR_MAX_CHARS));
        self.conn().execute(
            "UPDATE tool_calls SET duration_ms = ?2, ok = ?3, error = ?4 WHERE id = ?1",
            params![id, duration_ms, ok as i64, error],
        )?;
        Ok(())
    }

    /// Set the policy's decision of a call whose approval came after its start.
    pub fn tool_call_set_decision(&self, id: i64, decision: &str) -> Result<()> {
        self.conn().execute(
            "UPDATE tool_calls SET decision = ?2 WHERE id = ?1",
            params![id, decision],
        )?;
        Ok(())
    }

    /// Calls matching the filter, newest first.
    pub fn tool_calls_list(&self, filter: &CallFilter) -> Result<Vec<ToolCall>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT id, at_ms, agent_id, integration, tool, duration_ms, ok, error, decision FROM tool_calls
             WHERE (?1 IS NULL OR integration = ?1) AND (?2 IS NULL OR agent_id = ?2) AND (?3 IS NULL OR id < ?3)
             ORDER BY id DESC LIMIT ?4",
        )?;
        let rows = stmt.query_map(
            params![filter.integration, filter.agent_id, filter.before, filter.limit],
            row_to_call,
        )?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Per integration that has rows: calls and errors of the last 24 hours, calls of the last 7 days, and the time
    /// of the newest call. Newest call first.
    pub fn tool_call_stats(&self, now: i64) -> Result<Vec<CallStats>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT integration,
                    SUM(CASE WHEN at_ms >= ?1 THEN 1 ELSE 0 END),
                    SUM(CASE WHEN at_ms >= ?1 AND ok = 0 THEN 1 ELSE 0 END),
                    SUM(CASE WHEN at_ms >= ?2 THEN 1 ELSE 0 END),
                    MAX(at_ms)
             FROM tool_calls GROUP BY integration ORDER BY MAX(at_ms) DESC, integration",
        )?;
        let rows = stmt.query_map(params![now - DAY_MS, now - 7 * DAY_MS], |row| {
            Ok(CallStats {
                integration: row.get(0)?,
                calls_24h: row.get(1)?,
                errors_24h: row.get(2)?,
                calls_7d: row.get(3)?,
                last_at: row.get(4)?,
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000_000;

    fn start(store: &Store, agent: &str, integration: &str, at: i64) -> i64 {
        store
            .tool_call_start(agent, integration, "list_issues", None, at)
            .unwrap()
    }

    fn count(store: &Store) -> i64 {
        store
            .conn()
            .query_row("SELECT COUNT(*) FROM tool_calls", [], |r| r.get(0))
            .unwrap()
    }

    #[test]
    fn a_start_and_its_result_make_one_row() {
        let store = Store::open_in_memory().unwrap();
        let id = store
            .tool_call_start("a1", "linear", "list_issues", Some("allowed"), NOW)
            .unwrap();
        let rows = store
            .tool_calls_list(&CallFilter {
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, id);
        assert_eq!(rows[0].integration, "linear");
        assert_eq!(rows[0].tool, "list_issues");
        assert_eq!(rows[0].decision.as_deref(), Some("allowed"));
        assert_eq!(
            (rows[0].duration_ms, rows[0].ok, rows[0].error.clone()),
            (None, None, None)
        );

        store
            .tool_call_finish(id, 42, true, Some("text of a success is not kept"))
            .unwrap();
        let row = &store
            .tool_calls_list(&CallFilter {
                limit: 10,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!(
            (row.duration_ms, row.ok, row.error.clone()),
            (Some(42), Some(true), None)
        );
    }

    #[test]
    fn a_failure_keeps_at_most_300_characters_of_its_error() {
        let store = Store::open_in_memory().unwrap();
        let id = start(&store, "a1", "linear", NOW);
        let long = "é".repeat(500);
        store.tool_call_finish(id, 7, false, Some(&long)).unwrap();
        let row = &store
            .tool_calls_list(&CallFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!(row.ok, Some(false));
        assert_eq!(row.error.as_deref().map(|e| e.chars().count()), Some(ERROR_MAX_CHARS));
    }

    #[test]
    fn a_blank_error_is_not_kept() {
        let store = Store::open_in_memory().unwrap();
        let id = start(&store, "a1", "linear", NOW);
        store.tool_call_finish(id, 7, false, Some("  \n ")).unwrap();
        let row = &store
            .tool_calls_list(&CallFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!(row.error, None);
    }

    #[test]
    fn a_late_decision_is_set_on_its_row() {
        let store = Store::open_in_memory().unwrap();
        let id = start(&store, "a1", "linear", NOW);
        store.tool_call_set_decision(id, "asked").unwrap();
        let row = &store
            .tool_calls_list(&CallFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!(row.decision.as_deref(), Some("asked"));
    }

    #[test]
    fn rows_older_than_30_days_are_removed_when_a_call_is_recorded() {
        let store = Store::open_in_memory().unwrap();
        start(&store, "a1", "old", NOW - RETENTION_MS - 1);
        start(&store, "a1", "kept", NOW - RETENTION_MS + DAY_MS);
        assert_eq!(count(&store), 2);
        start(&store, "a1", "now", NOW);
        let names: Vec<String> = store
            .tool_calls_list(&CallFilter {
                limit: 10,
                ..Default::default()
            })
            .unwrap()
            .into_iter()
            .map(|r| r.integration)
            .collect();
        assert_eq!(names, vec!["now", "kept"]);
    }

    #[test]
    fn beyond_20000_rows_the_oldest_go_first() {
        let store = Store::open_in_memory().unwrap();
        // Seeded in one statement: the rows are an hour old, the newest of them the last one written.
        store
            .conn()
            .execute(
                "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1)
                 INSERT INTO tool_calls (at_ms, agent_id, integration, tool)
                 SELECT ?2 + i, 'a1', 'bulk', 't' FROM n",
                params![MAX_ROWS + 5, NOW - 3_600_000],
            )
            .unwrap();
        assert_eq!(count(&store), MAX_ROWS + 5);
        start(&store, "a1", "new", NOW);
        assert_eq!(count(&store), MAX_ROWS);
        let all = store
            .tool_calls_list(&CallFilter {
                limit: MAX_ROWS,
                ..Default::default()
            })
            .unwrap();
        // Six rows were over the cap: the six oldest seeded rows (at +1 .. +6) are gone, the oldest left is at +7.
        assert_eq!(all.last().unwrap().at_ms, NOW - 3_600_000 + 7);
        assert_eq!(all.first().unwrap().integration, "new");
    }

    #[test]
    fn filters_by_integration_agent_and_cursor_newest_first() {
        let store = Store::open_in_memory().unwrap();
        let a = start(&store, "a1", "linear", NOW - 3);
        let b = start(&store, "a2", "linear", NOW - 2);
        let c = start(&store, "a1", "github", NOW - 1);

        let ids =
            |f: CallFilter| -> Vec<i64> { store.tool_calls_list(&f).unwrap().into_iter().map(|r| r.id).collect() };
        assert_eq!(
            ids(CallFilter {
                limit: 10,
                ..Default::default()
            }),
            vec![c, b, a]
        );
        assert_eq!(
            ids(CallFilter {
                integration: Some("linear".into()),
                limit: 10,
                ..Default::default()
            }),
            vec![b, a]
        );
        assert_eq!(
            ids(CallFilter {
                agent_id: Some("a1".into()),
                limit: 10,
                ..Default::default()
            }),
            vec![c, a]
        );
        assert_eq!(
            ids(CallFilter {
                limit: 10,
                before: Some(c),
                ..Default::default()
            }),
            vec![b, a]
        );
        assert_eq!(
            ids(CallFilter {
                limit: 1,
                ..Default::default()
            }),
            vec![c]
        );
    }

    #[test]
    fn stats_count_24h_7d_errors_and_the_last_call_per_integration() {
        let store = Store::open_in_memory().unwrap();
        let ok_now = start(&store, "a1", "linear", NOW - 1000);
        store.tool_call_finish(ok_now, 5, true, None).unwrap();
        let failed = start(&store, "a1", "linear", NOW - 2000);
        store.tool_call_finish(failed, 5, false, Some("boom")).unwrap();
        start(&store, "a1", "linear", NOW - 3 * DAY_MS); // 7 days, not 24 hours
        start(&store, "a1", "linear", NOW - 10 * DAY_MS); // older than 7 days: in neither count
        start(&store, "a1", "github", NOW - 2 * 3_600_000); // no result: not an error

        let stats = store.tool_call_stats(NOW).unwrap();
        assert_eq!(
            stats,
            vec![
                CallStats {
                    integration: "linear".into(),
                    calls_24h: 2,
                    errors_24h: 1,
                    calls_7d: 3,
                    last_at: NOW - 1000,
                },
                CallStats {
                    integration: "github".into(),
                    calls_24h: 1,
                    errors_24h: 0,
                    calls_7d: 1,
                    last_at: NOW - 2 * 3_600_000,
                },
            ]
        );
    }

    #[test]
    fn stats_of_an_empty_journal_are_empty() {
        let store = Store::open_in_memory().unwrap();
        assert!(store.tool_call_stats(NOW).unwrap().is_empty());
    }
}
