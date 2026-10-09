#!/bin/sh
# shellcheck disable=SC2088 # the ~ in the remote commands is expanded by the server's shell, on purpose
# Rehearse the server side of the Bandito install on the testbed, the way the Mac app does it over SSH.
# No app, no real host: a Docker container with sshd and no systemd.
#
#   sh scripts/dev/rehearse.sh
#
# Steps:
#   1  testbed up                 container with sshd (testbed.sh)
#   2  Linux binary and archive   linux-binary.sh; REHEARSE_ARCHIVE=<tar.gz> skips the build
#   3  copy the archive            scp into the container home
#   4  install.sh --archive        script on stdin, --no-service (as SSHInstaller runs it)
#   5  service install --json      no systemd, so the daemon starts as a background process
#   6  info --json                 the daemon answers
#   7  pair --json                 a pairing code comes out
#   then testbed down (kept with REHEARSE_KEEP=1)
#
# The full log is in $HOME/.cache/bandito-testbed/rehearse.log. Exit status 0 means every step passed.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
T="$HERE/testbed.sh"
CACHE="${TESTBED_CACHE:-$HOME/.cache/bandito-testbed}"
LOG="$CACHE/rehearse.log"
TOTAL=7
STEP=0
CURRENT=""
ARCHIVE=""

mkdir -p "$CACHE"
: >"$LOG"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

begin() {
    STEP=$((STEP + 1))
    CURRENT="$1"
    printf '[%d/%d] %-28s ' "$STEP" "$TOTAL" "$1"
}

pass() {
    if [ -n "${1:-}" ]; then
        printf 'ok (%s)\n' "$1"
    else
        printf 'ok\n'
    fi
    CURRENT=""
}

note() {
    printf '      %s\n' "$*"
}

# Runs on every exit. A failed step prints its name and the end of the log. Then the container goes away.
finish() {
    status=$?
    trap - EXIT
    if [ -n "$CURRENT" ]; then
        printf 'FAILED\n'
        printf '\nLast lines of %s:\n' "$LOG"
        tail -n 25 "$LOG" | sed 's/^/  /'
        printf '\nRehearsal FAILED at step %d/%d: %s\n' "$STEP" "$TOTAL" "$CURRENT"
        [ "$status" -ne 0 ] || status=1
    fi
    if [ "${REHEARSE_KEEP:-0}" = "1" ]; then
        printf 'Container kept (REHEARSE_KEEP=1). Remove it with: sh %s down\n' "$T"
    elif "$T" down >>"$LOG" 2>&1; then
        printf 'Cleanup: container %s removed (or was not there).\n' "bandito-testbed"
    else
        printf 'Cleanup: could not remove the container, see %s\n' "$LOG"
    fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM HUP

printf 'Bandito testbed rehearsal (server side, as SSHInstaller does it)\n\n'

# A fresh first contact each run, as the app sees a new server. This only touches our cache file.
rm -f "$CACHE"/known_hosts "$CACHE"/known_hosts-nopasswd

begin "testbed up"
"$T" up >>"$LOG" 2>&1
pass "dev@127.0.0.1 port ${TESTBED_PORT:-2222}"

begin "Linux binary and archive"
if [ -n "${REHEARSE_ARCHIVE:-}" ]; then
    [ -f "$REHEARSE_ARCHIVE" ] || die "REHEARSE_ARCHIVE is not a file: $REHEARSE_ARCHIVE"
    ARCHIVE="$REHEARSE_ARCHIVE"
    pass "given: $(basename "$ARCHIVE")"
else
    out="$(sh "$HERE/linux-binary.sh" 2>>"$LOG")"
    printf '%s\n' "$out" >>"$LOG"
    ARCHIVE="$(printf '%s\n' "$out" | sed -n 's/^archive: //p')"
    [ -f "$ARCHIVE" ] || die "linux-binary.sh did not print an archive"
    pass "built: $(basename "$ARCHIVE")"
fi
ARCHIVE_NAME="$(basename "$ARCHIVE")"

begin "copy the archive"
"$T" scp "$ARCHIVE" "dev@127.0.0.1:" >>"$LOG" 2>&1
pass "$ARCHIVE_NAME"

begin "install.sh --archive"
out="$("$T" ssh "BANDITO_REQUIRE_SIGNATURE=0 sh -s -- --archive $ARCHIVE_NAME --no-service" \
    <"$REPO/scripts/install.sh" 2>>"$LOG")"
printf '%s\n' "$out" >>"$LOG"
installed="$(printf '%s\n' "$out" | sed -n 's/^Installed \(.*\) to .*/\1/p')"
[ -n "$installed" ] || die "install.sh did not report an installed binary"
pass "$installed"

begin "service install --json"
out="$("$T" ssh '~/.local/bin/bandito service install --json' 2>>"$LOG")"
printf '%s\n' "$out" >>"$LOG"
case "$out" in
    *'"ok":true'*) ;;
    *) die "service install did not report ok: $out" ;;
esac
mode="$(printf '%s' "$out" | sed -n 's/.*"mode":"\([^"]*\)".*/\1/p')"
pass "mode $mode"
warnings="$(printf '%s' "$out" | sed -n 's/.*"warnings":\[\(.*\)\].*/\1/p')"
[ -z "$warnings" ] || note "warnings: $warnings"

begin "info --json"
out="$("$T" ssh '~/.local/bin/bandito info --json' 2>>"$LOG")"
printf '%s\n' "$out" >>"$LOG"
case "$out" in
    *'"running":true'*) ;;
    *) die "info does not show a running daemon: $out" ;;
esac
listen="$(printf '%s' "$out" | sed -n 's/.*"listen":"\([^"]*\)".*/\1/p')"
pass "daemon running, listen $listen"

begin "pair --json"
out="$("$T" ssh '~/.local/bin/bandito pair --json' 2>>"$LOG")"
printf '%s\n' "$out" >>"$LOG"
code="$(printf '%s' "$out" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')"
[ -n "$code" ] || die "pair did not return a code: $out"
pass "code issued, ${#code} characters (not printed)"

printf '\nRehearsal PASSED: %d/%d steps. Server side of the install works on this testbed.\n' "$TOTAL" "$TOTAL"
