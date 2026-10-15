# Bandito iPhone app — notes for agents

Before any work on the iPhone app read `docs/IOS_APP.md` (the product spec: tabs, flows, what is built and what is not).

SwiftUI, iOS 17+, iPhone only, dark and light. The app is a thin shell (`apps/ios/Bandito`); the shared code is the
SwiftPM package `apps/mac/BanditoKit` (`BanditoKit` core, `BanditoDesign` tokens and fonts, `BanditoL10n` strings).
`BanditoUI` is macOS only: do not import it or copy its views into this target. Shared pieces that a screen needs
(the raccoon, the buttons) move to `BanditoDesign` first, in their own change.

## Build, test, look

- `bash apps/ios/scripts/build.sh` — xcodegen + build for the Simulator, no signing. Prints the `.app`. Products go to
  `~/.cache/bandito-ios/<checkout>`; the log of a failed build is there too.
- Tests: `xcodebuild -project apps/ios/BanditoIOS.xcodeproj -scheme BanditoIOS -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath ~/.cache/bandito-ios/<checkout> -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO "BUILD_DIR=<same>/Build/Products" "OBJROOT=<same>/Build/Intermediates.noindex" test`. Swift Testing, hosted in the app (`@testable import Bandito`: the module is named after the product).
- Screenshots: `bash apps/ios/scripts/shot.sh <out.png> [launch args]` boots the shared simulator headless, installs, launches, and writes `<out>.png` and `<out>_s.png` (800 px). `-demo` shows the demo team.
- Simulators: agents use `C6387D27-7A6C-4B71-8312-98CFE8C73EFE` ("Bandito iPhone 2", one agent at a time: check `pgrep -fl "xcodebuild.*C6387D27"` first). `D7E3834B-1BA6-4071-9131-9FDEDE135C81` (iPhone 17 Pro) is the owner's: never run, install, boot or shut down anything on it. Do not create others. Never `simctl shutdown all`.
- The owner's Mac may be asleep: never touch `~/.bandito`, `/Applications/Bandito.app` or anything outside the simulator.
  Interaction with the simulator is through XCUITest; screenshots through `xcrun simctl io`. Close Simulator.app when done.
- After a Swift build: `git checkout -- apps/mac/BanditoKit/Package.resolved` (the build rewrites it).

## Connecting a server (what to keep true)

- The device token only ever goes to a server whose certificate matches the pinned SHA-256 (`DirectTransport`); the
  system trust store is never used for these servers. A link that arrives from outside (paste, `bandito://`) is shown
  and confirmed before anything is sent; an address typed without a fingerprint shows what the server presents first.
- A server can also be reached through Bandito Relay (`docs/RELAY.md`): `ServerEndpoint.reachable` holds the direct addresses
  (with the pin) and/or the relay route with the daemon's Noise key; `ReachableTransport` tries the addresses first, then
  `RelayTransport` (Noise IK end to end, the relay only forwards bytes). The phone's Noise private key is kept in the
  Keychain next to the token (`ServerSession.noiseAccount`, never in `servers.v1`). A relay-only link has no fingerprint and
  is still shown and confirmed before anything is sent. The bytes of `NoiseIK` are checked against `snow` vectors
  (`daemon/tests/fixtures/noise_ik_vectors.json`, `NoiseVectorTests`).
- The token lives in the Keychain (`ServerSession`, one item per server); the saved list (`servers.v1`) never holds it.
  A token that cannot be saved is revoked on the daemon at once.
- `ServerSession.shared` is the one list of servers (paired ones, or the `-demo` world): Crew, Inbox, Activity, Settings,
  notifications, the background check, widgets, App Intents and Spotlight all read `session.current`. The saved list is a
  file in Application Support, left out of backups (`ServerStore`). A server name is cleaned (`ServerNameRules`) wherever
  it comes from or is typed. Notifications are asked once, after the first server, with the reason (`NotificationAsk`).
