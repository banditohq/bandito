# Bandito for iPhone — product and design spec

The phone is where the person *checks on* and *steers* the crew, not where the crew works. Every screen answers one of
four daily questions, in this order of frequency:

1. **Does anyone need me?** (approvals, forms, questions, failed runs) — answered in under 2 seconds from a cold start.
2. **What happened?** (overnight and since I last looked: finished turns, scheduled runs with something to say).
3. **Do this.** (give a task by text, voice, a photo or a shared link — in two taps from anywhere).
4. **How is it going?** (a long task in progress, a server's health).

Anything that serves none of these stays on the Mac.

## Information architecture

Tab bar, 4 tabs (iOS standard, thumb reachable):

| Tab | What | Badge |
|---|---|---|
| **Crew** (home) | "Needs you" cards on top, then the team: each agent with status, last line, unread count, mood avatar. Server switcher in the large title area. | none |
| **Inbox** | Everything that waits for the person across all servers and agents: approvals, forms, questions, connect requests. Swipe right Approve, left Deny; risky ones open a sheet with the full command. Empty state: a sleeping raccoon, "Nothing needs you". | count waiting |
| **Activity** | One timeline across agents: finished turns, scheduled runs that said something, errors, agent created. "Nothing new" quiet runs are hidden here. Filter chips: All / Mine to read / Errors. | unread finished |
| **Settings** | Servers (add, phone access, devices), notifications, Face ID lock, language, appearance, about, report a problem. | none |

Chat with an agent is pushed from Crew, Activity or a notification. A floating **New task** button (bottom right on Crew
and Activity) opens the composer with an agent picker (last used first).

## Key flows

- **First run**: Welcome (raccoon, one line, "Connect a server") → scan the QR from the Mac (Settings → Servers →
  Connect iPhone) or paste a `bandito://pair` link or type an address and code → name confirmation → notifications
  permission (asked only after the first server works, with the reason) → Crew. Under a minute.
- **Approve from the lock screen**: actionable notification "Forge wants to run git push origin feat/…" with Approve
  / Deny. Risky (push, deploy, delete, outside folder) → Approve needs Face ID. Without push service (phase 1) the
  same actions come from local notifications while the app is alive or refreshing in the background.
- **Task by voice**: long press the New task button → recording starts at once (dictation), release → picker shows the
  last agent, Send. Share sheet extension: "Send to Bandito agent" for text, links, images, files.
- **Read a result**: markdown rendered natively, code blocks horizontally scrollable with copy, long tool groups folded
  ("Ran 7 commands"), changes summary card ("12 files, +240 −30") opening a diff list. Links open in an in-app Safari
  view; ⌘-less phone: long press for "Open in Safari".
- **A long task**: Live Activity on the lock screen and Dynamic Island while a turn runs > 30 s: agent avatar, what it is
  doing now ("Running tests"), elapsed time, Stop. Ends with "Done" or "Needs you". (Built: `apps/ios/CLAUDE.md`, "Live Activities"; the switch is in Settings, Notifications.)

### Connecting a server (built)

- Three ways in, one sheet: the camera (framed viewfinder, haptic on read, the permission asked in place with its reason),
  the paste button (the system's, so no clipboard prompt), and a typed address (`host[:port]`, default 7879) with the six
  words and, if the person has it, the certificate fingerprint. `bandito://pair` links opened from outside use the same
  code and are confirmed before anything is sent.
- The app connects to the daemon's TLS listener, trying the addresses of the link in order (the last one that worked
  first, six seconds each) and trusting exactly the pinned SHA-256 of the certificate. An address typed with no
  fingerprint shows the one the server presents and waits for "They match" (trust on first use, confirmed by a person).
- Errors say what to do: code expired or used, too many tries, server unreachable (Tailscale? same Wi-Fi? phone access
  on?), and, loudly, a certificate that is not the pinned one ("This is not the server you paired", nothing was sent).
- The token goes to the Keychain (after first unlock, this device only); if it cannot be kept the device is revoked on
  the server again. Pairing a server whose certificate is already known replaces its record. Code: `apps/ios/Bandito/Connect`,
  `BanditoKit/Connect/DirectTransport.swift`, `DevicePairing.swift`.

### The chat (built)

- A list of reused cells over a diffable data source; message text is measured off the main thread and kept by
  (row, version, width); a streamed reply sets up only its own cell; older history comes in above without moving what is
  read; "down" shows the count of new messages and the list follows the bottom only while the person is there.
- Messages: Markdown read into blocks (headings, lists, quotes, rules, code with a horizontal scroll and Copy, links that open
  in the in-app Safari view, a long press for "Open in Safari" and "Copy"), pictures and files, the time under the last message
  of a group. Commands fold ("Ran 7 commands"). A finished turn with changes ends with the card "12 files, +240 −30", which
  opens the list of files and each file's diff.
- Inside the chat: approvals (a risky one asks for Face ID, as in the Inbox), forms, requests to connect, the agent's quick
  replies above the box, lines for scheduled runs and quiet turns, the working row with what the agent does and for how long.
- The box: grows to six lines, a button for photos, the camera and files (uploaded at once, shown as tiles), dictation
  (Apple's speech recognition, permission asked in place after a line of explanation), send and stop. A draft is kept per agent.
- Offline: a message written without a connection waits and goes out in order, once, when the connection is back.
- Haptics: light on send, success on an allowed request, warning on a refusal or a stop.
- Not yet: reactions, reply quotes, mentions, and the pictures other clients sent (see `apps/ios/CLAUDE.md`).

### The account (built)

Settings → Account (and the welcome step's "I have a Bandito account") signs in to bandito.dev: GitHub device flow or an
email code, the same Kit logic as the Mac. A new iPhone shows its own code and waits; a Mac approves it by comparing
codes, then the iPhone shows the Mac's code to confirm before it keeps the sync key. Then the servers of the account are
listed with their state: "Waiting for the Mac…" while a request is open, "Connected" once the Mac issued this iPhone a
token (docs/RELAY.md, "One account on every device"). Sign out parks the sync key, so signing in again needs no approval.
Code: `apps/ios/Bandito/Account/`.

## iOS-native extras (phase order)

1. Actionable notifications (local now, push later), Face ID lock (optional, off by default), haptics on approve/send. Built.
2. Widgets: small "Needs you: 2" (tap → Inbox), medium "Crew" (4 agents with status), lock screen circular count. Built.
3. Live Activities for running turns. Built (updated by the app; push updates wait for the APNs key).
4. App Intents / Shortcuts / Siri: "Ask Forge to …", "What needs me in Bandito". Built. Home screen quick actions:
   New task, Inbox. Built.
5. Share extension.
6. Spotlight: agents by name. Built.

## Look and feel

- Same brand as the Mac: tokens from BanditoDesign (dark first, light too), Unbounded for titles, Onest for text,
  raccoon avatars with moods (blink, smirk, sleep) drawn with Core Animation layers, not SwiftUI repeating animations.
- iOS conventions over Mac habits: large titles, tab bar, swipe actions, sheets with detents, context menus on long
  press, pull to refresh only where it means "check now" (Crew, Activity), system materials for bars.
- Motion: the brand curves (fast 0.12, base 0.2, slow 0.32, slide spring 0.36/0.9), every enter has an exit, respects
  Reduce Motion. Haptics: light on send, success on approve, warning on deny.
- Dynamic Type up to XXL without clipping; VoiceOver labels on every control; 9 languages.

## Speed (same bar as the Mac)

- 120 Hz on ProMotion: chat and lists never drop frames while scrolling; typing redraws only the field.
- Cold start to Crew with cached data < 400 ms (last state stored on disk, then live update).
- Chat: UICollectionView with diffable data source and reused cells; message text laid out off the main thread and
  cached by (id, version, width); a streamed reply reconfigures only its own cell.
- Work-budget tests like the Mac's `WorkBudgetTests`: scroll, typing, stream, agent switch.

## Reliability and privacy

- Offline: cached crew and last 200 events per agent readable; messages typed offline queue and send on reconnect
  (shown as "Waiting for connection").
- Reconnect with backoff; a server that refuses the device token shows "Paired again needed" with the steps.
- Device token in the Keychain (this device only), TLS with the pinned fingerprint from pairing; no server address or
  token ever in logs or analytics.

## Phases

1. **Core** (tonight): scaffold, pairing (QR, link, manual), Crew, Chat (read + send + stream), Inbox (approve / deny /
   forms / quick replies), Settings basics, local notifications, Face ID lock.
2. **Daily use**: Activity tab, New task button with voice, share extension, widgets, changes summary, agent details and
   new agent (with ready teams).
3. **Push and live**: push.bandito.dev (APNs key from the owner), notification service extension (decrypt), Live
   Activities, App Intents.
4. **Reach**: in-app SSH, Bandito Relay, iPad layout.

Each phase is accepted on simulator screenshots of every screen (dark/light, ru/en, small and large iPhone, XXL type),
XCUITest flows, work-budget tests, and the Mac suites staying green.

## Onboarding (iPhone and Mac, one story)

The first five minutes decide whether a person stays. Onboarding is a short film in the brand's heist voice that ends with
a real result: an agent that has done something for the person.

1. **Welcome.** The raccoon assembles from points of light (the website hero, as a Core Animation layer: 60–120 fps,
   static under Reduce Motion), then the title "Your crew is ready" and one line. One button: "Let's go". A small
   "I already have a server" link skips to step 3.
2. **What you get** (3 cards, swipe on iPhone, arrows/keys on Mac, auto-advance off): "A crew, not a chat" (the team
   lineup with moods), "Nothing risky without you" (an approval card that the person can press — it reacts), "Works
   while you sleep" (the night-shift strip). Each card is live, not a screenshot. Skippable.
3. **Where your crew lives.** Mac: "This Mac" (recommended, installs the daemon with progress) or "A server" (SSH or
   address). iPhone: "Scan the code from your Mac" (camera opens in place, with a framed viewfinder and haptic on read),
   "Paste a link", "Type an address". Errors are plain and say what to do next.
4. **Who does the work.** Detects Claude Code / Codex / Grok on the server; missing ones get "Install" with progress,
   and "Sign in" opens the CLI's sign-in where needed. At least one ready runtime to continue; others can wait.
5. **Hire your first crew.** Ready teams (Web project, Server on duty, Morning summary, Docs) or "Just one agent";
   a preview of agents, rights and schedules; one tap creates them. Folder picker on Mac; on iPhone the server's agents
   folder.
6. **First task.** Four suggestions written for the chosen crew ("Look around this project and tell me what it does",
   "Check the server's disk and updates"), or type your own. Sending it lands in the chat with the reply streaming —
   onboarding ends inside a working conversation, not on an empty screen.
7. **Just in time, not up front:** notifications are asked when the first approval or finished turn happens ("Want to
   know when Forge needs you?"), camera when scanning, microphone at the first dictation.

Rules: a progress line of steps at the top, Back always works, everything is resumable after quitting, nothing blocks
on the network without a visible state, 9 languages, Dynamic Type, VoiceOver, dark and light. Mac and iPhone share the
copy and the order; only the controls differ.
