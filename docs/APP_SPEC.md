# Apple app: build spec

The design canvas is the source of truth for every screen:
https://claude.ai/artifact/ENzMSHPsQX1wsfzPDHH8sm (boards 01–22, 19a). Its HTML sources are copied to
`docs/design/*.dc.html` so contributors can read exact sizes, colors and copy. This file says how
the app is put together; `docs/MAC_APP_UX.md` explains why it looks the way it does.

## Modules

`apps/mac/BanditoKit` (one Swift package, shared by macOS and iOS):

| target | owns |
|---|---|
| `BanditoKit` | wire models, `RPCClient`, transports, `ServerModel` (one per server), event reducer, terminal streams, file service client, SSH installer |
| `BanditoDesign` | generated brand tokens (`Color.Bandito.*`, radii, spacing, motion) |
| `BanditoL10n` | generated `L10n` from `i18n/*.json` |
| `BanditoUI` | every screen and component; no AppKit except behind `#if os(macOS)` in `Platform/` |

`BanditoUI` folders:

```
App/          AppModel (servers), Router, DemoStore, Keymap, Gestures, RootView
Shell/        MainWindow, Sidebar chrome, ModeBar, ServerPicker, UsageButton, UsagePopover
Team/         TeamSidebar, ThreadView, ApprovalCard, Composer, InspectorView, ChangesSheet, NewAgentSheet, FolderPicker, Palette
Files/        FilesSidebar, FileBrowser, FileViewer (Markdown, code, image, PDF, media)
Terminals/    TerminalsSidebar, TerminalWorkspace, TerminalPane (SwiftTerm), TerminalDock
Browser/      BrowserView
Screen/       ScreenView
Server/       ServerOverview, WorkspacesView, SecretsView, PortsView
Settings/     SettingsWindow and one view per section (19a: KeysAndGestures)
Onboarding/   Welcome, Account, FirstServer, FirstAgent, Tour
MenuBar/      MenuBarContent
Components/   the shared library (avatar, buttons, chips, bars, rings…)
Platform/     AppKit bridges: trackpad gestures, key recorder, window chrome
```

## Navigation

`Router` (`@Observable`, one per window):

- `mode: AppMode` — `.team, .files, .terminals, .browser, .screen, .server`. The sidebar's mode bar and ⌘1…⌘6 switch it. Each mode owns its sidebar content and its main area.
- `selection` per mode (agent id, folder path, terminal id, tab id, workspace id, server section), kept when switching modes.
- `sheet: Sheet?` — `.newAgent, .changes(agentId), .addServer, .settings(section)`; `palette: Bool`; `usagePopover: Bool`; `inspector: Bool`.
- History stack per mode for back/forward (⌘[ ⌘] and two-finger swipe).
- Onboarding shows instead of the main window until a server and an agent exist (or the user skips).

## Data

Everything comes from `ServerModel` over JSON-RPC (see `docs/ARCHITECTURE.md`). A screen checks
`server.info.features` before showing a feature and shows an "update the server" note when it is missing.

| screen | daemon methods |
|---|---|
| Team, Inspector | agents.*, events.*, approvals.*, schedules.*, usage.* |
| Changes | changes.* |
| New agent, Folder picker | runtimes.status, usage.limits (plan), fs.list, fs.projects, fs.mkdir |
| Files, File viewer | fs.*, GET /v1/files/raw (local server: read the file directly) |
| Terminals | term.* with term.output notifications |
| Server | host.*, secrets.*, devices.* |
| Browser, Screen, Workspaces | browser.*, screen.*, workspaces.* when the daemon has them; Demo data until then |

**Demo mode** (Settings → General → "Show examples"): `DemoStore` fills screens whose feature the
server lacks with the sample data from the canvas, under a quiet "Example" chip. It is on by default
only while a server lacks the feature; real data always wins.

## Keymap

All commands live in one registry: `Command(id, title: L10n, context, defaultBinding)`. A binding is
a key plus modifiers, or none. User overrides are stored as JSON (`keymap.v1`) and synced with the
account. Menus (`Commands`) and in-view handlers read the registry, so a rebinding applies everywhere.
Contexts: `global, team, terminals, files, viewer, browser, screen`. A binding may repeat across
contexts but not within one context or with `global`; the recorder warns and offers to swap.

Defaults (presets "VS Code", "iTerm", "Slack" only override what they differ in):

