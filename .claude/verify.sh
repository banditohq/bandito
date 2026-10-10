#!/usr/bin/env bash
# Fast checks before "done": guide coverage, the install script's checks, formatting, lints, tests of the daemon.
set -euo pipefail
python3 "$(dirname "$0")/../scripts/check_guide.py"
sh -n "$(dirname "$0")/../scripts/install.sh"
sh "$(dirname "$0")/../scripts/dev/test_install_archive.sh"
cd "$(dirname "$0")/../daemon"
# The Rust part runs when the daemon changed (or VERIFY_FULL=1): CI checks everything on every push, so a Swift-only
# change does not rebuild and test the daemon on a laptop each time an agent stops.
if [ "${VERIFY_FULL:-0}" != 1 ] && [ -z "$(git status --porcelain -- . 2>/dev/null)" ] \
    && git rev-parse -q --verify '@{upstream}' >/dev/null 2>&1 && git diff --quiet '@{upstream}' -- . 2>/dev/null; then
    echo "daemon unchanged: Rust checks skipped (VERIFY_FULL=1 runs them)"
    exit 0
fi
cargo fmt --check
cargo clippy -q --all-targets -- -D warnings
cargo test -q 2>&1 | tail -n 3
