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
  server left (sent to phones), 4008 monthly traffic limit (checked at 95%), 4009 message over 1 MiB or any text but
  `ping`/`pong`, 4010 too many messages (200/s per phone socket, 2000/s per server socket), 4011 a phone stream sent no
  binary frame within 15 s of opening. Before the upgrade: 401 bad
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
  daemon is authenticated by `nk`; the phone's key is new), sends `{"pair": true}`, then `pair.redeem`. The phone's key
  is the one the handshake proved: `noise_key` may be left out, and when given it must equal that key (else
  INVALID_PARAMS «noise_key does not match the session»). The daemon's anonymous limits apply with source = the `ip`
  from `open`; an `open` without a usable `ip` is refused.
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

## One account on every device: servers follow you

Signing in to the same bandito.dev account on the iPhone shows the servers added on the Mac, and a server added on the
phone appears on the Mac. Built on the existing end-to-end encrypted sync (`docs/ACCOUNTS_API.md`: device approval,
sync key envelopes, `SyncPayload` in BanditoKit — shared by both apps).

- **iPhone sign-in**: the same flows as the Mac (GitHub device flow, email code) from Settings → Account and from the
  onboarding («У меня есть аккаунт»). A new phone is approved on the Mac by comparing the code, as for a new Mac.
- **What syncs per server** (`SyncedServer`): besides today's endpoint, an optional `phone` record
  `{sid?, relay_host?, nk?, fp?, hosts[]}` — how any device can reach the daemon without SSH. Written by whichever
  device turns relay or direct access on. Device tokens are **never** in the shared blob.
- **Access is issued, not copied.** Each device needs its own device token from each daemon. A device that sees a
  server it has no token for adds a request to the blob: `access_requests: [{device_id, server_id, noise_key, at}]`.
  Any approved device that is connected to that daemon (the Mac over SSH, or a phone already paired) answers it:
  daemon RPC `devices.issue {name, platform, noise_key}` (owner peers only) returns a fresh device token for a new
  device row; the answering device seals it with HPKE to the requesting device's account public key (the same suite as
  sync key envelopes, info `bandito-device-token:v1`, AAD `<accountID>:<requestingDeviceID>:<serverID>`) and writes
  `access_grants: [{device_id, server_id, sealed, at}]`. The requester opens it, stores the token in its Keychain,
  connects (direct or relay), and removes its request and grant from the blob. Requests older than 7 days are dropped.
- So: sign in on the phone → approve it on the Mac → within seconds (while the Mac is online) every server with relay
  or direct access appears and connects. A server added on the phone by QR syncs to the Mac the same way (the phone
  answers the Mac's request).
- Revoking a device in the account removes it from the account; the Mac then also revokes its device rows on the
  servers it can reach (`devices.revoke`), so a lost phone loses access everywhere.

**As built** (BanditoKit `Account/Access`, daemon `devices.issue` and `phone.info`, see docs/ARCHITECTURE.md):

- The wire names are snake_case: `phone`, `access_requests`, `access_grants`, `device_id`, `server_id`, `noise_key`, `relay_host`.
  A request also carries `public_key`: the asking device's X25519 key. The answering device issues only if that key is the
  `public_key` that `GET /me` lists for the same device id (and the device is approved). An account service that lists no
  keys (an older one) gets no answers; the app logs that the service needs updating. A blob without the new fields reads
  as before, and fields a build does not know are kept when it writes the blob back.
- The sealed message is `0x01 || sender_pub (32) || enc (32) || ct`, base64, HPKE auth mode (`DeviceTokenSeal`). The
  requester opens it with its own key, for its own device id and server id; when `GET /me` lists device keys the sender
  must be one of them.
- A merge keeps the newest request and grant per device and server and drops entries older than 7 days. Removing an
  answered request is done on a fresh copy of the blob (`SyncStore.update` reads, changes and writes again on a version
  conflict), so a merge cannot bring it back. The answering device remembers on its own what it issued
  (`AccessLedger`): a request that comes back is not answered twice, a grant that could not be written is written by the
  next cycle without a second token, and the daemon's row id of every issue is kept for revocation.
- The Mac runs the answering side every 30 seconds with its connected servers, and writes `phone` for the servers whose
  daemon says it has a way in (`phone.info`: relay on, or a phone listener up). At most one issue per device and server
  in ten minutes, and a daemon holds at most 50 device rows (`devices.issue` says so). Before an issue the blob is read
  again and the request is skipped if another Mac answered; a grant never overwrites another device's grant for the same
  request, and a row whose grant did not stand is revoked at once.
- Revoking: every cycle compares the rows this device issued (its ledger) with the account's device list. A row issued
  to a device that is no longer in the account, or not approved, is revoked by the row id the ledger kept and forgotten
  (`devices.revoke`), whoever removed the device and however (another Mac, the device itself, an account reset). A
  device never revokes a row it did not issue and never looks rows up by name; with several Macs each one cleans its own.
  Servers that are offline are cleaned when they come back.
- The iPhone runs the asking side (`AccessRequester`) while the app is in front: every 10 seconds while a server waits,
  every minute otherwise. A token it receives goes to a `ServerAccessSink`; the connection itself is the relay and direct
  transports' job.

**Glue between the two apps** (one server, one entry; `PhoneEndpoint.swift`, `MacAccessSink`, `AccountAccessSink`):

- A server added by a link on a device (QR on the iPhone) is published as a `SyncedServer` with endpoint `.local(deviceID:)` of
  the device that added it (so a build that does not know the entry still reads the blob) and a `phone` record made from its
  endpoint (`SyncedPhone(endpoint:)`). Device tokens and Noise private keys are never in it.
- The id of a server is the id of its first entry. A device that receives an access builds the server **with that id** (and the
  Noise key it made for the request); the iPhone adds it to `ServerSession` and the Mac to its list, and both connect at once
  (`ServerAccess.serverConfig`). `hasAccess(serverID:phone:)` also answers true when the device holds the **same daemon**
  under another id: the same Noise key or certificate, and no key that differs. That is how a server paired by QR on the phone
  before the account knew it is not asked for again, and how the Mac's own ssh server (whose daemon says its `phone.info`)
  is not asked for from the Mac.
- Two entries of one daemon collapse when the blob is merged (`SyncPayload.merged`): ssh, then a WebSocket address, then a
  link-paired entry stays, the lower id among equals, and it keeps the way in the other knew. The same certificate behind
  another Noise key is another server: pairing it is refused on the iPhone (`differentServer`), never a replacement.
- The iPhone answers the account's requests for the servers it is connected to (`AccessResponder`, over the relay or
  direct as the device it is), and publishes what it was paired with; the Mac asks for the servers of the account it lacks
  (`AccessRequester`, every 30 s with the cycle). A server the person disconnected on the iPhone is remembered
  (`ServerSession.dismissed`) and not asked for again.
- A daemon can take a plain `ws://127.0.0.1` relay for tests only: the environment variable
  `BANDITO_RELAY_ALLOW_LOOPBACK_PLAIN` of the daemon process (never a request); any other plain address is refused.

**Residual risk.** A device removed from the account still holds the sync key: the key is not rotated on removal. It
cannot write the blob or read a newer one without a session of the account, and its session ends with the removal. Its
access to the servers is revoked by the rule above on the next cycle of any Mac that issued it.
