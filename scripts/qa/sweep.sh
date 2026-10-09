#!/bin/sh
# Screenshots of every mode and sheet of a running QA copy at three window sizes:
#   scripts/qa/sweep.sh <n> <outdir>
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

for size in 900x600 1200x800 1600x1000; do
    "$here/cmd.sh" "$n" window "$size"
    for mode in team files terminals browser screen server; do
        "$here/cmd.sh" "$n" mode "$mode"
        sleep "$pause"
        "$here/shot.sh" "$n" "$outdir/$mode-$size.png" >/dev/null
    done
    for sheet in newAgent account addServer; do
        "$here/cmd.sh" "$n" sheet "$sheet"
        sleep "$pause"
        "$here/shot.sh" "$n" "$outdir/sheet-$sheet-$size.png" >/dev/null
        "$here/cmd.sh" "$n" dismiss
    done
done

echo "screenshots in $outdir:"
ls "$outdir"