- Sign in with a Mac (`IOSAccount.join`, `Account/JoinScanner.swift`): a `bandito://join` code (scanner, connect sheet, `onOpenURL`) redeems a ticket; the envelope is accepted without a question only when `JoinTicket.isFromMac` says that Mac sealed it, else the old code comparison (`compareManually`). A signed-in phone is not signed in again (toast and `openFastWindow`). A debug build takes `-accountBaseURL <loopback url>` for a local cloud.
- A `.sheet(isPresented:)` that reads other state sees the old value of it: open the connect sheet with `.sheet(item:)`
  (`ConnectRequest`).
- UI tests of the flow: target `BanditoIOSPairing` (fake TLS daemon on the Simulator's loopback, `-resetServers`);
  `PairingS4ScreenshotTests` makes the pictures.

## Rules

- Every string goes through i18n (`i18n/*.json`, 9 languages, `python3 i18n/build.py`), used as `L10n.*`. Reuse
  existing keys first (`status.*`, `sidebar.team`, `settings.title`, `common.close`). Only `InfoPlist.strings` may hold
  a literal (permission texts, in `Bandito/Resources/<lang>.lproj`).
- Colors, fonts, spacing only from `BanditoDesign` (`Color.Bandito.*`, `BanditoFont`, `BanditoSpace`). No hex, no
  `.font(.system(...))` for text. SF Symbols are fine.
- Logic lives in small pure types next to the view; `IOSDemo` is the demo world (`-demo`), nothing else reads it.
- The app's bundle id is `dev.bandito.ios`; the debug and release builds are not yet split. Signing is not set up.

## The raccoon and the Crew

- The raccoon's geometry and mood timing are shared: `BanditoDesign/RaccoonShape.swift` (`RaccoonFace`, masks, eyes,
  `AvatarTile` colors) and `BanditoDesign/AvatarPose.swift` (`AvatarMood`, `AvatarPose`, `MotionKeyframes`). The head of
  the logo and the onboarding's lights are shared too: `BanditoDesign/RaccoonHead.swift` (the head's path and grid),
  `RaccoonLights.swift` (the figure as values) and `RaccoonLightsLayer.swift` (the Core Animation layer; the iPhone's
  `RaccoonLightsView` in `Onboarding/RaccoonLights.swift` only hosts it). The iPhone
  moves them with Core Animation layers (`Crew/CrewAvatar.swift`, `RaccoonMotionView`), never a SwiftUI repeating
  animation; Reduce Motion draws the rest pose.
- Crew (`Crew/`): facts per agent in `CrewFacts.swift` (`Equatable`), rows in `CrewRows.swift`. The screen counts row
  evaluations in `CrewCounters`; `CrewSpeedTests` holds a streamed reply to at most two row evaluations.
- The large title is the system's; the navigation bar background is transparent (`toolbarBackground(.hidden)`). A UIKit
  navigation appearance hid the title (see `BrandAppearance.swift`), so the bar is not styled in UIKit.

## The chat (`Chat/`)

The screen every day. Read the rules before changing it; each came from the Mac's freezes.

- The list is a `UICollectionView` with a diffable data source over `ChatListLayout` (a running sum of row heights, no
  self-sizing). `ChatModel` turns the thread into `ChatRow`s (`ChatRowBuilder`, pure, off the main thread) and says what
  changed (`ChatUpdate`); `ChatViewController` applies it, sets up only the cells of changed rows (`reconfigureItems`; a row
  that becomes another kind of row, as an approval card that is answered becomes a line, is `reloadItems`: a reconfigure
  with another cell kind crashes) and keeps the reading place (`ThreadAnchor`) or the bottom.
- Text is measured off the main thread by `ChatLayoutEngine`, once per (row id, row version, width, size category); the
  cells only place what it measured (`ChatTextView` draws an attributed string, no `UITextView`/`UILabel` per message).
  A new kind of row is a new layout type there and a cell in `ChatCells.swift`.
