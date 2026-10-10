#!/bin/sh
# Screenshots of every mode and sheet of a running QA copy at three window sizes:
#   scripts/qa/sweep.sh <n> <outdir>
# QA_SWEEP_SIZES="1280x820 900x600" replaces the sizes. A picture that could not be taken is reported and the sweep
# goes on; the exit status is 1 when any failed.
# Files: <outdir>/<mode>-<W>x<H>.png and <outdir>/sheet-<name>-<W>x<H>.png
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

n=${1:-}
outdir=${2:-}
[ -n "$n" ] && [ -n "$outdir" ] || qa_die "usage: sweep.sh <n> <outdir>"
qa_check_n "$n"
mkdir -p "$outdir"
pause=1.2
failed=0

# One picture; a failure is counted, not fatal.
shoot() {
    "$here/shot.sh" "$n" "$1" >/dev/null || {
        echo "sweep.sh: no picture for $1" >&2
        failed=1
    }
}

# Closes every sheet and popover before the next picture: `dismiss` clears the sheet, then Escape closes what is left
# (a popover, the account sign-in window). Without it the sign-in window stays on the next mode's picture.
close_all() {
    "$here/cmd.sh" "$n" dismiss
    qa_bid "$n"
    osascript -e "tell application id \"$bid\" to activate" \
        -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
    sleep 0.3
}

for size in ${QA_SWEEP_SIZES:-900x600 1200x800 1600x1000}; do
    "$here/cmd.sh" "$n" window "$size"
    for mode in team files terminals browser screen market server; do
        "$here/cmd.sh" "$n" mode "$mode"
        sleep "$pause"
        shoot "$outdir/$mode-$size.png"
    done
    for sheet in newAgent account addServer; do
        "$here/cmd.sh" "$n" sheet "$sheet"
        sleep "$pause"
        shoot "$outdir/sheet-$sheet-$size.png"
        close_all
    done
done

echo "screenshots in $outdir:"
ls "$outdir"
exit "$failed"
