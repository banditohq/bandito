# Accounts API

Base URL: `https://bandito.dev/api/v1` (served by the same Worker as the site, code in `src/api/`).

- JSON in and out. Every response has `cache-control: no-store`.
- Authenticated calls send `Authorization: Bearer <session token>`.
- Success: `{"ok": true, ...}`. Failure: `{"ok": false, "error": "<code>"}`, plus extra fields for some codes (e.g. `version` on `conflict`, `interval` on `slow_down`).
- A request body larger than 300 KB is `413`. Bodies that are not JSON objects are `400`.

## Errors

| HTTP | `error` | Meaning |
|---|---|---|
| 400 | `invalid` | Missing or malformed field: wrong type, bad base64, bad key length, bad platform, bad email, bad code format, weak X25519 key |
| 400 | `bad_json` | Body is not valid JSON |
| 400 | `bad_device_proof` | Nonce unknown, expired or already used, or the Ed25519 signature does not verify |
| 400 | `ip_required` | Client address missing (`cf-connecting-ip`) on `/auth/challenge`, `/auth/github/start`, `/auth/github/poll`, `/auth/email/start` |
| 401 | `unauthorized` | No token, or unknown/expired session |
| 401 | `github_invalid` | GitHub rejected the token obtained through the device flow |
| 401 | `code_invalid` | No unexpired code for this email, or wrong code, or code already used |
| 403 | `device_not_approved` | The session belongs to a device that is waiting for approval |
| 403 | `access_denied` | The user refused the GitHub authorization |
| 403 | `session_too_old` | `POST /account/reset` from a session older than 10 minutes |
| 404 | `not_found` | Unknown path, or a device id that does not belong to the caller |
| 404 | `not_yet` | No key envelope for this device yet |
| 404 | `flow_not_found` | Unknown GitHub flow, or the flow was already completed |
| 405 | `method` | Known path, wrong HTTP method |
| 409 | `conflict` | Sync version mismatch; response includes the current `version` |
| 409 | `already_approved` | Device is already approved |
| 409 | `account_conflict` | GitHub identity does not match the account that owns this email |
| 409 | `key_mismatch` | Known signing key sent with a different public key |
| 409 | `last_device` | Removing the only approved device while the account has other devices or a sync blob; retry with `?force=1` |
| 410 | `expired` | GitHub flow expired (device code lifetime is over) |
| 413 | `too_large` | Body > 300 KB, sync blob > 262144 characters, envelope > 4096 characters |
| 429 | `rate` | Hourly limit reached (challenge, GitHub start, email codes), or the code was guessed wrong too many times |
| 502 | `email_failed` | Resend rejected the message or was unreachable |
| 502 | `github_failed` | GitHub answered with something the flow does not expect |
| 503 | `email_unavailable` | `RESEND_API_KEY` is not configured |
| 503 | `github_unavailable` | GitHub could not be reached |
| 500 | `server` | Unexpected error. Logged by error class only, never with payloads |

## Device identity

A device sends this block with every login (`/auth/github/poll`, `/auth/email/verify`):

```json
{
  "name": "MacBook",
  "platform": "macos",
  "public_key": "<base64, raw X25519 public key, 32 bytes>",
  "signing_key": "<base64, raw Ed25519 public key, 32 bytes>",
  "nonce": "<base64url, from POST /auth/challenge>",
  "signature": "<base64, Ed25519 signature, 64 bytes>"
}
```

- `platform` is one of `macos`, `ios`, `ipados`. `name` is 1–100 characters.
- `public_key` (X25519) receives key envelopes. Zero, small-order and non-canonical X25519 points are rejected (`invalid`).
- `signing_key` (Ed25519) identifies the device. Within one account, a device is the pair (account, `signing_key`).
- `signature` is the Ed25519 signature, made with the private half of `signing_key`, over the UTF-8 bytes of:

  ```
  bandito-login:v1:<nonce>:<public_key>:<signing_key>
  ```

  Each nonce is single use and lives 5 minutes. A failed proof never reaches the account logic.

### `POST /auth/challenge`

Request: `{}`. Response: `{ "ok": true, "nonce": "<base64url, 32 bytes>", "expires_in": 300 }`.

Get a fresh nonce before every login call, including every poll of the GitHub flow. Limit: 60 per client address per hour (`429 rate`). A rejected request does not count.

## Sign-in with GitHub (server-side device flow)

The client never sees a GitHub token. The server runs GitHub's device flow with its client id (`GITHUB_CLIENT_ID`, default `Ov23li70prRt5b8Eauxk`, a public OAuth app id), with scope `read:user user:email`.

1. `POST /auth/github/start` with `{}`. The server asks GitHub for a device code and keeps `device_code` on its side. Limit: 10 per client address per hour (`429 rate`).

   Response:

   ```json
   { "ok": true, "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device",
     "expires_in": 900, "interval": 5, "flow_id": "<base64url, 32 bytes>" }
   ```

   The app shows `user_code` and opens `verification_uri`.

