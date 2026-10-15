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

/// How a connect request ended (see `EventBody::IntegrationRequestEnded`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConnectEnd {
    Connected,
    Declined,
    Expired,
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

/// One quick-reply button: the label on it, and the text sent as the person's message when it is pressed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuickButton {
    pub label: String,
    pub reply: String,
}

/// A link button next to the quick replies (https only).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuickLink {
    pub label: String,
    pub url: String,
}

/// "2 of 6" next to the quick replies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuickProgress {
    pub done: u32,
    pub total: u32,
}

/// The schedule that started a scheduled run (see docs/ARCHITECTURE.md#scheduler). `name` is empty when the
/// schedule has no title.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ScheduleRun {
    pub id: String,
    pub name: String,
    /// Unix milliseconds.
    pub fired_at: i64,
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
        /// True when the person sent this by pressing a quick-reply button the agent offered
        /// (see docs/ARCHITECTURE.md#quick-replies); the thread marks it, and so does the agent's prompt.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        via_button: bool,
        /// The schedule that started this message, on a scheduled run. `text` is the prompt the person sees; the
        /// runtime gets a note after it (see docs/ARCHITECTURE.md#scheduler).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        schedule: Option<ScheduleRun>,
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
        /// What the answer is about, for an approval the daemon asks itself (`agent.create`, see
        /// docs/ARCHITECTURE.md#agents-creating-agents); a client draws a card from it. Left out for the runtimes' own.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        input: Option<Value>,
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
    /// The agent ended its turn without a message: it called `nothing_to_report` (see docs/ARCHITECTURE.md#quiet-turns).
    /// Its messages in this turn are hidden, and nothing notifies anyone about the turn.
    #[serde(rename = "turn.quiet")]
    TurnQuiet {
        turn_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
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
    /// The form ended: submitted, rejected, answered with a message, or expired (never answered in time, or the turn was cancelled).
    #[serde(rename = "form_answered")]
    FormAnswered {
        form_id: String,
        action: FormAction,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        values: Option<Map<String, Value>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        comment: Option<String>,
        /// The person's message, on `reply`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// The agent asked the person to connect a catalog service (see docs/ARCHITECTURE.md#connect-requests).
    #[serde(rename = "integration_requested")]
    IntegrationRequested {
        request_id: String,
        /// The catalog id of the service.
        service: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    /// The request ended: connected, declined, or expired (no answer in time, the call went away, or a restart).
    #[serde(rename = "integration_request_ended")]
    IntegrationRequestEnded {
        request_id: String,
        status: ConnectEnd,
        /// The name of the integration, on `connected`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        integration: Option<String>,
    },
    /// Buttons the agent offers under its last message (the tool `reply_buttons`, see
    /// docs/ARCHITECTURE.md#quick-replies). The newest one replaces the older ones.
    #[serde(rename = "agent.quick_replies")]
    AgentQuickReplies {
        buttons: Vec<QuickButton>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        link: Option<QuickLink>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        progress: Option<QuickProgress>,
    },
    /// In the feed of the agent that created another one (see docs/ARCHITECTURE.md#agents-creating-agents).
    /// `approved_by`: `user` when the person pressed Create on the card, `policy` when the agent runs in `never`.
    #[serde(rename = "agent.spawned")]
    AgentSpawned {
        agent_id: String,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        role: Option<String>,
        runtime: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        approved_by: DecidedBy,
    },
    /// In the feed of the agent that another one created.
    #[serde(rename = "agent.created_by")]
    AgentCreatedBy {
        by_agent_id: String,
        by_name: String,
        approved_by: DecidedBy,
    },
    /// The chat was read to `seq` on one of the owner's devices (`messages.read`). Transient: broadcast with
    /// `seq = 0`, never written to the event log, never wakes the agent, never sends a push. A device applies it to
    /// its unread count and does not send it back.
    #[serde(rename = "read_mark")]
    ReadMark { seq: i64 },
    /// A reaction on a message, by seq. No `emoji` means the reaction was taken off.
    #[serde(rename = "reaction")]
    Reaction {
        seq: i64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        emoji: Option<String>,
        by: ReactionBy,
    },
    /// The Telegram bot's status or chats changed (see docs/ARCHITECTURE.md#telegram). Broadcast only, never stored,
    /// with an empty agent id: the app reads `telegram.status` again.
    #[serde(rename = "telegram.changed")]
    TelegramChanged,
    /// The relay's status changed: switched on or off, connected or not, a new error (see docs/RELAY.md). Broadcast
    /// only, never stored, with an empty agent id: the app reads `relay.status` again.
    #[serde(rename = "relay.changed")]
    RelayChanged,
    /// The owner changed server settings (see docs/ARCHITECTURE.md#server-settings). Broadcast only, never stored,
    /// with an empty agent id. `keys` are the names that changed; the app reads `server.settings_get` again.
    #[serde(rename = "server.settings_changed")]
    ServerSettingsChanged { keys: Vec<String> },
    #[serde(rename = "error")]
    Error { message: String },
}

/// Max bytes of tool output we keep in an event.
pub const TOOL_OUTPUT_LIMIT: usize = 16 * 1024;

impl EventBody {
    /// Streaming deltas and read marks are broadcast but not written to the store.
    pub fn is_persisted(&self) -> bool {
        !matches!(
            self,
            EventBody::MessageDelta { .. }
                | EventBody::ReadMark { .. }
                | EventBody::TelegramChanged
                | EventBody::RelayChanged
                | EventBody::ServerSettingsChanged { .. }
        )
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
    fn read_mark_is_a_transient_event_on_the_wire() {
        // The same envelope as every event (`kind` + `payload`), never written to the event log.
        let body = EventBody::ReadMark { seq: 42 };
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({"kind": "read_mark", "payload": {"seq": 42}})
        );
        assert!(!body.is_persisted());
        let back: EventBody = serde_json::from_value(serde_json::to_value(&body).unwrap()).unwrap();
        assert_eq!(back, body);
    }

    #[test]
    fn turn_quiet_and_the_schedule_of_a_run_roundtrip() {
        let quiet = EventBody::TurnQuiet {
            turn_id: "t".into(),
            reason: None,
        };
        let v = serde_json::to_value(&quiet).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"kind": "turn.quiet", "payload": {"turn_id": "t"}})
        );
        assert_eq!(serde_json::from_value::<EventBody>(v).unwrap(), quiet);

        let run = EventBody::MessageUser {
            text: "check the mail".into(),
            source: Source::Schedule,
            from_agent: None,
            command: None,
            reply_to: None,
            attachments: Vec::new(),
            mentions: Vec::new(),
            queued: false,
            via_button: false,
            schedule: Some(ScheduleRun {
                id: "s1".into(),
                name: String::new(),
                fired_at: 5,
            }),
        };
        let v = serde_json::to_value(&run).unwrap();
        assert_eq!(
            v["payload"]["schedule"],
            serde_json::json!({"id": "s1", "name": "", "fired_at": 5})
        );
        assert_eq!(serde_json::from_value::<EventBody>(v).unwrap(), run);

        // A message that is not a scheduled run carries no `schedule`.
        let mut plain = run.clone();
        if let EventBody::MessageUser { schedule, .. } = &mut plain {
            *schedule = None;
        }
        assert!(
            serde_json::to_value(&plain).unwrap()["payload"]
                .get("schedule")
                .is_none()
        );
    }

    #[test]
    fn server_settings_changed_names_the_keys_and_is_not_stored() {
        let body = EventBody::ServerSettingsChanged {
            keys: vec!["backup_keep".into()],
        };
        assert!(!body.is_persisted());
        let (kind, payload) = body.to_parts();
        assert_eq!(kind, "server.settings_changed");
        assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), body);
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({"kind": "server.settings_changed", "payload": {"keys": ["backup_keep"]}})
        );
    }

    #[test]
    fn telegram_changed_carries_no_data_and_is_not_stored() {
        let body = EventBody::TelegramChanged;
        assert!(!body.is_persisted());
        let (kind, payload) = body.to_parts();
        assert_eq!(kind, "telegram.changed");
        assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), body);
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({"kind": "telegram.changed"})
        );
    }

    #[test]
    fn relay_changed_carries_no_data_and_is_not_stored() {
        let body = EventBody::RelayChanged;
        assert!(!body.is_persisted());
        let (kind, payload) = body.to_parts();
        assert_eq!(kind, "relay.changed");
        assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), body);
        assert_eq!(
            serde_json::to_value(&body).unwrap(),
            serde_json::json!({"kind": "relay.changed"})
        );
    }

    #[test]
    fn quick_replies_and_the_creation_events_roundtrip() {
        let replies = EventBody::AgentQuickReplies {
            buttons: vec![QuickButton {
                label: "Done".into(),
                reply: "Connected".into(),
            }],
            link: Some(QuickLink {
                label: "Open".into(),
                url: "https://example.com".into(),
            }),
            progress: Some(QuickProgress { done: 2, total: 6 }),
        };
        assert!(replies.is_persisted());
        assert_eq!(
            serde_json::to_value(&replies).unwrap(),
            serde_json::json!({"kind": "agent.quick_replies", "payload": {
                "buttons": [{"label": "Done", "reply": "Connected"}],
                "link": {"label": "Open", "url": "https://example.com"},
                "progress": {"done": 2, "total": 6},
            }})
        );
        let bare = EventBody::AgentQuickReplies {
            buttons: Vec::new(),
            link: None,
            progress: None,
        };
        assert_eq!(
            serde_json::to_value(&bare).unwrap(),
            serde_json::json!({"kind": "agent.quick_replies", "payload": {"buttons": []}})
        );
        let spawned = EventBody::AgentSpawned {
            agent_id: "a2".into(),
            name: "Mailer".into(),
            role: None,
            runtime: "claude".into(),
            model: None,
            approved_by: DecidedBy::User,
        };
        let created_by = EventBody::AgentCreatedBy {
            by_agent_id: "a1".into(),
            by_name: "Forge".into(),
            approved_by: DecidedBy::Policy,
        };
        for body in [replies, bare, spawned, created_by] {
            let (kind, payload) = body.to_parts();
            assert_eq!(EventBody::from_parts(&kind, payload).unwrap(), body);
        }
    }

    #[test]
    fn an_approval_carries_its_input_only_when_it_has_one() {
        let mut body = EventBody::ApprovalRequested {
            approval_id: "p1".into(),
            call_id: "c1".into(),
            tool: "agent.create".into(),
            title: "Create agent".into(),
            command: None,
            diff: None,
            reason: "agent: create".into(),
            input: None,
        };
        assert!(serde_json::to_value(&body).unwrap()["payload"].get("input").is_none());
        if let EventBody::ApprovalRequested { input, .. } = &mut body {
            *input = Some(serde_json::json!({"name": "Mailer"}));
        }
        assert_eq!(
            serde_json::to_value(&body).unwrap()["payload"]["input"],
            serde_json::json!({"name": "Mailer"})
        );
        // An event stored before the field existed still reads.
        let old: EventBody = serde_json::from_value(serde_json::json!({"kind": "approval.requested", "payload": {
            "approval_id": "p", "call_id": "c", "tool": "Bash", "title": "ls", "reason": "r"}}))
        .unwrap();
        assert!(matches!(old, EventBody::ApprovalRequested { input: None, .. }));
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
