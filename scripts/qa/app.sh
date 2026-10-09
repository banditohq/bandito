#!/bin/sh
# The QA copies of the app: one debug build, copied per n as "Bandito QA<n>" with bundle id dev.bandito.mac.debug.qa<n>.
#   scripts/qa/app.sh build
#   scripts/qa/app.sh launch <n> [--onboarding] [extra launch arguments, e.g. -qa.mode team]
#   scripts/qa/app.sh quit <n>
#   scripts/qa/app.sh reset <n>
# The installed Bandito.app is never launched or touched; the build output is only copied.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
. "$here/lib.sh"

derived="$HOME/.cache/bandito-build/qa-xcode"
cargo_target="$HOME/.cache/bandito-build/qa-target"
plistbuddy=/usr/libexec/PlistBuddy

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
    build) ;;
    launch | quit | reset)
        n=${1:-}
        [ -n "$n" ] || qa_die "usage: app.sh launch|quit|reset <n> ..."
        qa_check_n "$n"
        qa_bid "$n"
        shift
        ;;
    *) qa_die "usage: app.sh build | launch <n> [--onboarding] [args] | quit <n> | reset <n>" ;;
esac

build() {
    mkdir -p "$qa_root"
    log="$qa_root/build.log"
    if ! (cd "$repo" && BANDITO_DERIVED_DATA="$derived" CARGO_TARGET_DIR="$cargo_target" sh apps/mac/scripts/build.sh >"$log" 2>&1); then
        tail -n 40 "$log" >&2
        qa_die "build failed; the full log is $log"
    fi
    app=$(tail -n 1 "$log")
    case "$app" in
        *.app) ;;
        *) qa_die "build did not print the app path; see $log" ;;
    esac
    echo "$app" >"$qa_root/app-src"
    echo "built: $app"
}

# A string key; the value is quoted for PlistBuddy, so spaces in it survive ("Bandito QA5").
set_key() {
    "$plistbuddy" -c "Set :$1 \"$2\"" "$3" 2>/dev/null || "$plistbuddy" -c "Add :$1 string \"$2\"" "$3"
}

# Removes the defaults of this copy. `defaults delete` alone did not remove the domain of QA 5 in testing, so the
# preference file with this exact name goes too.
drop_defaults() {
    defaults delete "$bid" 2>/dev/null || true
    rm -f "$HOME/Library/Preferences/$bid.plist"
}

# A boolean key (false / true).
set_bool() {
    "$plistbuddy" -c "Set :$1 $2" "$3" 2>/dev/null || "$plistbuddy" -c "Add :$1 bool $2" "$3"
}

# Pids of QA n, after asking it to quit. Waits up to 10 s; then sends TERM to what is left of this copy only.
quit_copy() {
    pids=$(qa_app_pids "$1")
    [ -n "$pids" ] || return 0
    osascript -e "tell application id \"$bid\" to quit" >/dev/null 2>&1 || true
    i=0
    while [ -n "$(qa_app_pids "$1")" ] && [ "$i" -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    for pid in $(qa_app_pids "$1"); do
        kill "$pid" 2>/dev/null || true
    done
}

launch() {
    onboarding=0
    if [ "${1:-}" = "--onboarding" ]; then
        onboarding=1
        shift
    fi
    src=$(cat "$qa_root/app-src" 2>/dev/null) || qa_die "no build yet: run app.sh build"
    [ -d "$src" ] || qa_die "the build is gone: $src (run app.sh build)"
    dst=$(qa_app_path "$n")

    quit_copy "$n"
    mkdir -p "$(dirname "$dst")"
    rsync -a --delete "$src/" "$dst/"

    plist="$dst/Contents/Info.plist"
    set_key CFBundleIdentifier "$bid" "$plist"
    set_key CFBundleName "Bandito QA$n" "$plist"
    set_key CFBundleDisplayName "Bandito QA$n" "$plist"
    # No network from a QA copy: no scheduled update check and no appcast. (The app also reads the switch from the
    # launch argument -SUEnableAutomaticChecks, which takes precedence over this key; see the launch below.)
    set_bool SUEnableAutomaticChecks false "$plist"
    "$plistbuddy" -c "Delete :SUFeedURL" "$plist" 2>/dev/null || true
    got=$("$plistbuddy" -c "Print :CFBundleIdentifier" "$plist")
    [ "$got" = "$bid" ] || qa_die "bundle id is '$got', expected '$bid'"
    name=$("$plistbuddy" -c "Print :CFBundleName" "$plist")
    [ "$name" = "Bandito QA$n" ] || qa_die "bundle name is '$name', expected 'Bandito QA$n'"
    display=$("$plistbuddy" -c "Print :CFBundleDisplayName" "$plist")
    [ "$display" = "Bandito QA$n" ] || qa_die "display name is '$display', expected 'Bandito QA$n'"
    codesign --force --deep --sign - "$dst" >/dev/null 2>&1 || qa_die "ad hoc signing failed"

    if [ "$onboarding" -eq 1 ]; then
        # From zero: saved servers would skip the first-run flow, so this copy's defaults are dropped first.
        drop_defaults
        open -n -a "$dst" --args -SUEnableAutomaticChecks NO -onboarding.done NO "$@"
        echo "launched $dst for onboarding (no server)"
    else
        token="$qa_root/$n/token"
        [ -f "$token" ] || echo "warning: no token file yet, run scripts/qa/server.sh up $n first" >&2
        open -n -a "$dst" --args \
            -SUEnableAutomaticChecks NO \
            -qa.server "ws://127.0.0.1:$((17880 + n))/v1/rpc" \
            -qa.tokenFile "$token" \
            -qa.serverName "QA $n" "$@"
        echo "launched $dst"
    fi
}

reset_copy() {
    quit_copy "$n"
    drop_defaults
    rm -rf "$HOME/Library/Saved Application State/$bid.savedState"
    rm -rf "$HOME/Library/Containers/$bid" "$HOME/Library/Application Support/$bid" "$HOME/Library/Caches/$bid"
    # Debug secrets are one file per service in a folder shared by all debug builds: only this copy's names go.
    secrets="$HOME/Library/Application Support/Bandito Debug/secrets"
    if [ -d "$secrets" ]; then
        # The secrets are folders named by service (one file per account inside), so they go with rm -rf.
        find "$secrets" -maxdepth 1 -name "dev.bandito.debug.qa$n.*" -exec rm -rf {} +
    fi
    echo "reset QA $n: defaults, saved state, container, support and cache of $bid, its debug secrets"
}

case "$cmd" in
    build) build ;;
    launch) launch "$@" ;;
    quit) quit_copy "$n"; echo "QA $n: quit" ;;
    reset) reset_copy ;;
esac