- Rare, form-heavy rows (an approval, a form, a connect request) are SwiftUI in `ChatHostedCell`; their height is measured by
  hosting them once (`ChatHostedSizer`) and again when the card says it changed. Their SwiftUI root has `.id(row id)`: a reused
  cell must not keep another row's typed text.
- Never read the thread in the screen: `ChatModel` follows it with one observation, folds a stream's tokens into one update
  per turn of the main actor, and the frame (header, box, quick replies) reads `threadSummary(for:)`.
- The message box is read only by itself; the screen hears about the first and the last character (`onHasContentChange`).
- Messages go through `ChatOutbox` (a file, `SendQueue`): written without a connection they wait ("Waiting for connection"),
  leave in order, once. The daemon has no client id: a send that ended without an answer is checked against the thread
  (more messages with its text than when the attempt began) before it is sent again.
- Budgets (`ChatSpeedTests`, counted not timed): a stream of 100 pieces sets up one cell and measures one row per update;
  typing touches no row; scrolling 500 messages measures each row once. `ChatCounters` has the numbers.
- The list and the box are placed by frames, never by constraints between them (`ChatFrameRules.frames`, pure and tested):
  the box is on the bottom edge (above the home indicator), or on the keyboard's top, and the list has the rest, with a floor
  (`min(120, a quarter of the room)`), so an empty or loading list can never hand the free space to the box and a keyboard
  frame the system reports wrongly for a moment (a screenshot, a trait change) cannot carry the box up. The keyboard is read
  from a hidden view tied to `view.keyboardLayoutGuide.topAnchor` (the interactive dismiss and the animation stay), and only
  counts while the box's field is first responder or the keyboard is on its way down (`keyboardWillHide`). The box's height
  is `composer.fittingHeight(width:)`. Screenshots and `didBecomeActive` lay the screen out again at once and 0.4 s later.
  Do not put the list or the box back on Auto Layout against each other.
- What stands in the list's place (`updateOverlays`): a spinner while the history is read (after 0.3 s, so a quick read does
  not flash it), "Couldn't load the chat" with "Try again" (`chat.loadFailed`, `chat.retryLoad`; `ChatModel.retryLoad`) when
  it could not be read and nothing is saved, the empty chat's invitation only when there is truly nothing (not loading, no
  error). A history whose newest page shows no row (only tool calls) reads older pages (up to 10) before saying "empty".
- Saved history (`ChatHistoryCache`): the last 200 items per (server, agent) as JSON in
  `Application Support/ChatCache/<server uuid>/<agent>.json`, `completeUntilFirstUserAuthentication`, out of the iCloud backup.
  Text and metadata only (no files, no tool calls, no cards that wait for an answer, no stream; a message is cut at 20 000
  characters). `ChatModel` draws it while `summary.loaded` is false and replaces it with the server's thread (never a merge);
  it writes 1.5 s after the thread settles, when the screen goes away and when the app goes to the background. Synthetic
  (demo) agents are never saved. It is removed with the server (`ServerSession.remove/forget/reset`), with the agent
  (`AgentDetailModel.delete`) and pruned to the agents a server lists (`saveAgentCaches`, only for a server whose list was read).
