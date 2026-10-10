//! Redacts secret values from what an agent produces (text, tool calls, approvals)
//! before the event is stored or sent. Each value becomes `••••NAME`.
//! See docs/ARCHITECTURE.md#secrets.

use crate::event::EventBody;
use crate::runtime::ApprovalRequest;
use serde_json::Value;
use std::borrow::Cow;

/// Values shorter than this are not redacted: they would match inside ordinary text.
pub const MIN_VALUE_BYTES: usize = 6;

/// Replaces secret values in text with `••••NAME`. The supervisor builds one per agent session,
/// from the secrets that session was started with.
#[derive(Debug, Clone, Default)]
pub struct Redactor {
    /// `(value, name)`, longest value first, so that of overlapping values the longer one wins.
    entries: Vec<(String, String)>,
}

impl Redactor {
    /// `secrets` are `(name, value)` pairs. Values shorter than [`MIN_VALUE_BYTES`] are skipped.
    pub fn new(secrets: impl IntoIterator<Item = (String, String)>) -> Self {
        let mut entries: Vec<(String, String)> = secrets
            .into_iter()
            .filter(|(_, value)| value.len() >= MIN_VALUE_BYTES)
            .map(|(name, value)| (value, name))
            .collect();
        entries.sort_by_key(|e| std::cmp::Reverse(e.0.len()));
        Self { entries }
    }

