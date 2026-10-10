-- Forms an agent asks the human for (`ask_form`): the checked spec, the status (pending|submitted|rejected|expired),
-- and the answer as `{action, values?, comment?}`. See docs/ARCHITECTURE.md#forms.
CREATE TABLE forms (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    spec TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    answer TEXT,
    created_at INTEGER NOT NULL,
    answered_at INTEGER
);
CREATE INDEX forms_agent_status ON forms(agent_id, status);

-- Reactions on messages, by seq of the message event. `by` is user or agent: one reaction of each per message.
-- See docs/ARCHITECTURE.md#reactions.
CREATE TABLE reactions (
    agent_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    by TEXT NOT NULL,
    emoji TEXT NOT NULL,
    at INTEGER NOT NULL,
    PRIMARY KEY (agent_id, seq, by)
);
CREATE INDEX reactions_agent_by_at ON reactions(agent_id, by, at);
