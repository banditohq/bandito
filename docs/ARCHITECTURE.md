# Bandito architecture (MVP)

Status: working design, October 2026. This file is the source of truth for the MVP; change it in the same PR as the code.

## Pieces

```
 Mac app (SwiftUI)                 your server
 ┌──────────────┐   transport   ┌──────────────────────────────────────────┐
 │ crew, threads│◀────────────▶│ bandito daemon (Rust, one binary)          │
 │ approvals    │  JSON-RPC 2.0 │  ├─ rpc: unix socket + HTTP/WebSocket     │
 │ schedules    │  over WS      │  ├─ store: SQLite (agents, events, ...)   │
 └──────────────┘               │  ├─ policy: what needs a human            │
                                │  ├─ scheduler: cron → prompts             │
                                │  ├─ crew MCP: agents talk to each other   │
                                │  └─ runtimes ─┬─ claude  (stream-json)    │
                                │               ├─ codex   (app-server)     │
                                │               ├─ grok    (ACP)            │
                                │               └─ api     (own loop)       │
                                └──────────────────────────────────────────┘
```

- The daemon runs as the user who owns the CLI logins (`~/.claude`, `~/.codex`, `~/.grok`), never as root.
- One binary: `bandito daemon` (service), `bandito pair`, `bandito status`, `bandito mcp` (crew MCP over stdio, proxies to the daemon socket), `bandito install-service`.

## Runtimes

Subscription mode drives the official, unmodified CLIs through their own structured stdio protocols. No screen scraping. One child process per agent session.

| Runtime | Command | Protocol | Approvals |
|---|---|---|---|
| Claude Code | `claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio --permission-mode default` | NDJSON; host answers `control_request{subtype:"can_use_tool"}` with `control_response{behavior:"allow"\|"deny"}` | per tool call |
| Codex | `codex app-server --stdio` | JSON-RPC 2.0: `initialize`, `thread/start`, `turn/start`, notifications `item/*`, `turn/completed` | server requests `item/commandExecution/requestApproval`, `item/fileChange/requestApproval` → `{decision:"accept"\|"decline"\|...}` |
| Grok | `grok agent --no-leader stdio` | ACP (JSON-RPC 2.0): `initialize`, `session/new`, `session/prompt`, notifications `session/update` | `session/request_permission` → `{outcome:{outcome:"selected",optionId}}` |
| API keys | built in | Anthropic Messages / OpenAI Responses / xAI, own tool loop (bash, read, write, edit) | same policy engine |

Recorded protocol transcripts live in `daemon/tests/fixtures/`. Adapter tests run against fake CLIs that replay them, so CI needs no logins.

Every adapter turns its protocol into the same internal events (below). Resuming after a daemon restart uses each CLI's own session id (`--resume`, `thread/resume`, `session/load`), stored on the agent.

Useful extras we surface: Claude's `rate_limit_event` and Codex `account/rateLimits/updated` → subscription usage in the app; `runtimes.status` reports installed / version / logged in for each CLI.

## Events

Everything an agent does becomes a row in `events` (append-only, global `seq`). Clients subscribe with `events.subscribe{after}` (live events, backfilled from `after`) and load a thread with `events.page{agent_id, before, limit}` (newest page first, each page oldest to newest). Global `seq` is contiguous on one connection, so a client that sees a jump re-subscribes from its last seq; a laptop that slept for a night catches up exactly.

| kind | payload |
|---|---|
| `turn.started` | `{turn_id, source: "user"\|"schedule"\|"crew"}` |
| `message.user` | `{text, source, from_agent?}` |
| `message.assistant` | `{text}` (final text of a message) |
| `message.delta` | `{text}` streaming chunk, **not persisted**, broadcast only |
| `tool.call` | `{call_id, tool, title, input}` |
| `tool.result` | `{call_id, ok, output}` (output truncated to 16 KB) |
| `approval.requested` | `{approval_id, call_id, tool, title, command?, diff?, reason}` |
| `approval.resolved` | `{approval_id, decision: "allow"\|"deny", by: "user"\|"policy", remember}` |
| `turn.completed` | `{turn_id, status: "ok"\|"error"\|"interrupted", usage?, cost_usd?}` |
| `agent.status` | `{status: "idle"\|"working"\|"needs_you"\|"error"\|"offline", detail?}` |
| `usage.limits` | `{runtime, windows:[{name, utilization, resets_at}]}` |
| `error` | `{message}` |

