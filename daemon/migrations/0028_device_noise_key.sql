-- The Noise static public key of a paired phone (base64url, 32 bytes), sent at `pair.redeem` when the phone pairs through
-- the relay (docs/RELAY.md). A relay stream is accepted only from the key of the device whose token it carries. NULL for
-- devices paired before, or without a key: they cannot use the relay. Additive: no table is rewritten.
ALTER TABLE devices ADD COLUMN noise_key TEXT;
