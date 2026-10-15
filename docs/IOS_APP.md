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
  / Deny. Risky (push, deploy, delete, outside folder) → Approve needs Face ID. With push (see "Push on the phone") the
  same actions arrive while the app is closed; without it (an older daemon) they come from local notifications while the
  app is alive or refreshing in the background.
- **Task by voice**: long press the New task button → recording starts at once (dictation), release → picker shows the
  last agent, Send. Share sheet extension (built): "Share" → Bandito in any app (text, a link, up to 4 pictures) → pick an
  agent → Send; Bandito opens on that agent's chat. The extension never reaches a server and never reads a token: it leaves
  the task in the App Group (`Shared/ShareInbox.swift`, `<group>/Share/<id>/`), opens `bandito://share/<id>` and the app
  (`Share/ShareImporter.swift`) uploads the pictures and queues the message in `ChatOutbox`; the task is deleted only
  after it is queued, and one that cannot go yet (pictures, server offline) waits. Tasks older than 7 days are dropped.
  If the extension cannot open the app it says so and the task goes the next time Bandito is opened. Files are not taken yet.
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
- Offline: a message written without a connection waits and goes out in order, once, when the connection is back. The last 200
  items of each chat are kept on the phone (text only, behind the first unlock, out of the iCloud backup), so a chat opens with
  its history while the connection is made or missing, and the server's history replaces it when it arrives. If the history
  cannot be read and nothing is saved, the chat says so and offers "Try again" (never a blank screen).
- Long press on a message: the bubble lifts, a row of quick reactions (the Mac's) is over the menu (Reply, Copy, Select text,
  Share; Send again for an undelivered one). Reactions sit under the bubble; a reply quotes the original above the box and in the
  bubble, and a tap on the quote goes to it.
- Read: a chat opened (a short one that fits, the end of a long one, an Activity entry), or one that is open when the app comes
  back or the history is read, is marked read, so the badge on Activity and the unread dots go away.
- The message box is always on the bottom edge (or on the keyboard); the list has the rest, in every state.
- Haptics: light on send, medium when the message menu opens, success on an allowed request, warning on a refusal or a stop,
  error when a reaction is refused.
- Not yet: mentions, reading aloud, and the pictures other clients sent (see `apps/ios/CLAUDE.md`).

### The account (built)

