#!/bin/sh
# Run clippy from the latest stable Rust (the version CI uses) in Docker, so lints that a
# local, older toolchain does not know yet are caught before pushing.
#   sh scripts/dev/clippy-latest.sh [path/to/daemon]
set -eu
DAEMON_DIR="$(cd "${1:-$(dirname "$0")/../../daemon}" && pwd)"
docker info >/dev/null 2>&1 || { echo "error: Docker is not running" >&2; exit 1; }
exec docker run --rm \
    -v "$DAEMON_DIR":/src \
    -v bandito-linux-target:/target \
    -v bandito-cargo-registry:/usr/local/cargo/registry \
    -e CARGO_TARGET_DIR=/target/clippy \
    -w /src rust:1-bookworm \
    sh -c 'rustup component add clippy >/dev/null 2>&1 && cargo clippy --version && cargo clippy --locked --all-targets -- -D warnings'
