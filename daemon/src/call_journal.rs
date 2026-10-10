//! The call journal's rules: which tool calls are recorded, and how a call's start, its policy decision and its result
//! are paired into one row. Rows and their retention are in [`crate::store::tool_calls`]; see
//! docs/ARCHITECTURE.md#call-journal.

use crate::integrations::RESERVED_NAME;
use crate::store::Store;
use std::collections::HashMap;

/// `mcp__<integration>__<tool>` → `(integration, tool)`. `None` for any other name, and for the crew server's own
/// tools (`mcp__bandito__…`): that server is Bandito's, not an integration.
pub fn split_mcp(name: &str) -> Option<(&str, &str)> {
    let (integration, tool) = name.strip_prefix("mcp__")?.split_once("__")?;
    (!integration.is_empty() && !tool.is_empty() && integration != RESERVED_NAME).then_some((integration, tool))
}

/// The calls of one agent that have started and have no result yet, and the policy decisions that came before
/// their call. Both are dropped when the turn ends: a call that never got its result keeps its row with no result.
#[derive(Default)]
pub struct Journal {
    open: HashMap<String, Open>,
    decisions: HashMap<String, &'static str>,
}

struct Open {
    row: i64,
    started_ms: i64,
}

impl Journal {
    /// A tool call started. It is recorded when its name is `mcp__<integration>__<tool>`; its decision is taken from
    /// the policy's verdict when that came first.
    pub fn started(&mut self, store: &Store, agent: &str, call_id: &str, tool: &str, now: i64) {
        let Some((integration, name)) = split_mcp(tool) else {
            return;
        };
        let decision = self.decisions.remove(call_id);
        match store.tool_call_start(agent, integration, name, decision, now) {
            Ok(row) => {
                self.open.insert(call_id.to_string(), Open { row, started_ms: now });
            }
            Err(e) => tracing::warn!(agent, "record tool call: {e:#}"),
        }
    }

    /// The policy's verdict on the approval of a call: `allowed`, `asked` or `denied`. A call that is not recorded
    /// (or whose verdict comes before it) is kept until the turn ends.
    pub fn decided(&mut self, store: &Store, call_id: &str, tool: &str, decision: &'static str) {
        if split_mcp(tool).is_none() {
            return;
        }
        match self.open.get(call_id) {
            Some(open) => {
                if let Err(e) = store.tool_call_set_decision(open.row, decision) {
                    tracing::warn!("record tool decision: {e:#}");
                }
            }
            None => {
                self.decisions.insert(call_id.to_string(), decision);
            }
        }
    }

    /// The result of a call. Its duration is measured from its start. Only a failure keeps its text.
    pub fn finished(&mut self, store: &Store, call_id: &str, ok: bool, output: &str, now: i64) {
        let Some(open) = self.open.remove(call_id) else {
            return;
        };
        let error = (!ok).then_some(output);
        if let Err(e) = store.tool_call_finish(open.row, (now - open.started_ms).max(0), ok, error) {
            tracing::warn!("record tool result: {e:#}");
        }
    }

    /// The turn ended: calls still open keep their rows without a result.
    pub fn turn_ended(&mut self) {
        self.open.clear();
        self.decisions.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_mcp_names_of_integrations_are_split() {
        assert_eq!(split_mcp("mcp__linear__list_issues"), Some(("linear", "list_issues")));
        assert_eq!(split_mcp("mcp__my-svc__get_x"), Some(("my-svc", "get_x")));
        assert_eq!(split_mcp("Bash"), None);
        assert_eq!(split_mcp("Read"), None);
        assert_eq!(split_mcp("mcp__linear"), None);
        assert_eq!(split_mcp("mcp____tool"), None);
        assert_eq!(split_mcp("mcp__linear__"), None);
        assert_eq!(split_mcp("server.tool"), None);
        // The crew server's tools are not an integration's.
        assert_eq!(split_mcp("mcp__bandito__send_message"), None);
    }

    #[test]
    fn a_start_a_decision_and_a_result_pair_into_one_row() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        journal.started(&store, "a1", "c1", "mcp__linear__list_issues", 1_000);
        journal.decided(&store, "c1", "mcp__linear__list_issues", "allowed");
        journal.finished(&store, "c1", true, "the output is not kept", 1_250);

        let rows = store
            .tool_calls_list(&crate::store::CallFilter {
                limit: 10,
                ..Default::default()
            })
            .unwrap();
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!((row.integration.as_str(), row.tool.as_str()), ("linear", "list_issues"));
        assert_eq!(row.decision.as_deref(), Some("allowed"));
        assert_eq!(
            (row.duration_ms, row.ok, row.error.clone()),
            (Some(250), Some(true), None)
        );
    }

    #[test]
    fn a_verdict_that_comes_before_its_call_is_taken_at_the_start() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        journal.decided(&store, "c1", "mcp__linear__x", "asked");
        journal.started(&store, "a1", "c1", "mcp__linear__x", 1_000);
        let row = &store
            .tool_calls_list(&crate::store::CallFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!(row.decision.as_deref(), Some("asked"));
    }

    #[test]
    fn a_failure_keeps_its_text_and_a_success_does_not() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        journal.started(&store, "a1", "c1", "mcp__linear__x", 1_000);
        journal.finished(&store, "c1", false, "not found", 1_010);
        let row = &store
            .tool_calls_list(&crate::store::CallFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!((row.ok, row.error.clone()), (Some(false), Some("not found".into())));
    }

    #[test]
    fn other_tools_and_results_without_a_start_leave_no_row() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        journal.started(&store, "a1", "c1", "Bash", 1_000);
        journal.decided(&store, "c1", "Bash", "allowed");
        journal.finished(&store, "c1", true, "", 1_010);
        journal.finished(&store, "unknown", true, "", 1_010);
        journal.started(&store, "a1", "c2", "mcp__bandito__send", 1_000);
        assert!(
            store
                .tool_calls_list(&crate::store::CallFilter {
                    limit: 10,
                    ..Default::default()
                })
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn a_call_without_a_result_keeps_its_row_when_the_turn_ends() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        journal.started(&store, "a1", "c1", "mcp__linear__x", 1_000);
        journal.turn_ended();
        // Its result, if it came now, has nothing to pair with.
        journal.finished(&store, "c1", true, "", 2_000);
        let row = &store
            .tool_calls_list(&crate::store::CallFilter {
                limit: 1,
                ..Default::default()
            })
            .unwrap()[0];
        assert_eq!((row.duration_ms, row.ok), (None, None));
    }
}
