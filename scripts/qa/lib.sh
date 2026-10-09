# Shared by scripts/qa/*.sh. Sourced, never run. Every QA path is derived from n (1..5) and checked here.

qa_root="$HOME/.cache/bandito-qa"

qa_die() {
    echo "$(basename "$0"): $*" >&2
    exit 1
}

qa_check_n() {
    case "$1" in
        1 | 2 | 3 | 4 | 5) ;;
        *) qa_die "n must be 1..5, got '$1'" ;;
    esac
}

# The bundle id of QA copy n. Refuses anything that is not dev.bandito.mac.debug.qa<digit>.
qa_bid() {
    bid="dev.bandito.mac.debug.qa$1"
    case "$bid" in
        dev.bandito.mac.debug.qa[0-9]) ;;
        *) qa_die "refusing bundle id '$bid'" ;;
    esac
}

# Where the copy of QA n lives: "Bandito QA<n>.app" under its own folder.
qa_app_path() {
    echo "$qa_root/$1/Bandito QA$1.app"
}

# Pids of the running QA copy n (its own executable path, nothing else), one per line.
qa_app_pids() {
    qa_bid "$1"
    exe="$(qa_app_path "$1")/Contents/MacOS/Bandito"
    # The path goes in through the environment: a command line with the path would match this awk itself.
    ps -axo pid=,command= | QA_EXE="$exe" awk 'index($0, ENVIRON["QA_EXE"]) { print $1 }'
}
