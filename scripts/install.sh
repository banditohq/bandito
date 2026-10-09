#!/bin/sh
# Install Bandito: download the release binary for this machine, check its SHA-256,
# put it in ~/.local/bin and start it as a user service.
#
#   curl -fsSL https://bandito.dev/install.sh | sh
#   sh install.sh [--version vX.Y.Z] [--no-service]
#
# Environment: BANDITO_VERSION (default: latest), BANDITO_INSTALL_DIR (default: $HOME/.local/bin).
set -eu

BASE="https://github.com/banditohq/bandito/releases"

usage() {
    cat <<'EOF'
Install Bandito on Linux or macOS.

Usage: sh install.sh [--version vX.Y.Z] [--no-service] [--help]

  --version vX.Y.Z   install this release instead of the latest one
  --no-service       only put the binary in place; do not start a service
  -h, --help         show this help

Environment:
  BANDITO_VERSION       same as --version
  BANDITO_INSTALL_DIR   where the binary goes (default: $HOME/.local/bin)
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

VERSION="${BANDITO_VERSION:-latest}"
INSTALL_DIR="${BANDITO_INSTALL_DIR:-$HOME/.local/bin}"
WITH_SERVICE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || die "--version needs a value, for example v0.1.0"
            VERSION="$2"
            shift 2
            ;;
        --version=*)
            VERSION="${1#--version=}"
            shift
            ;;
        --no-service)
            WITH_SERVICE=0
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

if [ "$VERSION" != "latest" ]; then
    case "$VERSION" in
        v*) ;;
        *) VERSION="v$VERSION" ;;
    esac
    case "$VERSION" in
        v[0-9]*.[0-9]*.[0-9]*) ;;
        *) die "not a version: $VERSION (expected vX.Y.Z)" ;;
    esac
fi

# Target triple, as in the release asset names.
os_name="$(uname -s)"
arch_name="$(uname -m)"
case "$os_name" in
    Linux) os_part="unknown-linux-gnu" ;;
    Darwin) os_part="apple-darwin" ;;
    *) die "unsupported OS: $os_name (Linux and macOS only)" ;;
esac
case "$arch_name" in
    x86_64 | amd64) arch_part="x86_64" ;;
    aarch64 | arm64) arch_part="aarch64" ;;
    *) die "unsupported architecture: $arch_name (x86_64 and aarch64 only)" ;;
esac
TARGET="$arch_part-$os_part"
ASSET="bandito-$TARGET.tar.gz"

if [ "$VERSION" = "latest" ]; then
    URL="$BASE/latest/download/$ASSET"
else
    URL="$BASE/download/$VERSION/$ASSET"
fi

if command -v curl >/dev/null 2>&1; then
    fetch() { curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch() { wget --https-only -q -O "$2" "$1"; }
else
    die "need curl or wget to download Bandito"
fi

if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{ print $1 }'; }
elif command -v shasum >/dev/null 2>&1; then
    sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
else
    die "need sha256sum or shasum to verify the download"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bandito-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' INT TERM HUP

say() {
    printf '%s\n' "$*"
}

say "Downloading Bandito ($VERSION, $TARGET)..."
fetch "$URL" "$TMP/$ASSET" || die "download failed: $URL"
fetch "$URL.sha256" "$TMP/$ASSET.sha256" || die "download failed: $URL.sha256"

expected="$(awk '{ print $1 }' "$TMP/$ASSET.sha256")"
case "$expected" in
    [0-9a-fA-F]*) ;;
    *) die "checksum file is malformed" ;;
esac
if [ "${#expected}" -ne 64 ]; then
    die "checksum file is malformed"
fi
actual="$(sha256_of "$TMP/$ASSET")"
if [ "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" != "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" ]; then
    die "checksum mismatch for $ASSET: the download is corrupt or was tampered with"
fi
say "Checksum OK."

mkdir -p "$TMP/unpack"
tar -xzf "$TMP/$ASSET" -C "$TMP/unpack" || die "cannot unpack $ASSET"
[ -f "$TMP/unpack/bandito" ] || die "archive has no bandito binary"

mkdir -p "$INSTALL_DIR"
# Copy next to the target and rename: a running daemon keeps its old inode, and a rename
# never fails with "text file busy" the way an overwrite would.
staged="$INSTALL_DIR/.bandito.new.$$"
cp "$TMP/unpack/bandito" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$INSTALL_DIR/bandito"
BIN="$INSTALL_DIR/bandito"

say "Installed $("$BIN" --version) to $BIN"

BIN_CMD="$BIN"
case ":$PATH:" in
    *":$INSTALL_DIR:"*) BIN_CMD="bandito" ;;
    *)
        say ""
        say "$INSTALL_DIR is not in your PATH. Add it to your shell profile, for example:"
        say "  echo 'export PATH=\"$INSTALL_DIR:\$PATH\"' >> ~/.profile"
        ;;
esac

if [ "$WITH_SERVICE" -eq 1 ]; then
    say ""
    say "Installing the Bandito service..."
    if "$BIN" service install </dev/null; then
        :
    else
        warn "service install failed. Bandito is installed; run '$BIN_CMD service install' again after fixing the cause."
        exit 1
    fi
else
    say ""
    say "Service not installed (--no-service). To start Bandito as a service later: $BIN_CMD service install"
fi

say ""
say "Next: open the Bandito app, choose Add server, then run '$BIN_CMD pair' here and enter the code."
