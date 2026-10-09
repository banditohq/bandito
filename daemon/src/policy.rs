//! Decides what happens to a tool call the CLI asked permission for:
//! let it run, ask the human, or refuse. See docs/ARCHITECTURE.md#approvals-policy.

use crate::runtime::ApprovalRequest;
use crate::store::{ApprovalMode, Rule, RuleAction};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Allow,
    /// Ask the human; the string says why (shown in the app).
    Ask(String),
    Deny(String),
}

/// Built-in risky patterns, matched case-insensitively against each command
/// segment (see [`command_segments`]).
pub const RISKY: &[&str] = &[
    "git push*",
    "git reset --hard*",
    "git clean -*f*",
    "git branch -D*",
    "rm -rf*",
    "rm -fr*",
    "rm -r *",
    "*deploy*",
    "npm publish*",
    "pnpm publish*",
    "yarn publish*",
    "cargo publish*",
    "kubectl delete*",
    "kubectl apply*",
    "terraform apply*",
    "terraform destroy*",
    "docker system prune*",
    "*drop table*",
    "*drop database*",
    "*truncate table*",
    "shutdown*",
    "reboot*",
];

/// Decide for one request.
///
/// Order:
/// 1. `rules` are already ordered (agent's own first, then global). The first
///    rule whose `pattern` matches `subject` (= `req.command` if present, else
///    `req.title`) with [`glob_match`] (case-sensitive) decides:
///    `Deny` → `Deny("rule: <pattern>")`, `Allow` → `Allow`,
///    `Ask` → `Ask("rule: <pattern>")`.
/// 2. No rule matched:
///    - `Never`  → `Allow`
///    - `Always` → `Ask("approval required for every action")`
///    - `Risky`  → if any segment of `req.command` matches a [`RISKY`] pattern
///      (case-insensitive) → `Ask("risky: <pattern>")`; else if any of
///      `req.paths` is outside `cwd` ([`is_outside`]) → `Ask("writes outside <cwd>")`;
///      else `Allow`.
pub fn evaluate(mode: ApprovalMode, req: &ApprovalRequest, cwd: &str, rules: &[Rule]) -> Verdict {
    let subject = req.command.as_deref().unwrap_or(req.title.as_str());
    if let Some(rule) = rules.iter().find(|rule| glob_match(&rule.pattern, subject, false)) {
        return match rule.action {
            RuleAction::Deny => Verdict::Deny(format!("rule: {}", rule.pattern)),
            RuleAction::Allow => Verdict::Allow,
            RuleAction::Ask => Verdict::Ask(format!("rule: {}", rule.pattern)),
        };
    }
    match mode {
        ApprovalMode::Never => Verdict::Allow,
        ApprovalMode::Always => Verdict::Ask("approval required for every action".into()),
        ApprovalMode::Risky => {
            if let Some(command) = req.command.as_deref() {
                for segment in command_segments(command) {
                    for &pattern in RISKY {
                        if glob_match(pattern, &segment, true) {
                            return Verdict::Ask(format!("risky: {pattern}"));
                        }
                    }
                }
            }
            if req.paths.iter().any(|path| is_outside(path, cwd)) {
                return Verdict::Ask(format!("writes outside {cwd}"));
            }
            Verdict::Allow
        }
    }
}

/// `*` matches any run of characters (including empty); every other char is
/// literal; the whole `text` must match. No other wildcards. Iterative, no
/// recursion blowup on long inputs.
pub fn glob_match(pattern: &str, text: &str, case_insensitive: bool) -> bool {
    let (pat, txt): (Vec<char>, Vec<char>) = if case_insensitive {
        (
            pattern.to_lowercase().chars().collect(),
            text.to_lowercase().chars().collect(),
        )
    } else {
        (pattern.chars().collect(), text.chars().collect())
    };
    // Classic wildcard matching: on a mismatch, rewind to the last `*` and let
    // it absorb one more character. Only the last `*` ever needs revisiting.
    let (mut p, mut t) = (0, 0);
    // Index in `pat` of the last `*` seen.
    let mut star: Option<usize> = None;
    // Index in `txt` where the last `*` started absorbing.
    let mut star_t = 0;
    while t < txt.len() {
        if p < pat.len() && pat[p] == '*' {
            star = Some(p);
            star_t = t;
            p += 1;
        } else if p < pat.len() && pat[p] == txt[t] {
            p += 1;
            t += 1;
        } else if let Some(star_p) = star {
            p = star_p + 1;
            star_t += 1;
            t = star_t;
        } else {
            return false;
        }
    }
    pat[p..].iter().all(|&c| c == '*')
}