2. `POST /auth/github/poll` with `{ "flow_id": "...", "device": { ... } }` (device block as above, with a fresh nonce). Poll no faster than `interval` seconds.

   | Answer | Meaning | Client |
   |---|---|---|
   | `200 {"ok": false, "error": "pending"}` | User has not confirmed yet | wait `interval`, poll again |
   | `200 {"ok": false, "error": "slow_down", "interval": 10}` | Polling too fast: GitHub asked for it, or this poll came sooner than `interval` seconds after the previous accepted one (GitHub not called) | wait `interval` seconds, then poll again |
   | `410 expired` | Code expired; flow deleted | start again |
   | `403 access_denied` | User refused; flow deleted | show an error |
   | `404 flow_not_found` | Unknown or already completed flow | start again |
   | `400 bad_device_proof` | Nonce or signature problem | get a new challenge, retry |
   | `503 github_unavailable` | GitHub unreachable; flow kept | retry later |
   | `200 {"ok": true, "token", "user", "device"}` | Signed in; flow deleted | store the token |

   `pending` and `slow_down` are HTTP 200 with `ok: false`, not errors: the request itself succeeded. Each poll, including a `slow_down` one, spends its device nonce.

Server-side details of a successful poll: the access token is used once to read `GET /user` and `GET /user/emails`, then discarded. The email is the entry of `/user/emails` with `primary` and `verified` both true. `/user.email` (public profile) is never used. Without the `user:email` scope (`/user/emails` answers 403) the login continues with `email: null` and no linking by email happens.

Account lookup: by GitHub id, then by that email (GitHub is linked to the existing account), otherwise a new account is created. Two concurrent first logins of the same user produce one account.

## Sign-in by email code

### `POST /auth/email/start`

Request: `{ "email": "user@example.com" }`. Response: `{ "ok": true }`, whether or not the account exists.

Sends a 6-digit code (Resend), valid 10 minutes. The request must carry a client IP (`cf-connecting-ip`), otherwise `400 ip_required`. Limits, counted over the last hour including the request itself:

- 5 codes per email. The 6th is `429 rate`.
- 10 codes per client address. IPv4 is keyed by the address, IPv6 by its first /64.

A request over a limit is removed again, so rejected requests do not count.

### `POST /auth/email/verify`

Request: `{ "email": "...", "code": "123456", "device": { ... } }` (device block with a fresh nonce).

Order of checks: device proof first (a bad proof does not touch the code), then the latest unexpired code for the email.

- Each verification attempt is counted atomically before the code is compared. The 5th attempt is the last one: a 6th gets `429 rate`, even with the right code. Concurrent guesses cannot exceed 5 in total.
- Wrong code: `401 code_invalid`.
- Right code: single use. All codes of the email are deleted on success. A second concurrent use gets `401`.

Response on success: the same shape as `/auth/github/poll`.

## Session response

Both sign-in paths return:

```json
{
  "ok": true,
  "token": "<session token, shown once, stored as sha256 on the server>",
  "user": { "id": "...", "email": "...", "name": "...", "github_login": "..." },
  "device": { "id": "...", "approved": true }
}
```

A session lasts 90 days. A device keeps at most 10 sessions; logging in an 11th time drops the oldest session of that device.

### Approval rule

- A device that is new to the account (new `signing_key`) is approved only if the account has no approved device **and** no sync blob. Otherwise it is pending.
- A device that logs in with a known `signing_key` reuses its row: `name`, `platform` and `last_seen_at` are refreshed, a new session is issued, and `approved` is kept. The exception: if the account has no approved device and no sync blob (e.g. after a reset), the device becomes approved.
- The same `signing_key` with a different `public_key` is `409 key_mismatch`. A public key of a device never changes.

## Account and devices

### `POST /auth/logout`

Deletes the current session only. Response: `{ "ok": true }`.

### `GET /me`

Works for any valid session, including devices waiting for approval. A pending device uses it to learn that it has been approved.

```json
{
  "ok": true,
  "user": { "id": "...", "email": "...", "name": "...", "github_login": "..." },
  "device": { "id": "...", "approved": false },
  "devices": [
    { "id": "...", "name": "...", "platform": "macos", "approved": true,
      "created_at": "...", "last_seen_at": "...", "current": false }
  ]
}
```

`last_seen_at` of the session and of the device is written at most once every 10 minutes.

### `GET /devices/pending` (approved device only)

Devices of the same account that are not approved yet:

```json
{ "ok": true, "devices": [ { "id": "...", "name": "...", "platform": "ios", "public_key": "...", "created_at": "..." } ] }
```

### `POST /devices/:id/approve` (approved device only)

The approving device seals the sync key to the target's `public_key` and sends the envelope here.

Request: `{ "envelope": "<base64, at most 4096 characters>" }`.

The target must belong to the same account and must not be approved yet (`404` otherwise; `409 already_approved` if it is). The envelope and `approved = 1` are written in one D1 batch. Response: `{ "ok": true }`.

### `GET /devices/me/envelope` (any valid session)

Used by a pending device after approval to fetch its envelope:

