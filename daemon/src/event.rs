//! Normalized agent events. Every runtime adapter translates its own protocol
//! into these; clients render threads from them. See docs/ARCHITECTURE.md#events.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Where a user-side message came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    User,
    Schedule,
    Crew,
    /// Bandito itself, e.g. the hidden wrap-up turn before a new chapter.
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    Idle,
    Working,
    NeedsYou,
    Error,
    Offline,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TurnStatus {
    Ok,
    Error,
    Interrupted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Decision {
    Allow,
    Deny,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecidedBy {
    User,
    Policy,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LimitWindow {
    pub name: String,
    /// 0.0..=1.0
    pub utilization: f64,
    /// Unix seconds.
    pub resets_at: Option<i64>,
}

/// The typed body of an event. Serialized as `{"kind": "...", "payload": {...}}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "payload")]
pub enum EventBody {
    #[serde(rename = "turn.started")]
    TurnStarted { turn_id: String, source: Source },
    #[serde(rename = "message.user")]
    MessageUser {
        text: String,
        source: Source,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from_agent: Option<String>,
    },
    #[serde(rename = "message.assistant")]
    MessageAssistant { text: String },
    /// Streaming chunk. Broadcast only, never stored.
    #[serde(rename = "message.delta")]
    MessageDelta { text: String },
    #[serde(rename = "tool.call")]
    ToolCall {
        call_id: String,
        tool: String,
        title: String,
        input: Value,
    },
    #[serde(rename = "tool.result")]
    ToolResult { call_id: String, ok: bool, output: String },
    #[serde(rename = "approval.requested")]
    ApprovalRequested {
        approval_id: String,
        call_id: String,
        tool: String,
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        diff: Option<String>,
        reason: String,
    },
    #[serde(rename = "approval.resolved")]
    ApprovalResolved {
        approval_id: String,
        decision: Decision,
        by: DecidedBy,
        remember: bool,
    },
    #[serde(rename = "turn.completed")]
    TurnCompleted {
        turn_id: String,
        status: TurnStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        usage: Option<Usage>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cost_usd: Option<f64>,
    },
    #[serde(rename = "agent.status")]
    AgentStatus {
        status: AgentStatus,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    /// The agent's CLI session was closed and the conversation continues in
    /// a fresh one (chapter `chapter`). `context_tokens` is the size of the
    /// closed chapter's context.
    #[serde(rename = "session.rotated")]
    SessionRotated {
        chapter: u32,
        reason: String,
        context_tokens: u64,
    },
    #[serde(rename = "usage.limits")]
    UsageLimits { runtime: String, windows: Vec<LimitWindow> },
    #[serde(rename = "error")]
    Error { message: String },
}

/// Max bytes of tool output we keep in an event.
pub const TOOL_OUTPUT_LIMIT: usize = 16 * 1024;

impl EventBody {
    /// Streaming deltas are broadcast but not written to the store.
    pub fn is_persisted(&self) -> bool {
        !matches!(self, EventBody::MessageDelta { .. })
    }

    /// Split into the `kind` string and the `payload` JSON for storage.
    pub fn to_parts(&self) -> (String, Value) {
        let mut v = serde_json::to_value(self).expect("EventBody serializes");
        let kind = v["kind"].as_str().unwrap_or_default().to_string();
        let payload = v.get_mut("payload").map(Value::take).unwrap_or(Value::Null);
        (kind, payload)
    }

    pub fn from_parts(kind: &str, payload: Value) -> serde_json::Result<Self> {
        serde_json::from_value(serde_json::json!({ "kind": kind, "payload": payload }))
    }
}

/// Cut `s` to at most `max` bytes on a char boundary, marking the cut.
pub fn truncate_output(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… [truncated {} bytes]", &s[..end], s.len() - end)
}

/// A stored (or broadcast) event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Event {
    /// 0 for events that were not persisted (deltas).
    pub seq: i64,
    pub agent_id: String,
    /// Unix milliseconds.
    pub ts: i64,
    #[serde(flatten)]
    pub body: EventBody,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_parts() {
        let b = EventBody::ToolCall {
            call_id: "c1".into(),
            tool: "Bash".into(),
            title: "git push".into(),
            input: serde_json::json!({"command": "git push"}),
        };
        let (kind, payload) = b.to_parts();
        assert_eq!(kind, "tool.call");
        assert_eq!(payload["call_id"], "c1");
        assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), b);
    }

    #[test]
    fn event_flattens() {
        let e = Event {
            seq: 7,
            agent_id: "a".into(),
            ts: 1,
            body: EventBody::AgentStatus {
                status: AgentStatus::NeedsYou,
                detail: None,
            },
        };
        let v = serde_json::to_value(&e).unwrap();
        assert_eq!(v["kind"], "agent.status");
        assert_eq!(v["payload"]["status"], "needs_you");
        assert_eq!(serde_json::from_value::<Event>(v).unwrap(), e);
    }

    #[test]
    fn chapter_events_use_their_wire_names() {
        assert_eq!(serde_json::to_value(Source::System).unwrap(), "system");
        let b = EventBody::SessionRotated {
            chapter: 2,
            reason: "context".into(),
            context_tokens: 130_000,
        };
        let (kind, payload) = b.to_parts();
        assert_eq!(kind, "session.rotated");
        assert_eq!(payload["chapter"], 2);
        assert_eq!(payload["reason"], "context");
        assert_eq!(payload["context_tokens"], 130_000);
        assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), b);
    }

    #[test]
    fn truncates_on_char_boundary() {
        let s = "ж".repeat(10); // 20 bytes
        let t = truncate_output(&s, 5);
        assert!(t.starts_with("жж"));
        assert!(t.contains("truncated 16 bytes"));
        assert_eq!(truncate_output("abc", 5), "abc");
    }
}
