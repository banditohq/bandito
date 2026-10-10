//! What the owner allowed the tools of an integration to do (docs/ARCHITECTURE.md#tool-permissions): the part of the
//! approvals policy that decides calls of `mcp__<service>__<tool>`.
//!
//! Order: the owner's word on the tool (`tool_overrides`), else the service's mode (`tool_mode`). A tool that reads
//! runs in `read_only` and `confirm_writes`; one that changes something is refused in `read_only` and asked about in
//! `confirm_writes`. Tool names are compared as Claude Code writes them in `mcp__<service>__<tool>`: every character
//! outside `A-Za-z0-9_-` is an underscore ([`normalize`]), on both sides, so `create.issue` and `create_issue` are one
//! tool. A name that can be split in more than one way (`mcp__a__b__go` is `a` with `b__go`, or `a__b` with `go`) is
//! judged both ways and the strictest verdict stands ([`judge_call`]). Whether a tool reads comes from [`ToolCatalog`] (the annotations of `tools/list`); a tool that is
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

/// Reason of a refusal because what the owner allowed could not be read.
pub const REASON_UNCHECKED: &str = "service: permissions unreadable";
/// Said to the agent when the owner's permissions could not be read: nothing runs, and it is worth another try.
pub const UNCHECKED_MESSAGE: &str = "Bandito could not read what the owner allowed for this service just now, so the call was not run. Try again in a moment; if it keeps failing, tell the owner.";

/// Reason of a refusal because no service of the agent has that name any more.
pub const REASON_GONE: &str = "service: not the agent's any more";
/// Said to the agent when a call names a service it does not have now (renamed, removed, turned off, not its own).
pub const GONE_MESSAGE: &str = "This service is no longer available to this agent (it was renamed, removed or turned off), so the call was not run. Do not retry it; tell the owner if the task needs it.";

/// What is known about the tools of the services: whether a tool only reads. The answer comes from the annotations the
/// server sent in `tools/list` (`readOnlyHint`), kept by the daemon. `None` when the tool is not known.
pub trait ToolCatalog {
    fn read_only(&self, integration_id: &str, tool: &str) -> Option<bool>;
}

/// No tool is known: every tool counts as a write. For callers that have no probe to read.
pub struct NoToolCache;

impl ToolCatalog for NoToolCache {
    fn read_only(&self, _integration_id: &str, _tool: &str) -> Option<bool> {
        None
    }
}

/// The tools of one service as the last probe saw them (`integration_tools`).
pub struct StoredTools {
    integration_id: String,
    tools: Vec<crate::store::IntegrationTool>,
}

impl StoredTools {
    pub fn new(integration_id: String, tools: Vec<crate::store::IntegrationTool>) -> Self {
        Self { integration_id, tools }
    }
}

impl ToolCatalog for StoredTools {
    fn read_only(&self, integration_id: &str, tool: &str) -> Option<bool> {
        if integration_id != self.integration_id {
            return None;
        }
        // Names that become one name after normalizing count as one tool, and it reads only if all of them do.
        let wanted = normalize(tool);
        let same: Vec<_> = self.tools.iter().filter(|t| normalize(&t.name) == wanted).collect();
        (!same.is_empty()).then(|| same.iter().all(|t| t.read_only))
    }
}

/// A name as Claude Code writes it into `mcp__<service>__<tool>`: every character outside `A-Za-z0-9_-` becomes an
/// underscore, one for each UTF-16 unit (the CLI replaces with a JavaScript regular expression).
pub fn normalize(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
            out.push(c);
        } else {
            out.extend(std::iter::repeat_n('_', c.len_utf16()));
        }
    }
    out
}

