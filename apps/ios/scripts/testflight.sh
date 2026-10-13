#!/usr/bin/env bash
# Builds the iPhone app for the App Store and uploads it to TestFlight, signed with the team's Apple Distribution
# certificate through the Apple account signed in to Xcode (no API key). Xcode registers the bundle ids, the App Group
# and the profiles itself (-allowProvisioningUpdates). The app record (dev.bandito.ios) must exist in App Store Connect.
#   apps/ios/scripts/testflight.sh            # archive and upload
#   apps/ios/scripts/testflight.sh --no-upload  # archive and export an .ipa only
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
upload=1
[ "${1:-}" = "--no-upload" ] && upload=0

xcodegen generate --quiet
# Each upload needs a build number of its own: the time, which only grows.
build="$(date -u +%Y%m%d%H%M)"
out="${BANDITO_IOS_TESTFLIGHT_DIR:-$HOME/.cache/bandito-ios/testflight}/$build"
mkdir -p "$out"

xcodebuild -project BanditoIOS.xcodeproj -scheme BanditoIOS -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$out/Bandito.xcarchive" \
    -allowProvisioningUpdates -skipPackagePluginValidation \
    CURRENT_PROJECT_VERSION="$build" \
    archive >"$out/archive.log" 2>&1 || { grep -E "error:" "$out/archive.log" | head -20 >&2; echo "archive failed: $out/archive.log" >&2; exit 1; }

destination=export
[ "$upload" = 1 ] && destination=upload
cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$destination</string>
    <key>teamID</key><string>74Q24ZMD7A</string>
    <key>signingStyle</key><string>automatic</string>
    <key>uploadSymbols</key><true/>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$out/Bandito.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates >"$out/export.log" 2>&1 \
    || { grep -E "error:|Error" "$out/export.log" | head -20 >&2; echo "export failed: $out/export.log" >&2; exit 1; }
echo "build $build: $([ "$upload" = 1 ] && echo uploaded to App Store Connect || echo exported to $out/export)"
