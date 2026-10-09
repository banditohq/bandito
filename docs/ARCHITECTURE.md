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

Everything an agent does becomes a row in `events` (append-only, global `seq`). Clients render from events and resume with `events.since(seq)`, so a laptop that slept for a night catches up exactly.

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

Risky = matches a rule. Built-in rules (editable): `git push*`, `git reset --hard*`, `rm -rf*`, `*deploy*`, `npm publish*`, `cargo publish*`, `kubectl delete*`, `terraform apply*`, `DROP TABLE*`, `prisma migrate deploy*`, writes outside the agent's `cwd`. Agent rules (`allow` / `ask` / `deny` patterns) win over built-ins. "Always allow here" on an approval adds an `allow` rule to that agent.

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

- Requests: `daemon.info`, `runtimes.status`, `agents.list|get|create|update|delete`, `agents.send{agent_id,text}`, `agents.interrupt`, `events.since{seq,limit,agent_id?}`, `approvals.list|resolve{approval_id,decision,remember}`, `rules.list|set|delete`, `schedules.list|create|update|delete|run_now`, `devices.list|revoke`, `pair.redeem{code,device_name}` (only unauthenticated method).
- Notifications (server → client): `event{seq, agent_id, kind, payload, ts}` for every event including `message.delta`.

## Transports (connect any way you like)

The daemon always listens on:

1. Unix socket `~/.bandito/bandito.sock` (0600). Trusted: same user.
2. `127.0.0.1:7878` HTTP + WebSocket (`/v1/rpc`, `/v1/health`). Token required.

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

Before a chapter closes, the daemon sends a hidden wrap-up turn (`source: "system"`): *update your memory files with what matters from this chapter*. Then the session is dropped and `session.rotated` is emitted.

**Agent home.** Every agent gets its own folder on the server, `~/bandito/agents/<slug>/`, next to (not inside) the project it works on:

```
MEMORY.md        short index, read at the start of every chapter (≤ 200 lines)
notes/<topic>.md details: decisions, how things work, people, preferences
journal/<date>.md one line per finished piece of work
files/           anything the agent makes for itself
```

The agent's instructions (built by the daemon, before the user's own) explain this layout. The CLI is allowed to write there (`--add-dir` for Claude, writable roots for Codex). The user can open, edit or delete these files; they are plain Markdown.

**Recall instead of remembering.** The crew MCP server also offers `history_search{query}` and `history_day{date}` over the agent's own past messages in the daemon's database, so an agent looks up what was said weeks ago instead of carrying it.

**Effort.** Each agent has an `effort` (`low`, `medium`, `high`, `xhigh`, `max`). The daemon maps it to the runtime (`--effort` for Claude, the turn's `effort` for Codex, `--reasoning-effort` for Grok) and refuses levels a runtime does not offer.

**Usage.** Rate-limit windows reported by the CLIs are cached per runtime (`usage.limits`), so the app shows remaining quota even when no turn is running; `usage.refresh` asks runtimes that can be asked (Codex: `account/rateLimits/read`).
