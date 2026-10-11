//! The call journal's rules: which tool calls are recorded, and how a call's start, its policy decision and its result
//! are paired into one row. Rows and their retention are in [`crate::store::tool_calls`]; see
//! docs/ARCHITECTURE.md#call-journal.

use crate::integrations::RESERVED_NAME;
use crate::redact::Redactor;
use crate::store::{ERROR_MAX_CHARS, Store};
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
    /// The names of the MCP servers of the running session: the integrations the agent may use.
    servers: Vec<String>,
    /// The secret values the running session's integrations got, replaced in error texts as the probe does.
    secrets: Redactor,
    open: HashMap<String, Open>,
    decisions: HashMap<String, &'static str>,
}

struct Open {
    row: i64,
    started_ms: i64,
}

impl Journal {
    /// The MCP servers and secrets of a session that starts now. Codex names an MCP call `<server>.<tool>`, and the
    /// server is an integration only when it is one of these.
    pub fn set_session(&mut self, names: Vec<String>, secrets: Redactor) {
        self.servers = names;
        self.secrets = secrets;
    }

    /// `(integration, tool)` of a tool name: `mcp__<integration>__<tool>` (Claude Code), or `<server>.<tool>` (Codex)
    /// when the server is one of the session's. The name the runtime reports is not changed; this is for the journal.
    fn recognize<'a>(&self, tool: &'a str) -> Option<(&'a str, &'a str)> {
        if let Some(found) = split_mcp(tool) {
            return Some(found);
        }
        let (server, name) = tool.split_once('.')?;
        let known = server != RESERVED_NAME && self.servers.iter().any(|s| s == server);
        (known && !name.is_empty()).then_some((server, name))
    }

    /// A tool call started. It is recorded when its name is an integration's (see [`Journal::recognize`]); its
    /// decision is taken from the policy's verdict when that came first.
    pub fn started(&mut self, store: &Store, agent: &str, call_id: &str, tool: &str, now: i64) {
        let Some((integration, name)) = self.recognize(tool) else {
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
        if self.recognize(tool).is_none() {
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

    /// The result of a call. Its duration is measured from its start. Only a failure keeps its text, shaped by
    /// [`error_text`].
    pub fn finished(&mut self, store: &Store, call_id: &str, ok: bool, output: &str, now: i64) {
        let Some(open) = self.open.remove(call_id) else {
            return;
        };
        let error = (!ok).then(|| error_text(output, &self.secrets));
        if let Err(e) = store.tool_call_finish(open.row, (now - open.started_ms).max(0), ok, error.as_deref()) {
            tracing::warn!("record tool result: {e:#}");
        }
    }

    /// The turn ended: calls still open keep their rows without a result.
    pub fn turn_ended(&mut self) {
        self.open.clear();
        self.decisions.clear();
    }
}

/// The error text a journal row keeps: the first line of the result, with the session's secret values replaced
/// (`••••NAME`, as the probe does), e-mail addresses as `***@***` and runs of seven or more digits as `***`, and at
/// most [`ERROR_MAX_CHARS`] characters.
pub fn error_text(output: &str, secrets: &Redactor) -> String {
    let line = output.lines().next().unwrap_or("").trim();
    let line = secrets.redact(line);
    let line = hide_digit_runs(&hide_emails(&line));
    line.chars().take(ERROR_MAX_CHARS).collect()
}

fn is_token_char(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '.' | '_' | '%' | '+' | '-' | '@')
}

/// An e-mail address: `local@domain`, where the domain's labels are non-empty and separated by dots.
fn is_email(word: &str) -> bool {
    let Some((local, domain)) = word.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && domain.split('.').all(|label| !label.is_empty() && !label.contains('@'))
}

fn push_token(out: &mut String, token: &str) {
    // A full stop that ends a sentence right after an address stays after the mask.
    let word = token.trim_end_matches('.');
    if is_email(word) {
        out.push_str("***@***");
        out.push_str(&token[word.len()..]);
    } else {
        out.push_str(token);
    }
}

fn hide_emails(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut token = String::new();
    for c in text.chars() {
        if is_token_char(c) {
            token.push(c);
        } else {
            push_token(&mut out, &token);
            token.clear();
            out.push(c);
        }
    }
    push_token(&mut out, &token);
    out
}

fn push_digits(out: &mut String, run: &str) {
    if run.len() >= 7 {
        out.push_str("***");
    } else {
        out.push_str(run);
    }
}

fn hide_digit_runs(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut run = String::new();
    for c in text.chars() {
        if c.is_ascii_digit() {
            run.push(c);
        } else {
            push_digits(&mut out, &run);
            run.clear();
            out.push(c);
        }
    }
    push_digits(&mut out, &run);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_000;

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
            .tool_calls_list(
                &crate::store::CallFilter {
                    limit: 10,
                    ..Default::default()
                },
                NOW,
            )
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
            .tool_calls_list(
                &crate::store::CallFilter {
                    limit: 1,
                    ..Default::default()
                },
                NOW,
            )
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
            .tool_calls_list(
                &crate::store::CallFilter {
                    limit: 1,
                    ..Default::default()
                },
                NOW,
            )
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
                .tool_calls_list(
                    &crate::store::CallFilter {
                        limit: 10,
                        ..Default::default()
                    },
                    NOW
                )
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
            .tool_calls_list(
                &crate::store::CallFilter {
                    limit: 1,
                    ..Default::default()
                },
                NOW,
            )
            .unwrap()[0];
        assert_eq!((row.duration_ms, row.ok), (None, None));
    }

    #[test]
    fn a_codex_call_is_recorded_when_its_server_is_one_of_the_sessions() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        let all = |store: &Store| {
            store
                .tool_calls_list(
                    &crate::store::CallFilter {
                        limit: 10,
                        ..Default::default()
                    },
                    NOW,
                )
                .unwrap()
        };
        // No servers yet: nothing is an integration.
        journal.started(&store, "a1", "c0", "linear.create_issue", 1_000);
        assert!(all(&store).is_empty());

        journal.set_session(vec!["linear".into(), "bandito".into()], Redactor::default());
        journal.started(&store, "a1", "c1", "linear.create_issue", 1_000);
        journal.started(&store, "a1", "c2", "github.get_repo", 1_000); // not a server of this session
        journal.started(&store, "a1", "c3", "bandito.crew_send", 1_000); // Bandito's own crew server
        journal.started(&store, "a1", "c4", "apply_patch", 1_000); // a Codex built-in tool
        let rows = all(&store);
        assert_eq!(rows.len(), 1);
        assert_eq!(
            (rows[0].integration.as_str(), rows[0].tool.as_str()),
            ("linear", "create_issue")
        );
    }

    #[test]
    fn an_error_text_hides_e_mail_addresses_and_long_numbers() {
        let none = Redactor::default();
        assert_eq!(
            error_text("no such user ivan.petrov@corp-mail.example", &none),
            "no such user ***@***"
        );
        assert_eq!(
            error_text("call 81234567890 and 12345 and <a@b.co>. ok", &none),
            "call *** and 12345 and <***@***>. ok"
        );
        // A full stop right after an address is kept; a number of exactly 7 digits is hidden.
        assert_eq!(error_text("mail a@b.ru.", &none), "mail ***@***.");
        assert_eq!(error_text("code 1234567", &none), "code ***");
        assert_eq!(
            error_text("not an email: @x.ru and a@b", &none),
            "not an email: @x.ru and a@b"
        );
    }

    #[test]
    fn an_error_text_is_its_first_line_and_at_most_120_characters() {
        let none = Redactor::default();
        assert_eq!(error_text("first\nsecond", &none), "first");
        assert_eq!(error_text(&"x".repeat(500), &none).chars().count(), 120);
        assert_eq!(error_text("  \n ", &none), "");
    }

    #[test]
    fn an_error_text_replaces_the_session_secrets_like_the_probe() {
        let secrets = Redactor::exact([("TOKEN".to_string(), "k7".to_string())]);
        assert_eq!(error_text("bad token k7 here", &secrets), "bad token ••••TOKEN here");
    }

    #[test]
    fn a_failure_is_stored_redacted_and_masked() {
        let store = Store::open_in_memory().unwrap();
        let mut journal = Journal::default();
        journal.set_session(
            vec!["linear".into()],
            Redactor::exact([("TOKEN".to_string(), "k7".to_string())]),
        );
        journal.started(&store, "a1", "c1", "mcp__linear__x", 1_000);
        journal.finished(
            &store,
            "c1",
            false,
            "denied for k7, ivan@corp.example, phone 89621234567\nstack",
            1_010,
        );
        let row = &store
            .tool_calls_list(
                &crate::store::CallFilter {
                    limit: 1,
                    ..Default::default()
                },
                NOW,
            )
            .unwrap()[0];
        assert_eq!(row.error.as_deref(), Some("denied for ••••TOKEN, ***@***, phone ***"));
    }
}
