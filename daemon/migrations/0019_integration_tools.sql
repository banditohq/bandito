-- The tools an integration's server listed at its last successful probe, with their MCP annotations (see
-- docs/ARCHITECTURE.md#integrations). `input_schema` is the tool's JSON schema, NULL when it was over 32 KB.
-- The rows go with their integration (`integration_delete`).
CREATE TABLE integration_tools (
    integration_id TEXT NOT NULL,
    name TEXT NOT NULL,
    title TEXT,
    description TEXT,
    read_only INTEGER NOT NULL DEFAULT 0,
    destructive INTEGER NOT NULL DEFAULT 0,
    input_schema TEXT,
    seen_at INTEGER NOT NULL,
    PRIMARY KEY (integration_id, name)
);
