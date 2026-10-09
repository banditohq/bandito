#!/usr/bin/env bash
# Release the Mac app: Release build signed with Developer ID, notarized and stapled, Bandito-<version>.zip and .dmg,
# the Sparkle signature of the zip, and an item in the appcast of the platform checkout.
# It uploads nothing and deploys nothing: the printed next steps are for the owner.
#
#   apps/mac/scripts/release-app.sh <version> [--dry-run]
#
# <version> is X.Y.Z, or X.Y.Z-beta.N for the beta channel. The build number is the commit count of HEAD.
# --dry-run does everything up to Apple's notary service: no submission, no stapling, no Gatekeeper check.
#
# Environment:
#   BANDITO_PLATFORM_DIR   platform checkout that gets public/appcast.xml (default: ../platform next to this repo)
#   BANDITO_DERIVED_DATA   Xcode derived data (default: apps/mac/build/DerivedData)
#   CARGO_TARGET_DIR       Rust target of the daemon build (default: ~/.cache/bandito-target-app)
#   SPARKLE_BIN            Sparkle's bin directory with sign_update (default: ~/.cache/sparkle/2.10.0/extracted/bin)
set -euo pipefail

TEAM_ID="74Q24ZMD7A"
IDENTITY="Developer ID Application: Nikita Terekhin (74Q24ZMD7A)"
NOTARY_PROFILE="bandito-notary"
MIN_SYSTEM="14.0"
REPO_SLUG="banditohq/bandito"

usage() {
    echo "usage: $0 <version> [--dry-run]" >&2
    exit 2
}

[ $# -ge 1 ] || usage
version="$1"
shift
dry_run=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) dry_run=1 ;;
        *) usage ;;
    esac
done
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$'; then
    echo "error: version must look like 0.1.0 or 0.2.0-beta.1 (got '$version')" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$here/../.." && pwd)"
derived="${BANDITO_DERIVED_DATA:-$here/build/DerivedData}"
release="$here/build/release"
work="$here/build/work"
platform="${BANDITO_PLATFORM_DIR:-$repo/../platform}"
sparkle_bin="${SPARKLE_BIN:-$HOME/.cache/sparkle/2.10.0/extracted/bin}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/.cache/bandito-target-app}"
app_name="Bandito.app"

step() { printf '\n==> %s\n' "$*"; }

# --- preflight -------------------------------------------------------------------------------------------------------
for tool in xcodegen xcodebuild codesign ditto hdiutil xcrun python3 git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found" >&2; exit 1; }
done
[ -x "$sparkle_bin/sign_update" ] || {
    echo "error: $sparkle_bin/sign_update not found; unpack Sparkle 2.10.0 there (see docs/ARCHITECTURE.md#mac-app-updates)" >&2
    exit 1
}
security find-identity -v -p codesigning | grep -Fq "\"$IDENTITY\"" || {
    echo "error: signing identity not in the Keychain: $IDENTITY" >&2
    exit 1
}
# A release is built from committed code. project.yml (the version) and Config/Info.plist (generated) may differ.
dirty="$(git -C "$repo" status --porcelain | grep -v -e '^ M apps/mac/project.yml$' -e '^ M apps/mac/Config/Info.plist$' || true)"
if [ -n "$dirty" ]; then
    echo "error: commit the changes first; the release must be built from a clean tree:" >&2
    echo "$dirty" >&2
    exit 1
fi
[ -d "$platform/public" ] || { echo "error: no public/ in platform checkout: $platform (set BANDITO_PLATFORM_DIR)" >&2; exit 1; }

mkdir -p "$release" "$work"
build_number="$(git -C "$repo" rev-list --count HEAD)"
echo "version $version, build $build_number, dry run: $dry_run"

# --- (a) version in project.yml --------------------------------------------------------------------------------------
step "Set the version in project.yml"
python3 - "$here/project.yml" "$version" "$build_number" <<'PY'
import re
import sys

path, version, build = sys.argv[1:4]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
text, marketing = re.subn(r"(?m)^(\s*MARKETING_VERSION:\s*).*$", lambda m: m.group(1) + version, text)
text, project = re.subn(r"(?m)^(\s*CURRENT_PROJECT_VERSION:\s*).*$", lambda m: m.group(1) + build, text)
if marketing != 1 or project != 1:
    sys.exit("error: project.yml must have one MARKETING_VERSION and one CURRENT_PROJECT_VERSION")
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

