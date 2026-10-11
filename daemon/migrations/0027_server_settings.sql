-- The server settings the owner changes from the apps (docs/ARCHITECTURE.md#server-settings). One row per key, value as
-- text. A missing row means the default. Additive: no table is rewritten.
CREATE TABLE IF NOT EXISTS server_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
