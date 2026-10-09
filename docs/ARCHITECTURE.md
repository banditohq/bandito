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
- One binary: `bandito daemon` (foreground), `bandito pair`, `bandito info`, `bandito status`, `bandito mcp` (crew MCP over stdio, proxies to the daemon socket), `bandito service install|uninstall|status` (see [Install and service](#install-and-service)).

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
| `message.user` | `{text, source, from_agent?, command?}` (`text` is what the person typed; `command` names a slash command, see [Commands](#commands)) |
| `message.assistant` | `{text}` (final text of a message) |
| `message.delta` | `{text}` streaming chunk, **not persisted**, broadcast only |
| `tool.call` | `{call_id, tool, title, input}` |
| `tool.result` | `{call_id, ok, output}` (output truncated to 16 KB) |
| `approval.requested` | `{approval_id, call_id, tool, title, command?, diff?, reason}` |
| `approval.resolved` | `{approval_id, decision: "allow"\|"deny", by: "user"\|"policy", remember}` |
| `turn.completed` | `{turn_id, status: "ok"\|"error"\|"interrupted", usage?, cost_usd?}` |
| `agent.status` | `{status: "idle"\|"working"\|"needs_you"\|"error"\|"offline", detail?}` |
| `usage.limits` | `{runtime, windows:[{name, utilization, resets_at}]}` |
| `runtime.switched` | `{from, to, until?}`: the agent moved to another runtime (see [Fallback subscription](#fallback-subscription)); `until` is when the limit resets (Unix seconds), if known |
| `error` | `{message}` |

## Approvals (policy)

Per agent `approval_mode`:

- `risky` (default): the daemon auto-allows routine tool calls and escalates risky ones to the human.
- `always`: every tool call that the CLI asks about goes to the human.
- `never`: auto-allow everything (for sandboxes).

Risky = matches a rule. Built-in rules (editable): `git push*`, `git reset --hard*`, `rm -rf*`, `*deploy*`, `npm publish*`, `cargo publish*`, `kubectl delete*`, `terraform apply*`, `DROP TABLE*`, `prisma migrate deploy*`, writes outside the agent's own folders (its `cwd` and its home folder). Agent rules (`allow` / `ask` / `deny` patterns) win over built-ins. "Always allow here" on an approval adds an `allow` rule to that agent.

A pending approval blocks only that agent. Approvals time out after 24 h → deny.

## Store (SQLite)

- `agents(id, name, role, runtime, model, cwd, approval_mode, system_prompt, runtime_session_id, created_at, updated_at, fallback_runtime, fallback_model, active_runtime)`: the last three are the [fallback subscription](#fallback-subscription); `active_runtime` NULL means the primary `runtime`
- `events(seq INTEGER PRIMARY KEY, agent_id, ts, kind, payload JSON)`
- `approvals(id, agent_id, call_id, tool, title, payload JSON, status, decision, created_at, resolved_at)`
- `rules(id, agent_id NULL, pattern, action)`
- `schedules(id, agent_id, cron, tz, prompt, enabled, last_run_at, next_run_at)`
- `devices(id, name, token_hash, created_at, last_seen_at)`; `pairing(code_hash, expires_at)`
- `checkpoints(id, agent_id, sha, label, kind, turn_id, created_at)`: points in an agent's folder history (see [Changes](#changes))
- `secrets(name, value, agents, created_at, updated_at)` for API keys, file mode 0600 (keychain/age later); see [Secrets](#secrets)

Migrations: numbered SQL files embedded in the binary, applied by `PRAGMA user_version`.

## RPC

JSON-RPC 2.0. Same methods on every transport.

- Requests: `daemon.info`, `runtimes.status`, `agents.list|get|create|update|delete`, `agents.send{agent_id,text}`, `agents.interrupt`, `events.since{seq,limit,agent_id?}`, `approvals.list|resolve{approval_id,decision,remember}`, `rules.list|set|delete`, `schedules.list|create|update|delete|run_now`, `devices.list|revoke`, `pair.redeem{code,device_name}` (only unauthenticated method), `term.list|open|input|resize|rename|close|attach|detach` (see Terminals), `fs.*` (see [Files](#files)), `changes.checkpoints|diff|file|restore` (see [Changes](#changes)), `secrets.list|set|delete` (see [Secrets](#secrets), `host.stats|history|processes|ports|kill`, `setup.status|install|job` (see [Setup](#setup)), `commands.list|install` (see [Commands](#commands)).
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

Environment: a terminal gets only a whitelist of the daemon's variables (`PATH`, `HOME`, `USER`, `LOGNAME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `SHELL`, `TZ`, `TMPDIR`, `XDG_RUNTIME_DIR`) plus the `env` given to `term.open`. The daemon's secrets (API keys, tokens) never reach a terminal. It also sets `BANDITO_TERM=1` and `BANDITO_TERM_ID=<terminal id>`, which mark the terminal's processes for [Host](#host).

Errors: code `-32021` (`TERM_ERROR`), message `<code>: <text>`, where `<code>` is `too_many`, `not_found`, `invalid_size`, `exited` or `busy`.

When the daemon stops, every terminal is hung up (`TerminalManager::shutdown_all`). Feature string: `"terminals"` in `daemon.info`.
## Secrets

API keys and passwords that agents need, such as `OPENAI_API_KEY` or a database password. A session gets them as environment variables when it starts. Their values never reach the app, the event log or the chat. `daemon/src/store/secrets.rs` holds the rules and storage, `daemon/src/redact.rs` the redaction, `daemon/src/rpc/secrets.rs` the methods. Clients show the feature when `daemon.info.features` contains `"secrets"`.

- `secrets.list {}` → `[SecretInfo]`, sorted by name.
- `secrets.set {name, value, agents}` → `SecretInfo`. Creates the secret or replaces its value and agents.
- `secrets.delete {name}` → `{deleted: bool}`.

`SecretInfo` is `{name, tail, agents, updated_at}`. `tail` is the last 4 characters of a value of 12 characters or more, otherwise `""`. No method returns a value. `agents` lists agent ids; `["*"]` means every agent, and `[]` means no agent yet. A list that mixes `"*"` with ids is `INVALID_PARAMS`.

**Rules.** Name: `^[A-Z_][A-Z0-9_]{0,63}$`, and not `PATH`, `HOME`, `USER`, `SHELL`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, or anything starting with `DYLD_` or `BANDITO_`. Value: 1 to 65 536 bytes, no NUL byte. Bad input is `INVALID_PARAMS`, and nothing is stored.

**Storage.** Table `secrets` in `bandito.db`, as plain text. The daemon sets the database file to mode 0600 when it opens it (unix). Values are not encrypted. The server's owner can read the file, and so can an agent with shell access, because it runs as the same user. This is the owner model; encryption at rest (keychain, age) comes later.

**Delivery.** A session gets the secrets that list its agent id, or `*`, as environment variables of the CLI process. `secrets.set` and `secrets.delete` restart the sessions of the agents concerned (every agent for `*`): an idle session closes at once, a running one when its turn ends. The next message starts with the new values. Terminals never get them (see Terminals).

**Redaction.** Before an event is stored or sent, each value of the session's secrets is replaced by `••••NAME`. This covers message text, tool call titles and inputs (every string inside the JSON), tool output, error text, and approval title, command, diff, input and reason. The approval keeps its key, so the answer still reaches the right request. Messages the user types are stored as typed. Values shorter than 6 bytes are not redacted. Where values overlap, the longer one wins.

**Limits.**

- Redaction works on whole strings. A value split across two `message.delta` chunks can show in the live stream. The stored `message.assistant` text is complete and redacted.
- Runtimes cut tool output to 16 KB before the daemon sees it, so a value cut at that point leaks its first part. Encoded forms of a value (base64, URL-encoded) are not matched.
- Redaction protects the chat, the event log and the app. It does not protect files. An agent that writes a secret into a file it may write has put it on disk, where it is the owner's to keep.

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
| `fs.clone` | `url`, `dest` | `{path, default_branch}` (see below) |

**Writing.** Overwriting an existing file needs the `etag` from the last `fs.read`. Without it, or with a stale one, the write is refused with `conflict`, and `error.data.etag` holds the current etag. `create: true` without an etag makes a new file and gives `exists` if the path is taken. `etag` on a missing file gives `not_found`.

**Errors.** File failures use code `-32020` and `error.data.reason`: `not_found`, `exists`, `not_a_directory`, `is_a_directory`, `not_a_file`, `permission_denied`, `too_large` (`size`, `limit`), `binary`, `conflict` (`etag`), `invalid_path`, `outside_roots`, `cross_device`, `io`, `clone_failed` (`stderr`). Bad params are `-32602`.

**Clone.** `fs.clone` copies a git repository into a new folder. `url` is `https://…` or scp-style `user@host:path` (ssh); anything else (`file://`, `http://`, `ssh://`, options such as `--upload-pack=…`) is `invalid_params`. `dest` is resolved like any path (`~` is home, otherwise absolute, under the roots) and must not exist, though its parent must. The daemon runs `git clone --depth 50 -- <url> <dest>` with a 10-minute limit and `GIT_TERMINAL_PROMPT=0`: nothing prompts, and private repositories work through the server's own ssh keys. The result is `{path, default_branch}` (`default_branch` is `null` when HEAD is detached). A failure is `FS_ERROR` with `reason: "clone_failed"` and `data.stderr`: the last 2 KB of git's stderr, with `user:password@` cut from every URL in it. The partial folder is removed. An existing `dest` gives `exists`.


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

## Changes

Bandito records what an agent changes in its folder, so the app can show it and undo it. The working folder does not need to be a git repository.

**Checkpoints.** Before a turn that starts from a user, schedule or crew message, the daemon takes a snapshot of the agent's working folder (its `cwd`): a `before` checkpoint, labelled with the start of the message. When the turn ends, an `after` checkpoint is taken in the background. Wrap-up turns (saving memory) are not checkpointed. A snapshot is a commit in a shadow git repository, `.checkpoints/` inside the agent's home folder, driven with `GIT_DIR` and `GIT_WORK_TREE` set to the working folder. A project's own `.git` is never touched, and its `.gitignore` is honored. An unchanged folder gives the same commit, so a turn that changed nothing adds no new commit.

Not checkpointed: credentials (`.env`, `.env.*`, keys, certificates, `.npmrc`, `.netrc`), files over 5 MiB (they are dropped from the index and stay out), `node_modules/`, `target/`, `.venv/`, `venv/`, `__pycache__/`, `dist/`, `build/`, `.next/`, `.cache/` and `*.log` (the full list is in `daemon/src/checkpoint.rs`), and whole folders with more than 20 000 files. A `before` snapshot that takes more than 10 s is abandoned, and the turn goes on without it. The shadow repository holds file contents, including files that the project ignores in git but this list does not exclude (such as `.env`). It sits in the agent's home folder, which only the daemon's user can read.

**Restore.** A restore first takes a `restore` checkpoint of the current state, so it can be undone with the same method. Paths must be relative and stay inside the working folder; `.git` and `.checkpoints` are refused. Without `paths`, every file that differs from the checkpoint comes back, and files that did not exist then are removed.

**Methods.**

| method | params | result |
|---|---|---|
| `changes.checkpoints` | `agent_id`, `limit?` (1–200, default 50) | `[{id, sha, label, kind, turn_id, created_at}]`, newest first |
| `changes.diff` | `agent_id`, `from?`, `to?` (checkpoint ids) | `{from, to, files}` |
| `changes.file` | `agent_id`, `path`, `from?`, `to?` | `{diff, truncated}` |
| `changes.restore` | `agent_id`, `checkpoint_id`, `paths?` | `{restored, undo_checkpoint_id}` |

`from` defaults to the agent's last `before` checkpoint, `to` to the working folder as it is now (`to` is then `null`). A `file` is `{path, status, from?, additions, deletions}` with `status` one of `added`, `modified`, `deleted`, `renamed` (`from` is the old path of a rename). `additions` and `deletions` are `null` for binary files. `changes.file` gives a unified diff with 3 lines of context, cut at 512 KiB (`truncated: true`).

**Errors.** An unknown agent, a checkpoint of another agent, a bad path or a bad id is `INVALID_PARAMS`. A git or file failure is `CHANGES_ERROR` (`-32022`) with `error.data.reason`: `missing_folder`, `too_many_files`, `undo_unavailable`, `git` or `io`. An agent with no checkpoints gets empty lists, not an error.

Feature string: `"changes"`.

## Host

The app shows what the server is doing: CPU, memory, disks, network, the processes of each agent and terminal, and the ports they listen on. Clients show it when `daemon.info.features` contains `"host"`. Code: `daemon/src/host.rs` (readers and sampler), `daemon/src/rpc/host.rs` (methods).

**Methods.** Error code `HOST_ERROR` = `-32023`; `error.data.reason` is `forbidden`, `not_found` or `io`. A bad `pid` or `range` is `-32602`.

| method | params | result |
|---|---|---|
| `host.stats` | `{}` | `HostStats`: the last sample, or a fresh one if the daemon has not sampled yet |
| `host.history` | `range`: `"1h"` or `"24h"` | `{points: [{t, cpu, mem_used, net_rx_bps, net_tx_bps}]}`, at most 360 points, each the average of its span; `t` is Unix ms |
| `host.processes` | `{}` | `{supported, owners: [{owner, cpu_percent, rss_bytes, processes: [{pid, name, cmd}]}]}` |
| `host.ports` | `{}` | `{supported, ports: [{port, addr, pid, process, owner?}]}`, unique by port and address |
| `host.kill` | `pid` | `{}` |

`HostStats` fields: `os`, `kernel`, `arch`, `hostname`, `cpus`, `cpu_percent` (busy share of all CPUs), `load` (1, 5, 15 min), `mem_total`, `mem_used`, `swap_total`, `swap_used`, `disks: [{mount, total, used}]` (`/` and the daemon user's home, one entry per device), `net_rx_bps`, `net_tx_bps`, `net_supported`, `uptime_s`. Bytes everywhere unless a name says `_bps`.

**Sampling.** The daemon samples every 10 s and keeps the last 24 h (8640 samples) in memory. The history is lost on restart.

**Sources.** Linux: `/proc/stat`, `loadavg`, `meminfo` (used = total − available), `net/dev` (loopback excluded), `uptime`, `sys/kernel/osrelease`, `/etc/os-release` (`PRETTY_NAME`), `statvfs`. macOS: `sysctl` (`hw.ncpu`, `hw.memsize`, `kern.boottime`, `kern.osrelease`, `kern.osproductversion`, `vm.loadavg`), `vm_stat` (used = active + wired + compressed pages), `netstat -ib`, `ps`, `lsof`, `statvfs`.

**Owners.** Every agent CLI is started with `BANDITO_AGENT_ID=<agent id>` in its environment, and every terminal's process with `BANDITO_TERM_ID=<terminal id>`. Children inherit the variable, so a test run or a dev server started by an agent is listed under that agent. The daemon's own process is `{kind: "daemon", id: null}`. Other processes have no owner and are not listed. An owner's `cpu_percent` is summed over its processes, so it can exceed 100.

**CPU per process.** Linux: the share of one core between two `host.processes` calls, from the process's utime + stime. The first call reports 0. macOS: the `%cpu` that `ps` gives, which is an average over the process's life, not a current rate.

**Ports.** Linux: `/proc/net/tcp` and `tcp6`, state LISTEN. The socket's owner is found through `/proc/<pid>/fd`, so a port of another user's process has `pid: null`. IPv4-mapped IPv6 addresses print as IPv4. macOS: `lsof -nP -iTCP -sTCP:LISTEN`; `addr` `*` means all interfaces.

**Kill.** `host.kill` sends SIGTERM to a process that belongs to an agent or a terminal. The daemon itself, processes without an owner (init, other users) and `pid` ≤ 0 are refused with `reason: "forbidden"` (or `-32602` for `pid` ≤ 0, since `kill(0)` and `kill(-1)` would signal whole groups). After 3 s SIGKILL follows if the process is still there with the same owner.

**Limits on macOS.** `ps -E` shows the environment only of processes of the same user that are not Apple system binaries. So agent CLIs (node, Rust, Python) and what they start count, while short system tools (`/bin/sleep`, `/bin/sh`, `/bin/zsh`) have no owner. Swap is not read (0). Without `netstat` the network fields are 0 and `net_supported` is `false`. `supported: false` in a process or port reply means the platform has no reader (not Linux or macOS, or `ps`/`lsof` missing).

## Install and service

`scripts/install.sh` (served as `https://bandito.dev/install.sh`) picks the release asset for the machine (`bandito-<target>.tar.gz`, targets `x86_64|aarch64` × `unknown-linux-gnu|apple-darwin`), checks its `.sha256`, installs `bandito` to `~/.local/bin`, and runs `bandito service install` unless `--no-service` is given. Releases are built by `.github/workflows/release.yml` on tag publish or by manual dispatch with a tag.

`bandito service install` writes `~/.config/systemd/user/bandito.service` (Linux) or `~/Library/LaunchAgents/dev.bandito.daemon.plist` (macOS), starts it, and waits up to 10 s for `daemon.info` on the socket. Linux machines without a user systemd manager (WSL without systemd, containers) get a detached background process with its pid in `<home>/daemon.pid` and output in `<home>/logs/daemon.log`; it does not survive a reboot. On Linux the installer also asks for lingering (`loginctl enable-linger`), so the daemon outlives the SSH session that installed it; if that is refused, the command prints the `sudo` line. `service uninstall` removes the unit or plist and stops the daemon; data is kept. `service install --dry-run` prints what would be written and run, and changes nothing.

Machine-readable output for scripts and the app: `bandito pair --json` prints `{"code","expires_in_ms"}`; `bandito info --json` prints version, paths, `listen`, `running`, and the `features` the daemon reports (empty when it is down); `service install --json` prints `{"ok","mode","listen","socket","warnings"}`; `service status --json` prints `{"installed","mode","running","pid"?}`.

## Setup

The server sets itself up from the app. The daemon knows which components each feature needs, checks whether they are there, and installs the missing ones. Clients show a feature from `setup.status`, and offer the install. Code: `daemon/src/setup.rs` (checks, plans, jobs), `daemon/src/rpc/setup.rs` (methods). Feature string: `"setup"`.

**Features and components.** `screen` needs `xvfb`, `x11vnc`, `xdotool`, `window_manager` (openbox) and `fonts` (Noto). `browser` needs `browser` and `fonts`. `agents` are `claude`, `codex` and `grok`; `claude` and `codex` need `node`. `containers` needs `docker`. The screen feature is `unsupported` off Linux.

**Checks.** A component is installed when its program is on `PATH`: `Xvfb`, `x11vnc`, `xdotool`, `openbox`, one of `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser`, or `node`, `claude`, `codex`, `grok`. Tools that have a version must answer `--version`. Node must be 18 or newer (`node --version`). `fonts` passes when `fc-list` lists a Noto family. `docker` passes when `docker info` succeeds. The check uses the daemon's `PATH`, which starts with `<data dir>/tools/bin`.

**How it is installed.**

| component | how | needs sudo |
|---|---|---|
| `xvfb`, `x11vnc`, `xdotool`, `window_manager`, `fonts`, `browser` | apt, dnf or pacman, one batch per job (apt runs `update` first). Ubuntu on x86_64 gets Google Chrome as a .deb, since its `chromium-browser` is a snap. Ubuntu on arm64 has no installer | yes |
| `node` | Node 22 LTS tarball from nodejs.org, checked against `SHASUMS256.txt` (sha256), unpacked into `<data dir>/tools/node`, linked as `node`, `npm`, `npx` in `<data dir>/tools/bin` | no |
| `claude`, `codex` | `npm install -g @anthropic-ai/claude-code` / `@openai/codex` with `NPM_CONFIG_PREFIX=<data dir>/tools` | no |
| `grok`, `docker` | not installed by Bandito. The hint names the docs; a docker permission error hints `sudo usermod -aG docker $USER` | — |

On macOS, Bandito installs only `node`, `claude` and `codex`. The screen feature is `unsupported`, and `browser`, `grok` and `docker` show a hint.

**Sudo.** Bandito never asks for or takes a sudo password. Package commands run as `sudo -n`, which fails rather than prompt. `setup.status` reports `sudo`: `passwordless` (`sudo -n true` works), `password` (sudo exists but asks), or `none` (no sudo). When a job needs sudo and it is not `passwordless`, nothing runs: the job ends in `needs_password` with `command`, the exact command line for the user to run in a terminal of the app. The app opens that terminal; the user types the password there, not in Bandito. Then the user starts the install again. Commands for node and the agent CLIs never use sudo.

**Jobs.** `setup.install` starts one job in the background and answers at once. A second install while one runs is `busy`. The order is node, then system packages (one batch), then Chrome, then npm packages. A component that needs node pulls it in. No command gets stdin. apt installs run with `DEBIAN_FRONTEND=noninteractive`, and each command has a limit of 15 minutes. Its stdout and stderr go to the job log. At the end every requested component is checked again. A failure names the first component still missing in `failed_component`.

**Methods.**

| method | params | result |
|---|---|---|
| `setup.status` | `{}` | `{os, arch, package_manager, sudo, components: [Component], features}`. `Component` is `{id, feature, installed, version, installable, needs_sudo, hint}`. `features` is `{screen, browser, containers: ready\|missing\|unsupported, agents: {claude, codex, grok: ready\|missing}}` |
| `setup.install` | `{components: [id]}` | `{job_id}`. Unknown ids and an empty list are `-32602` |
| `setup.job` | `{job_id, from?: u64}` | `{state, step, log, offset, command?, failed_component?}`. `state` is `running`, `done`, `failed` or `needs_password`. `log` holds bytes from `from` (a byte offset) to the end; `offset` is the next `from`. The log keeps the newest 256 KiB |

Poll `setup.job` about once a second with the last `offset`. The daemon keeps only the most recent job, so an unknown id is `not_found`. Errors: code `-32024` (`SETUP_ERROR`) with `error.data.reason`: `busy` or `not_found`.

**PATH.** At start the daemon puts `<data dir>/tools/bin` first on its `PATH`, before the runtime starts, so the tools reach agents and terminals. The data dir is `$BANDITO_HOME` or `~/.bandito`; `--home` does not move it.

## Commands

Slash commands in an agent's chat. The daemon lists what an agent can run, and a message that starts with `/name` reaches every runtime. Code: `daemon/src/commands.rs` (discovery, expansion, install), `daemon/src/rpc/commands.rs` (methods). Feature string: `"commands"`.

**Discovery.** For an agent whose folder is `cwd`, and the daemon user's home:

| source | files | name |
|---|---|---|
| `project` | `<cwd>/.claude/commands/**/*.md` | the path without `.md`, folders joined by `:` (`git/commit.md` is `git:commit`) |
| `user` | `~/.claude/commands/**/*.md` | the same |
| `skill` | `~/.claude/skills/<name>/SKILL.md`, `<cwd>/.claude/skills/<name>/SKILL.md` | front matter `name:`, or the folder name |
| `codex_prompt` | `~/.codex/prompts/*.md` | the file name without `.md` |

Limits: files up to 256 KiB, at most 500 commands per list, folders up to 4 levels below `commands/` or `skills/`, symlinks not followed, names only `[A-Za-z0-9_:.-]` and not starting with a dot. The list is sorted by source (`project`, `user`, `skill`, `codex_prompt`), then by name. When names clash, the first one wins.

Front matter is the YAML block between two `---` lines. The daemon reads top-level `key: value` lines only: `description`, `argument-hint` (or `args`), and `name` for skills. Quotes around a value are removed. Nested and multi-line values are not read.

`runtime_native` is true for Claude commands and skills, because the CLI runs them itself. It is false for Codex, for Grok, and for codex prompts.

**Sending.** A message that starts with `/name`, where `name` is a command for the agent, is handled like this:

- Claude and a native command: the text goes to the CLI as typed.
- Anything else: the runtime gets the expansion. The thread keeps what the person typed (`message.user.text`) and the command name (`message.user.command`).
- An unknown `/x` goes as typed, and the CLI deals with it.

This applies to messages from people (`agents.send`) and to schedule prompts. Crew messages are not expanded.

Expansion: the front matter is dropped. `$ARGUMENTS` becomes the whole argument string, and `$1`…`$9` become the words of it. Words are split as a shell does for simple cases: spaces separate them, `"…"` and `'…'` group them (single quotes are literal), and a backslash escapes the next character. A file without placeholders, given arguments, gets `Arguments: <args>` appended after a blank line. A skill becomes `Use the skill below.`, its body, and `Task: <args>` (the last line only when there are arguments).

**Methods.**

| method | params | result |
|---|---|---|
| `commands.list` | `agent_id` | `[Command]`: `{name, description?, args_hint?, source, path, runtime_native}`, no file content |
| `commands.install` | `scope: "user"\|"project"`, `agent_id` (for `project`), `kind: "command"\|"skill"`, `name`, `files: [{path, content}]` (`content` is base64), `overwrite?` (default false) | `{path}` |

Install writes under the daemon user's home (`user`) or under the agent's folder (`project`). A command is `.claude/commands/<name>.md`, one file (`git:commit` goes to `commands/git/commit.md`). A skill is the folder `.claude/skills/<name>/`, which must contain `SKILL.md`; it takes at most 50 files and 2 MiB decoded in total. File paths are relative and have no `..`. Everything is checked before the first write. Without `overwrite`, an existing command or skill is an error. With it, a skill folder is replaced as a whole. Like the file methods, these are open to any paired device, with the rights of the daemon user.

Errors: code `-32027` (`COMMANDS_ERROR`) with `error.data.reason`: `invalid_name`, `invalid_path`, `invalid_content`, `file_count`, `too_many_files`, `too_large`, `missing_skill_file`, `exists`, `no_home`, `io`. Bad params are `-32602`.

## Mac app

SwiftUI, macOS 14+. Sidebar: servers → crew. Thread view rendered from events; approval cards with Approve / Deny / Always; schedules; connection wizard. Menu bar item with the status dot. Local notifications with Approve / Deny actions while the app runs. Strings in a String Catalog, 9 languages. Colors from `brand/tokens/dist`.

## Repo layout

```
daemon/            Rust crate `bandito`
  src/main.rs      CLI entry
  src/service.rs   user service: systemd unit, launchd plist, background fallback
  src/rpc/         JSON-RPC, transports, auth, pairing
  src/store/       SQLite + migrations
  src/runtime/     process.rs (shared child-process plumbing), claude.rs, codex.rs, grok.rs, api/
  src/policy.rs    approval rules
  src/host.rs      host load, processes, ports, kill (see Host)
  src/setup.rs     components per feature, install jobs (see Setup)
  src/commands.rs  slash commands: discovery, expansion, install (see Commands)
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

**One source of strings.** `i18n/en.json` is the reference; every language is one file next to it (`i18n/ru.json`, …) and is listed in `i18n/languages.json`. Keys are flat and dotted (`thread.approve`). Plurals are objects with CLDR categories (`{"one": "…", "other": "…"}`), placeholders are `{name}`; a placeholder named `count` is an integer, any other is text. `i18n/build.py` generates platform files (now: `Resources/<code>.lproj/Localizable.strings` and `.stringsdict` + typed `L10n` accessors in BanditoKit; later Android `strings.xml`, web JSON). CI fails if a language has missing or extra keys, placeholders that differ from English, or generated files that are out of date. A missing translation falls back to English at runtime.

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

**Changing an agent.** `agents.update` applies name, role, model, effort, system prompt, memory mode, context budget, folder, runtime and fallback from the next session: an idle agent's session is closed at once, a running one when its turn ends. The chapter goes on, except after a folder or runtime change, which starts a new chapter (a CLI session is tied to its folder and its runtime). A runtime change also resets effort to null, with a `warnings` entry in the response, when the new runtime does not offer the old level. The approval mode is read on every request and needs no restart.

**Effort.** Each agent has an `effort` (`low`, `medium`, `high`, `xhigh`, `max`). The daemon maps it to the runtime (`--effort` for Claude, the turn's `effort` for Codex, `--reasoning-effort` for Grok) and refuses levels a runtime does not offer.

**Usage.** Rate-limit windows reported by the CLIs are cached per runtime (`usage.limits`), so the app shows remaining quota even when no turn is running; `usage.refresh` asks runtimes that can be asked (Codex: `account/rateLimits/read`).

**Plan.** The subscription of each runtime's account is cached next to its windows, as `plan: {id, label}` (Claude `max_20x` / «Max ×20», `max_5x` / «Max ×5», `max` / «Max», `pro`; ChatGPT `plus`, `pro`, `team`, …), or `null` when unknown. `usage.refresh` asks for it in the same call as the windows, with the same timeout, and never starts a turn:

- Claude: read from `<config_dir>/.credentials.json`, where `config_dir` is `CLAUDE_CONFIG_DIR` or else `$HOME/.claude`. Only `subscriptionType` and `rateLimitTier` are read. The OAuth tokens in that file are never deserialized, logged or returned. On macOS the CLI keeps its login in the Keychain and writes no file, so the plan stays unknown there.
- Codex: a separate `codex app-server` for `initialize` → `account/read` (`account.planType`).
- Grok and API keys: no plan yet.

A runtime that reports no plan, or fails, leaves the stored plan as it was.

## Fallback subscription

An agent can name a fallback runtime (`fallback_runtime`, one of `claude`, `codex`, `grok`, different from its `runtime`) and a `fallback_model` for it. It is used when the primary runtime's subscription runs out of usage. `agents.create` and `agents.update` take both (`null` clears them), and `agents.get`/`agents.list` return `active_runtime`: the runtime the agent runs on now, `null` for the primary one.

**Recognising a limit.** A turn that ends with an error, and whose runtime reported its usage as used up during it:

| runtime | error message (case-insensitive) | or usage reported |
|---|---|---|
| Claude | `usage limit` (`Claude AI usage limit reached…`), `rate limit`, `rate_limit`, `429` | `rate_limit_event` window at utilization 1.0 or more |
| Codex | `usage_limit_reached`, `usage limit` | `account/rateLimits/updated` window at `usedPercent` 100 or more |
| Grok | `rate limit` (`Rate limited: …`), `429`, `too many requests` | none |

Only runtime error messages are checked, never the agent's text. The message is the one the adapter reports, so a runtime that words its limit differently is not recognised.

**Switching.** When the limit is recognised, the fallback is free, and the turn had no retry yet, the daemon:

1. closes the session and starts a new chapter (`session.rotated`, reason `runtime switched`). The memory carries over in the agent's files, so no wrap-up turn runs;
2. sets `active_runtime` to the other runtime and emits `runtime.switched {from, to, until?}`;
3. sends the same message again on the new runtime. The thread shows the user's message once. A retry that hits the limit again is a plain error: one switch per message.

Without a fallback, or when the fallback is out of usage too, the turn is an ordinary error.

**Coming back.** Before a message goes out, an agent on its fallback returns to the primary runtime once that runtime's windows do not block: a full window (utilization 1.0 or more) blocks while its `resets_at` is in the future. A full window with no reset time blocks for one hour after it was reported; after that the primary runtime is tried again, and if its limit is still there, the message switches to the fallback again. The return emits `runtime.switched {from: fallback, to: primary}` and starts a new chapter.

**Usage cache.** The runtime left is recorded as used up: its own windows if it reported them, else a window named `limit` at 100% with no reset time. The app shows that window under the runtime's usage.

**Changing the primary runtime.** `agents.update {runtime}` checks that the runtime is installed on this server, clears `active_runtime`, starts a new chapter (`session.rotated`, reason `runtime changed`) and drops the CLI session. The fallback must differ from the new runtime: switching to the current fallback is refused unless the same patch clears it.

**Limits of this design.** Codex limits are recognised by the words in the error message the adapter passes on. A switch does not run a wrap-up turn, so what the agent did not write to its memory files during the chapter is not saved.

## Accounts, sync and push (planned)

An account is optional: without one the app works on one Mac. With one, every device of the person sees the same servers and agents, and approvals reach the phone.

**Service.** `api.bandito.dev` (Cloudflare Worker + D1, in the private `platform` repo; the protocol is documented here so anyone can run their own). Sign in with Apple, GitHub, or an email link. No passwords.

**What the service stores.** Account (id, email), devices (name, platform, public key, push token), and one **encrypted vault** per account. The vault holds the server list (names, how to reach them) and per-device settings. It is encrypted on the device with a vault key the service never sees.

**Vault key.** Created on the first device and kept in the Keychain. A new device signs in, shows a short code, and an existing device approves it: the existing device encrypts the vault key to the new device's public key (X25519 + XChaCha20-Poly1305). An optional printed recovery key restores the vault if every device is lost; without it the person re-pairs servers, and nothing on the servers is lost.

**Server access per device.** Devices never share daemon tokens. When a device joins, an existing device asks each server for a pairing code (`pair.create`) and passes it through the vault channel; the new device redeems it for its own token. Revoking a device revokes only its tokens.

**Push.** Approvals and finished turns reach phones through `push.bandito.dev`: the daemon sends an end-to-end encrypted payload addressed to device push tokens; a notification service extension decrypts it on the phone. Approve and Deny from the notification call the daemon directly (through whatever connection the phone has: Tailscale, SSH, relay).

**Reaching servers from a phone.** Tailscale and direct TLS work as on the Mac; SSH works through an in-app SSH client; the Bandito Relay (outbound-only, end-to-end encrypted) covers servers behind NAT without any setup.

## Screen

A virtual desktop on a Linux server that people see in the app and agents can drive. `daemon/src/screen.rs` runs it; `daemon/src/rpc/screen.rs` is the RPC layer. Other systems answer `unsupported`.

**Lifecycle.** `screen.start {workspace?, width?, height?}` starts `Xvfb` on the first free display from `:90`, `openbox` when it is installed, and `x11vnc` bound to `127.0.0.1` on a free port with a random password (file mode 0600 under `$BANDITO_HOME/screens/<workspace>/`). Each process has its own process group; x11vnc is restarted once if it dies. `screen.status` returns `{running, display, width, height, vnc_port, vnc_password, started_at, controller, idle_ms}`; `screen.stop` ends it. A screen with no VNC client and no agent tool call for 30 minutes stops by itself. The daemon stops every screen when it shuts down.

**Viewing.** The app calls `screen.start`, then opens `/v1/tunnel?port=<vnc_port>` through a one-shot local forwarder and speaks VNC with the password. RFB uses only the first 8 characters of a password; the tunnel is what keeps the screen private (loopback only, paired device only).

**Agents.** The crew MCP server offers `screen_screenshot` (PNG, at most 1280 px wide, with the original size so clicks use screen pixels), `screen_click {x, y, button?, double?}`, `screen_move`, `screen_type {text}`, `screen_key {keys}`, `screen_scroll {direction, amount?}` and `screen_launch {command}`. They call local-only `screen.agent.*` methods and start the screen when it is off.

**Control.** `screen.control {holder: user|agent|none}`. While the user holds the screen, agent tools fail with a message asking the agent to wait or ask for it back.

**Needs** `xvfb`, `x11vnc`, `xdotool`, ImageMagick (`import`) and optionally `openbox` (see [Setup](#setup)). A missing one is `SCREEN_ERROR` (`-32025`) with `data.reason = "missing_component"` and `data.component`. Feature string: `"screen"` (Linux only).
