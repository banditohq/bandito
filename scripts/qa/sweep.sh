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
        "$here/cmd.sh" "$n" dismiss
    done
done

echo "screenshots in $outdir:"
ls "$outdir"
exit "$failed"