## Approvals (policy)

Per agent `approval_mode`:

- `risky` (default): the daemon auto-allows routine tool calls and escalates risky ones to the human.
- `always`: every tool call that the CLI asks about goes to the human.
- `never`: auto-allow everything (for sandboxes).

Risky = matches a rule. Built-in rules (editable): `git push*`, `git reset --hard*`, `rm -rf*`, `*deploy*`, `npm publish*`, `cargo publish*`, `kubectl delete*`, `terraform apply*`, `DROP TABLE*`, `prisma migrate deploy*`, writes outside the agent's own folders (its `cwd` and its home folder). Agent rules (`allow` / `ask` / `deny` patterns) win over built-ins. "Always allow here" on an approval adds an `allow` rule to that agent.

A pending approval blocks only that agent. Approvals time out after 24 h → deny.

## Store (SQLite)

- `agents(id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at)`
- `events(seq INTEGER PRIMARY KEY, agent_id, ts, kind, payload JSON)`
- `approvals(id, agent_id, call_id, tool, title, payload JSON, status, decision, created_at, resolved_at)`
- `rules(id, agent_id NULL, pattern, action)`
- `schedules(id, agent_id, cron, tz, prompt, enabled, last_run_at, next_run_at)`
- `devices(id, name, token_hash, created_at, last_seen_at)`; `pairing(code_hash, expires_at)`
- `secrets(name, value)` for API keys, file mode 0600 (keychain/age later)

Migrations: numbered SQL files embedded in the binary, applied by `PRAGMA user_version`.

## RPC

JSON-RPC 2.0. Same methods on every transport.

