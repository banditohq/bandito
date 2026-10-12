-- Indexes for the store's hot reads, one per statement named in its comment. The plans are checked by
-- daemon/tests/query_plans.rs (docs/ARCHITECTURE.md#store-sqlite). Additive: no table is rewritten.

-- The scheduler tick (every few seconds): enabled schedules whose next run is due (`schedule_due`).
CREATE INDEX IF NOT EXISTS schedules_due ON schedules (enabled, next_run_at);

-- One agent's schedules (`schedule_list` for `schedules.agent.list` and the agent's delete).
CREATE INDEX IF NOT EXISTS schedules_agent ON schedules (agent_id, created_at);

-- Forms by status across agents (`form_list` for `forms.list` without an agent), as `approvals_status`.
CREATE INDEX IF NOT EXISTS forms_status ON forms (status, created_at);

-- Start-up check of queued user messages (`queued_messages_unresolved`). Partial: only the queued rows are indexed.
CREATE INDEX IF NOT EXISTS events_queued_user ON events (kind, seq)
    WHERE kind = 'message.user' AND json_extract(payload, '$.queued') = 1;

-- Start-up check of connect requests (`connect_requests_unresolved`). Partial, as above.
CREATE INDEX IF NOT EXISTS events_integration_requested ON events (kind, seq)
    WHERE kind = 'integration_requested';
