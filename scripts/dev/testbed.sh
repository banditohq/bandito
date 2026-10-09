#!/bin/sh
# A clean Linux server in Docker for rehearsing the Bandito install over SSH. No real hosts involved.
#
#   sh scripts/dev/testbed.sh up        build the image, start the container, print how to connect
#   sh scripts/dev/testbed.sh status    container state, and whether sshd answers
#   sh scripts/dev/testbed.sh ssh [cmd] log in as dev (or run cmd there)
#   sh scripts/dev/testbed.sh scp ...   scp with the testbed options (use dev@127.0.0.1:)
#   sh scripts/dev/testbed.sh logs [-f] sshd log of the container
#   sh scripts/dev/testbed.sh down      remove the container (the image stays)
#
# Environment:
#   TESTBED_PORT=2222      host port on 127.0.0.1 (container port 22)
#   SUDO_NOPASSWD=1        build the variant where dev has passwordless sudo
#   TESTBED_CACHE          cache dir (default: $HOME/.cache/bandito-testbed)
#
# The key and the known_hosts file live in the cache dir. ~/.ssh is never read or written.
set -eu

NAME="bandito-testbed"
USER_NAME="dev"
HOST_ADDR="127.0.0.1"
PORT="${TESTBED_PORT:-2222}"
CACHE="${TESTBED_CACHE:-$HOME/.cache/bandito-testbed}"
KEY="$CACHE/id_ed25519"
PASSFILE="$CACHE/dev-password"
# Each image variant makes its own host key, so each variant gets its own known_hosts file.
if [ "${SUDO_NOPASSWD:-0}" = "1" ]; then
    KNOWN="$CACHE/known_hosts-nopasswd"
else
    KNOWN="$CACHE/known_hosts"
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
CONTEXT="$HERE/testbed"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*"
}

check_docker() {
    command -v docker >/dev/null 2>&1 || die "Docker is not installed (need the docker CLI)"
    docker info >/dev/null 2>&1 || die "Docker is not running: start Docker Desktop (or the docker daemon) and try again"
}

# Image tag: the sudo variant gets its own tag so the two images do not replace each other.
image_tag() {
    if [ "${SUDO_NOPASSWD:-0}" = "1" ]; then
        printf 'bandito-testbed:nopasswd'
    else
        printf 'bandito-testbed'
    fi
}

container_state() {
    docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || true
}

container_image() {
    docker inspect -f '{{.Config.Image}}' "$NAME" 2>/dev/null || true
}

# True when something already listens on 127.0.0.1:PORT.
port_busy() {
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1
    else
        nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1
    fi
}

ensure_key() {
    if [ ! -f "$KEY" ]; then
        command -v ssh-keygen >/dev/null 2>&1 || die "need ssh-keygen to make the test key"
        mkdir -p "$CACHE"
        chmod 700 "$CACHE"
        ssh-keygen -q -t ed25519 -N "" -C "bandito-testbed" -f "$KEY"
        say "Made the test key: $KEY"
    fi
}

ensure_password() {
    if [ ! -f "$PASSFILE" ]; then
        mkdir -p "$CACHE"
        chmod 700 "$CACHE"
        (umask 077 && openssl rand -hex 12 >"$PASSFILE")
    fi
}

# Options shared by ssh and scp: our own key and known_hosts, never the user's ~/.ssh.
ssh_run() {
    ssh -p "$PORT" -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new "$USER_NAME@$HOST_ADDR" "$@"
}

scp_run() {
    scp -P "$PORT" -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o UserKnownHostsFile="$KNOWN" -o StrictHostKeyChecking=accept-new "$@"
}

# The login key goes in after the container starts, so the image does not hold it.
install_key() {
    docker cp "$KEY.pub" "$NAME:/tmp/bandito-testbed.pub" >/dev/null
    docker exec "$NAME" sh -c 'install -d -m 700 -o dev -g dev /home/dev/.ssh \
        && install -m 600 -o dev -g dev /tmp/bandito-testbed.pub /home/dev/.ssh/authorized_keys \
        && rm -f /tmp/bandito-testbed.pub'
}

