#!/usr/bin/env bash
# Generate the Xcode project and build the iPhone app for the Simulator (Debug, no code signing).
# Prints the path of the built app. Build products live under ~/.cache/bandito-ios/<checkout>, so parallel worktrees
# do not share one app. The log of a failed build is printed.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
cd "$here"
xcodegen generate --quiet

derived="${BANDITO_IOS_DERIVED_DATA:-$HOME/.cache/bandito-ios/$(basename "$repo")}"
log="$derived/build.log"
mkdir -p "$derived"
# -skipPackagePluginValidation: SwiftTerm (pinned in apps/mac/BanditoKit) ships a build-info package plugin; without
# this flag Xcode waits for someone to trust the plugin in the UI.
if ! xcodebuild -project BanditoIOS.xcodeproj -scheme BanditoIOS -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO \
    "BUILD_DIR=$derived/Build/Products" "OBJROOT=$derived/Build/Intermediates.noindex" \
    build >"$log" 2>&1; then
    grep -E "error:|BUILD FAILED" "$log" | head -40 >&2
    echo "error: build failed, full log: $log" >&2
    exit 1
fi
app="$derived/Build/Products/Debug-iphonesimulator/Bandito.app"
[ -d "$app" ] || { echo "error: no app at $app" >&2; exit 1; }
echo "$app"
