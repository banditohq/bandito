-- The team's per-agent reads take the newest event of one kind, and the agent's pending approvals:
-- one index lookup each (see docs/ARCHITECTURE.md#team-preview).
CREATE INDEX events_agent_kind_seq ON events(agent_id, kind, seq);
CREATE INDEX approvals_agent_status ON approvals(agent_id, status);