/// Every way a CLI's tool name can be read as a service and a tool: `mcp__linear__create_issue` is the integration
/// `linear` and the tool `create_issue`. A name with `__` inside is ambiguous (`a` with `b__go`, `a__b` with `go`):
/// all the readings are returned, so the caller can judge each. The tool is returned as written in the call.
pub fn splits<'a>(name: &str, rows: &'a [Integration]) -> Vec<(&'a Integration, String)> {
    let Some(rest) = name.strip_prefix(MCP_PREFIX) else {
        return Vec::new();
    };
    rows.iter()
        .filter_map(|row| {
            let tool = rest.strip_prefix(normalize(&row.name).as_str())?.strip_prefix("__")?;
            (!tool.is_empty()).then_some((row, tool.to_string()))
        })
        .collect()
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

/// The owner's word on a tool: the words of every name that normalizes to this one, the strictest of them.
fn word_for(row: &Integration, tool: &str) -> Option<ToolOverride> {
    fn rank(word: ToolOverride) -> u8 {
        match word {
            ToolOverride::Allow => 0,
            ToolOverride::Ask => 1,
            ToolOverride::Deny => 2,
        }
    }
    row.tool_overrides
        .iter()
        .filter(|(name, _)| normalize(name) == tool)
        .map(|(_, word)| *word)
        .max_by_key(|word| rank(*word))
}

fn base(row: &Integration, tool: &str, catalog: &dyn ToolCatalog) -> Option<Base> {
    if let Some(word) = word_for(row, tool) {
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
    let tool = normalize(tool);
    let tool = tool.as_str();
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

/// Decide a call named `name` (`mcp__<service>__<tool>`). Every way of reading the name as a service and a tool is judged
/// and the strictest verdict stands: a refusal over a question, a question over a call that runs, and a reading with no
/// opinion keeps the normal policy in charge unless another reading refuses or asks. `None`: no reading has an
/// opinion, or the name is no tool of a service. `catalog_of` reads what is known about a service's tools; its error is
/// the caller's to turn into a refusal.
pub fn judge_call(
    name: &str,
    rows: &[Integration],
    mode: ApprovalMode,
    rules: &[Rule],
    subject: &str,
    mut catalog_of: impl FnMut(&Integration) -> anyhow::Result<Box<dyn ToolCatalog>>,
) -> anyhow::Result<Option<Judged>> {
    let mut asked: Option<Judged> = None;
    let mut allowed: Option<Judged> = None;
    let mut open = false;
    for (row, tool) in splits(name, rows) {
        let catalog = catalog_of(row)?;
        match judge(row, &tool, catalog.as_ref(), mode, rules, subject) {
            None => open = true,
            Some(judged) => match judged.verdict {
                Verdict::Deny(_) => return Ok(Some(judged)),
                Verdict::Ask(_) => asked = asked.or(Some(judged)),
                Verdict::Allow => allowed = allowed.or(Some(judged)),
            },
        }
    }
    Ok(asked.or(if open { None } else { allowed }))
}

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
    fn a_tool_name_is_read_as_each_service_it_can_belong_to() {
        let rows = vec![
            row("a", ToolMode::All, &[]),
            row("a__b", ToolMode::All, &[]),
            row("linear", ToolMode::All, &[]),
        ];
        let one = splits("mcp__linear__create_issue", &rows);
        assert_eq!(one.len(), 1);
        assert_eq!((one[0].0.name.as_str(), one[0].1.as_str()), ("linear", "create_issue"));
        // Both readings of an ambiguous name are returned.
        let both: Vec<(String, String)> = splits("mcp__a__b__go", &rows)
            .into_iter()
            .map(|(r, t)| (r.name.clone(), t))
            .collect();
        assert_eq!(
            both,
            vec![
                ("a".to_string(), "b__go".to_string()),
                ("a__b".to_string(), "go".to_string())
            ]
        );
        assert_eq!(splits("mcp__a__go", &rows).len(), 1);
        assert!(splits("Bash", &rows).is_empty());
        assert!(splits("mcp__nobody__x", &rows).is_empty());
        assert!(splits("mcp__linear__", &rows).is_empty());
        assert!(splits("mcp__linearx__x", &rows).is_empty());
    }

    fn catalog_of(known: Known) -> impl FnMut(&Integration) -> anyhow::Result<Box<dyn ToolCatalog>> {
        let mut once = Some(known);
        move |_| Ok(Box::new(once.take().unwrap_or_else(|| Known::of(&[]))) as Box<dyn ToolCatalog>)
    }

    #[test]
    fn the_strictest_reading_of_an_ambiguous_name_stands() {
        // `a` is read-only and `a__b` is open: mcp__a__b__go is `go` of a__b, but also `b__go` of a, which is refused.
        let rows = vec![row("a", ToolMode::ReadOnly, &[]), row("a__b", ToolMode::All, &[])];
        for mode in MODES {
            let judged = judge_call("mcp__a__b__go", &rows, mode, &[], "t", |_| {
                Ok(Box::new(NoToolCache) as Box<dyn ToolCatalog>)
            })
            .unwrap()
            .unwrap();
            assert!(matches!(judged.verdict, Verdict::Deny(_)), "{mode:?}");
            assert!(judged.agent_message.is_some());
        }
        // A question beats a call that runs; a reading with no opinion leaves the normal policy in charge.
        let confirm = vec![row("a", ToolMode::ConfirmWrites, &[]), row("a__b", ToolMode::All, &[])];
        let asked = judge_call("mcp__a__b__go", &confirm, ApprovalMode::Risky, &[], "t", |_| {
            Ok(Box::new(NoToolCache) as Box<dyn ToolCatalog>)
        })
        .unwrap()
        .unwrap();
        assert!(matches!(asked.verdict, Verdict::Ask(_)));
        let reads = vec![
            row("a", ToolMode::ReadOnly, &[("b__go", ToolOverride::Allow)]),
            row("a__b", ToolMode::All, &[]),
        ];
        assert_eq!(
            judge_call("mcp__a__b__go", &reads, ApprovalMode::Risky, &[], "t", |_| Ok(
                Box::new(NoToolCache) as Box<dyn ToolCatalog>
            ))
            .unwrap(),
            None,
            "one reading allows, the other has no opinion: the normal policy decides"
        );
        // Not a tool of a service at all.
        assert_eq!(
            judge_call("Bash", &rows, ApprovalMode::Risky, &[], "t", catalog_of(Known::of(&[]))).unwrap(),
            None
        );
    }

    #[test]
    fn a_catalog_error_is_the_callers_to_handle() {
        let rows = vec![row("svc", ToolMode::ReadOnly, &[])];
        let err = judge_call("mcp__svc__x", &rows, ApprovalMode::Risky, &[], "t", |_| {
            anyhow::bail!("database is locked")
        });
        assert!(err.is_err());
    }

    #[test]
    fn names_are_compared_as_claude_code_writes_them() {
        assert_eq!(normalize("create.issue"), "create_issue");
        assert_eq!(normalize("a b/c"), "a_b_c");
        assert_eq!(normalize("ok-name_1"), "ok-name_1");
        // One underscore for each UTF-16 unit: a letter outside ASCII is one, an emoji is two.
        assert_eq!(normalize("é"), "_");
        assert_eq!(normalize("😀"), "__");
        // An override on `create.issue` reaches the call Claude Code names `mcp__svc__create_issue`.
        let svc = row("svc", ToolMode::All, &[("create.issue", ToolOverride::Deny)]);
        let judged = judge_call(
            "mcp__svc__create_issue",
            &[svc],
            ApprovalMode::Risky,
            &[],
            "t",
            catalog_of(Known::of(&[])),
        )
        .unwrap()
        .unwrap();
        assert_eq!(judged.verdict, Verdict::Deny(REASON_TOOL_DENIED.into()));
        // Two names that normalize alike: the stricter word wins.
        let both = row(
            "svc",
            ToolMode::All,
            &[("a.b", ToolOverride::Allow), ("a b", ToolOverride::Deny)],
        );
        let judged = judge(&both, "a_b", &Known::of(&[]), ApprovalMode::Risky, &[], "t").unwrap();
        assert!(matches!(judged.verdict, Verdict::Deny(_)));
    }

    #[test]
    fn what_the_probe_saw_is_matched_by_normalized_name() {
        let tool = |name: &str, read_only: bool| crate::store::IntegrationTool {
            name: name.into(),
            title: None,
            description: None,
            read_only,
            destructive: false,
            input_schema: None,
            seen_at: 1,
        };
        let stored = StoredTools::new(
            "i1".into(),
            vec![tool("list.issues", true), tool("a.b", true), tool("a b", false)],
        );
        assert_eq!(stored.read_only("i1", "list_issues"), Some(true));
        // Two names that become one: it reads only if both do.
        assert_eq!(stored.read_only("i1", "a_b"), Some(false));
        assert_eq!(stored.read_only("i1", "unknown"), None);
        assert_eq!(stored.read_only("other", "list_issues"), None);
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
