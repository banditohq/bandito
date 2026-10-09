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

`bandito mcp` is an MCP server (stdio) injected into every agent: `--mcp-config` for Claude, `mcp_servers` config for Codex, `mcpServers` in ACP `session/new` for Grok. Tools: `crew_list`, `crew_send{to, message}` (becomes `message.user` with `source:"crew"` for the target), `report{text}` (shows in the user's inbox). Loop guard: a crew message chain stops after 8 hops without a human.

## Mac app

SwiftUI, macOS 14+. Sidebar: servers → crew. Thread view rendered from events; approval cards with Approve / Deny / Always; schedules; connection wizard. Menu bar item with the status dot. Local notifications with Approve / Deny actions while the app runs. Strings in a String Catalog, 9 languages. Colors from `brand/tokens/dist`.

## Repo layout

```
daemon/            Rust crate `bandito`
  src/main.rs      CLI entry
  src/rpc/         JSON-RPC, transports, auth, pairing
  src/store/       SQLite + migrations
  src/runtime/     claude.rs, codex.rs, grok.rs, api/, fake test CLIs
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
