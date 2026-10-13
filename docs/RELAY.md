# Bandito Relay — phone to server from anywhere

The third way for the iPhone (and later any device) to reach a daemon, next to Tailscale and the local network: through
Bandito's cloud. The server may be in another country behind NAT, the phone on mobile data; nothing is opened on the
server and nothing needs configuring. **The relay only forwards opaque bytes**: the phone and the daemon run an
end-to-end encrypted session (Noise) through it, so the relay never sees commands, replies, files or tokens.

## Pieces

| Piece | Where | Does |
|---|---|---|
| Relay service | `banditohq/platform`, `relay/` — its own Worker `bandito-relay` on `relay.bandito.dev`, one Durable Object per server | Holds the server's outbound WebSocket, accepts phone WebSockets, forwards frames between them; registration API; limits |
| Daemon relay client | `daemon/src/relay.rs` | Keeps one outbound WebSocket to the relay while relay mode is on; answers each phone stream with a Noise responder; feeds decrypted frames to the normal RPC handler as the device |
| Phone transport | BanditoKit `Connect/RelayTransport.swift` | WebSocket to the relay, Noise initiator, then the same RPC frames as `DirectTransport` |
| Mac | server settings → iPhone; profile → Devices → «Подключить iPhone» | Turns relay mode on (one click when signed in), shows the QR |

## Identity and keys

- **Server relay id** `sid`: 128-bit random, base32 (26 chars, lower case). Made by the relay at registration.
- **Server relay secret** `rs`: 256-bit random. Only its SHA-256 is stored at the relay. Kept by the daemon in
  `<data_home>/relay.json` (mode 0600) with `sid` and the relay URL.
- **Daemon Noise static key**: X25519, made once, `<data_home>/noise.key` (0600). Its public key `nk` (32 bytes,
  base64url without padding) goes into the pairing link. It is pinned like the TLS fingerprint.
- **Phone Noise static key**: X25519, made at pairing on the phone, kept in the Keychain next to the device token.
  Sent at `pair.redeem` (new optional field `noise_key`) and stored on the device row; the daemon accepts relay streams
  only from a known phone key, and the device token is still required inside the session.

## Registration (Mac, signed in to a bandito.dev account)

1. Mac → platform `POST https://bandito.dev/api/v1/relay/servers` with the account bearer token, body
   `{name}` → `{sid, secret, relay_url}`. At most 10 servers per account. `DELETE /api/v1/relay/servers/:sid` removes.
   `GET /api/v1/relay/servers` lists `{sid, name, created_at, online, last_seen_at}`.
2. Mac → daemon RPC `relay.enable {relay_url, sid, secret}` (owner peers only: Local or a device; never an agent). The
   daemon saves `relay.json`, makes the Noise key if missing, connects. `relay.disable {}` stops and forgets (the Mac
   also deletes the registration). `relay.status` → `{enabled, connected, sid, relay_url, last_error}`.
3. The server settings «Доступ с телефона» gains the mode **Через облако Bandito** (recommended, default in the wizard).
   Modes stay independent: relay can be on together with Tailscale/LAN; the pairing link lists every way.

## Wire protocol (relay)

- Daemon: `GET wss://relay.bandito.dev/v1/server/<sid>` with `Authorization: Bearer <secret>`. One connection per sid;
  a new one replaces the old (the old gets close 4001). Binary frames: `[u32 BE stream_id][u8 kind][payload]`, kind
  0 = data, 1 = open (payload: JSON `{"ip": "<client ip>", "v": 1}`), 2 = close. Keepalive is a **text** message
  `ping` answered by the text `pong` (a Worker cannot see WebSocket ping frames): the relay answers `ping` itself and
  sends `ping` to both sides every 25 s; both the daemon and the phone answer `pong` and send their own `ping` every
  25 s; 60 s of silence closes with 4002.
- Close codes: 4001 replaced by a newer server connection, 4002 silence timeout, 4003 registration deleted, 4004 the
  server left (sent to phones), 4008 monthly traffic limit, 4009 message over 1 MiB. Before the upgrade: 401 bad
  secret, 503 `{"error":"offline"}` (server not connected or unknown sid), 429 `{"error":"too_many_streams"}` or
  `{"error":"rate"}`.
- Phone: `GET wss://relay.bandito.dev/v1/client/<sid>` (no auth at the relay: the Noise session is the auth). If the
  server is not connected: HTTP 503 `{"error":"offline"}` before the upgrade. The relay gives the stream an id, sends
  `open` to the server, then forwards each binary message of the phone as `data`, and the server's `data` for that id
  to the phone; either side closing sends `close`.
- Limits (relay): 16 open streams per sid, 1 MiB per message, 60 new client connections per minute per IP and per sid,
  monthly traffic per account 20 GB (counted per server in the Durable Object, summed per account in D1 hourly);
  over → close 4008 with a reason the apps show. The registration API needs an approved device of the account and allows 20
  registrations an hour.

## Session protocol (phone ↔ daemon, inside a relay stream)

- `Noise_IK_25519_ChaChaPoly_SHA256`, prologue `bandito-relay-v1`. Initiator = phone (knows `nk`), responder = daemon.
  Message 1 (→): handshake with the phone static key; payload JSON `{"v":1}`. Message 2 (←): handshake; payload
  `{"v":1}`. Then transport messages, one per relay data frame, max 65535 bytes of ciphertext; larger RPC frames are
  split as `[u8 more][chunk]` and joined.
- After the handshake the phone sends `{"auth": "<device token>"}` (or `{"pair": true}` for a first pairing, see below);
  the daemon checks it like the `Authorization` header of a direct connection, and that the phone static key matches
  the device's `noise_key`. Then the stream carries exactly the JSON-RPC text frames of `/v1/rpc`.
- **Pairing through the relay**: the link has `relay` and `nk`; the phone opens a stream, completes Noise IK (the
  daemon is authenticated by `nk`; the phone's key is new), sends `{"pair": true}`, then `pair.redeem` with
  `noise_key` = its static public key. The daemon's anonymous limits apply with source = the `ip` from `open`.
- v1 carries RPC only. Files, previews, tunnels and screens over the relay come later (stream kinds reserved).

## Pairing link

`bandito://pair?v=1&code=…&fp=…&name=…&host=…&host=…&relay=<relay host>/<sid>&nk=<base64url>` — `relay` and `nk` are
present when relay mode is on; `host` entries may be absent (relay only). The phone tries direct hosts first (fast on
the same network), then the relay.

## Failure and safety rules

- The relay never logs payloads; it logs sid, sizes, close codes.
- A compromised relay can drop or delay traffic, not read or forge it (Noise IK with the pinned `nk`; replays fail on
  the Noise nonce).
- Revoking a device closes its relay streams too (the device cancel token of `phone.rs`).
- `relay.disable` closes the outbound connection and every stream at once.
- Deleting the account deletes its relay registrations.