# --- (b) build and sign ----------------------------------------------------------------------------------------------
step "Generate the project and build Release"
(cd "$here" && xcodegen generate --quiet)
# BUILD_DIR and OBJROOT are passed as build.sh does: a custom build location in Xcode's settings would otherwise
# win over -derivedDataPath and put the product in the global DerivedData.
xcodebuild -project "$here/Bandito.xcodeproj" -scheme Bandito -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$derived" -skipPackagePluginValidation \
    "BUILD_DIR=$derived/Build/Products" "OBJROOT=$derived/Build/Intermediates.noindex" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp -quiet build > "$work/xcodebuild.log" 2>&1 || {
    echo "error: xcodebuild failed, the tail of $work/xcodebuild.log:" >&2
    tail -n 40 "$work/xcodebuild.log" >&2
    exit 1
}
built="$derived/Build/Products/Release/$app_name"
[ -d "$built" ] || { echo "error: no product at $built" >&2; exit 1; }
rm -rf "${release:?}/$app_name"
ditto "$built" "$release/$app_name"
app="$release/$app_name"

# Signs one nested code item with the release identity, keeping its own entitlements. get-task-allow is a debug
# entitlement: notarization refuses it, so it is dropped if a build still carries it. No --deep: each item is signed
# on its own, inside out.
sign_item() {
    local path="$1"
    if codesign -d --entitlements :- "$path" > "$work/entitlements.plist" 2>/dev/null && [ -s "$work/entitlements.plist" ]; then
        plutil -remove com.apple.security.get-task-allow "$work/entitlements.plist" 2>/dev/null || true
        codesign --force --options runtime --timestamp --entitlements "$work/entitlements.plist" --sign "$IDENTITY" "$path"
    else
        codesign --force --options runtime --timestamp --sign "$IDENTITY" "$path"
    fi
}

step "Sign Sparkle's nested code, inside out, then the app"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
for item in \
    "$sparkle/Versions/B/XPCServices/Installer.xpc" \
    "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
    "$sparkle/Versions/B/Autoupdate" \
    "$sparkle/Versions/B/Updater.app" \
    "$sparkle"; do
    [ -e "$item" ] || { echo "error: expected Sparkle item missing: $item" >&2; exit 1; }
    sign_item "$item"
done
sign_item "$app"
if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q "get-task-allow"; then
    echo "error: the app still carries com.apple.security.get-task-allow; notarization would refuse it" >&2
    exit 1
fi
codesign --verify --deep --strict "$app"
codesign -dvv "$app" 2>&1 | grep -E '^(Authority=Developer ID|TeamIdentifier|CodeDirectory)' || true

# --- (c) first archive, for notarization ------------------------------------------------------------------------------
zip_name="Bandito-$version.zip"
zip_path="$release/$zip_name"
step "Zip the app for notarization"
rm -f "$zip_path"
(cd "$release" && ditto -c -k --keepParent "$app_name" "$zip_name")

# notarize <file>: submits it to Apple and waits. Anything but Accepted fails, with Apple's log.
notarize() {
    local file="$1" out status id
    out="$work/notary-$(basename "$file").json"
    echo "submitting $(basename "$file") to the notary service (this can take a few minutes)"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$out" || true
    status="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' < "$out" 2>/dev/null || true)"
    id="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' < "$out" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        echo "error: notarization of $(basename "$file") ended with status '${status:-unknown}' (submission ${id:-none})" >&2
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
    echo "notarized $(basename "$file"): Accepted (submission $id)"
}

# --- (d) notarize, staple, final archives -----------------------------------------------------------------------------
if [ "$dry_run" -eq 1 ]; then
    step "Dry run: skipping notarization, stapling and the Gatekeeper check"
else
    step "Notarize the app"
    notarize "$zip_path"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
fi

step "Final zip (with the staple inside the app)"
rm -f "$zip_path"
(cd "$release" && ditto -c -k --keepParent "$app_name" "$zip_name")

