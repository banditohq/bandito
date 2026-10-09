#!/bin/sh
# Sends one command to a running QA copy (see QACommand in QAHooks.swift).
#   scripts/qa/cmd.sh <n> <command...>
#   e.g. cmd.sh 1 mode files | window 900x600 | sheet addServer | dismiss | tab journal | settings
#        | onboarding | files /some/folder
set -eu
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

n=${1:-}
[ -n "$n" ] || qa_die "usage: cmd.sh <n> <command...>"
shift
qa_check_n "$n"
[ $# -gt 0 ] || qa_die "usage: cmd.sh <n> <command...>"
qa_bid "$n"
[ -n "$(qa_app_pids "$n")" ] || qa_die "QA $n is not running (scripts/qa/app.sh launch $n)"

# The text goes in as an argument, not inside the script, so quotes in it cannot break the JavaScript.
osascript -l JavaScript \
    -e 'ObjC.import("Foundation")' \
    -e 'function run(argv) { $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(argv[0], argv[1], $(), true); return "sent" }' \
    "dev.bandito.qa.$bid" "$*" >/dev/null