wait_for_ssh() {
    tries=0
    err="$CACHE/ssh-probe.err"
    while ! ssh_run true >/dev/null 2>"$err"; do
        # A changed host key does not fix itself: stop at once and say how to clear it.
        if grep -q 'HOST KEY\|IDENTIFICATION HAS CHANGED' "$err"; then
            die "the host key of $HOST_ADDR:$PORT changed (the image was rebuilt). Remove the old entry: ssh-keygen -R '[$HOST_ADDR]:$PORT' -f $KNOWN"
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 30 ]; then
            sed 's/^/  ssh: /' "$err" >&2
            die "sshd did not answer on $HOST_ADDR:$PORT within 30 s; see: sh $0 logs"
        fi
        sleep 1
    done
}

print_connection() {
    say ""
    say "Connect:  ssh $USER_NAME@$HOST_ADDR -p $PORT"
    say "          sh $HERE/testbed.sh ssh"
    say "Password for sudo (the app asks for it in its terminal): $PASSFILE"
    say ""
    say "Optional block for ~/.ssh/config (not written by this script):"
    say ""
    say "Host bandito-testbed"
    say "    HostName $HOST_ADDR"
    say "    Port $PORT"
    say "    User $USER_NAME"
    say "    IdentityFile $KEY"
    say "    IdentitiesOnly yes"
}

cmd_up() {
    check_docker
    ensure_key
    ensure_password
    tag="$(image_tag)"
    state="$(container_state)"

    if [ -n "$state" ]; then
        current="$(container_image)"
        if [ "$current" != "$tag" ]; then
            die "container $NAME runs image $current, but this run wants $tag: run 'sh $0 down' first"
        fi
        if [ "$state" != "running" ]; then
            say "Starting the existing container..."
            docker start "$NAME" >/dev/null
        else
            say "Container $NAME is already running."
        fi
    else
        if port_busy; then
            die "127.0.0.1:$PORT is already in use. Pick another port: TESTBED_PORT=2223 sh $0 up"
        fi
        say "Building image $tag (the first build takes a few minutes)..."
        docker build -q \
            --build-arg "DEV_PASSWORD=$(cat "$PASSFILE")" \
            --build-arg "SUDO_NOPASSWD=${SUDO_NOPASSWD:-0}" \
            -t "$tag" "$CONTEXT" >/dev/null
        say "Starting container $NAME on 127.0.0.1:$PORT..."
        if ! docker run -d --name "$NAME" --hostname "$NAME" -p "127.0.0.1:$PORT:22" "$tag" >/dev/null; then
            docker rm -f "$NAME" >/dev/null 2>&1 || true
            die "could not publish 127.0.0.1:$PORT (is the port in use?). Try: TESTBED_PORT=2223 sh $0 up"
        fi
    fi

    install_key
    wait_for_ssh
    say "sshd is up. Login key: $KEY.pub"
    print_connection
}

cmd_down() {
    check_docker
    if [ -n "$(container_state)" ]; then
        docker rm -f "$NAME" >/dev/null
        say "Removed container $NAME."
    else
        say "No container $NAME; nothing to do."
    fi
}

cmd_status() {
    check_docker
    state="$(container_state)"
    if [ -z "$state" ]; then
        say "Container $NAME: not created. Start it with: sh $0 up"
        return 0
    fi
    say "Container $NAME: $state (image $(container_image), 127.0.0.1:$PORT)"
    if [ "$state" = "running" ] && [ -f "$KEY" ]; then
        if ssh_run true >/dev/null 2>&1; then
            say "sshd: answers, key login works"
        else
            say "sshd: no answer (see: sh $0 logs)"
        fi
    fi
}

cmd_ssh() {
    [ -f "$KEY" ] || die "no test key yet: run sh $0 up"
    ssh_run "$@"
}

cmd_scp() {
    [ -f "$KEY" ] || die "no test key yet: run sh $0 up"
    scp_run "$@"
}

cmd_logs() {
    check_docker
    [ -n "$(container_state)" ] || die "no container $NAME: run sh $0 up"
    docker logs "$@" "$NAME"
}

usage() {
    cat <<EOF
Usage: sh $0 up|down|status|ssh [cmd...]|scp ...|logs [-f]
EOF
}

case "${1:-}" in
    up) shift; cmd_up "$@" ;;
    down) shift; cmd_down "$@" ;;
    status) shift; cmd_status "$@" ;;
    ssh) shift; cmd_ssh "$@" ;;
    scp) shift; cmd_scp "$@" ;;
    logs) shift; cmd_logs "$@" ;;
    -h | --help | help) usage ;;
    *) usage >&2; exit 2 ;;
esac
