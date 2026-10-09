#!/usr/bin/env bash
# Fast checks before "done": guide coverage, formatting, lints, tests of the daemon.
set -euo pipefail
python3 "$(dirname "$0")/../scripts/check_guide.py"
cd "$(dirname "$0")/../daemon"
cargo fmt --check
cargo clippy -q --all-targets -- -D warnings
cargo test -q 2>&1 | tail -n 3
