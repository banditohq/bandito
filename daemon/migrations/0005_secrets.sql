-- Migration 0001 already created `secrets(name, value)`, unused. Extend it instead of
-- recreating it. Rows that existed get no agents, so they reach nobody until set again.
ALTER TABLE secrets ADD COLUMN agents TEXT NOT NULL DEFAULT '[]';
ALTER TABLE secrets ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;
ALTER TABLE secrets ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0;
