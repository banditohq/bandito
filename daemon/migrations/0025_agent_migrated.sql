-- Where an agent was moved to by `agents.migrate_done` (see docs/ARCHITECTURE.md#agent-migration).
-- Both NULL for every agent that was not moved, so old rows keep working.
ALTER TABLE agents ADD COLUMN migrated_to TEXT;
ALTER TABLE agents ADD COLUMN migrated_at INTEGER;