- Long press on a message (`ChatMessageMenu`, pure): the preview is the bubble itself (`UITargetedPreview` with the bubble's
  path), above the menu a palette of the Mac's 16 quick reactions (`ReactionRules.common`, two rows; the person's own is marked
  and a second tap takes it off), then Reply (a quote above the box; `QueuedSend.replyTo` goes out as `replyTo`), Copy, Copy
  Markdown (only when it differs), Select text (`ChatSelectTextController`, a sheet), Share, Send again, Try again / Delete for a
  message still on the phone. A message without a `seq` (a stream, a teammate's, still on the phone) or a server without the
  feature (`reactions`, `attachments`) offers no reaction/reply. Reactions are drawn under the bubble as capsules and show at
  once (`ChatModel.react`, the daemon's event lets the stand-in go; a refusal takes it back with an error buzz and an alert).
  A tap on a quote jumps to the original (older pages are read, up to 12). A tap of the Taptic Engine opens the menu.
- Read marks: `markReadIfSeen` (`ChatSeenRules`) asks `ThreadSummary.markRead()` whenever the end can have come into view and
  the screen is visible in an active app: on appearing, on every applied update, on scrolling to the bottom, on
  `didBecomeActive`, after the history is read. A short list that fits counts as at its end; a chat opened from Activity
  (`focusRowID`) counts as looked at wherever it opens.
- Debug launch arguments: `-chat <agent>` (Crew), `-chat-draft <text>`, `-chat-send <text>`, `-chat-top`, `-chat-row <id part>`.
  The demo agents answer (`Demo/DemoChatScript.swift`: commands, a streamed reply, an approval for Forge, two buttons).

## New task (`NewTask/`)

- The floating button is on the roots of Crew and Activity only (environment `newTaskAction`, set by RootView) and only
  when some server has an agent. It is the main button of the design system: cream with the orange dot, the floating
  shadow. A tap opens the sheet; a press held 0.35 s opens it with the dictation on (it fires while the finger is down;
  the flags reset through `@GestureState`, so the next tap is never swallowed).
- `NewTaskRules` (pure, tested) orders the agents (last used first), says when Send is enabled and whether the
  microphone is offered. Sending opens the agent's chat with the task (`LinksAndNewTaskUITests`).
- The app icon's actions (`QuickActions.swift`: New task, Inbox) are set in code and read by a small app delegate and a
  scene delegate; `bandito://` links keep working through the scene delegate. With Face ID lock on, an action waits for
  the unlock.

## Crew details

- "Waits for you" shows at most two cards (`CrewWaitingSplit`, from `InboxRules`) and "N more — in the Inbox". An
  approval is answered right on the card through `InboxAnswer` (Face ID when the lock asks for it, as in the Inbox).
- A running agent shows what it does now and for how long (`WorkingLine`, `AgentActivity.current(running:)`), in the row
  and the chat header; the timer is `Text(timerInterval:)`, so the list does not redraw every second.
- Rows switch to a stacked layout at accessibility text sizes (`AdaptiveRowLayout`); button pairs use `AnswerPair`
  (`ViewThatFits`: side by side, else stacked). Previews show plain text (`MessageBlocks.plainText`), not markdown.

## Live Activities (`LiveActivity/`, `Shared/TurnActivity*.swift`)

- A turn that runs 30 seconds gets an activity (agent avatar, "what it does now", time, Stop); it ends on Done, Needs you
  or a failure. `TurnActivityRules` (pure, `TurnActivityRulesTests`) decides; `TurnActivities.shared` applies it to
  ActivityKit and is fed by `IOSNotifications.attach` (`ingest`), RootView (foreground, servers, the setting).
- One activity per (server, agent), three running at most; `pushType: nil` (the app updates it itself, so a request needs
  the foreground: a turn that passes 30 s in the background gets its activity when the app returns). `doing` changes at most
  every 5 s. Ended ones stay 15 minutes (an hour on "needs you"). Orphans of a killed run are swept 15 s after launch.
- Stop is `StopTurnIntent` (a `LiveActivityIntent`, runs in the app via `TurnStopRelay`), no connection leaves the activity and says so.
- The extension draws only (`TurnActivityViews.swift`): static raccoon, no animation. Do not put a `BanditoFont` font on
  `Text(timerInterval:)`: the system archives that text and the extension crashes (the timer uses the system's mono font).
- Debug: `-demo -live-demo` starts Forge's activity, "Done" after 20 s (`-live-demo-seconds N`). On the Simulator the first
  request asks the system's consent on the lock screen ("Always allow"); the Island's pixels are not in `simctl` screenshots.
## The share extension (`BanditoShare/`)

- `ShareViewController` hosts the SwiftUI `ShareView`; `ShareModel` is its state. The agents come from the widget snapshot's
  `directory` (so no server list of its own). The extension writes `ShareInbox` and opens `bandito://share/<id>` through the
  responder chain (no `UIApplication.shared` in an extension); it never calls a server and never reads the Keychain.
- The app side is `Share/ShareImporter.swift` (drained on a `.share` link, on `.active`, when servers load and when one
  connects; not while Face ID covers the app). Remove a task only after `ChatOutbox.enqueue`.
- `ShareView` and `ShareModel` are also compiled into the app for `-share-preview` (DEBUG; `-share-empty` for no agents).
- `NSExtensionActivationSupportsImageWithMaxCount` is 4: with 5 or more photos selected the system does not offer Bandito at
  all (the rule is all-or-nothing, the extension cannot take the first four). Text and one link have no such limit.
- The extension always ends on the saved screen (a check, "Done"): opening the app from it does not work on iOS 18+, so it
  leaves a local reminder (`share-<id>`, only if notifications are allowed) whose press opens `bandito://share/<id>`.
  The importer takes the reminder down. A task is dropped (with a toast) when its agent is gone after one list refresh, or
  after 5 failed uploads (`SharedTask.attempts`); uploaded pictures are kept in `task.json` and not sent twice.
- The extension has a ~120 MB memory limit: pictures are read one at a time and shrunk with ImageIO (`ShareLoader`).

## Push (`Push/`, `SharedPush/`, `BanditoNotify/`)

- Target `BanditoNotify` (Notification Service Extension, `dev.bandito.ios.notify`) opens a push with the server's key and makes
  the notification with the same code as the app (`PhoneNotice`, `SharedPush/PushNotice.swift`). `SharedPush/` is compiled into
  the app and the extension only (it uses BanditoKit; `Shared/` also goes into the widgets and Share, which do not).
- Keys and the cloud handle are in the Keychain under the access group `group.dev.bandito.ios` (`PushKeychain`); never log
  a key, a handle or a token. Push does not work in an unsigned build (no Keychain group, no token): sign for the Simulator
  (`CODE_SIGN_IDENTITY=-` with the entitlements, or the team's automatic signing) to try it. Full description: `docs/IOS_APP.md`, "Push on the phone".
- Try it on the Simulator: allow notifications, read `Documents/push-debug.json` in the app's data container (DEBUG), then
  `xcrun simctl push <udid> dev.bandito.ios x.apns` with a payload sealed with a key from `-push-test-key`, or send through the cloud.

## Known gaps before a release

- `bandito://pair…` opens the connect sheet (shown and confirmed before anything is sent); the other `bandito://` links (`inbox`, `crew`, `agent/<server>/<agent>`) are read by `BanditoLink` (`Shared/WidgetSnapshot.swift`) and opened in `RootView`: the tab switches, and an agent opens its chat in the Crew (`CrewFocus`). A notification's press and the Inbox sheet's chat button take the same way.
- Not in the chat yet: mentions (the Mac has them), reading a message aloud, and pictures that other clients sent (the daemon's file route is not reachable over `.direct`, so only pictures this phone sent show; others are a tile with the name).
- The agent card (`Agent/AgentDetailView.swift`) and the creation sheet (`Agent/NewAgentSheet.swift`, `OneAgentForm.swift`)
  are built. The rules they use (`NewAgentModelRules`, `NewAgentFolderRules`, `ReadyTeamsLogic`, `AgentCapability`,
  `BotScheduleWords`) live in BanditoKit; `Agent/AgentForms.swift` holds only the form glue.
- The button styles (`.signal`, `.quiet`) exist only in `BanditoUI`; `SignalButtonStyle` in `Crew/TeamViews.swift` is a
  copy for this target until they move to `BanditoDesign`.