/// Split a shell command into simple commands: on `&&`, `||`, `;`, `|`, and
/// newlines. Each segment is trimmed, then leading `sudo `, `env ` and
/// `NAME=value ` assignments (any number) are stripped. Empty segments are
/// dropped. Quotes are not parsed (good enough for a safety net).
pub fn command_segments(cmd: &str) -> Vec<String> {
    let split_points = cmd.replace("&&", "\n").replace("||", "\n").replace([';', '|'], "\n");
    split_points
        .split('\n')
        .filter_map(|segment| {
            let mut rest = segment.trim();
            while let Some(stripped) = strip_prefix(rest) {
                rest = stripped;
            }
            (!rest.is_empty()).then(|| rest.to_string())
        })
        .collect()
}

/// Removes one leading `sudo`, `env` or `NAME=value` word, but only when
/// whitespace and more text follow it. Returns the trimmed remainder.
fn strip_prefix(segment: &str) -> Option<&str> {
    let (word, after) = segment.split_once(char::is_whitespace)?;
    let rest = after.trim_start();
    if rest.is_empty() {
        return None;
    }
    (word == "sudo" || word == "env" || is_assignment(word)).then_some(rest)
}

/// `NAME=value` where NAME is `[A-Za-z_][A-Za-z0-9_]*`; the value may be empty.
fn is_assignment(word: &str) -> bool {
    let Some((name, _value)) = word.split_once('=') else {
        return false;
    };
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// True if `path` (absolute, or relative to `cwd`) lands outside `cwd` after
/// lexical normalization of `.` and `..` (no filesystem access). `cwd`
/// itself and anything under it are inside. `/a/bc` is NOT inside `/a/b`.
pub fn is_outside(path: &str, cwd: &str) -> bool {
    let full = if path.starts_with('/') {
        path.to_string()
    } else {
        format!("{cwd}/{path}")
    };
    let base = normalize(cwd);
    let target = normalize(&full);
    !target.starts_with(&base)
}

/// Lexical path components: empty and `.` are dropped, `..` pops the last
/// component (no-op at the root).
fn normalize(path: &str) -> Vec<&str> {
    let mut parts: Vec<&str> = Vec::new();
    for component in path.split('/') {
        match component {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    parts
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    const CWD: &str = "/home/u/app";

    fn req(command: Option<&str>, title: &str, paths: &[&str]) -> ApprovalRequest {
        ApprovalRequest {
            key: "k".into(),
            call_id: "c".into(),
            tool: "Bash".into(),
            title: title.into(),
            command: command.map(str::to_string),
            diff: None,
            paths: paths.iter().map(|p| p.to_string()).collect(),
            input: serde_json::Value::Null,
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

    // --- glob_match ---

    #[test]
    fn glob_trailing_star_matches_rest() {
        assert!(glob_match("git push*", "git push origin main", false));
    }

    #[test]
    fn glob_trailing_star_rejects_other_command() {
        assert!(!glob_match("git push*", "git pull", false));
    }

    #[test]
    fn glob_star_on_both_sides() {
        assert!(glob_match("*deploy*", "npx wrangler deploy --env prod", false));
    }

    #[test]
    fn glob_stars_match_in_order() {
        assert!(glob_match("a*b*c", "abc", false));
    }

    #[test]
    fn glob_stars_reject_wrong_order() {
        assert!(!glob_match("a*b*c", "acb", false));
    }

    #[test]
    fn glob_star_matches_empty_text() {
        assert!(glob_match("*", "", false));
    }

    #[test]
    fn glob_empty_pattern_matches_empty_text() {
        assert!(glob_match("", "", false));
    }

    #[test]
    fn glob_empty_pattern_rejects_text() {
        assert!(!glob_match("", "x", false));
    }

    #[test]
    fn glob_case_insensitive_matches() {
        assert!(glob_match("abc", "ABC", true));
    }

    #[test]
    fn glob_case_sensitive_rejects_other_case() {
        assert!(!glob_match("abc", "ABC", false));
    }

    #[test]
    fn glob_works_on_chars_not_bytes_cyrillic() {
        assert!(glob_match("удали*", "удалить всё", false));
    }

    #[test]
    fn glob_long_input_fails_fast() {
        let text = "a".repeat(10_000);
        let started = Instant::now();
        assert!(!glob_match("*a*a*a*b", &text, false));
        assert!(started.elapsed() < Duration::from_secs(1));
    }

    // --- command_segments ---

    #[test]
    fn segments_split_on_and() {
        assert_eq!(
            command_segments("cd x && git push"),
            vec!["cd x".to_string(), "git push".to_string()]
        );
    }

    #[test]
    fn segments_strip_sudo() {
        assert_eq!(
            command_segments("sudo rm -rf /tmp/x"),
            vec!["rm -rf /tmp/x".to_string()]
        );
    }

    #[test]
    fn segments_strip_assignments_and_env_in_any_order() {
        assert_eq!(
            command_segments("FOO=1 BAR=2 env sudo npm publish"),
            vec!["npm publish".to_string()]
        );
    }

    #[test]
    fn segments_split_on_pipe_semicolon_or_and_newline() {
        assert_eq!(command_segments("a | b; c || d\ne"), vec!["a", "b", "c", "d", "e"]);
    }

    #[test]
    fn segments_only_separators_yield_nothing() {
        assert!(command_segments("  ;; ").is_empty());
    }

    #[test]
    fn segments_keep_assignment_not_at_start() {
        assert_eq!(command_segments("echo a=b"), vec!["echo a=b".to_string()]);
    }

    #[test]
    fn segments_keep_lone_assignment_without_command() {
        assert_eq!(command_segments("FOO=1"), vec!["FOO=1".to_string()]);
    }

    #[test]
    fn segments_keep_bare_sudo_and_do_not_strip_prefix_of_longer_word() {
        assert_eq!(command_segments("sudo"), vec!["sudo".to_string()]);
        assert_eq!(command_segments("sudoku x"), vec!["sudoku x".to_string()]);
    }

    // --- is_outside ---

    #[test]
    fn outside_relative_inside_cwd() {
        assert!(!is_outside("src/main.rs", CWD));
    }

    #[test]
    fn outside_parent_escape_is_outside() {
        assert!(is_outside("../other/x", CWD));
    }

    #[test]
    fn outside_cwd_itself_is_inside() {
        assert!(!is_outside("/home/u/app", CWD));
    }

    #[test]
    fn outside_sibling_with_common_prefix_is_outside() {
        assert!(is_outside("/home/u/appx/f", CWD));
    }

    #[test]
    fn outside_dot_and_dotdot_normalized_inside() {
        assert!(!is_outside("./a/../b", CWD));
    }

    #[test]
    fn outside_absolute_elsewhere_is_outside() {
        assert!(is_outside("/etc/passwd", CWD));
    }

    #[test]
    fn outside_climbing_past_root_is_outside() {
        assert!(is_outside("../../..", "/a"));
    }

    // --- evaluate ---

    #[test]
    fn risky_git_push_asks() {
        let r = req(Some("git push origin main"), "Bash", &[]);
        assert_eq!(
            evaluate(ApprovalMode::Risky, &r, CWD, &[]),
            Verdict::Ask("risky: git push*".into())
        );
    }

    #[test]
    fn risky_checks_each_segment_after_prefix_strip() {
        let r = req(Some("cd app && GIT_SSH=x git push"), "Bash", &[]);
        assert_eq!(
            evaluate(ApprovalMode::Risky, &r, CWD, &[]),
            Verdict::Ask("risky: git push*".into())
        );
    }

    #[test]
    fn risky_safe_command_allowed() {
        let r = req(Some("cargo test"), "Bash", &[]);
        assert_eq!(evaluate(ApprovalMode::Risky, &r, CWD, &[]), Verdict::Allow);
    }

    #[test]
    fn risky_builtin_match_is_case_insensitive() {
        let r = req(Some("psql -c 'DROP TABLE users'"), "Bash", &[]);
        assert_eq!(
            evaluate(ApprovalMode::Risky, &r, CWD, &[]),
            Verdict::Ask("risky: *drop table*".into())
        );
    }

    #[test]
    fn risky_write_outside_cwd_asks_without_command() {
        let r = req(None, "Edit /etc/hosts", &["/etc/hosts"]);
        assert_eq!(
            evaluate(ApprovalMode::Risky, &r, CWD, &[]),
            Verdict::Ask("writes outside /home/u/app".into())
        );
    }

    #[test]
    fn risky_write_inside_cwd_allowed() {
        let r = req(None, "Edit src/main.rs", &["src/main.rs"]);
        assert_eq!(evaluate(ApprovalMode::Risky, &r, CWD, &[]), Verdict::Allow);
    }

    #[test]
    fn risky_command_reason_wins_over_outside_path() {
        let r = req(Some("rm -rf /"), "Bash", &["/etc/hosts"]);
        assert_eq!(
            evaluate(ApprovalMode::Risky, &r, CWD, &[]),
            Verdict::Ask("risky: rm -rf*".into())
        );
    }

    #[test]
    fn risky_allow_rule_overrides_builtin() {
        let r = req(Some("git push origin main"), "Bash", &[]);
        let rules = [rule("git push*", RuleAction::Allow)];
        assert_eq!(evaluate(ApprovalMode::Risky, &r, CWD, &rules), Verdict::Allow);
    }

    #[test]
    fn risky_ask_rule_reports_rule_pattern() {
        let r = req(Some("git push origin main"), "Bash", &[]);
        let rules = [rule("git push*", RuleAction::Ask)];
        assert_eq!(
            evaluate(ApprovalMode::Risky, &r, CWD, &rules),
            Verdict::Ask("rule: git push*".into())
        );
    }

    #[test]
    fn never_allows_risky_command() {
        let r = req(Some("git push"), "Bash", &[]);
        assert_eq!(evaluate(ApprovalMode::Never, &r, CWD, &[]), Verdict::Allow);
    }

    #[test]
    fn never_still_honors_deny_rule() {
        let r = req(Some("git push"), "Bash", &[]);
        let rules = [rule("git push*", RuleAction::Deny)];
        assert_eq!(
            evaluate(ApprovalMode::Never, &r, CWD, &rules),
            Verdict::Deny("rule: git push*".into())
        );
    }

    #[test]
    fn always_asks_for_every_action() {
        let r = req(Some("ls"), "Bash", &[]);
        assert_eq!(
            evaluate(ApprovalMode::Always, &r, CWD, &[]),
            Verdict::Ask("approval required for every action".into())
        );
    }

    #[test]
    fn always_allow_rule_skips_prompt() {
        let r = req(Some("ls"), "Bash", &[]);
        let rules = [rule("ls*", RuleAction::Allow)];
        assert_eq!(evaluate(ApprovalMode::Always, &r, CWD, &rules), Verdict::Allow);
    }

    #[test]
    fn first_matching_rule_wins() {
        let r = req(Some("git push"), "Bash", &[]);
        let rules = [rule("git *", RuleAction::Allow), rule("git push*", RuleAction::Deny)];
        assert_eq!(evaluate(ApprovalMode::Risky, &r, CWD, &rules), Verdict::Allow);
    }

    #[test]
    fn rule_matches_title_when_no_command() {
        let r = req(None, "Edit src/main.rs", &[]);
        let rules = [rule("Edit src/*", RuleAction::Allow)];
        assert_eq!(evaluate(ApprovalMode::Always, &r, CWD, &rules), Verdict::Allow);
    }
}
