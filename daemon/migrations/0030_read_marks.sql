-- The seq each agent's chat was read to, on the server, so that every device of the owner shows the same unread state
-- (docs/ARCHITECTURE.md#read-marks). One row per agent; `seq` only moves forward and is cut to the agent's newest event.
-- `updated_ms` is when a device last moved it. The row goes with the agent (delete). Additive: no table is rewritten.
CREATE TABLE read_marks (
    agent_id   TEXT PRIMARY KEY REFERENCES agents(id) ON DELETE CASCADE,
    seq        INTEGER NOT NULL,
    updated_ms INTEGER NOT NULL
);
