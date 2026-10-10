-- MCP servers the owner adds for the agents (see docs/ARCHITECTURE.md#integrations).
-- `args`, `env` and `headers` are JSON: an array, and objects of name to value. A value is a literal or
-- `secret:<name>`, resolved only when an agent session starts. `enabled` 0 keeps the row out of every session.
CREATE TABLE integrations (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('stdio', 'http')),
    command TEXT,
    args TEXT NOT NULL DEFAULT '[]',
    url TEXT,
    env TEXT NOT NULL DEFAULT '{}',
    headers TEXT NOT NULL DEFAULT '{}',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
);
-- The integrations an agent may use: a JSON array of ids. NULL = every enabled one.
ALTER TABLE agents ADD COLUMN integrations TEXT;
