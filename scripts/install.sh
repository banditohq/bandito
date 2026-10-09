#!/bin/sh
# Install Bandito: download the release binary for this machine, check it against the signed
# SHA256SUMS of the release, put it in ~/.local/bin and start it as a user service.
#
#   curl -fsSL https://bandito.dev/install.sh | sh
#   sh install.sh [--version vX.Y.Z] [--no-service]
#   sh install.sh --archive bandito-<target>.tar.gz --sums SHA256SUMS --sig SHA256SUMS.sig
#   sh install.sh --archive bandito-<target>.tar.gz   (no check here: the caller vouches for the archive)
#
# With --sums, the archive's SHA-256 is compared with its line in SHA256SUMS on every machine, without OpenSSL.
# With --sig too, SHA256SUMS is checked against the release key, when OpenSSL 3 is there. Without OpenSSL 3 the
# signature cannot be checked here, so the script warns and goes on: the Bandito app has checked that signature
# on the Mac, and it copies these very files over. The server checks the hash of the copy it installs, against
# the list whose signature was checked, so a file swapped in transit fails here.
#
# Environment: BANDITO_VERSION (default: latest), BANDITO_INSTALL_DIR (default: $HOME/.local/bin),
# BANDITO_REQUIRE_SIGNATURE=1 (fail instead of falling back to the plain SHA-256 when the signature
# cannot be checked; the Bandito app always sets it). With --archive it means --sums and --sig are both
# required; a missing OpenSSL 3 does not fail it, see above.
set -eu

BASE="https://github.com/banditohq/bandito/releases"

# The release signing key: Ed25519, base64 of its SubjectPublicKeyInfo. scripts/release-key.sh
# writes it. SHA256SUMS of every release is signed with the matching private key.
RELEASE_PUBKEY="MCowBQYDK2VwAyEA0H7rMV2eLDmjqQ403ipWCERN6K+aZNuWTW5IKuLSpWY="

usage() {
    cat <<'EOF'
Install Bandito on Linux or macOS.

Usage: sh install.sh [--version vX.Y.Z] [--archive FILE [--sums FILE [--sig FILE]]] [--no-service] [--help]

  --version vX.Y.Z   install this release instead of the latest one
  --archive FILE     install from this release archive instead of downloading it
  --sums FILE        with --archive: the release's SHA256SUMS; the archive must match its line
  --sig FILE         with --sums: SHA256SUMS.sig (base64); checked when OpenSSL 3 is available
  --no-service       only put the binary in place; do not start a service
  -h, --help         show this help

Environment:
  BANDITO_VERSION       same as --version
  BANDITO_INSTALL_DIR   where the binary goes (default: $HOME/.local/bin)
  BANDITO_REQUIRE_SIGNATURE=1
                        stop when the release signature cannot be checked; with --archive,
                        stop unless --sums and --sig are both given
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
REQUIRE_SIGNATURE="${BANDITO_REQUIRE_SIGNATURE:-0}"
INSTALL_DIR="${BANDITO_INSTALL_DIR:-$HOME/.local/bin}"
WITH_SERVICE=1
ARCHIVE=""
SUMS=""
SIG=""

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
        --archive)
            [ $# -ge 2 ] || die "--archive needs a file"
            ARCHIVE="$2"
            shift 2
            ;;
        --archive=*)
            ARCHIVE="${1#--archive=}"
            shift
            ;;
        --sums)
            [ $# -ge 2 ] || die "--sums needs a file"
            SUMS="$2"
            shift 2
            ;;
        --sums=*)
            SUMS="${1#--sums=}"
            shift
            ;;
        --sig)
            [ $# -ge 2 ] || die "--sig needs a file"
            SIG="$2"
            shift 2
            ;;
        --sig=*)
            SIG="${1#--sig=}"
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

if [ -n "$SIG" ] && [ -z "$SUMS" ]; then
    die "--sig needs --sums"
fi
if [ -n "$SUMS" ] && [ -z "$ARCHIVE" ]; then
    die "--sums and --sig go with --archive (a download checks its own SHA256SUMS)"
fi

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
    DOWNLOAD="$BASE/latest/download"
else
    DOWNLOAD="$BASE/download/$VERSION"
fi
URL="$DOWNLOAD/$ASSET"

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

