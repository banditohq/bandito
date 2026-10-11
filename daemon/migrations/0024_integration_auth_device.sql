-- A third way to sign in (see docs/ARCHITECTURE.md#integrations): `device` is the code flow (OAuth Device Flow), whose
-- token the daemon keeps in its secrets like a browser sign-in's. SQLite cannot change a CHECK, so the table is made
-- again with the wider one; nothing refers to it by a foreign key, and every row and column is copied as it was.
CREATE TABLE integrations_new (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    kind TEXT NOT NULL CHECK (kind IN ('stdio', 'http')),
    command TEXT,
    args TEXT NOT NULL DEFAULT '[]',
    url TEXT,
    env TEXT NOT NULL DEFAULT '{}',
    headers TEXT NOT NULL DEFAULT '{}',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    auth TEXT NOT NULL DEFAULT 'none' CHECK (auth IN ('none', 'oauth', 'device')),
    tool_mode TEXT NOT NULL DEFAULT 'all' CHECK (tool_mode IN ('all', 'read_only', 'confirm_writes')),
    tool_overrides TEXT NOT NULL DEFAULT '{}'
);
INSERT INTO integrations_new (id, name, kind, command, args, url, env, headers, enabled, created_at, auth, tool_mode, tool_overrides)
    SELECT id, name, kind, command, args, url, env, headers, enabled, created_at, auth, tool_mode, tool_overrides FROM integrations;
DROP TABLE integrations;
ALTER TABLE integrations_new RENAME TO integrations;
