#!/usr/bin/env bash
# Screenshot of the iPhone app on the shared Simulator, headless (no Simulator.app window): build, boot the device if
# needed, install, launch with the given arguments, wait, then save the picture and a small copy (<name>_s.png).
#   apps/ios/scripts/shot.sh <out.png> [launch arguments...]
#   apps/ios/scripts/shot.sh /tmp/x/s1-demo.png -demo
set -euo pipefail
out="${1:?usage: shot.sh <out.png> [launch arguments...]}"
shift
here="$(cd "$(dirname "$0")/.." && pwd)"
device="${BANDITO_IOS_SIM:-D7E3834B-1BA6-4071-9131-9FDEDE135C81}"
bundle="dev.bandito.ios"

app="$(bash "$here/scripts/build.sh")"

# Boot without a window; bootstatus waits until the device is ready.
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"
xcrun simctl terminate "$device" "$bundle" 2>/dev/null || true
xcrun simctl launch "$device" "$bundle" "$@" >/dev/null
sleep 4

mkdir -p "$(dirname "$out")"
xcrun simctl io "$device" screenshot "$out"
small="${out%.png}_s.png"
sips -Z 800 "$out" --out "$small" >/dev/null
echo "$out"
echo "$small"
