#!/usr/bin/env bash
# Generate the Xcode project and build the Mac app (Debug). Build output stays out of the repo.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
xcodegen generate --quiet
derived="${BANDITO_DERIVED_DATA:-$HOME/.cache/bandito-derived}"
xcodebuild -project Bandito.xcodeproj -scheme Bandito -configuration Debug \
  -derivedDataPath "$derived" -destination 'platform=macOS' -quiet build
echo "$derived/Build/Products/Debug/Bandito.app"