| context | command | default |
|---|---|---|
| global | Quick open | ⌘K |
| global | Modes Team…Server | ⌘1…⌘6 |
| global | New agent | ⌘N |
| global | Back / Forward | ⌘[ / ⌘] |
| global | Toggle sidebar | ⌃⌘S |
| global | Usage limits | ⌥⌘U |
| global | Settings | ⌘, |
| global | Search all history | ⌘⇧F |
| team | Previous / next agent | ⌥⌘↑ / ⌥⌘↓ |
| team | Go to who needs you | ⌘⇧A |
| team | Approve / Deny focused request | ⌘↵ / ⎋ |
| team | Stop agent | ⌘. |
| team | Pause all | ⌘⇧P |
| team | What changed | ⌘⇧D |
| team | Agent details | ⌘I |
| terminals | New terminal | ⌘T |
| terminals | Split vertically / horizontally | ⌘D / ⌘⇧D |
| terminals | Collapse: the pane leaves the screen into the dock, output keeps being followed (keeps running) | ⌘⇧↓ |
| terminals | Bring back last collapsed | ⌘⇧T |
| terminals | Next pane | ⌥⌘←→↑↓ |
| terminals | Close (ends the process) | ⌘W |
| terminals | Clear | ⌘⇧K |
| terminals | Font bigger / smaller / reset | ⌘+ / ⌘− / ⌘0 |
| files | Open / Enclosing folder | ⌘↓ / ⌘↑ |
| files | Quick look | Space |
| files | New folder / New file | ⌘⇧N / ⌥⌘N |
| files | Rename | ↵ |
| files | Move to Trash | ⌘⌫ |
| files | Copy path | ⌥⌘C |
| files | Duplicate | ⌘D |
| viewer | Read ⇄ Edit | ⌘E |
| viewer | Side by side | ⌥⌘↵ |
| viewer | Save | ⌘S |
| viewer | Next / previous tab | ⌃⇥ / ⌃⇧⇥ |
| browser | Address bar | ⌘L |
| browser | Reload | ⌘R |
| browser, screen | Take / give back control | ⌘⇧C |
| screen | Send ⌃⌥⌦ | ⌃⌥⌫ |

Text fields keep their system shortcuts (⌘A, ⌘Z, ⌘C…); the composer sends on ↵, new line on ⇧↵.

## Slash commands

Typing `/` in the composer opens a list (board 10a): ↑↓ pick, ↵ run, ⇥ complete. Sources, merged and
searchable:

- **Server** — the agent CLI's own commands and skills: `~/.claude/commands`, `~/.claude/skills`,
  the project's `.claude/` in the agent's folder, `~/.codex/prompts`. Listed by the daemon
  (`commands.list {agent_id}`).
- **This Mac** — `~/.claude/commands` and `~/.claude/skills` on the Mac, marked "from Mac". The first
  use offers "Install on the server" (copied into the server's `~/.claude/…` over `fs.upload`);
  afterwards they stay in sync while the setting is on.
- **Bandito** — `/new, /model, /effort, /chapter, /memory, /changes, /terminal, /files, /usage, /pause`,
  handled by the app.
- **Mine** — saved prompts with `{placeholders}`, stored in the account and synced.

Claude Code runs its commands and skills itself, so `/name args` is sent as is. For Codex and Grok the
daemon expands the command file into the message (front matter dropped, `$ARGUMENTS` and `$1…$9`
filled) before it reaches the CLI, so one command works for every agent.

## Trackpad gestures

Each can be switched off in Settings → Keys and gestures; one sensitivity slider for swipes.

| gesture | where | does |
|---|---|---|
| Two-finger swipe left/right | Files, Browser, File viewer | back / forward (scroll-wheel phase tracking, like Safari) |
| Two-finger swipe on an agent row | Sidebar | left: pin, pause, delete; right: mark read (like Mail) |
| Pinch | Terminal, File viewer, Screen | text size / zoom |
| Pinch out / in on a pane | Terminals | full screen / back to the grid |
| Force click | agent, file, link | peek preview |
| Two-finger double tap | Screen, Browser | smart zoom |

## Motion

Use `banditoAnimation` (respects Reduce Motion). Entrances: rise 8 pt + fade, 0.3–0.45 s, 40–90 ms
stagger in lists. Sheets: rise 22 pt + scale 0.98. Popovers: scale from their anchor. Status:
"needs you" pulses; working agents' eyes scan; idle agents blink, each on its own rhythm from the
name hash. Only one attention animation per screen.

## Strings

Every visible string goes through `L10n`. New keys go to `i18n/en.json` (source) and `i18n/ru.json`;
other languages are filled in a translation pass. Run `python3 i18n/build.py` after editing.

## Guide is mandatory

`guide/` is the user reference of the Apple app: each entry says what a screen, a setting or a command does and
where to find it, in the current version. A new screen, sheet, settings section, `@AppStorage`/UserDefaults setting,
keymap command or onboarding step must have an entry in `guide/` in the same PR. A change that adds one without it
does not pass CI.

`scripts/check_guide.py` extracts the real list from the Swift code (`AppMode`, `Sheet`, `SettingsSection`, the keys
read by the Settings views, `Command` ids in `Keymap.swift`, `OnboardingStep`) and compares it with the
`covers:` keys of the entries. It fails on a missing element and on a key that names nothing in the code (a stale
guide). Run `python3 scripts/check_guide.py --list` to see what it extracts. It runs in `.claude/verify.sh` and in the
`apple` workflow.

Entry format: `## <Title>`, then `<!-- id: <unique>; covers: <kind:name, …>; status: planned -->` (status only for
features that are in the design but not working yet), a sentence or two, `Где:` with the path, the numbered steps,
and `Хоткей:` when the entry has a shortcut.
