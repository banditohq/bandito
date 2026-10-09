-- Paused agents: messages are kept in the history but no session starts, and scheduled runs
-- are skipped (see docs/ARCHITECTURE.md#pause).
ALTER TABLE agents ADD COLUMN paused INTEGER NOT NULL DEFAULT 0;
