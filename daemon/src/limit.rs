//! Subscription usage limits: when a runtime says its usage is used up, and when
//! its windows are free again. See docs/ARCHITECTURE.md#fallback-subscription.

use crate::event::LimitWindow;
use crate::runtime::RuntimeKind;

/// A full window whose reset time is unknown counts as blocking until this long after it was reported.
pub const UNKNOWN_RESET_RECHECK_MS: i64 = 60 * 60 * 1000;

/// Words in a runtime's error message that say its usage is used up. Matched in lower case.
/// Only runtime error messages are checked, never the agent's own text.
fn limit_words(kind: RuntimeKind) -> &'static [&'static str] {
    match kind {
        // Claude Code: "Claude AI usage limit reached|<epoch>"; API throttling is "429 rate_limit_error".
        RuntimeKind::Claude => &["usage limit", "rate limit", "rate_limit", "429"],
        // Codex: the turn error carries `usage_limit_reached` ("You've hit your usage limit").
        RuntimeKind::Codex => &["usage_limit_reached", "usage limit", "usagelimit", "rate limit", "429"],
        // Grok (ACP): "Rate limited: You've used all the included free usage ...".
        RuntimeKind::Grok => &["rate limit", "429", "too many requests"],
        RuntimeKind::Api => &["usage limit", "rate limit", "429", "too many requests"],
    }
}

/// Whether an error message of a finished turn says that the runtime's usage is used up.
pub fn error_marks_limit(kind: RuntimeKind, message: &str) -> bool {
    let lower = message.to_lowercase();
    limit_words(kind).iter().any(|word| lower.contains(word))
}

/// Whether one window is full (utilization 1.0 or more), whatever its reset time.
pub fn window_full(window: &LimitWindow) -> bool {
    window.utilization >= 1.0
}

/// Whether one window blocks the runtime at `now_ms` (see [`blocked`]).
fn window_blocks(window: &LimitWindow, reported_at_ms: i64, now_ms: i64) -> bool {
    if !window_full(window) {
        return false;
    }
    match window.resets_at {
        Some(reset_s) => reset_s.saturating_mul(1000) > now_ms,
        None => now_ms < reported_at_ms.saturating_add(UNKNOWN_RESET_RECHECK_MS),
    }
}

/// Whether the windows still block the runtime at `now_ms`. A full window blocks while its
/// reset (`resets_at`, Unix seconds) is in the future. Without a reset time it blocks until
/// `UNKNOWN_RESET_RECHECK_MS` after `reported_at_ms`.
pub fn blocked(windows: &[LimitWindow], reported_at_ms: i64, now_ms: i64) -> bool {
    windows.iter().any(|w| window_blocks(w, reported_at_ms, now_ms))
}