    /// `text` with every secret value replaced. Borrowed when nothing matched.
    pub fn redact<'a>(&self, text: &'a str) -> Cow<'a, str> {
        if !self.entries.iter().any(|(value, _)| text.contains(value.as_str())) {
            return Cow::Borrowed(text);
        }
        let mut out = String::with_capacity(text.len());
        let mut rest = text;
        // One pass, so a replacement is never searched again. At each position the longest value wins.
        while let Some(c) = rest.chars().next() {
            match self.entries.iter().find(|(value, _)| rest.starts_with(value.as_str())) {
                Some((value, name)) => {
                    out.push_str("••••");
                    out.push_str(name);
                    rest = &rest[value.len()..];
                }
                None => {
                    out.push(c);
                    rest = &rest[c.len_utf8()..];
                }
            }
        }
        Cow::Owned(out)
    }

    /// Redacts every string inside a JSON value, in place. Object keys are kept.
    pub fn redact_json(&self, v: &mut Value) {
        match v {
            Value::String(s) => {
                let red = match self.redact(s.as_str()) {
                    Cow::Owned(red) => Some(red),
                    Cow::Borrowed(_) => None,
                };
                if let Some(red) = red {
                    *s = red;
                }
            }
            Value::Array(items) => items.iter_mut().for_each(|x| self.redact_json(x)),
            Value::Object(map) => map.values_mut().for_each(|x| self.redact_json(x)),
            _ => {}
        }
    }

    /// `body` with the text a runtime produced redacted: message text, tool call title and input,
    /// tool output, and error text. Other events come back unchanged.
    pub fn redact_event(&self, body: EventBody) -> EventBody {
        match body {
            EventBody::MessageDelta { text } => EventBody::MessageDelta { text: self.owned(text) },
            EventBody::MessageAssistant { text } => EventBody::MessageAssistant { text: self.owned(text) },
            EventBody::ToolCall {
                call_id,
                tool,
                title,
                mut input,
            } => {
                self.redact_json(&mut input);
                EventBody::ToolCall {
                    call_id,
                    tool,
                    title: self.owned(title),
                    input,
                }
            }
            EventBody::ToolResult { call_id, ok, output } => EventBody::ToolResult {
                call_id,
                ok,
                output: self.owned(output),
            },
            EventBody::Error { message } => EventBody::Error {
                message: self.owned(message),
            },
            other => other,
        }
    }

    /// Redacts the title, command, diff and input of an approval request, in place. The key and
    /// the other fields are kept, so the answer still reaches the right CLI request.
    pub fn redact_approval(&self, req: &mut ApprovalRequest) {
        req.title = self.owned(std::mem::take(&mut req.title));
        req.command = req.command.take().map(|c| self.owned(c));
        req.diff = req.diff.take().map(|d| self.owned(d));
        self.redact_json(&mut req.input);
    }

    /// `s` with secrets replaced, without copying when nothing matched.
    fn owned(&self, s: String) -> String {
        let red = match self.redact(&s) {
            Cow::Owned(red) => Some(red),
            Cow::Borrowed(_) => None,
        };
        red.unwrap_or(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::EventBody;
    use serde_json::json;
    use std::borrow::Cow;

    fn pair(name: &str, value: &str) -> (String, String) {
        (name.to_string(), value.to_string())
    }

    #[test]
    fn replaces_every_occurrence_with_the_name() {
        let r = Redactor::new([pair("OPENAI_API_KEY", "sk-test-123456")]);
        assert_eq!(
            r.redact("a sk-test-123456 b sk-test-123456!"),
            "a ••••OPENAI_API_KEY b ••••OPENAI_API_KEY!"
        );
    }

    #[test]
    fn text_without_a_secret_is_borrowed() {
        let r = Redactor::new([pair("K", "sk-test-123456")]);
        assert!(matches!(r.redact("nothing here"), Cow::Borrowed(_)));
        assert!(matches!(r.redact("with sk-test-123456"), Cow::Owned(_)));
        let none = Redactor::default();
        assert!(matches!(none.redact("sk-test-123456"), Cow::Borrowed(_)));
    }

    #[test]
    fn the_longer_value_wins_when_values_overlap() {
        // The short value is a prefix of the long one. Either order must give the long replacement.
        let short_first = Redactor::new([pair("SHORT", "secret-12345"), pair("LONG", "secret-1234567890")]);
        let long_first = Redactor::new([pair("LONG", "secret-1234567890"), pair("SHORT", "secret-12345")]);
        for r in [&short_first, &long_first] {
            assert_eq!(r.redact("x secret-1234567890 y"), "x ••••LONG y");
            assert_eq!(r.redact("x secret-12345 y"), "x ••••SHORT y");
        }
    }

    #[test]
    fn values_shorter_than_six_bytes_are_left_alone() {
        let r = Redactor::new([pair("PIN", "12345"), pair("SIX", "123456")]);
        assert_eq!(r.redact("pin 12345 and 123456"), "pin 12345 and ••••SIX");
    }

    #[test]
    fn redacts_text_in_any_script() {
        let r = Redactor::new([pair("TOKEN", "ключ-доступа-42")]);
        assert_eq!(r.redact("вот ключ-доступа-42 и ещё"), "вот ••••TOKEN и ещё");
    }

    #[test]
    fn json_is_walked_through_its_strings_and_keeps_its_shape() {
        let r = Redactor::new([pair("TOKEN", "sk-test-123456")]);
        let mut v = json!({
            "command": "curl -H 'Bearer sk-test-123456'",
            "args": ["sk-test-123456", 5, true, null],
            "nested": {"deep": "sk-test-123456"},
        });
        r.redact_json(&mut v);
        assert_eq!(
            v,
            json!({
                "command": "curl -H 'Bearer ••••TOKEN'",
                "args": ["••••TOKEN", 5, true, null],
                "nested": {"deep": "••••TOKEN"},
            })
        );
    }

    #[test]
    fn runtime_events_are_redacted_in_every_text_field() {
        let r = Redactor::new([pair("TOKEN", "sk-test-123456")]);
        let s = "sk-test-123456";
        let red = "••••TOKEN";

        assert_eq!(
            r.redact_event(EventBody::MessageDelta { text: format!("a {s}") }),
            EventBody::MessageDelta {
                text: format!("a {red}")
            }
        );
        assert_eq!(
            r.redact_event(EventBody::MessageAssistant {
                text: format!("key {s}")
            }),
            EventBody::MessageAssistant {
                text: format!("key {red}")
            }
        );
        assert_eq!(
            r.redact_event(EventBody::ToolCall {
                call_id: "c1".into(),
                tool: "Bash".into(),
                title: format!("run {s}"),
                input: json!({"command": format!("echo {s}")}),
            }),
            EventBody::ToolCall {
                call_id: "c1".into(),
                tool: "Bash".into(),
                title: format!("run {red}"),
                input: json!({"command": format!("echo {red}")}),
            }
        );
        assert_eq!(
            r.redact_event(EventBody::ToolResult {
                call_id: "c1".into(),
                ok: true,
                output: format!("out {s}"),
            }),
            EventBody::ToolResult {
                call_id: "c1".into(),
                ok: true,
                output: format!("out {red}"),
            }
        );
        assert_eq!(
            r.redact_event(EventBody::Error {
                message: format!("bad {s}")
            }),
            EventBody::Error {
                message: format!("bad {red}")
            }
        );
    }

    #[test]
    fn other_events_pass_through_unchanged() {
        use crate::event::Source;
        let r = Redactor::new([pair("TOKEN", "sk-test-123456")]);
        let body = EventBody::TurnStarted {
            turn_id: "t1".into(),
            source: Source::User,
            reactions_until: None,
        };
        assert_eq!(r.redact_event(body.clone()), body);
    }
}
