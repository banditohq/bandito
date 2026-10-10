//! What the owner allowed the tools of an integration to do (docs/ARCHITECTURE.md#tool-permissions): the part of the
//! approvals policy that decides calls of `mcp__<service>__<tool>`.
//!
//! Order: the owner's word on the tool (`tool_overrides`), else the service's mode (`tool_mode`). A tool that reads
//! runs in `read_only` and `confirm_writes`; one that changes something is refused in `read_only` and asked about in
//! `confirm_writes`. Whether a tool reads comes from [`ToolCatalog`] (the annotations of `tools/list`); a tool that is
//! not known there counts as a write, so a doubt is a question or a refusal and never a silent run.
//!
//! Approval modes: a refusal (`deny`, or a write under `read_only`) stands in every mode, `never` included. A question
//! (`ask`, a write under `confirm_writes`) is dropped by `never`, which never asks. In `always` nothing is let through
//! without a question: what would run falls back to the normal policy, which asks.

use crate::policy::{Verdict, glob_match};
use crate::store::{ApprovalMode, Integration, Rule, RuleAction, ToolMode, ToolOverride};

/// The start of every tool name a CLI gives to a tool of an MCP server.
pub const MCP_PREFIX: &str = "mcp__";

/// Reason of a question that comes from the service's mode.
pub const REASON_CONFIRM_MODE: &str = "service: confirm changes";
/// Reason of a question that comes from the owner's word on this tool.
pub const REASON_CONFIRM_TOOL: &str = "service: confirm tool";
/// Reason of a refusal that comes from the `read_only` mode.
pub const REASON_READ_ONLY: &str = "service: read only";
/// Reason of a refusal that comes from the owner's word on this tool.
pub const REASON_TOOL_DENIED: &str = "service: tool forbidden";

/// What is known about the tools of the services: whether a tool only reads. The answer comes from the annotations the
/// server sent in `tools/list` (`readOnlyHint`), kept by the daemon. `None` when the tool is not known.
pub trait ToolCatalog {
    fn read_only(&self, integration_id: &str, tool: &str) -> Option<bool>;
}

/// No tool is known: every tool counts as a write. Used until a source of annotations is connected, and by sessions
/// that have none.
pub struct NoToolCache;

impl ToolCatalog for NoToolCache {
    fn read_only(&self, _integration_id: &str, _tool: &str) -> Option<bool> {
        None
    }
}

/// The service and the tool a CLI's tool name refers to: `mcp__linear__create_issue` is the integration `linear` and
/// the tool `create_issue`. The longest matching integration name wins, so `a__b` is not taken for `a`.
pub fn split<'a>(name: &str, rows: &'a [Integration]) -> Option<(&'a Integration, String)> {
    let rest = name.strip_prefix(MCP_PREFIX)?;
    rows.iter()
        .filter_map(|row| {
            let tool = rest.strip_prefix(row.name.as_str())?.strip_prefix("__")?;
            (!tool.is_empty()).then_some((row, tool.to_string()))
        })
        .max_by_key(|(row, _)| row.name.len())
}

/// The answer of this layer: what happens to the call, and the sentence the agent reads when it is refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Judged {
    pub verdict: Verdict,
    /// Said to the agent with the refusal, so it does not retry and tells its owner.
    pub agent_message: Option<String>,
}

