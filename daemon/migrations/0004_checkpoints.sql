CREATE TABLE checkpoints (
    id TEXT PRIMARY KEY,
    agent_id TEXT NOT NULL,
    sha TEXT NOT NULL,
    label TEXT NOT NULL,
    kind TEXT NOT NULL,
    turn_id TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX checkpoints_agent ON checkpoints(agent_id, created_at);
