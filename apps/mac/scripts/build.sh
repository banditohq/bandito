#!/usr/bin/env bash
# Generate the Xcode project and build the Mac app (Debug). Prints the path of the built app.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
xcodegen generate --quiet
derived="${BANDITO_DERIVED_DATA:-$HOME/.cache/bandito-derived}"
# -skipPackagePluginValidation: SwiftTerm (pinned in BanditoKit/Package.swift) ships a build-info package plugin;
# without this flag Xcode stops the build until someone trusts the plugin in the UI.
args=(-project Bandito.xcodeproj -scheme Bandito -configuration Debug -derivedDataPath "$derived" -destination 'platform=macOS' -skipPackagePluginValidation)
xcodebuild "${args[@]}" -quiet build
# Xcode's "custom build location" setting can move products elsewhere; ask Xcode where they are.
products="$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
echo "$products/Bandito.app"
