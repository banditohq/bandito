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

## Rules

- Every string goes through i18n (`i18n/*.json`, 9 languages, `python3 i18n/build.py`), used as `L10n.*`. Reuse
  existing keys first (`status.*`, `sidebar.team`, `settings.title`, `common.close`). Only `InfoPlist.strings` may hold
  a literal (permission texts, in `Bandito/Resources/<lang>.lproj`).
- Colors, fonts, spacing only from `BanditoDesign` (`Color.Bandito.*`, `BanditoFont`, `BanditoSpace`). No hex, no
  `.font(.system(...))` for text. SF Symbols are fine.
- Logic lives in small pure types next to the view; `IOSDemo` is the demo world (`-demo`), nothing else reads it.
- The app's bundle id is `dev.bandito.ios`; the debug and release builds are not yet split. Signing is not set up.

## Known gaps before a release

- `AppIcon` is `brand/png/icon-1024.png` with an alpha channel; App Store Connect rejects an icon with alpha: flatten it
  before the first upload.
- The pairing flow (QR, link, address) is a placeholder sheet. The `bandito://` URL scheme is registered, but no link
  handler exists yet.
- The button styles (`.signal`, `.quiet`) exist only in `BanditoUI`; `SignalButtonStyle` in `Crew/TeamViews.swift` is a
  copy for this target until they move to `BanditoDesign`.
