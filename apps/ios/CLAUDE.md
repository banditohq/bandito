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
- The simulator is one, shared: `D7E3834B-1BA6-4071-9131-9FDEDE135C81` (iPhone 17 Pro). Do not create others. At the end of a task: `xcrun simctl shutdown all`.
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
- Debug launch arguments: `-chat <agent>` (Crew), `-chat-draft <text>`, `-chat-send <text>`, `-chat-top`, `-chat-row <id part>`.
  The demo agents answer (`Demo/DemoChatScript.swift`: commands, a streamed reply, an approval for Forge, two buttons).

## Known gaps before a release

- `AppIcon` is `brand/png/icon-1024.png` with an alpha channel; App Store Connect rejects an icon with alpha: flatten it
  before the first upload.
- `bandito://pair…` opens the connect sheet (shown and confirmed before anything is sent); the other `bandito://` links (`inbox`, `crew`, `agent/<server>/<agent>`) are read by `BanditoLink` (`Shared/WidgetSnapshot.swift`) and opened in `RootView`: the tab switches, and an agent opens its chat in the Crew (`CrewFocus`). A notification's press and the Inbox sheet's chat button take the same way.
- Not in the chat yet: reactions, reply quotes and mentions (the Mac has them), pictures that other clients sent (the daemon's file route is not reachable over `.direct`, so only pictures this phone sent show; others are a tile with the name), and a thread cache for a cold start without a connection (threads live in memory).
- The agent card (`Agent/AgentDetailView.swift`) and the creation sheet (`Agent/NewAgentSheet.swift`, `OneAgentForm.swift`)
  are built. The rules they use (`NewAgentModelRules`, `NewAgentFolderRules`, `ReadyTeamsLogic`, `AgentCapability`,
  `BotScheduleWords`) live in BanditoKit; `Agent/AgentForms.swift` holds only the form glue.
- The button styles (`.signal`, `.quiet`) exist only in `BanditoUI`; `SignalButtonStyle` in `Crew/TeamViews.swift` is a
  copy for this target until they move to `BanditoDesign`.
