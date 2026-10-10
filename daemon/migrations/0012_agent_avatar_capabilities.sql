-- The agent's avatar: tile color and face. NULL (both) = the app derives them from the name.
-- The capabilities the agent may use: a JSON array of `terminal`, `files`, `browser`, `team`, `screen`.
-- NULL = all of them (see docs/ARCHITECTURE.md#capabilities).
ALTER TABLE agents ADD COLUMN avatar_color TEXT;
ALTER TABLE agents ADD COLUMN avatar_face TEXT;
ALTER TABLE agents ADD COLUMN capabilities TEXT;
