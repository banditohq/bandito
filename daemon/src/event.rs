//! Normalized agent events. Every runtime adapter translates its own protocol
//! into these; clients render threads from them. See docs/ARCHITECTURE.md#events.

use crate::attachments::Attachment;
use crate::forms::{FormAction, FormField, FormKind};
use crate::mentions::Mention;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

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

/// What happened to an agent's record (see `EventBody::AgentChanged`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentChange {
    Created,
    Updated,
    Deleted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DecidedBy {
    User,
    Policy,
}

/// Who put a reaction on a message.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReactionBy {
    User,
    Agent,
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

/// The subscription an account is on, as the CLI names it: `id` is stable (`max_20x`, `pro`),
/// `label` is for people (`Max ×20`, `Pro`). Holds no credentials.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub id: String,
    pub label: String,
}

/// The typed body of an event. Serialized as `{"kind": "...", "payload": {...}}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "payload")]
pub enum EventBody {
    #[serde(rename = "turn.started")]
    /// `reactions_until`: for a human turn, the moment its reactions were read (see docs/ARCHITECTURE.md#reactions).
    /// The next human turn's reactions start after it.
    TurnStarted {
        turn_id: String,
        source: Source,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reactions_until: Option<i64>,
        /// Seq of the `message.user` this turn answers, when that message was shown before the turn began
        /// (it waited behind a turn, a wrap-up or a pause). Absent when the message is shown right after this event.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message_seq: Option<i64>,
    },
    #[serde(rename = "message.user")]
    MessageUser {
        text: String,
        source: Source,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        from_agent: Option<String>,
        /// Name of the slash command in `text`, when one was recognised (see docs/ARCHITECTURE.md#commands).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        command: Option<String>,
        /// Seq of the message this one replies to (see docs/ARCHITECTURE.md#replies-and-attachments).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reply_to: Option<i64>,
        /// Files attached to the message.
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        attachments: Vec<Attachment>,
        /// `@` mentions in the text: services, teammates, files, browser tabs (see docs/ARCHITECTURE.md#mentions).
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        mentions: Vec<Mention>,
        /// True when the message was shown while it still waits for its turn (the agent was busy, saving its memory
        /// for a new chapter, or paused). The turn that takes it carries its seq in `turn.started.message_seq`.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        queued: bool,
    },
    /// A message shown as waiting (`message.user` with `queued: true`) will not get a turn: the queue was lost
    /// (a crash, a stop, a restart) or the session could not start. `reason`: `crash`, `stopped`, `failed`,
    /// `restart`. The message stays in the thread; a client shows it as not delivered.
    #[serde(rename = "message.dropped")]
    MessageDropped { seq: i64, reason: String },
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
    /// The runtime took the request back (its CLI cancelled it): nobody answered it, so no decision.
    #[serde(rename = "approval.withdrawn")]
    ApprovalWithdrawn { approval_id: String },
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
    /// The agent moved to another runtime: its fallback when the primary one ran out of
    /// usage, or back to the primary one when its limit reset. `until` is when the limit
    /// resets (Unix seconds), if known.
    #[serde(rename = "runtime.switched")]
    RuntimeSwitched {
        from: String,
        to: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        until: Option<i64>,
    },
    #[serde(rename = "usage.limits")]
    UsageLimits { runtime: String, windows: Vec<LimitWindow> },
    /// An agent's record was created, changed or deleted. The event tells every client to re-read
    /// its agent list, since the change may come from another client or from a path with no reply.
    #[serde(rename = "agent_changed")]
    AgentChanged { action: AgentChange },
    /// The agent asked the human for an answer (see docs/ARCHITECTURE.md#forms). The rest of the payload is
    /// the form as checked by `forms::parse_spec`.
    #[serde(rename = "form_requested")]
    FormRequested {
        form_id: String,
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        intro: Option<String>,
        kind: FormKind,
        fields: Vec<FormField>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        submit_label: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reject_label: Option<String>,
    },
    /// The form ended: submitted, rejected, or expired (never answered in time, or the turn was cancelled).
    #[serde(rename = "form_answered")]
    FormAnswered {
        form_id: String,
        action: FormAction,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        values: Option<Map<String, Value>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment: Option<String>,
    },
    /// A reaction on a message, by seq. No `emoji` means the reaction was taken off.
    #[serde(rename = "reaction")]
    Reaction {
        seq: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        emoji: Option<String>,
        by: ReactionBy,
    },
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
    fn withdrawn_approval_event_names_only_the_approval() {
        // The CLI took the request back: no decision, so no `decision` or `by` field.
        let body = EventBody::ApprovalWithdrawn {
            approval_id: "a1".into(),
        };
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({"kind": "approval.withdrawn", "payload": {"approval_id": "a1"}})
        );
        let back: EventBody = serde_json::from_value(serde_json::to_value(&body).unwrap()).unwrap();
        assert_eq!(back, body);
    }

    #[test]
    fn agent_changed_names_the_action() {
        let body = EventBody::AgentChanged {
            action: AgentChange::Deleted,
        };
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({"kind": "agent_changed", "payload": {"action": "deleted"}})
        );
        let (kind, payload) = body.to_parts();
        assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), body);
    }

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
