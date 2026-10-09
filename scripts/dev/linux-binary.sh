#!/bin/sh
# Build the Linux bandito daemon for the architecture of the Docker host (aarch64 on Apple silicon),
# inside a rust container. The result is a release-style archive for scripts/install.sh --archive.
#
#   sh scripts/dev/linux-binary.sh
#
# Output (paths are printed at the end):
#   $HOME/.cache/bandito-testbed/bandito-<target>            the binary
#   $HOME/.cache/bandito-testbed/bandito-<target>.tar.gz     bandito, LICENSE.md, README.md (as in the release)
#
# The build uses named volumes for the target dir and the cargo registry, so a rebuild is incremental.
# glibc: bookworm has 2.36, Ubuntu 24.04 has 2.39, so the binary runs on the testbed.
#
# Environment: TESTBED_RUST_IMAGE (default rust:1-bookworm), TESTBED_CACHE (default $HOME/.cache/bandito-testbed).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
CACHE="${TESTBED_CACHE:-$HOME/.cache/bandito-testbed}"
RUST_IMAGE="${TESTBED_RUST_IMAGE:-rust:1-bookworm}"
TARGET_VOLUME="bandito-linux-target"
REGISTRY_VOLUME="bandito-cargo-registry"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

say() {
    printf '%s\n' "$*" >&2
}

command -v docker >/dev/null 2>&1 || die "Docker is not installed (need the docker CLI)"
docker info >/dev/null 2>&1 || die "Docker is not running: start Docker Desktop (or the docker daemon) and try again"
[ -f "$REPO/daemon/Cargo.toml" ] || die "daemon/Cargo.toml not found under $REPO"
[ -f "$REPO/daemon/Cargo.lock" ] || die "daemon/Cargo.lock not found: --locked needs it"

# Docker reports the engine's architecture; map it to the release target names.
case "$(docker info --format '{{.Architecture}}')" in
    aarch64 | arm64) ARCH="aarch64" ;;
    x86_64 | amd64) ARCH="x86_64" ;;
    *) die "unsupported Docker architecture: $(docker info --format '{{.Architecture}}')" ;;
esac
TARGET="$ARCH-unknown-linux-gnu"

mkdir -p "$CACHE"
WORK="$(mktemp -d "$CACHE/linux-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

say "Building bandito for $TARGET in $RUST_IMAGE (cached between runs)..."
# The same command as release.yml, run in daemon/. The source is mounted read-only; cargo writes only to the volume.
docker run --rm \
    -v "$REPO:/src:ro" \
    -v "$TARGET_VOLUME:/target" \
    -v "$REGISTRY_VOLUME:/usr/local/cargo/registry" \
    -v "$WORK:/out" \
    -e CARGO_TARGET_DIR=/target \
    -w /src/daemon \
    "$RUST_IMAGE" \
    sh -c 'cargo build --release --locked --bin bandito && cp /target/release/bandito /out/bandito' >&2

[ -f "$WORK/bandito" ] || die "the build did not produce a binary"

BINARY="$CACHE/bandito-$TARGET"
ARCHIVE="$CACHE/bandito-$TARGET.tar.gz"
mv -f "$WORK/bandito" "$BINARY"

STAGE="$WORK/stage"
mkdir -p "$STAGE"
cp "$BINARY" "$STAGE/bandito"
cp "$REPO/LICENSE.md" "$REPO/README.md" "$STAGE/"
# COPYFILE_DISABLE keeps macOS from adding AppleDouble (._*) entries to the archive.
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$ARCHIVE" bandito LICENSE.md README.md

say "Built bandito for $TARGET."
printf 'binary: %s\n' "$BINARY"
printf 'archive: %s\n' "$ARCHIVE"
