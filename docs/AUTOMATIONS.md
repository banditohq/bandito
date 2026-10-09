# Automations, the manager bot and connectors (design, after v0.1.0)

Status: design approved by the owner on 2026-10-09, not built yet. Order of work is at the end.

The owner's words: "I tell the main bot: make a bot that checks my mail every 15 minutes. It sets
everything up; I only connect the mail." Or: "you watch my mail yourself", and the main bot takes the
task on itself. Every bot knows the app: asked "how do I connect a server?", it answers step by step
for the current version.

## 1. Every agent knows Bandito

- **`bandito_help {query}`** — a crew tool for every agent. The daemon embeds `guide/*.md` at build
  time (the guide CI already keeps complete), splits it into entries (`## ` sections with their
  `<!-- id; covers -->`), and returns the 3 best entries for the query (word overlap on title, path and
  body; exact `covers` keys win). The reply carries the entry text and its path line, so the agent
  can answer "Server → Add server → SSH" for this exact version.
- **A short system note** for every session: "You run inside Bandito (version X) on the user's
  server. For questions about the app, call `bandito_help`." Claude: `--append-system-prompt`. Codex
  and Grok: their instruction setting (`-c instructions=…` / ACP system message).

## 2. Tasks an agent sets for itself

- Crew tools `my_schedules_list | create | update | delete` — scoped to the calling agent (the token
  names it). A schedule is a cron expression with a time zone and the prompt to send, as `schedules.*`
  already stores.
- Creating or changing one is an approval request to the owner ("Forge wants to run every 15 min:
  *check the inbox and tell me about invoices*"), with "Always allow Forge to schedule itself".
  Deleting its own schedule needs no approval.

## 3. The manager bot

- An agent flag `manager` (owner-only, set in the Inspector or when creating the agent). The first
  server gets one ready-made manager called **Bandito**, with its avatar, at the top of the team.
- Manager tools (crew, only for a manager's token): `agents_list`, `agents_create`, `agents_update`
  (name, role, instructions, runtime, model, folder, workspace — never `approval_mode` above `risky`,
  never rules or secrets), `agents_pause`, `agents_delete`, `schedules_*` and `triggers_*` for any
  agent, `connectors_list`, `connector_request`.
- Every changing call becomes an approval card that shows exactly what changes (a diff of the agent,
  the schedule in words: "every 15 minutes, 08:00–20:00"). The owner can allow a kind of change for
  this manager once. Deleting an agent always asks.
- Flexible by design: "make a mail bot" → `agents_create` + `schedules_create` for it + a
  `connector_request(gmail)` if mail is not connected; "watch my mail yourself" → the manager's own
  `my_schedules_create`. Both go through the same approvals.

## 4. Triggers (events, not only time)

- `triggers.*`: an event source plus a prompt template. Sources: a **webhook** (Bandito gives a URL and
  a secret; GitHub, Stripe, anything can call it), a **connector event** (new mail, new issue — from
  the connector service), a **server event** (a process died, disk above 90%, from the host monitor).
- Webhooks need a public address. The address is `https://bandito.dev/hooks/<id>`; the cloud forwards
  the request to the daemon over the **Relay** connection (below), checking the signature first. So
  triggers come after Relay.

## 5. Connectors marketplace (Composio)

- Connectors come from **Composio** (hundreds of services: Gmail, Google Calendar, Slack, GitHub,
  Notion…). The owner adds their Composio API key once (Settings → Connectors); it is stored as a
  server secret, never shown to agents.
- "Connect Gmail" opens Composio's OAuth link in the browser; Bandito stores only the Composio
  connection id.
- Each agent gets only the connectors the owner (or an approved manager request) gave it: the daemon
  writes an MCP config for that agent's session with the Composio MCP endpoint limited to those
  toolkits. Agents never see the API key.
- The marketplace screen: search, categories, connected / not connected, which agents use each one.

## 6. Bandito Relay

- The daemon keeps one outbound WebSocket to `relay.bandito.dev` (Cloudflare Durable Object per
  device pair). The app connects to the same object. Traffic is end-to-end encrypted with the device
  keys from the account (Noise IK or HPKE + ChaCha20-Poly1305 per frame); the relay sees only sizes and
  times. Works behind NAT without SSH or Tailscale.
- The same connection carries webhook deliveries (section 4) and lets the app reach the server from
  anywhere, including the iPhone later.

## Order of work

1. `bandito_help` + system note (small).
2. Self-schedules with approvals (small).
3. Manager flag, tools, approval cards with diffs, the ready-made "Bandito" manager (medium).
4. Queue on exhausted limits (owner's item 4) — the manager benefits from it.
5. Relay (large), then webhooks and triggers over it (medium).
6. Connectors marketplace on Composio (medium; needs the owner's Composio account and key).
Every step: design board in the canvas first (it is the final spec), then daemon, then app, then guide.