dmg_name="Bandito-$version.dmg"
dmg_path="$release/$dmg_name"
step "Disk image"
stage="$work/dmg-stage"
rm -rf "$stage" "$dmg_path"
mkdir -p "$stage"
ditto "$app" "$stage/$app_name"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Bandito $version" -srcfolder "$stage" -ov -format UDZO "$dmg_path" > "$work/hdiutil.log"
codesign --force --timestamp --sign "$IDENTITY" "$dmg_path"
if [ "$dry_run" -eq 0 ]; then
    notarize "$dmg_path"
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    step "Gatekeeper check"
    spctl_out="$(spctl -a -vvv -t exec "$app" 2>&1 || true)"
    echo "$spctl_out"
    if ! { grep -Fq "accepted" <<< "$spctl_out" && grep -Fq "source=Notarized Developer ID" <<< "$spctl_out"; }; then
        echo "error: Gatekeeper does not accept the app as Notarized Developer ID" >&2
        exit 1
    fi
fi

# --- (e) Sparkle signature of the final zip ---------------------------------------------------------------------------
step "Sparkle signature of $zip_name"
sig_line="$("$sparkle_bin/sign_update" "$zip_path")"
signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$sig_line")"
length="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$sig_line")"
[ -n "$signature" ] && [ -n "$length" ] || { echo "error: sign_update printed no signature or length" >&2; exit 1; }
echo "length $length, signature $(printf '%s' "$signature" | cut -c1-12)…"

# --- (f) appcast item -------------------------------------------------------------------------------------------------
appcast="$platform/public/appcast.xml"
url="https://github.com/$REPO_SLUG/releases/download/v$version/$zip_name"
step "Add the item to $appcast"
python3 - "$appcast" "$version" "$build_number" "$length" "$signature" "$url" "$MIN_SYSTEM" <<'PY'
import email.utils
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

path, version, build, length, signature, url, min_system = sys.argv[1:8]
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
EMPTY_FEED = f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">
  <channel>
    <title>Bandito</title>
    <link>https://bandito.dev/</link>
    <description>Bandito app updates</description>
    <language>en</language>
  </channel>
</rss>
"""
channel_line = "      <sparkle:channel>beta</sparkle:channel>\n" if "-beta" in version else ""
item = f"""    <item>
      <title>Bandito {version}</title>
      <pubDate>{email.utils.format_datetime(datetime.now(timezone.utc))}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
{channel_line}      <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream"/>
    </item>
"""

text = EMPTY_FEED
if os.path.exists(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
# A re-run for the same version replaces its item; the other items stay as they are.
marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
for found in list(re.finditer(r"[ \t]*<item>.*?</item>[ \t]*\n?", text, re.S)):
    if marker in found.group(0):
        text = text.replace(found.group(0), "", 1)
        break
# The newest item goes first, above the older ones.
first = re.search(r"^[ \t]*<item>", text, re.M)
if first:
    text = text[: first.start()] + item + text[first.start():]
else:
    closing = re.search(r"^[ \t]*</channel>", text, re.M)
    if not closing:
        sys.exit("error: appcast has no <channel>")
    text = text[: closing.start()] + item + text[closing.start():]

# Refuse to write anything that is not a well-formed feed with exactly one item for this version.
root = ET.fromstring(text)
if root.tag != "rss":
    sys.exit("error: appcast root is not <rss>")
versions = [el.text for el in root.iter(f"{{{SPARKLE_NS}}}shortVersionString")]
if versions.count(version) != 1:
    sys.exit(f"error: expected one item for {version}, found {versions.count(version)}")
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(text)
os.replace(tmp, path)
print(f"appcast: {len(versions)} item(s), {version} on top")
PY
xmllint --noout "$appcast"

# --- (g) summary and next steps ---------------------------------------------------------------------------------------
step "Done"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
echo "app      $app"
echo "zip      $zip_path ($(sha "$zip_path"))"
echo "dmg      $dmg_path ($(sha "$dmg_path"))"
echo "appcast  $appcast (uncommitted)"
echo
echo "Not done by this script:"
if [ "$dry_run" -eq 1 ]; then
    echo "  - notarization (dry run): repeat without --dry-run before publishing"
fi
echo "  - commit apps/mac/project.yml and apps/mac/Config/Info.plist on the app branch"
echo "  - upload the release:  gh release upload v$version $zip_path $dmg_path --repo $REPO_SLUG"
echo "  - commit public/appcast.xml on the platform appcast branch; deploying the site is a separate decision"
