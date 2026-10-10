-- Call journal: one row per `mcp__<integration>__<tool>` call an agent made (docs/ARCHITECTURE.md#call-journal).
-- Arguments and results are never stored. Self-contained: a table or index that already exists is left as it is.
CREATE TABLE IF NOT EXISTS tool_calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at_ms INTEGER NOT NULL,
    agent_id TEXT NOT NULL,
    integration TEXT NOT NULL,
    tool TEXT NOT NULL,
    duration_ms INTEGER,
    ok INTEGER,
    error TEXT,
    decision TEXT
);
CREATE INDEX IF NOT EXISTS tool_calls_integration_at ON tool_calls (integration, at_ms);
CREATE INDEX IF NOT EXISTS tool_calls_agent_at ON tool_calls (agent_id, at_ms);
