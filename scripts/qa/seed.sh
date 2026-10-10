#!/bin/sh
# Fills a fresh QA daemon with agents, threads, an image and a browser tool card (see seed.py):
#   scripts/qa/seed.sh <n>      (run after `server.sh up <n> --fresh`; needs python3 with `websockets`)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

n=${1:-}
[ -n "$n" ] || qa_die "usage: seed.sh <n>"
qa_check_n "$n"
token="$qa_root/$n/token"
[ -f "$token" ] || qa_die "no token file: run scripts/qa/server.sh up $n first"
python3 "$here/seed.py" "ws://127.0.0.1:$((17880 + n))/v1/rpc" "$token" "$qa_root/$n/home"
