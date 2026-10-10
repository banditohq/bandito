-- Avatar extras: an emoji, and a picture kept on disk under `<data>/avatars/` (see docs/ARCHITECTURE.md#capabilities).
-- They belong to the avatar: NULL / 0 while the avatar is NULL (derived from the name).
-- `avatar_image_rev` changes with every new picture, so the app can drop its cache.
ALTER TABLE agents ADD COLUMN avatar_emoji TEXT;
ALTER TABLE agents ADD COLUMN avatar_image INTEGER NOT NULL DEFAULT 0;
ALTER TABLE agents ADD COLUMN avatar_image_rev INTEGER;