- Requests: `daemon.info`, `runtimes.status`, `agents.list|get|create|update|delete`, `agents.send{agent_id,text}`, `agents.interrupt`, `events.since{seq,limit,agent_id?}`, `approvals.list|resolve{approval_id,decision,remember}`, `rules.list|set|delete`, `schedules.list|create|update|delete|run_now`, `devices.list|revoke`, `pair.redeem{code,device_name}` (only unauthenticated method), `term.list|open|input|resize|rename|close|attach|detach` (see Terminals), `fs.*` (see [Files](#files)).
- Notifications (server → client): `event{seq, agent_id, kind, payload, ts}` for every event including `message.delta`; `term.output|gap|exit|closed` for attached terminals (see Terminals).

## Transports (connect any way you like)

The daemon always listens on:

1. Unix socket `~/.bandito/bandito.sock` (0600). Trusted: same user.
2. `127.0.0.1:7878` HTTP + WebSocket (`/v1/rpc`, `/v1/health`, `/v1/files/raw`, `/v1/tunnel`). Token required.

WebSocket upgrades that carry an `Origin` header are refused: native apps don't send one, browsers always do, so a web page can't drive the daemon through the user's browser. Unix socket paths are limited to ~104 bytes on macOS, so keep `BANDITO_HOME` short.

Optional: `listen = ["0.0.0.0:7879"]` with TLS (self-signed cert generated on first start; the app pins its SHA-256 fingerprint at pairing).

Pairing: `bandito pair` prints a 6-word code, a QR and a `bandito://pair?...` link (host hints + cert fingerprint). `pair.redeem` swaps the one-time code (10 min) for a device token; the app keeps it in the Keychain. Tokens are stored hashed and can be revoked.

Ways the Mac app reaches a server, all ending in the same WebSocket:

| Method | How |
|---|---|
| This Mac | local socket, no pairing |
| SSH | app runs system `ssh -N -L` (your `~/.ssh/config`, agent, keys, jump hosts); pairing happens over the same SSH session automatically; can also install the daemon for you |
| Tailscale | `ws://<machine>.<tailnet>.ts.net:7878` or `tailscale serve` HTTPS; daemon option `listen = ["tailscale"]` binds to the 100.x address only |
| Direct | host:port, TLS with pinned fingerprint |
| Cloudflare Tunnel, WireGuard/ZeroTier/Netbird, reverse proxy | any URL that ends at the daemon port; token auth |
| Bandito Relay | later: outbound-only connection from the daemon through bandito.dev, end-to-end encrypted |

## Scheduler

Cron expressions with a time zone. On fire: `agents.send` with `source:"schedule"`. Missed runs while the daemon was down run once on start if missed by less than 1 h.

## Crew

`bandito mcp` is an MCP server (stdio) injected into every agent: `--mcp-config` for Claude, `mcp_servers` config for Codex, `mcpServers` in ACP `session/new` for Grok. It answers `initialize` with the client's protocol version when it is one of `2025-06-18`, `2025-03-26`, `2024-11-05`, otherwise with `2025-06-18`. Input lines over 1 MB get a parse error and are skipped.

Tools today: `crew_list` and `crew_send{to, message}` (becomes `message.user` with `source:"crew"` for the target). `report{text}` (shows in the user's inbox) is later, not in the MVP yet. `crew.send` over RPC is accepted only from the local socket, i.e. from the crew MCP servers on the server; paired apps can call `crew.list` only.

Loop guards: every crew message belongs to a chain, which starts with each user or schedule message. The daemon counts three limits:

- depth: a chain stops after 8 hops without a human (`MAX_CREW_HOPS`);
- per turn: one turn sends at most 3 crew messages (`MAX_CREW_SENDS_PER_TURN`);
- per chain: a chain carries at most 20 crew messages in total, across all its turns (`MAX_CREW_MESSAGES_PER_CHAIN`).

A refused `crew_send` comes back to the agent as a tool error that tells it to report to the user. The counters are in memory: a daemon restart resets them, and they are dropped all at once when more than 10 000 chains are tracked. A crew message sent while the agent has no running turn is not counted against the per-turn limit.

These limits stop accidental loops. They are not a security boundary: an agent with shell access runs as your user and can do anything you can.

## Terminals

Persistent shells and programs on the server, PTY-backed, like a tmux-lite. A terminal keeps running while no app is attached. Unix only. `daemon/src/terminal.rs` is the engine; `daemon/src/rpc/term.rs` is the RPC layer.

A terminal runs as the daemon's user, so a paired app can do anything that user can. Anonymous connections get `UNAUTHORIZED`.

Methods:

- `term.list {}` → `[TermInfo]`, oldest first.
- `term.open {cwd?, command?: [string], title?, cols, rows, env?: {string:string}}` → `TermInfo`. `cwd` defaults to the home folder; `~` and `~/…` expand; anything else must be an absolute, existing folder (else `INVALID_PARAMS`). `command` defaults to the user's login shell. `cols` and `rows` are 1..=1000.
- `term.input {id, data}` → `{}`. `data` is base64, at most 64 KiB decoded.
- `term.resize {id, cols, rows}` → `TermInfo`; `term.rename {id, title}` → `TermInfo`.
- `term.close {id}` → `{}`. Hangs up the process group: SIGHUP, then SIGKILL after 2 s.
- `term.attach {id, from?}` → `{info, start, data}`. Subscribes this connection to the terminal's output. `data` is base64 output from `start` to the current offset; `start` is `from` (or the oldest byte still kept, if `from` is older). Attaching again only resets the connection's expected offset.
- `term.detach {id}` → `{}`. The terminal keeps running; its output goes on into the scrollback.

Notifications, sent on the connection that attached (every one has `id`):

| method | params | meaning |
|---|---|---|
| `term.output` | `{id, offset, data}` | base64 bytes that start at byte `offset` of the terminal's output |
| `term.gap` | `{id, lost}` | `lost` bytes were not delivered (scrollback overflow, or the connection lagged); sent just before the output that follows |
| `term.exit` | `{id, code, signal}` | the program ended; `code` or `signal` is null |
| `term.closed` | `{id}` | the terminal was closed; the connection is no longer attached to it |

Offsets: each terminal counts its output bytes from 0 and never resets. A client remembers the offset just past the last byte it has; `term.attach {from}` continues from there. A connection that goes away detaches from all its terminals, which keeps running. An app that collapses a terminal sends `term.detach`; to show it again it sends `term.attach` with the stored offset.

Limits: 16 live terminals (an exited one keeps its slot until closed); 512 KiB of output history per terminal; 64 KiB per `term.input`. An input that cannot be written within 5 s fails with `busy`, and a prefix of it may already have been written.

Environment: a terminal gets only a whitelist of the daemon's variables (`PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `SHELL`, `TZ`, `TMPDIR`, `XDG_RUNTIME_DIR`) plus the `env` given to `term.open`. The daemon's secrets (API keys, tokens) never reach a terminal.

Errors: code `-32021` (`TERM_ERROR`), message `<code>: <text>`, where `<code>` is `too_many`, `not_found`, `invalid_size`, `exited` or `busy`.

When the daemon stops, every terminal is hung up (`TerminalManager::shutdown_all`). Feature string: `"terminals"` in `daemon.info`.
## Files

The app browses and edits files on the server: `fs.*` RPC methods, plus `GET`/`HEAD /v1/files/raw` to stream a file's bytes. Clients show the feature when `daemon.info.features` contains `"files"`.

**Access.** Any paired device can use the file methods and the raw endpoint, with the rights of the user running the daemon. The model is owner-of-the-server: roots are a convenience limit, not a security boundary. `~` is the daemon user's home; other paths must be absolute. A relative path is `invalid_path`.

Params are objects; unknown fields are `invalid_params`.

| method | params | result |
|---|---|---|
| `fs.list` | `path`, `hidden?` (default false) | `Listing {path, parent, entries, truncated, skipped}` |
| `fs.stat` | `path` | `Entry` |
| `fs.read` | `path` | `TextFile {path, content, etag, size, modified_ms, readonly}`; text up to 2 MiB, binary refused |
| `fs.write` | `path`, `content`, `etag?`, `create?` (default false) | `{etag}` |
| `fs.create_file`, `fs.mkdir` | `path` | `Entry` |
| `fs.rename`, `fs.copy` | `from`, `to` | `Entry` |
| `fs.trash` | `path` | `{trashed_to}` |
| `fs.search` | `root`, `query`, `limit?` (1–1000, default 200) | `[Entry]` |
| `fs.projects` | `limit?` (1–200, default 30) | `[ProjectHint]` |
| `fs.upload.begin` | `path` (destination) | `{upload_id}` |
| `fs.upload.append` | `upload_id`, `offset`, `data` (standard base64) | `{written}` |
| `fs.upload.commit` | `upload_id`, `overwrite?` (default false) | `Entry` |
| `fs.upload.abort` | `upload_id` | `{}` |

**Writing.** Overwriting an existing file needs the `etag` from the last `fs.read`. Without it, or with a stale one, the write is refused with `conflict`, and `error.data.etag` holds the current etag. `create: true` without an etag makes a new file and gives `exists` if the path is taken. `etag` on a missing file gives `not_found`.

**Errors.** File failures use code `-32020` and `error.data.reason`: `not_found`, `exists`, `not_a_directory`, `is_a_directory`, `not_a_file`, `permission_denied`, `too_large` (`size`, `limit`), `binary`, `conflict` (`etag`), `invalid_path`, `outside_roots`, `cross_device`, `io`. Bad params are `-32602`.

**Upload in chunks.** `begin` creates a temp file next to the destination. Each `append` must send `offset` equal to the bytes already written; a chunk is at most 1 MiB decoded, and the total at most 4 GiB. One WebSocket message may be up to 4 MiB, so a full 1 MiB chunk fits after base64. `commit` moves the file into place (`overwrite: false` gives `exists`). An upload idle for an hour is removed with its temp file (checked every 10 minutes). `abort` removes it at once.

**Raw download.** `GET` or `HEAD /v1/files/raw?path=<percent-encoded>` (encode `+` as `%2B`; the query is form-decoded). Needs `Authorization: Bearer`: no token or an unknown one is 401, and an `Origin` header is 403. Errors: 400 for an invalid path, a folder or a non-regular file; 403 outside roots or no permission; 404 when missing. The body is streamed from the file.

- `Range`: one `bytes=a-b`, `bytes=a-` or `bytes=-n` gives 206 with `Content-Range`. A range outside the file, a reversed range, or several ranges gives 416 with `Content-Range: bytes */size`.
- `Content-Type` by extension: video, audio, image and PDF types as usual; text, markdown, code and config files as `text/plain; charset=utf-8`; SVG and HTML are never served as markup; anything else is `application/octet-stream`.
- Always: `ETag: "<size>-<mtime_ms>"`, `Accept-Ranges: bytes`, `Cache-Control: private, no-cache`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: sandbox`, `Content-Disposition: inline; filename*=UTF-8''<name>`.

## Tunnel

`GET /v1/tunnel?port=<1..=65535>` is a WebSocket that carries one TCP connection to `127.0.0.1:<port>` on the server. It lets the app reach what agents start on the server, such as a dev server on `localhost:3000`. Later it carries the server's screen (VNC) and a browser's DevTools port (CDP). The client listens on a local port of its own and sends the traffic through this socket: a WKWebView points at the local port, a VNC viewer connects to it.

**Access.** Same as the file routes: a paired device only. Without `Authorization: Bearer` the upgrade is 401, and so is an unknown or revoked token. An `Origin` header is 403. Checks run before the upgrade, so a refusal is a plain HTTP response.

**Target.** The loopback interface only. The only parameter is `port`: no host, no path, so the route cannot reach other machines (no SSRF). The daemon tries `127.0.0.1:<port>`, then `[::1]:<port>`, with 5 s to connect. If neither accepts, the socket closes with code 1011 and reason `connect failed`. A missing `port`, or one outside 1..=65535, is 400 before the upgrade.

**Frames.** The tunnel is a byte stream. Binary WebSocket messages go to the target as they are, and the target's bytes come back in binary messages of up to 64 KiB, so one message does not map to one TCP read. A text message from the client is ignored. A message over 1 MiB closes the tunnel. Ping and pong work as in axum by default.

**Close.** When either side closes or fails, the daemon shuts down the TCP write side and closes the WebSocket with code 1000. The target closing ends the WebSocket the same way.

**Limits.** At most 64 live tunnels per device. The 65th upgrade gets 429 before the upgrade. A slot is freed when its tunnel ends, whichever side ended it.

Feature string: `"tunnel"` in `daemon.info`.

## Mac app

SwiftUI, macOS 14+. Sidebar: servers → crew. Thread view rendered from events; approval cards with Approve / Deny / Always; schedules; connection wizard. Menu bar item with the status dot. Local notifications with Approve / Deny actions while the app runs. Strings in a String Catalog, 9 languages. Colors from `brand/tokens/dist`.

## Repo layout

```
daemon/            Rust crate `bandito`
  src/main.rs      CLI entry
  src/rpc/         JSON-RPC, transports, auth, pairing
  src/store/       SQLite + migrations
  src/runtime/     process.rs (shared child-process plumbing), claude.rs, codex.rs, grok.rs, api/
  src/policy.rs    approval rules
  src/scheduler.rs
  src/crew.rs      MCP server
  tests/fixtures/  recorded protocol transcripts
apps/mac/          Xcode project
scripts/install.sh
```

## MVP milestones

1. Core: store, events, agents CRUD, RPC over unix socket and WebSocket, tokens, pairing.
2. Claude runtime + policy engine.
3. Codex and Grok runtimes.
4. Scheduler + crew MCP.
5. Mac app: connections (local, SSH, Tailscale, direct), crew, thread, approvals, notifications.
6. Install script, systemd/launchd service, release builds; tested on a real Linux box.
7. API-key runtime.

## Extending Bandito (contributions land on every platform)

Bandito is built so a PR adds something once and every client gets it.

**Behavior lives in the daemon.** Policy, scheduling, crew, runtimes, history: all server-side. Clients render state and send intents over RPC, so a new capability is implemented once. `daemon.info` returns `features` (strings like `"schedules"`, `"crew"`); clients show a feature only when the server has it, so new apps work with old daemons and the other way round.

**Apple clients share one core.** `apps/mac/BanditoKit` (Swift package: models, RPC client, thread reducer, server model, design tokens, strings) is used by the Mac app and the future iPhone app. Platform targets hold only views.

**One source of strings.** `i18n/en.json` is the reference; every language is one file next to it (`i18n/ru.json`, …) and is listed in `i18n/languages.json`. Keys are flat and dotted (`thread.approve`). Plurals are objects with CLDR categories (`{"one": "…", "other": "…"}`), placeholders are `{name}`; a placeholder named `count` is an integer, any other is text. `i18n/build.py` generates platform files (now: `Localizable.xcstrings` + typed `L10n` accessors in BanditoKit; later Android `strings.xml`, web JSON). CI fails if a language has missing or extra keys, placeholders that differ from English, or generated files that are out of date. A missing translation falls back to English at runtime.

**Protocol is described, not implied.** The daemon's RPC types are the contract; `docs/ARCHITECTURE.md#rpc` lists methods, and types for non-Swift clients will be generated from a JSON Schema exported by the daemon.

## Memory and context (keeping long chats cheap)

A chat with an agent can run for weeks. If one CLI session carried all of it, every message would resend a growing context and cost more each time. Bandito keeps the **conversation** (our event log, shown in the app as one continuous thread) separate from the **session** (what the CLI holds in its context window).

**Chapters.** A session is one chapter of the thread. When a chapter gets long, Bandito closes it and the next message starts a fresh, small session. The user sees one thread with a quiet "New chapter · memory saved" line; nothing is lost.

Per agent `memory_mode`:

| mode | when a new chapter starts | for |
|---|---|---|
| `smart` (default) | context passes `context_budget` tokens (default 120 000), or the first message after 04:00 local when the last turn was yesterday | almost everyone |
| `daily` | every first message after 04:00 local | assistants with daily routines |
| `full` | never; the CLI compacts on its own | short projects, debugging one long task |

Before a chapter closes, the daemon sends a wrap-up turn shown in the thread as a quiet line (`source: "system"`), excluded from history search: *update your memory files with what matters from this chapter*. Then the session is dropped and `session.rotated` is emitted. The check runs when the next message arrives, so an idle agent costs nothing, and that message waits while the wrap-up runs. If the CLI session has gone, Bandito resumes it for the wrap-up. If it cannot resume, the chapter closes without a wrap-up and the thread says `memory not saved`.

**Agent home.** Every agent gets its own folder on the server, `~/bandito/agents/<slug>/`, next to (not inside) the project it works on:

```
MEMORY.md        short index, read at the start of every chapter (≤ 200 lines)
notes/<topic>.md details: decisions, how things work, people, preferences
journal/<date>.md one line per finished piece of work
files/           anything the agent makes for itself
```

The agent's instructions (built by the daemon, before the user's own) explain this layout. The CLI is allowed to write there (`--add-dir` for Claude, writable roots for Codex). The user can open, edit or delete these files; they are plain Markdown. The root can be moved with `BANDITO_AGENTS_DIR`, which must be an absolute path (a relative one is ignored with a warning).

**Grok.** Grok does not report context size, so Grok agents start new chapters by day only. Its CLI has no extra-folder flag: the approval policy decides whether the agent may act (allow or ask), and the CLI's own sandbox limits access to the home folder.

**Recall instead of remembering.** The crew MCP server also offers `history_search{query}` and `history_day{date}` over the agent's own past messages in the daemon's database, so an agent looks up what was said weeks ago instead of carrying it.

**Changing an agent.** `agents.update` applies name, role, model, effort, system prompt, memory mode, context budget and folder from the next session: an idle agent's session is closed at once, a running one when its turn ends. The chapter goes on, except after a folder change, which starts a new chapter (a CLI session is tied to its folder). The approval mode is read on every request and needs no restart.

**Effort.** Each agent has an `effort` (`low`, `medium`, `high`, `xhigh`, `max`). The daemon maps it to the runtime (`--effort` for Claude, the turn's `effort` for Codex, `--reasoning-effort` for Grok) and refuses levels a runtime does not offer.

**Usage.** Rate-limit windows reported by the CLIs are cached per runtime (`usage.limits`), so the app shows remaining quota even when no turn is running; `usage.refresh` asks runtimes that can be asked (Codex: `account/rateLimits/read`).

**Plan.** The subscription of each runtime's account is cached next to its windows, as `plan: {id, label}` (Claude `max_20x` / «Max ×20», `max_5x` / «Max ×5», `max` / «Max», `pro`; ChatGPT `plus`, `pro`, `team`, …), or `null` when unknown. `usage.refresh` asks for it in the same call as the windows, with the same timeout, and never starts a turn:

- Claude: read from `<config_dir>/.credentials.json`, where `config_dir` is `CLAUDE_CONFIG_DIR` or else `$HOME/.claude`. Only `subscriptionType` and `rateLimitTier` are read. The OAuth tokens in that file are never deserialized, logged or returned. On macOS the CLI keeps its login in the Keychain and writes no file, so the plan stays unknown there.
- Codex: a separate `codex app-server` for `initialize` → `account/read` (`account.planType`).
- Grok and API keys: no plan yet.

A runtime that reports no plan, or fails, leaves the stored plan as it was.

## Accounts, sync and push (planned)

An account is optional: without one the app works on one Mac. With one, every device of the person sees the same servers and agents, and approvals reach the phone.

**Service.** `api.bandito.dev` (Cloudflare Worker + D1, in the private `platform` repo; the protocol is documented here so anyone can run their own). Sign in with Apple, GitHub, or an email link. No passwords.

**What the service stores.** Account (id, email), devices (name, platform, public key, push token), and one **encrypted vault** per account. The vault holds the server list (names, how to reach them) and per-device settings. It is encrypted on the device with a vault key the service never sees.

**Vault key.** Created on the first device and kept in the Keychain. A new device signs in, shows a short code, and an existing device approves it: the existing device encrypts the vault key to the new device's public key (X25519 + XChaCha20-Poly1305). An optional printed recovery key restores the vault if every device is lost; without it the person re-pairs servers, and nothing on the servers is lost.

**Server access per device.** Devices never share daemon tokens. When a device joins, an existing device asks each server for a pairing code (`pair.create`) and passes it through the vault channel; the new device redeems it for its own token. Revoking a device revokes only its tokens.

**Push.** Approvals and finished turns reach phones through `push.bandito.dev`: the daemon sends an end-to-end encrypted payload addressed to device push tokens; a notification service extension decrypts it on the phone. Approve and Deny from the notification call the daemon directly (through whatever connection the phone has: Tailscale, SSH, relay).

**Reaching servers from a phone.** Tailscale and direct TLS work as on the Mac; SSH works through an in-app SSH client; the Bandito Relay (outbound-only, end-to-end encrypted) covers servers behind NAT without any setup.