```json
{ "ok": true, "envelope": "<base64>", "from_public_key": "<public key of the approving device>" }
```

Returns `404 not_yet` until another device approves this one.

### `DELETE /devices/:id`

- A device can always remove itself.
- Removing another device of the same account requires the caller to be approved (`403 device_not_approved` otherwise).
- Removes the device, its sessions and its key envelope.

The last-device rule is enforced by one conditional statement inside a transaction, so two concurrent removals cannot leave the account without an approved device:

- Removing the only approved device while the account has other devices (pending ones) or a sync blob gets `409 last_device`. Nothing is deleted.
- `?force=1` confirms the reset. It applies only when the removed device was approved and no approved device remains. The device, its sessions and its envelope are deleted, and so are the account's sync blob and all of its key envelopes. Pending devices that remain stay pending. The next device that logs in becomes the first approved device and creates a new sync key.
- `?force=1` does nothing extra when another approved device exists: the sync data is kept.

Response: `{ "ok": true }`.

### `POST /account/reset` (any valid session, at most 10 minutes old)

Recovery for an account whose key is lost. Request: `{ "confirm": "RESET" }` (any other value is `400 invalid`).

The session must have been created within the last 10 minutes (a fresh sign-in), otherwise `403 session_too_old`. Effects in one transaction:

- deletes the sync blob and all key envelopes of the account;
- deletes all other devices of the account and their sessions;
- makes the calling device approved.

Response: `{ "ok": true, "device": { "id": "...", "approved": true } }`.

## Sync (approved device only)

The server stores one opaque ciphertext blob per account. It never sees the sync key.

### `GET /sync`

```json
{ "ok": true, "version": 3, "blob": "<base64>" }
```

For an account without data: `{ "ok": true, "version": 0, "blob": null }`.

### `PUT /sync`

Request: `{ "version": 3, "blob": "<base64, at most 262144 characters>" }`.

`version` must equal the stored version (`0` for an account without data). On match the server stores the blob with version + 1 and returns `{ "ok": true, "version": 4 }`. On mismatch: `409` with `{ "ok": false, "error": "conflict", "version": <current> }`. The client fetches, merges and retries.

## Encryption model

- The server stores only ciphertext (`sync.blob`) and envelopes (`key_envelopes.envelope`). It cannot read any synced content.
- The sync key is created by the first approved device of an account. That device is approved automatically when the account has no approved device and no sync blob.
- A new device is pending. It has an X25519 key pair (`public_key` is public, the private part stays on the device) and an Ed25519 key pair (`signing_key`). Until approved it cannot read or write sync data.
- An approved device opens the pending device's `public_key`, seals the sync key to it (X25519 envelope) and calls `POST /devices/:id/approve`. The new device fetches the envelope with `GET /devices/me/envelope` and opens it with its private key, which never leaves the device.
- Ed25519 signatures prove that the login comes from the holder of `signing_key`. A stolen session token alone cannot register a new device.
- If every approved device is lost, the sync key is lost too, and the server cannot recover it. Recovery is `POST /account/reset`, which discards the encrypted sync data.

## Limits

| What | Limit |
|---|---|
| Request body | 300 KB (`413`) |
| Sync blob | 262144 characters (`413`) |
| Key envelope | 4096 characters (`413`) |
| Email codes | 5 per email per hour; 10 per client address per hour (`429`); IPv6 by /64 |
| Challenges | 60 per client address per hour (`429`); IPv6 by /64 |
| GitHub flow start | 10 per client address per hour (`429`) |
| GitHub flow poll | one accepted poll per flow `interval` (`slow_down` otherwise) |
| Code attempts | 5 per code, counted atomically (`429`) |
| Code lifetime | 10 minutes |
| Device nonce | 5 minutes, single use |
| GitHub flow | lifetime from GitHub (900 s); `device_code` never leaves the server |
| Sessions | 90 days; at most 10 per device |
| Reset window | session created within the last 10 minutes |
| `last_seen_at` writes | at most once per 10 minutes per session/device |

## Maintenance

A Cron Trigger (`17 * * * *`, see `wrangler.jsonc`) runs `runCleanup` (`src/api/maintenance.ts`). It deletes expired challenges, GitHub flows and sessions; email codes and rate events older than one hour (they are kept for the hourly limits even after they expire).

Rate limits use the `rate_events(key, created_at)` table. The key is the hashed client address with a prefix (`challenge:`, `gh_start:`) or the flow id (`poll:`).

## Configuration

| Name | Kind | Notes |
|---|---|---|
| `RESEND_API_KEY` | secret | `wrangler secret put RESEND_API_KEY`. Without it `/auth/email/start` returns `503`. |
| `EMAIL_FROM` | optional var | Default `Bandito <hello@bandito.dev>`. |
| `GITHUB_CLIENT_ID` | optional var | Default `Ov23li70prRt5b8Eauxk`. The client id of a GitHub OAuth app is public, not a secret. |

Database: apply `migrations/0002_accounts.sql` to the production D1 and to the preview D1 (`bandito-waitlist-preview`). The migration is not applied anywhere yet.
