-- Whether an agent's CLI loads the owner's own Claude settings (user scope: their CLAUDE.md, hooks, plugins, MCP).
-- Off by default: the agent sees its project and local settings only (see docs/ARCHITECTURE.md#personal-settings).
ALTER TABLE agents ADD COLUMN use_personal_settings INTEGER NOT NULL DEFAULT 0;
