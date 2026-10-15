-- Where a paired phone wants push notifications (docs/ARCHITECTURE.md#push). One row per device: `handle` is the
-- address the phone got from bandito.dev, `key` the 32-byte key that encrypts each payload for it (never sent back to
-- any client, never logged), `server_ref` the name the phone gives this server, `kinds` the notification kinds it
-- wants (comma separated: approval, question, done, error, connect). The row goes with the device (revoke).
-- Additive: no table is rewritten.
CREATE TABLE push_targets (
    device_id  TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    handle     TEXT NOT NULL,
    key        BLOB NOT NULL,
    server_ref TEXT NOT NULL,
    kinds      TEXT NOT NULL,
    lang       TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
