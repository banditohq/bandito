#!/bin/sh
# Screenshot of the main window of a running QA copy: scripts/qa/shot.sh <n> <out.png>
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

n=${1:-}
out=${2:-}
[ -n "$n" ] && [ -n "$out" ] || qa_die "usage: shot.sh <n> <out.png>"
qa_check_n "$n"

winid_dir="$qa_root/bin"
winid="$winid_dir/winid"
if [ ! -x "$winid" ] || [ "$here/winid.swift" -nt "$winid" ]; then
    mkdir -p "$winid_dir"
    swiftc -O -o "$winid" "$here/winid.swift" || qa_die "could not build winid"
fi

pid=$(qa_app_pids "$n" | head -n 1)
[ -n "$pid" ] || qa_die "QA $n is not running"
wid=$("$winid" "$pid" 2>/dev/null) || {
    # A window that is behind other windows or on another Space is not on screen: bring this copy to the front once.
    qa_bid "$n"
    osascript -e "tell application id \"$bid\" to activate" >/dev/null 2>&1 || true
    sleep 0.5
    wid=$("$winid" "$pid") || qa_die "QA $n has no window on screen"
}

# The window id is the main window. Its capture includes an attached sheet (checked on QA 5: the sheet of
# "New agent" is in the picture), so no region capture is needed.
mkdir -p "$(dirname "$out")"
screencapture -o -x -l "$wid" "$out"
echo "$out"
