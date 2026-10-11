-- The agent template the bot was made from by `agents.create_from_template` (see docs/ARCHITECTURE.md#agent-templates).
-- NULL for every other agent, so old rows keep working. Only that method sets it; `agents.create|update` never do.
ALTER TABLE agents ADD COLUMN template_id TEXT;