enum Base {
    Allow,
    Ask(&'static str),
    Deny(&'static str, String),
}

fn base(row: &Integration, tool: &str, catalog: &dyn ToolCatalog) -> Option<Base> {
    if let Some(word) = row.tool_overrides.get(tool) {
        return Some(match word {
            ToolOverride::Allow => Base::Allow,
            ToolOverride::Ask => Base::Ask(REASON_CONFIRM_TOOL),
            ToolOverride::Deny => Base::Deny(
                REASON_TOOL_DENIED,
                format!(
                    "The owner forbade the tool {tool} of {service}, so it was not run. Do not retry it; tell the owner if the task needs it.",
                    service = row.name
                ),
            ),
        });
    }
    let reads = catalog.read_only(&row.id, tool) == Some(true);
    match row.tool_mode {
        ToolMode::All => None,
        _ if reads => Some(Base::Allow),
        ToolMode::ReadOnly => Some(Base::Deny(
            REASON_READ_ONLY,
            format!(
                "The owner allowed {service} to read only, and {tool} can change things there, so it was not run. Do not retry it; tell the owner if the task needs it, and they can change this for {service} in the Marketplace of Bandito.",
                service = row.name
            ),
        )),
        ToolMode::ConfirmWrites => Some(Base::Ask(REASON_CONFIRM_MODE)),
    }
}

/// Decide a call of `tool` of the service `row`. `None`: this layer has no opinion (the mode is `all` and the tool
/// has no override, or the approval mode is `always` and the call would run), and the normal policy decides.
/// `subject` is what the owner's rules are matched against (the call's title).
pub fn judge(
    row: &Integration,
    tool: &str,
    catalog: &dyn ToolCatalog,
    mode: ApprovalMode,
    rules: &[Rule],
    subject: &str,
) -> Option<Judged> {
    let (verdict, message) = match base(row, tool, catalog)? {
        Base::Deny(reason, message) => (Verdict::Deny(reason.to_string()), Some(message)),
        Base::Ask(_) if mode == ApprovalMode::Never => (Verdict::Allow, None),
        Base::Ask(reason) => (Verdict::Ask(reason.to_string()), None),
        Base::Allow if mode == ApprovalMode::Always => return None,
        Base::Allow => (Verdict::Allow, None),
    };
    // The owner's own rules still count: a deny rule refuses, and a rule that allows answers a question.
    let rule = rules.iter().find(|rule| glob_match(&rule.pattern, subject, false));
    Some(match (rule, &verdict) {
        (Some(rule), v) if rule.action == RuleAction::Deny && !matches!(v, Verdict::Deny(_)) => Judged {
            verdict: Verdict::Deny(format!("rule: {}", rule.pattern)),
            agent_message: Some(format!(
                "A rule of the owner forbids this call of {service}, so it was not run. Do not retry it.",
                service = row.name
            )),
        },
        (Some(rule), Verdict::Ask(_)) if rule.action == RuleAction::Allow => Judged {
            verdict: Verdict::Allow,
            agent_message: None,
        },
        _ => Judged {
            verdict,
            agent_message: message,
        },
    })
}

/// The longest value of an argument the card shows whole, in bytes.
const VALUE_SHOWN_BYTES: usize = 400;

/// The arguments of a call as the card shows them: indented JSON, cut to `limit` characters.
pub fn arguments_text(input: &serde_json::Value, limit: usize) -> Option<String> {
    if input.is_null() || input.as_object().is_some_and(serde_json::Map::is_empty) {
        return None;
    }
    // Each long value is cut on its own first, so one big field does not push the others off the card.
    let text = serde_json::to_string_pretty(&crate::runtime::clip_input(input, VALUE_SHOWN_BYTES)).ok()?;
    if text.chars().count() <= limit {
        return Some(text);
    }
    let cut: String = text.chars().take(limit).collect();
    Some(format!("{cut}\n…"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{IntegrationAuth, IntegrationKind};
    use std::collections::{BTreeMap, HashMap};

    /// A source of annotations for the tests: `(integration id, tool)` to whether it reads.
    struct Known(HashMap<(String, String), bool>);

    impl Known {
        fn of(list: &[(&str, bool)]) -> Self {
            Self(
                list.iter()
                    .map(|(t, r)| (("i1".to_string(), t.to_string()), *r))
                    .collect(),
            )
        }
    }

    impl ToolCatalog for Known {
        fn read_only(&self, id: &str, tool: &str) -> Option<bool> {
            self.0.get(&(id.to_string(), tool.to_string())).copied()
        }
    }

    fn row(name: &str, mode: ToolMode, overrides: &[(&str, ToolOverride)]) -> Integration {
        Integration {
            id: "i1".into(),
            name: name.into(),
            kind: IntegrationKind::Http,
            command: None,
            args: vec![],
            url: Some("https://example.com/mcp".into()),
            env: BTreeMap::new(),
            headers: BTreeMap::new(),
            enabled: true,
            created_at: 0,
            auth: IntegrationAuth::None,
            tool_mode: mode,
            tool_overrides: overrides.iter().map(|(t, o)| (t.to_string(), *o)).collect(),
        }
    }

    fn rule(pattern: &str, action: RuleAction) -> Rule {
        Rule {
            id: "r".into(),
            agent_id: None,
            pattern: pattern.into(),
            action,
            created_at: 0,
        }
    }

    const MODES: [ApprovalMode; 3] = [ApprovalMode::Never, ApprovalMode::Risky, ApprovalMode::Always];

    fn verdict(row: &Integration, tool: &str, known: &Known, mode: ApprovalMode) -> Option<Verdict> {
        judge(row, tool, known, mode, &[], tool).map(|j| j.verdict)
    }

    #[test]
    fn all_has_no_opinion_without_an_override() {
        let known = Known::of(&[("get", true), ("put", false)]);
        let all = row("svc", ToolMode::All, &[]);
        for mode in MODES {
            assert_eq!(verdict(&all, "get", &known, mode), None);
            assert_eq!(verdict(&all, "put", &known, mode), None);
        }
    }

    #[test]
    fn read_only_runs_reads_and_refuses_writes_in_every_mode() {
        let known = Known::of(&[("get", true), ("put", false)]);
        let svc = row("svc", ToolMode::ReadOnly, &[]);
        assert_eq!(verdict(&svc, "get", &known, ApprovalMode::Never), Some(Verdict::Allow));
        assert_eq!(verdict(&svc, "get", &known, ApprovalMode::Risky), Some(Verdict::Allow));
        // In `always` a read is not let through unasked: the normal policy asks.
        assert_eq!(verdict(&svc, "get", &known, ApprovalMode::Always), None);
        for mode in MODES {
            assert_eq!(
                verdict(&svc, "put", &known, mode),
                Some(Verdict::Deny(REASON_READ_ONLY.into())),
                "{mode:?}: never does not lift read_only"
            );
        }
    }

    #[test]
    fn a_tool_that_is_not_known_is_a_write() {
        let known = Known::of(&[]);
        let read_only = row("svc", ToolMode::ReadOnly, &[]);
        assert_eq!(
            verdict(&read_only, "mystery", &known, ApprovalMode::Risky),
            Some(Verdict::Deny(REASON_READ_ONLY.into()))
        );
        let confirm = row("svc", ToolMode::ConfirmWrites, &[]);
        assert_eq!(
            verdict(&confirm, "mystery", &known, ApprovalMode::Risky),
            Some(Verdict::Ask(REASON_CONFIRM_MODE.into()))
        );
        // The same with no source of annotations at all.
        let judged = judge(&read_only, "get", &NoToolCache, ApprovalMode::Risky, &[], "get").unwrap();
        assert!(matches!(judged.verdict, Verdict::Deny(_)));
    }

    #[test]
    fn confirm_writes_asks_before_a_write_and_never_drops_the_question() {
        let known = Known::of(&[("get", true), ("put", false)]);
        let svc = row("svc", ToolMode::ConfirmWrites, &[]);
        assert_eq!(verdict(&svc, "get", &known, ApprovalMode::Risky), Some(Verdict::Allow));
        assert_eq!(
            verdict(&svc, "put", &known, ApprovalMode::Risky),
            Some(Verdict::Ask(REASON_CONFIRM_MODE.into()))
        );
        assert_eq!(
            verdict(&svc, "put", &known, ApprovalMode::Always),
            Some(Verdict::Ask(REASON_CONFIRM_MODE.into()))
        );
        assert_eq!(verdict(&svc, "put", &known, ApprovalMode::Never), Some(Verdict::Allow));
        assert_eq!(verdict(&svc, "get", &known, ApprovalMode::Always), None);
    }

    #[test]
    fn an_override_wins_over_the_mode() {
        let known = Known::of(&[("get", true), ("put", false)]);
        // A read that is denied, a write that is allowed, in a read-only service.
        let svc = row(
            "svc",
            ToolMode::ReadOnly,
            &[("get", ToolOverride::Deny), ("put", ToolOverride::Allow)],
        );
        assert_eq!(
            verdict(&svc, "get", &known, ApprovalMode::Risky),
            Some(Verdict::Deny(REASON_TOOL_DENIED.into()))
        );
        assert_eq!(verdict(&svc, "put", &known, ApprovalMode::Risky), Some(Verdict::Allow));
        // An override on a service whose mode is `all` is still applied.
        let open = row(
            "svc",
            ToolMode::All,
            &[("put", ToolOverride::Ask), ("get", ToolOverride::Deny)],
        );
        assert_eq!(
            verdict(&open, "put", &known, ApprovalMode::Risky),
            Some(Verdict::Ask(REASON_CONFIRM_TOOL.into()))
        );
        assert_eq!(verdict(&open, "other", &known, ApprovalMode::Risky), None);
    }

    #[test]
    fn deny_stands_in_never_and_ask_does_not() {
        let known = Known::of(&[]);
        let svc = row(
            "svc",
            ToolMode::All,
            &[("a", ToolOverride::Deny), ("b", ToolOverride::Ask)],
        );
        assert_eq!(
            verdict(&svc, "a", &known, ApprovalMode::Never),
            Some(Verdict::Deny(REASON_TOOL_DENIED.into()))
        );
        assert_eq!(verdict(&svc, "b", &known, ApprovalMode::Never), Some(Verdict::Allow));
        assert_eq!(
            verdict(&svc, "b", &known, ApprovalMode::Always),
            Some(Verdict::Ask(REASON_CONFIRM_TOOL.into()))
        );
    }

    #[test]
    fn an_allow_override_is_not_a_free_pass_in_always() {
        let known = Known::of(&[]);
        let svc = row("svc", ToolMode::ReadOnly, &[("put", ToolOverride::Allow)]);
        assert_eq!(verdict(&svc, "put", &known, ApprovalMode::Always), None);
    }

    #[test]
    fn a_refusal_carries_a_sentence_for_the_agent() {
        let known = Known::of(&[]);
        let svc = row("linear", ToolMode::ReadOnly, &[("danger", ToolOverride::Deny)]);
        let write = judge(&svc, "create_issue", &known, ApprovalMode::Risky, &[], "t").unwrap();
        let text = write.agent_message.unwrap();
        assert!(
            text.contains("linear") && text.contains("create_issue") && text.contains("read only"),
            "{text}"
        );
        let denied = judge(&svc, "danger", &known, ApprovalMode::Risky, &[], "t").unwrap();
        assert!(denied.agent_message.unwrap().contains("forbade"));
        let asked = judge(
            &row("linear", ToolMode::ConfirmWrites, &[]),
            "x",
            &known,
            ApprovalMode::Risky,
            &[],
            "t",
        )
        .unwrap();
        assert_eq!(asked.agent_message, None);
    }

    #[test]
    fn the_owners_rules_still_refuse_and_still_answer_a_question() {
        let known = Known::of(&[("get", true)]);
        let confirm = row("svc", ToolMode::ConfirmWrites, &[]);
        let deny = [rule("mcp__svc__*", RuleAction::Deny)];
        // A deny rule refuses even a read the mode would let through.
        let read = judge(&confirm, "get", &known, ApprovalMode::Risky, &deny, "mcp__svc__get").unwrap();
        assert_eq!(read.verdict, Verdict::Deny("rule: mcp__svc__*".into()));
        assert!(read.agent_message.is_some());
        // An allow rule answers the question "always allow here" left behind.
        let allow = [rule("mcp__svc__put", RuleAction::Allow)];
        let put = judge(&confirm, "put", &known, ApprovalMode::Risky, &allow, "mcp__svc__put").unwrap();
        assert_eq!(put.verdict, Verdict::Allow);
        // But an allow rule does not lift a read-only refusal.
        let read_only = row("svc", ToolMode::ReadOnly, &[]);
        let still = judge(&read_only, "put", &known, ApprovalMode::Risky, &allow, "mcp__svc__put").unwrap();
        assert!(matches!(still.verdict, Verdict::Deny(_)));
        // A rule for something else changes nothing.
        let other = [rule("git push*", RuleAction::Deny)];
        let ask = judge(&confirm, "put", &known, ApprovalMode::Risky, &other, "mcp__svc__put").unwrap();
        assert!(matches!(ask.verdict, Verdict::Ask(_)));
    }

    #[test]
    fn a_tool_name_is_split_into_the_service_and_the_tool() {
        let rows = vec![
            row("a", ToolMode::All, &[]),
            row("a__b", ToolMode::All, &[]),
            row("linear", ToolMode::All, &[]),
        ];
        let (svc, tool) = split("mcp__linear__create_issue", &rows).unwrap();
        assert_eq!((svc.name.as_str(), tool.as_str()), ("linear", "create_issue"));
        // The longest name wins.
        let (svc, tool) = split("mcp__a__b__go", &rows).unwrap();
        assert_eq!((svc.name.as_str(), tool.as_str()), ("a__b", "go"));
        let (svc, tool) = split("mcp__a__go", &rows).unwrap();
        assert_eq!((svc.name.as_str(), tool.as_str()), ("a", "go"));
        assert!(split("Bash", &rows).is_none());
        assert!(split("mcp__nobody__x", &rows).is_none());
        assert!(split("mcp__linear__", &rows).is_none());
        assert!(split("mcp__linearx__x", &rows).is_none());
    }

    #[test]
    fn arguments_are_shown_cut() {
        assert_eq!(arguments_text(&serde_json::Value::Null, 100), None);
        assert_eq!(arguments_text(&serde_json::json!({}), 100), None);
        let short = arguments_text(&serde_json::json!({"a": 1}), 100).unwrap();
        assert!(short.contains("\"a\": 1") && !short.ends_with('…'));
        let long = arguments_text(&serde_json::json!({"text": "x".repeat(500)}), 50).unwrap();
        assert!(long.ends_with('…'));
        assert!(long.chars().count() <= 52);
    }
}
