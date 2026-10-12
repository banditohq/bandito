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

## Known gaps before a release

- `AppIcon` is `brand/png/icon-1024.png` with an alpha channel; App Store Connect rejects an icon with alpha: flatten it
  before the first upload.
- `bandito://pair…` opens the connect sheet (shown and confirmed before anything is sent); the other `bandito://` links (`inbox`, `crew`, `agent/<server>/<agent>`) are read by `BanditoLink` (`Shared/WidgetSnapshot.swift`) and opened in `RootView`: the tab switches, and an agent opens its row in the Crew (the chat is still a stub).
- The chat is a stub (Crew shows it as "coming soon").
- The agent card (`Agent/AgentDetailView.swift`) and the creation sheet (`Agent/NewAgentSheet.swift`, `OneAgentForm.swift`)
  are built. The rules they use (`NewAgentModelRules`, `NewAgentFolderRules`, `ReadyTeamsLogic`, `AgentCapability`,
  `BotScheduleWords`) live in BanditoKit; `Agent/AgentForms.swift` holds only the form glue.
- The button styles (`.signal`, `.quiet`) exist only in `BanditoUI`; `SignalButtonStyle` in `Crew/TeamViews.swift` is a
  copy for this target until they move to `BanditoDesign`.
