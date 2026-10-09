#!/usr/bin/env bash
# Generate the Xcode project and build the Mac app (Debug). Prints the path of the built app.
# The bandito daemon is built by a build phase of the target (project.yml) and copied into Contents/Helpers.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
cd "$here"
xcodegen generate --quiet

# Every checkout gets its own build products, so parallel worktrees do not share Bandito.app.
# The Xcode setting "custom build location" (user defaults) overrides -derivedDataPath alone,
# so BUILD_DIR and OBJROOT are passed explicitly; command-line settings win over every other setting.
derived="${BANDITO_DERIVED_DATA:-$HOME/.cache/bandito-xcode/$(basename "$repo")}"
cargo_target="${CARGO_TARGET_DIR:-$HOME/.cache/bandito-target-app}"
# -skipPackagePluginValidation: SwiftTerm (pinned in BanditoKit/Package.swift) ships a build-info package plugin;
# without this flag Xcode stops the build until someone trusts the plugin in the UI.
args=(-project Bandito.xcodeproj -scheme Bandito -configuration Debug
    -derivedDataPath "$derived" -destination 'platform=macOS' -skipPackagePluginValidation
    "BUILD_DIR=$derived/Build/Products" "OBJROOT=$derived/Build/Intermediates.noindex"
    "CARGO_TARGET_DIR=$cargo_target")
xcodebuild "${args[@]}" -quiet build
# Ask Xcode where the products are, so the printed path is the real one.
products="$(xcodebuild "${args[@]}" -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2; exit}')"
echo "$products/Bandito.app"
