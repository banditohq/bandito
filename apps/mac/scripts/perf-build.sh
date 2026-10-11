#!/usr/bin/env bash
# Builds "Bandito Perf": the app compiled as a release is (Release configuration), under its own bundle id
# (dev.bandito.mac.perf) and name, signed ad hoc, without the bundled daemon. Run it with --perf-check: it opens only
# the smoothness check on demo daemons and touches nothing of an installed Bandito (no servers, Keychain, account,
# statistics or updates); the results are saved in ~/Library/Application Support/dev.bandito.mac.perf/.
#
#   apps/mac/scripts/perf-build.sh [destination folder]   (default ~/.cache/bandito-build/perf-dist)
#   open -n "<destination>/Bandito Perf.app" --args --perf-check
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
dest="${1:-$HOME/.cache/bandito-build/perf-dist}"
derived="${BANDITO_DERIVED_DATA:-$HOME/.cache/bandito-xcode/perf-$(basename "$repo")}"
cd "$here"
xcodegen generate --quiet
args=(-project Bandito.xcodeproj -scheme Bandito -configuration Release
    -derivedDataPath "$derived" -destination 'platform=macOS' -skipPackagePluginValidation
    "BUILD_DIR=$derived/Build/Products" "OBJROOT=$derived/Build/Intermediates.noindex"
    "CODE_SIGN_IDENTITY=-" "BANDITO_SKIP_DAEMON=1")
# The bundle id and the name are set in the built app's Info.plist below, not as build settings: a setting given
# here reaches every target, and resource bundles that share the app's id lose their colours (the asset catalog
# is looked up by the id and found in the app).
xcodebuild "${args[@]}" -quiet build
products="$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
mkdir -p "$dest"
rm -rf "$dest/Bandito Perf.app"
cp -R "$products/Bandito.app" "$dest/Bandito Perf.app"
plist="$dest/Bandito Perf.app/Contents/Info.plist"
# Its own id (its own defaults, Application Support and processes) and name; the executable stays Bandito.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.bandito.mac.perf" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Bandito Perf" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Bandito Perf" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Bandito Perf" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Bandito Perf" "$plist"
# Sparkle must not check for updates of this copy.
/usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :SUEnableAutomaticChecks false" "$plist" 2>/dev/null || true
codesign --force --deep --sign - "$dest/Bandito Perf.app"
# The build rewrites the package pins; the checkout keeps the committed ones.
git -C "$repo" checkout -- apps/mac/BanditoKit/Package.resolved 2>/dev/null || true
echo "$dest/Bandito Perf.app"
