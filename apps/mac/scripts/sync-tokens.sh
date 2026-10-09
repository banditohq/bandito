#!/usr/bin/env bash
# Copy generated brand tokens into the BanditoDesign target. Run after brand/tokens/build.py.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../../../brand/tokens/dist"
dst="$here/../BanditoKit/Sources/BanditoDesign"
cp "$src/BanditoTokens.swift" "$dst/BanditoTokens.swift"
rm -rf "$dst/Colors.xcassets"
cp -R "$src/Colors.xcassets" "$dst/Colors.xcassets"
echo "tokens synced"
