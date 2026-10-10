-- How an http integration signs in (see docs/ARCHITECTURE.md#integrations): `none` is the headers it holds,
-- `oauth` is a browser sign-in whose tokens the daemon keeps in its secrets.
ALTER TABLE integrations ADD COLUMN auth TEXT NOT NULL DEFAULT 'none' CHECK (auth IN ('none', 'oauth'));
