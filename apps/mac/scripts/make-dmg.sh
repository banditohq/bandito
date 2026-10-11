#!/usr/bin/env bash
# Builds the install disk image of an already built Bandito.app: the window, the background, the icon positions and the
# app's icon as the volume icon. dmgbuild writes the layout straight into the image (UDZO). No Finder or AppleScript,
# so it runs in CI too.
# The image is neither signed nor notarized here: release-app.sh does that after this script. Without the signing and
# notarization it is the same image, for a look before a release.
#
#   apps/mac/scripts/make-dmg.sh <Bandito.app> <out.dmg>
#
# Environment:
#   VOLUME_NAME   the volume name (default: "Bandito <CFBundleShortVersionString of the app>")
#
# dmgbuild is pinned in apps/mac/scripts/dmg-requirements.txt: python3 -m pip install --user -r <that file>
set -euo pipefail

usage() {
    echo "usage: $0 <Bandito.app> <out.dmg>" >&2
    exit 2
}
[ $# -eq 2 ] || usage

here="$(cd "$(dirname "$0")" && pwd)"
brand="$here/../../../brand/dmg"
app="$(cd "$1" 2>/dev/null && pwd)" || { echo "error: no app bundle at $1" >&2; exit 1; }
[ -d "$app/Contents" ] || { echo "error: $app is not an app bundle" >&2; exit 1; }
out_dir="$(cd "$(dirname "$2")" 2>/dev/null && pwd)" || { echo "error: no folder for $2 (create it first)" >&2; exit 1; }
out="$out_dir/$(basename "$2")"

icon="$app/Contents/Resources/AppIcon.icns"
[ -f "$icon" ] || { echo "error: the volume icon $icon is missing" >&2; exit 1; }
background="$brand/background.tiff"
[ -f "$background" ] || { echo "error: the background $background is missing" >&2; exit 1; }

python3 -c 'import dmgbuild' >/dev/null 2>&1 || {
    echo "error: dmgbuild is not installed: python3 -m pip install --user -r $here/dmg-requirements.txt" >&2
    exit 1
}

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
volume="${VOLUME_NAME:-Bandito $version}"

rm -f "$out"
python3 -m dmgbuild -s "$here/dmg_settings.py" \
    -D "app=$app" -D "icon=$icon" -D "background=$background" \
    "$volume" "$out"
echo "disk image $out (volume \"$volume\", unsigned)"
