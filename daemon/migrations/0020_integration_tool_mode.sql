-- What an integration's tools may do (see docs/ARCHITECTURE.md#tool-permissions): `all` runs them as the approval
-- mode says, `read_only` refuses the tools that change things, `confirm_writes` asks the owner before each of them.
-- `tool_overrides` is a JSON object of tool name to `allow`, `ask` or `deny`. Existing rows keep `all`.
ALTER TABLE integrations ADD COLUMN tool_mode TEXT NOT NULL DEFAULT 'all' CHECK (tool_mode IN ('all', 'read_only', 'confirm_writes'));
ALTER TABLE integrations ADD COLUMN tool_overrides TEXT NOT NULL DEFAULT '{}';