/// The earliest reset (Unix seconds) among the windows that block at `now_ms`, when known.
/// `None` when nothing blocks or the blocking window has no reset time.
pub fn blocked_until(windows: &[LimitWindow], reported_at_ms: i64, now_ms: i64) -> Option<i64> {
    let blocking: Vec<&LimitWindow> = windows
        .iter()
        .filter(|w| window_blocks(w, reported_at_ms, now_ms))
        .collect();
    if blocking.iter().any(|w| w.resets_at.is_none()) {
        return None;
    }
    blocking.iter().filter_map(|w| w.resets_at).min()
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW_MS: i64 = 1_791_000_000_000;
    const NOW_S: i64 = NOW_MS / 1000;

    fn window(utilization: f64, resets_at: Option<i64>) -> LimitWindow {
        LimitWindow {
            name: "five_hour".into(),
            utilization,
            resets_at,
        }
    }

    /// The Grok `rate_limited` fixture: the error the turn ends with, as the adapter words it.
    fn grok_fixture_message() -> String {
        let line = include_str!("../tests/fixtures/grok/rate_limited.jsonl")
            .lines()
            .find(|l| l.contains("Rate limited"))
            .expect("fixture has the rate limit answer");
        let v: serde_json::Value = serde_json::from_str(line).unwrap();
        let err = &v["send"]["error"];
        format!(
            "{}: {}",
            err["message"].as_str().unwrap(),
            err["data"].as_str().unwrap()
        )
    }

    #[test]
    fn claude_limit_messages_are_recognised() {
        // Claude Code words the exhausted subscription as "usage limit reached", API throttling as 429.
        assert!(error_marks_limit(
            RuntimeKind::Claude,
            "Claude AI usage limit reached|1791543600"
        ));
        assert!(error_marks_limit(
            RuntimeKind::Claude,
            "API Error: 429 rate_limit_error"
        ));
        // An ordinary failed turn, and an interrupted one, are not limits.
        assert!(!error_marks_limit(RuntimeKind::Claude, "Hit the limit"));
        assert!(!error_marks_limit(RuntimeKind::Claude, "Interrupted"));
    }

    #[test]
    fn codex_limit_messages_are_recognised() {
        assert!(error_marks_limit(
            RuntimeKind::Codex,
            "usage_limit_reached: You've hit your usage limit"
        ));
        assert!(error_marks_limit(
            RuntimeKind::Codex,
            "You've hit your usage limit. Try again later."
        ));
        assert!(!error_marks_limit(RuntimeKind::Codex, "Codex turn failed"));
    }

    #[test]
    fn grok_limit_fixture_is_recognised() {
        let msg = grok_fixture_message();
        assert!(msg.starts_with("Rate limited"), "{msg}");
        assert!(error_marks_limit(RuntimeKind::Grok, &msg));
        assert!(!error_marks_limit(RuntimeKind::Grok, "grok refused the request"));
    }

    #[test]
    fn no_runtime_reads_an_unrelated_failure_as_a_limit() {
        for kind in [
            RuntimeKind::Claude,
            RuntimeKind::Codex,
            RuntimeKind::Grok,
            RuntimeKind::Api,
        ] {
            assert!(
                !error_marks_limit(kind, "the agent process exited (code Some(1))"),
                "{kind:?}"
            );
        }
    }

    #[test]
    fn a_full_window_with_a_future_reset_blocks() {
        let w = [window(1.0, Some(NOW_S + 100))];
        assert!(blocked(&w, NOW_MS, NOW_MS));
    }

    #[test]
    fn a_full_window_whose_reset_passed_is_free() {
        let w = [window(1.0, Some(NOW_S - 1))];
        assert!(!blocked(&w, NOW_MS - 3_600_000, NOW_MS));
    }

    #[test]
    fn a_window_below_full_does_not_block() {
        let w = [window(0.99, Some(NOW_S + 100))];
        assert!(!window_full(&w[0]));
        assert!(!blocked(&w, NOW_MS, NOW_MS));
    }

    #[test]
    fn a_full_window_without_reset_blocks_only_for_a_while() {
        let w = [window(1.0, None)];
        assert!(blocked(&w, NOW_MS - 10 * 60 * 1000, NOW_MS));
        assert!(!blocked(&w, NOW_MS - 2 * UNKNOWN_RESET_RECHECK_MS, NOW_MS));
    }

    #[test]
    fn no_windows_never_block() {
        assert!(!blocked(&[], NOW_MS, NOW_MS));
    }

    #[test]
    fn blocked_until_is_the_earliest_known_reset_of_the_blocking_windows() {
        let w = [
            window(1.0, Some(NOW_S + 2000)),
            window(1.0, Some(NOW_S + 1500)),
            window(0.5, Some(NOW_S + 100)),
            window(1.0, Some(NOW_S - 5)),
        ];
        assert_eq!(blocked_until(&w, NOW_MS, NOW_MS), Some(NOW_S + 1500));
    }

    #[test]
    fn blocked_until_is_none_when_nothing_blocks_or_the_reset_is_unknown() {
        assert_eq!(blocked_until(&[window(0.2, Some(NOW_S + 5))], NOW_MS, NOW_MS), None);
        assert_eq!(blocked_until(&[window(1.0, None)], NOW_MS, NOW_MS), None);
    }
}
