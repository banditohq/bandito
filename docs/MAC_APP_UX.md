# Mac app UX (MVP)

The layout follows the pattern people already know from chat-style agent apps (one window, a sidebar of agents, a thread, an inspector), so moving to Bandito costs nothing. Visual language is ours: Ember Signature tokens from `brand/tokens`, Geist, the raccoon, orange only for "needs you".

## Window

```
┌────────────┬──────────────────────────────────────────┬──────────────┐
│ sidebar    │ thread                                   │ inspector    │
│ (≈260 pt)  │ (centered column, max ≈740 pt)           │ (≈320 pt,    │
│            │                                          │  toggles)    │
└────────────┴──────────────────────────────────────────┴──────────────┘
```

Native SwiftUI `NavigationSplitView`, dark by default, light theme available. Minimum window 900×600.

## Sidebar

Top bar: search button (⌘K) and new button (⌘N), right of the traffic lights.

1. **Pinned** — up to 4 large tiles (avatar 56 pt, name, role chip). A crew channel tile shows stacked avatars.
2. **Agents** — rows: avatar 40 pt with status dot (ok / working / needs you / error), name, role chip, one-line preview of the last message. Rows that need you sort to the top and get the orange dot.
3. **Servers** — collapsed group at the bottom of the list when there is more than one server; each server shows online/offline.

Bottom: profile button (avatar) and a pill button **Connect apps** (MCP servers and plugins, later). Profile menu: Get the iPhone app · Help › · Settings… (⌘,) · Add server · Sign out of this server.

Context menu on an agent: Pin / Unpin · Mark as unread · Copy agent ID · Pause / Resume · Hide from sidebar · Delete….

## Search (⌘K)

Centered palette: search field, then results — agents (name, role chip, first line of the system prompt), then messages. Arrow keys + Enter. Esc closes.

## New (⌘N)

Thread area turns into a composer with a **To:** field and a dropdown:

- New agent (⌘1) → agent sheet
- New crew channel (⌘2)
- existing agents with ⌘3…⌘9

Typing in **To:** filters. Sending to an existing agent just opens its thread.

**New agent sheet:** name, role (short chip text), avatar, runtime (Claude Code / Codex / Grok / API key — unavailable ones disabled with the reason, e.g. "codex is not logged in on vps-1 · Run `codex login`"), model, folder on the server (picker backed by the daemon), approval mode (Ask for risky actions · Ask for everything · Never ask), instructions. Create.

## Thread

- Floating pill at the top center: avatar + name + status. Click → inspector.
- Messages: the agent's replies are bubbles on the left, yours on the right. Dates as centered small captions.
- **Crew and system events** are quiet centered lines with an icon, not bubbles: "2 messages with Scout", "Schedule paused · Night audit", "Message for Forge", "Session restarted".
- **Tool calls** collapse into one line per call ("$ cargo test · 14 passed"), expandable to output; consecutive calls group ("Ran 6 commands").
- **Approval card** inline (same as the landing demo): chip "needs you", agent + action, the command or a diff, buttons Deny (esc) · Approve (↵), checkbox "Always allow this here". Resolved cards shrink to a line ("Approved by you · 14:02").
- Hover actions on a message: react, reply (quote into composer), more (copy, copy as Markdown).
- Banner above the composer for blocking states, with one action: runtime not logged in, server offline, usage limit reached (with reset time).
- Composer: "+" (attach files → uploaded to the agent's folder), placeholder "Message Forge", mic (dictation, later), send. Enter sends, ⇧Enter newline. While a turn runs, the send button becomes Stop (interrupt).

## Inspector (agent)

Large avatar (click → avatar editor), name, role chip. Segmented tabs:

- **Details** — runtime, model, folder, approval mode, instructions (editable), schedules list (cron in words: "Every day at 02:00", next run, toggle, run now), rules for this agent.
- **Library** — what the agent produced: files it changed, PRs, links, attachments; newest first.
- **Server** — server name and status, CLI versions and login state, usage limits (every limit window the program reports, with reset times), live log tail.

Avatar editor: tabs Presets (raccoon-family shapes × brand colors) · Generate (prompt) · Upload · Reset; Cancel / Set avatar.

## Settings (⌘,)

Modal with a left nav, content in grouped cards (title + description on the left, control on the right).

- **General** — appearance (theme, accent, language), notifications (approvals, finished turns, errors; sound), menu bar item on/off, launch at login.
- **Servers** — list of servers (name, how connected, status, version); Add server (wizard below); per server: rename, reconnect, show pairing devices, remove.
- **Approvals** — global rules table (Action · Behavior: Allow / Ask / Deny, edit, delete), "Add rule" (pattern + behavior), the built-in risky list (read-only, explained), default mode for new agents. Note: "Rules apply on this server. Built-in checks always apply."
- **Usage** — per runtime: plan limits from the CLI. All limit windows the program reports are shown, shortest first, each with how much is used and when it resets; the app does not assume a fixed set of windows. Grok does not report its limits. API spend for API-key agents.
- **Updates** — channel (Stable / Beta), automatic updates, app version + Check now; daemon version per server + Update daemon; danger zone: Restart daemon (red).

## Add server wizard

1. Pick how: **This Mac** · **SSH** · **Tailscale** · **Direct (TLS)** · **Other URL** (Cloudflare Tunnel, reverse proxy, WireGuard…).
2. SSH: host (from `~/.ssh/config` suggestions), user, port; the app checks the daemon, offers to install it (shows the exact command), then pairs automatically over the same SSH session.
3. Others: URL + pairing code (6 words) or scan/paste the `bandito://pair` link.
4. Done → server appears, runtimes check runs, suggest creating the first agent.

## Menu bar item

Raccoon icon with the status dot. Menu: agents that need you (click → approve inline), running agents, Open Bandito, Pause all.

## Notifications

macOS notifications with actions Approve / Deny for approvals; "Forge finished" for turns longer than 1 minute while the window is not focused.

## Keyboard

⌘K search · ⌘N new · ⌘1…⌘9 agents · ⌘, settings · ↵ / esc on a focused approval · ⌘. stop turn · ⌘I inspector.