Settings → Account (and the welcome step's "I have a Bandito account") signs in to bandito.dev: GitHub device flow or an
email code, the same Kit logic as the Mac. A new iPhone shows its own code and waits; a Mac approves it by comparing
codes, then the iPhone shows the Mac's code to confirm before it keeps the sync key. Then the servers of the account are
listed with their state: "Waiting for the Mac…" while a request is open, "Connected" once the Mac issued this iPhone a
token (docs/RELAY.md, "One account on every device"). Sign out parks the sync key, so signing in again needs no approval. Without a signed-in account, Settings lists the servers this iPhone has by code under "Servers on this iPhone"
("Connected by code"), and the account row reads "Sign in to the account" with "Then your Mac's servers will appear here by themselves".
"Sign in with a Mac" is the first button of the sign-in screen: the Mac shows a QR code (profile → Devices → "Add iPhone or
iPad", or the Connect iPhone wizard), the iPhone scans it (the in-app scanner, the connect sheet's scanner, or the system
camera, which opens `bandito://join`), redeems the ticket and takes the key from that Mac without a code to compare: the key
counts only when its sender is the Mac of the code. A phone that is signed in already says so and asks for its servers
(docs/ACCOUNTS_API.md, "Sign in with a Mac"). Code: `apps/ios/Bandito/Account/`.

## iOS-native extras (phase order)

1. Actionable notifications (local, and push through the Bandito cloud), Face ID lock (optional, off by default), haptics on approve/send. Built.
2. Widgets: small "Needs you: 2" (tap → Inbox), medium "Crew" (4 agents with status), lock screen circular count. Built.
3. Live Activities for running turns. Built (updated by the app; push updates wait for the APNs key).
4. App Intents / Shortcuts / Siri: "Ask Forge to …", "What needs me in Bandito". Built. Home screen quick actions:
   New task, Inbox. Built.
5. Share extension. Built (see `apps/ios/CLAUDE.md`).
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
3. **Push and live**: push through the Bandito cloud (APNs key from the owner), notification service extension (decrypt;
   format below), Live Activities, App Intents.
4. **Reach**: in-app SSH, Bandito Relay, iPad layout.

Each phase is accepted on simulator screenshots of every screen (dark/light, ru/en, small and large iPhone, XXL type),
XCUITest flows, work-budget tests, and the Mac suites staying green.

### Push payload (for the notification service extension)

The daemon registers per device with `push.register {handle, key, serverRef, kinds}` (docs/ARCHITECTURE.md#push): the
phone makes a random 32-byte key for each server, keeps it in the shared Keychain, and sends it with the handle the
cloud gave it. A push carries `ct` and `nonce` as the daemon sent them (base64, standard, padded).

- Decrypt: ChaCha20-Poly1305, key = the server's 32 bytes, nonce = the 12 bytes of `nonce`, associated data = the UTF-8
  text `bandito-push:v1:<handle>`. `ct` is the ciphertext followed by the 16-byte tag:

  ```swift
  let raw = Data(base64Encoded: ct)!
  let box = try ChaChaPoly.SealedBox(nonce: .init(data: Data(base64Encoded: nonce)!),
                                     ciphertext: raw.dropLast(16), tag: raw.suffix(16))
  let json = try ChaChaPoly.open(box, using: key, authenticating: Data("bandito-push:v1:\(handle)".utf8))
  ```

- Parse the JSON: `{"v":1,"srv":serverRef,"seq":Int,"agent":agentID,"name":agentName,"ts":ms,"event":{"kind":..,"payload":{..}}}`.
  `srv` says which server it is (the name the phone gave it at `push.register`). `event` is an event body exactly as
  `events.since` returns it (decode it with `Event`'s body decoder, with `agent_id`, `seq` and `ts` from the outer
  fields). Build the notification from it like the local one (`IOSNotifications.notice(for:)`).
- Long texts are cut (300 characters, `…`); if the event was too big, `payload` holds only `approval_id`, `form_id` or
  `request_id`: show a generic text for the kind and open the app to `events.since` for the rest.
- The actions follow the decrypted event: `approval.requested` gets Approve and Deny. `collapseId` is `b<seq>`, so the
  same event shown by the app as a local notification replaces the push.
- A push that cannot be opened (no key for that server, bad tag) is shown with a generic text, never dropped.

### Push on the phone (built)

Notifications arrive with the app closed: the daemon sends an encrypted push through the Bandito cloud and Apple; the
notification service extension opens it and makes the same notification the app makes from a live event, in the phone's
language. Code: `apps/ios/Bandito/Push/` (the app side), `apps/ios/SharedPush/` (compiled into the app and the extension),
`apps/ios/BanditoNotify/` (the extension, `NotifyService`).

- **Entitlements.** The app has `aps-environment` (`development`; Xcode makes it `production` when it signs for TestFlight
  or the App Store). `BanditoNotify` is a Notification Service Extension (`dev.bandito.ios.notify`) in the App Group
  `group.dev.bandito.ios`. `UIBackgroundModes` is unchanged: a push with `mutable-content` needs no background mode.
- **Keychain.** `PushKeychain` keeps, under the access group `group.dev.bandito.ios` (an app group is a valid keychain
  access group on iOS; service `dev.bandito.ios.push`, readable after the first unlock, this device only): one random
  32-byte key per server (`push.key.<serverRef>`, `serverRef` = the server's UUID string), and the cloud address
  (`push.handle`, with the `push.token` and `push.env` it was made for). Plain values the extension reads are in the
  group's UserDefaults (`PushShared`): `push.seen.<serverRef>` (the ring of seen seqs) and the Face ID choice for risky approvals.
- **Cloud address** (`PushDevice`). While notifications are allowed the app asks Apple for a token at every launch
  (`registerForRemoteNotifications`, from `PushCoordinator`; the permission is read again when the app comes to the front).
  The token (hex) and the environment go to `POST /push/register {apnsToken, env, bundleId}` and the answer's `handle` is kept.
  `env` is `sandbox` on the Simulator and in debug builds; otherwise it is read from `aps-environment` in
  `embedded.mobileprovision` (`development` is sandbox), and a build with no profile (the App Store) is `production`
  (`PushEnvironment`). A new token, a new environment, or a day later registers again; the old handle is unregistered
  (silently). A 409 (the token is known in the other environment) is retried once with the other
  environment; if that works the environment is kept in the Keychain next to the handle (`push.envFixed`), if not the handle is
  dropped, the next launch tries again, and Settings > Notifications shows a grey line "Push unavailable" (the app's own
  notices still work). No network or a refusal is retried at the next launch or when a server connects (not sooner than a
  minute); while no handle is known the registrar also retries by itself after 30 s, 2 min, 10 min, then every hour. A handle is used only after
  this launch has confirmed it: after a reinstall the Keychain still holds the earlier install's handle and keys.
- **Servers** (`PushRegistrar`). A server that is connected, has `"push"` in `daemon.info.features`, with a confirmed handle
  and notifications allowed gets `push.register {handle, key, serverRef, kinds, lang}`. `kinds` follow the Notifications
  switches (approvals and questions: "needs you"; `done`: answers; `error`: errors), `lang` is the phone's first language.
  What was told is remembered per server (a hash of handle, kinds, language and the first 8 bytes of the SHA-256 of the server's key, in UserDefaults), so it is repeated only
  when one of them changes (a new key or a forget resets it), and once a day. A server that connects is asked `push.status` once: if the daemon lost the
  registration the cloud is asked again and then the daemon. Notifications off, or every switch off, sends
  `push.unregister` to every connected server (once). A server removed from the phone is told to stop (when reachable;
  disconnecting revokes the device, which removes it on the daemon) and its key is deleted; keys of servers that are not in
  the list are deleted too. Servers without `"push"` are never touched. Demo servers never register.
- **A replaced handle.** The Keychain keeps the previous handle with its date (`push.handle.prev`, `push.handle.prevAt`). The
  extension tries the associated data of the current handle, then of the previous one (younger than 7 days), so a push sent
  before the server learnt the new handle still opens. The previous handle is deleted once every push server the phone has
  registered carries the new one.
- **The extension.** It tries each server's key against `ct`/`nonce` (ChaCha20-Poly1305, associated data
  `bandito-push:v1:<handle>`), reads the payload, and builds the notification with the same code as the app (`PhoneNotice`:
  event, then `AgentNotice` and `NotificationContent`, in `SharedPush/PushNotice.swift`): title, text, category
  (`bandito.approval`, `.approval.review`, `.approval.risky`, `.finished`, `.failed`, `.form`, `.question`: the app registers
  them), `threadIdentifier` = the agent, and `userInfo` (`agentID`, `approvalID`, `formID`, `risky`, `server`), so Allow,
  Deny and Reply work as on a local notification. An event the daemon cut down (no payload) still gets the text of its kind;
  one that cannot be opened keeps the cloud's own English text, with the finished category (no buttons). When it runs out of
  time (`serviceExtensionTimeWillExpire`) it shows what it has. The server's name is not used (neither is it in the local
  notice).
- **No repeats.** The extension records the seq of each event it showed in a ring of the last 200 per server
  (`push.seen.<serverRef>` in the group's UserDefaults) and takes down a local notification of the same event
  (`<server>:<seq>`). The app's `ingest` makes no local notice for an event whose seq is in that set (the cursor moves as
  always); an earlier event whose push never came is still shown. So the background check does not repeat a push. A push that arrives while the app is on
  the screen is not shown (`willPresent` returns no options, as for local notices); the app shows its own.
- **Buttons with the app closed.** A press on Allow, Deny or Reply wakes the app: it reads the saved servers, connects the
  one named in the notification's `server` (older notices without it: the one that has the agent), sends the answer, and only then returns to the system (20 seconds at most).
- **Debug.** `-push-test-key <base64 32 bytes>` (DEBUG) keeps a known key for the server `TEST`; `Documents/push-debug.json`
  holds the token, the handle and the environment. On the Simulator (Apple silicon) a push can be sent with
  `xcrun simctl push <udid> dev.bandito.ios file.apns`, or through the cloud with the handle (`POST /push/send`).

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
