#!/bin/sh
# A QA daemon: its own bandito daemon, home and port, paired for one QA copy of the app.
#   scripts/qa/server.sh up|down|status|logs <n> [--fresh]     (n = 1..5)
# Port 17880+n. Everything lives in ~/.cache/bandito-qa/<n>/ (home, daemon.log, daemon.pid, token).
# It never touches ~/.bandito, ~/.local/bin/bandito, launchd or the owner's daemon.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
qa_root="$HOME/.cache/bandito-qa"
build_target="$HOME/.cache/bandito-build/qa-target"

die() {
    echo "server.sh: $*" >&2
    exit 1
}

cmd=${1:-}
n=${2:-}
flag=${3:-}
case "$n" in
    1 | 2 | 3 | 4 | 5) ;;
    *) die "usage: server.sh up|down|status|logs <n 1..5> [--fresh]" ;;
esac
case "$cmd" in
    up | down | status | logs) ;;
    *) die "usage: server.sh up|down|status|logs <n 1..5> [--fresh]" ;;
esac
if [ -n "$flag" ] && { [ "$flag" != "--fresh" ] || [ "$cmd" != "up" ]; }; then
    die "--fresh goes only with up"
fi

dir="$qa_root/$n"
home="$dir/home"
log="$dir/daemon.log"
pidfile="$dir/daemon.pid"
token="$dir/token"
port=$((17880 + n))
url="ws://127.0.0.1:$port/v1/rpc"
bin="${QA_BANDITO_BIN:-$build_target/release/bandito}"

# The pid of this QA daemon, if it is alive. Only a process whose command line names this home counts.
running_pid() {
    [ -f "$pidfile" ] || return 1
    pid=$(cat "$pidfile" 2>/dev/null) || return 1
    case "$pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    cmdline=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
    case "$cmdline" in
        *"--home $home "*) echo "$pid" ;;
        *) return 1 ;;
    esac
}

# Builds the release daemon when it is missing or older than its sources.
ensure_binary() {
    if [ -n "${QA_BANDITO_BIN:-}" ]; then
        [ -x "$bin" ] || die "QA_BANDITO_BIN is not an executable: $bin"
        return 0
    fi
    if [ ! -x "$bin" ] || [ -n "$(find "$repo/daemon" -path "$repo/daemon/target" -prune -o -type f -newer "$bin" -print -quit)" ]; then
        echo "building the daemon (release) into $build_target ..."
        (cd "$repo/daemon" && CARGO_TARGET_DIR="$build_target" cargo build --release --bin bandito) ||
            die "cargo build failed"
    fi
}

stop_daemon() {
    pid=$(running_pid) || {
        rm -f "$pidfile"
        return 1
    }
    kill "$pid"
    i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 50 ]; do
        sleep 0.2
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
    echo "$pid"
}

status() {
    if pid=$(running_pid); then
        answer=$("$bin" --home "$home" info --json 2>/dev/null || true)
        case "$answer" in
            *'"running":true'*) state="running" ;;
            *) state="pid $pid alive, not answering" ;;
        esac
        echo "n=$n: $state (pid $pid), $url, home $home"
    else
        echo "n=$n: not running, $url, home $home"
    fi
    if [ -f "$token" ]; then
        echo "token file: $token (mode $(stat -f %Lp "$token"))"
    else
        echo "token file: none"
    fi
}

up() {
    if [ "$flag" = "--fresh" ]; then
        stop_daemon >/dev/null || true
        rm -rf "$home" "$token"
        echo "n=$n: home wiped"
    elif pid=$(running_pid); then
        echo "n=$n: already running"
        status
        return 0
    fi

    ensure_binary
    mkdir -p "$home"
    # Everything the daemon keeps goes under the QA home: some parts read $BANDITO_HOME instead of --home, and the
    # agents' folders default to ~/bandito/agents.
    BANDITO_HOME="$home" BANDITO_AGENTS_DIR="$dir/agents" \
        nohup "$bin" --home "$home" daemon --listen "127.0.0.1:$port" >>"$log" 2>&1 </dev/null &
    echo $! >"$pidfile"

    i=0
    until "$bin" --home "$home" info --json 2>/dev/null | grep -q '"running":true'; do
        i=$((i + 1))
        if ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
            tail -n 20 "$log" >&2 || true
            die "the daemon exited at start; its log: $log"
        fi
        if [ "$i" -ge 100 ]; then
            die "the daemon did not answer within 20 s; its log: $log"
        fi
        sleep 0.2
    done

    # The app pairs the same way: a one-time code from the daemon, exchanged over the WebSocket for a device token.
    "$bin" --home "$home" pair --json | python3 "$here/redeem.py" "$url" "$token" "QA $n" ||
        die "pairing failed; the daemon keeps running (log: $log)"

    echo "daemon up: pid $(cat "$pidfile"), $url"
    echo "home: $home"
    echo "token file: $token (mode 0600, the token itself is not printed)"
}

down() {
    if pid=$(stop_daemon); then
        echo "n=$n: stopped (pid $pid)"
    else
        echo "n=$n: not running"
    fi
}

logs() {
    if [ -f "$log" ]; then
        tail -n 200 "$log"
    else
        echo "no log yet: $log"
    fi
}

case "$cmd" in
    up) up ;;
    down) down ;;
    status) status ;;
    logs) logs ;;
esac
