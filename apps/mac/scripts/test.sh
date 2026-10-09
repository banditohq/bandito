#!/usr/bin/env bash
# Tests for the Apple side: the BanditoKit package (models, reducer, L10n, UI snapshots) and the i18n check.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$here/../../.."
scratch="${BANDITO_SWIFT_SCRATCH:-$HOME/.cache/bandito-swift}"
swift test --package-path "$here/../BanditoKit" --scratch-path "$scratch"
python3 "$repo/i18n/build.py" --check