# An OpenSSL that can verify Ed25519 signatures (OpenSSL 3; older LibreSSL cannot).
ed25519_openssl() {
    for candidate in openssl /usr/bin/openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" genpkey -algorithm ed25519 >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# Checks the signature $2 (a base64 text file) of the file $1 against the release key. Needs OpenSSL 3. Without
# it, only a warning: the Bandito app has checked the signature on the Mac before it copied these files here.
verify_sums_signature() {
    if ! OPENSSL="$(ed25519_openssl)"; then
        warn "SHA256SUMS signature not checked here (no OpenSSL 3): the Bandito app checked it on the Mac"
        return 0
    fi
    [ -n "$RELEASE_PUBKEY" ] || die "this install.sh carries no release key, so the signature cannot be checked"
    printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$RELEASE_PUBKEY" > "$TMP/release.pub"
    "$OPENSSL" base64 -d -A -in "$2" -out "$TMP/sums.sig" 2>/dev/null || die "the release signature file is malformed"
    if ! "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/release.pub" -rawin -in "$1" -sigfile "$TMP/sums.sig" >/dev/null 2>&1; then
        die "signature check failed: SHA256SUMS is not signed by the Bandito release key"
    fi
    say "Signature OK."
}

# Checks the archive $1 against its line in SHA256SUMS $2. The signature of $2 is checked when $3 is given.
# The archive hash is compared on every machine, so a swapped archive fails here even without OpenSSL.
check_against_sums() {
    [ -f "$2" ] || die "no such file: $2"
    if [ -n "$3" ]; then
        [ -f "$3" ] || die "no such file: $3"
        verify_sums_signature "$2" "$3"
    elif [ "$REQUIRE_SIGNATURE" = "1" ]; then
        die "BANDITO_REQUIRE_SIGNATURE=1 needs --sig FILE together with --sums"
    else
        warn "SHA256SUMS signature not checked here (no --sig given)"
    fi
    expected="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1; exit }' "$2")"
    [ -n "$expected" ] || die "$ASSET is not listed in $2"
    case "$expected" in
        [0-9a-fA-F]*) ;;
        *) die "checksum list is malformed" ;;
    esac
    [ "${#expected}" -eq 64 ] || die "checksum list is malformed"
    actual="$(sha256_of "$1")"
    if [ "$(printf '%s' "$expected" | tr 'A-F' 'a-f')" != "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" ]; then
        die "checksum mismatch for $ASSET: the archive is not the one the signed SHA256SUMS lists"
    fi
    say "Checksum OK (the archive matches SHA256SUMS)."
}

if [ -n "$ARCHIVE" ]; then
    [ -f "$ARCHIVE" ] || die "no such archive: $ARCHIVE"
    say "Installing from $ARCHIVE..."
    # The copy is what gets checked and unpacked: nothing can change between the check and the install.
    cp "$ARCHIVE" "$TMP/$ASSET"
    if [ -n "$SUMS" ]; then
        check_against_sums "$TMP/$ASSET" "$SUMS" "$SIG"
    elif [ "$REQUIRE_SIGNATURE" = "1" ]; then
        die "BANDITO_REQUIRE_SIGNATURE=1 needs --sums FILE and --sig FILE with --archive"
    else
        warn "archive not checked against SHA256SUMS (no --sums given): the caller vouches for it"
    fi
else
    say "Downloading Bandito ($VERSION, $TARGET)..."
    fetch "$URL" "$TMP/$ASSET" || die "download failed: $URL"

    if [ -n "$RELEASE_PUBKEY" ] && OPENSSL="$(ed25519_openssl)"; then
        fetch "$DOWNLOAD/SHA256SUMS" "$TMP/SHA256SUMS" || die "download failed: $DOWNLOAD/SHA256SUMS"
        fetch "$DOWNLOAD/SHA256SUMS.sig" "$TMP/SHA256SUMS.sig.b64" || die "download failed: $DOWNLOAD/SHA256SUMS.sig"
        printf -- '-----BEGIN PUBLIC KEY-----\n%s\n-----END PUBLIC KEY-----\n' "$RELEASE_PUBKEY" > "$TMP/release.pub"
        "$OPENSSL" base64 -d -A -in "$TMP/SHA256SUMS.sig.b64" -out "$TMP/SHA256SUMS.sig" 2>/dev/null ||
            die "the release signature file is malformed"
        if ! "$OPENSSL" pkeyutl -verify -pubin -inkey "$TMP/release.pub" -rawin \
            -in "$TMP/SHA256SUMS" -sigfile "$TMP/SHA256SUMS.sig" >/dev/null 2>&1; then
            die "signature check failed: SHA256SUMS is not signed by the Bandito release key"
        fi
        expected="$(awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1; exit }' "$TMP/SHA256SUMS")"
        [ -n "$expected" ] || die "$ASSET is not listed in the signed SHA256SUMS"
        say "Signature OK."
    elif [ "$REQUIRE_SIGNATURE" = "1" ]; then
        [ -n "$RELEASE_PUBKEY" ] || die "this install.sh carries no release key, and a signature is required"
        die "cannot check the release signature: install OpenSSL 3 (it verifies Ed25519) and try again"
    else
        warn "release signature not checked (no OpenSSL 3, or no release key in this script): checking the SHA-256 only"
        fetch "$URL.sha256" "$TMP/$ASSET.sha256" || die "download failed: $URL.sha256"
        expected="$(awk '{ print $1 }' "$TMP/$ASSET.sha256")"
    fi
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
fi

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
