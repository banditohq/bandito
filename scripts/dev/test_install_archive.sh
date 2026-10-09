#!/bin/sh
# Tests the checks of `install.sh --archive FILE --sums FILE --sig FILE` locally, without network.
# A test key pair signs a SHA256SUMS made here; a copy of install.sh carries the test public key in place of the
# release key, so the real key is never needed. Run: sh scripts/dev/test_install_archive.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/../install.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bandito-test-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAILED=0

pass() { printf 'ok: %s\n' "$*"; }
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    FAILED=$((FAILED + 1))
}

# The same platform mapping as install.sh; other platforms are not covered.
case "$(uname -s)" in
    Linux) os_part="unknown-linux-gnu" ;;
    Darwin) os_part="apple-darwin" ;;
    *) echo "skip: unsupported OS"; exit 0 ;;
esac
case "$(uname -m)" in
    x86_64 | amd64) arch_part="x86_64" ;;
    aarch64 | arm64) arch_part="aarch64" ;;
    *) echo "skip: unsupported architecture"; exit 0 ;;
esac
ASSET="bandito-$arch_part-$os_part.tar.gz"

if command -v sha256sum >/dev/null 2>&1; then
    sha256_of() { sha256sum "$1" | awk '{ print $1 }'; }
else
    sha256_of() { shasum -a 256 "$1" | awk '{ print $1 }'; }
fi

# OpenSSL 3 verifies Ed25519; it is searched the same way install.sh searches it.
OPENSSL=""
for candidate in openssl /usr/bin/openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" genpkey -algorithm ed25519 >/dev/null 2>&1; then
        OPENSSL="$candidate"
        break
    fi
done

# A fake release: an archive holding a bandito that answers --version, its SHA256SUMS, and the signature.
mkdir -p "$WORK/pkg" "$WORK/release"
printf '#!/bin/sh\necho "bandito 0.0.0-test"\n' > "$WORK/pkg/bandito"
chmod 755 "$WORK/pkg/bandito"
tar -czf "$WORK/release/$ASSET" -C "$WORK/pkg" bandito
printf '%s  %s\n' "$(sha256_of "$WORK/release/$ASSET")" "$ASSET" > "$WORK/release/SHA256SUMS"

PUB_B64=""
if [ -n "$OPENSSL" ]; then
    "$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/key.pem"
    "$OPENSSL" pkey -in "$WORK/key.pem" -pubout -outform DER -out "$WORK/key.der"
    PUB_B64="$("$OPENSSL" base64 -A -in "$WORK/key.der")"
    "$OPENSSL" pkeyutl -sign -inkey "$WORK/key.pem" -rawin -in "$WORK/release/SHA256SUMS" -out "$WORK/sig.bin"
    "$OPENSSL" base64 -A -in "$WORK/sig.bin" -out "$WORK/release/SHA256SUMS.sig"
fi

# install.sh with the test key in place of the release key (the file itself is never edited).
if [ -n "$PUB_B64" ]; then
    sed "s|^RELEASE_PUBKEY=.*|RELEASE_PUBKEY=\"$PUB_B64\"|" "$INSTALL" > "$WORK/install.sh"
else
    cp "$INSTALL" "$WORK/install.sh"
fi

# run_install ARCHIVE SUMS SIG REQUIRE: sets RC (exit status) and OUT (output). SUMS and SIG may be empty.
run_install() {
    rm -rf "$WORK/bin"
    set +e
    OUT="$(env BANDITO_INSTALL_DIR="$WORK/bin" BANDITO_REQUIRE_SIGNATURE="$4" \
        sh "$WORK/install.sh" --archive "$1" ${2:+--sums "$2"} ${3:+--sig "$3"} --no-service 2>&1)"
    RC=$?
    set -e
}

installed() {
    [ -x "$WORK/bin/bandito" ]
}

# expect_ok NAME: the install went through and the binary is in place.
expect_ok() {
    if [ "$RC" -eq 0 ] && installed; then pass "$1"; else fail "$1 (exit $RC): $OUT"; fi
}

# expect_refused NAME TEXT: the install stopped with TEXT in its output, and nothing was installed.
expect_refused() {
    if [ "$RC" -ne 0 ] && ! installed && printf '%s\n' "$OUT" | grep -Eq "$2"; then
        pass "$1"
    else
        fail "$1 (exit $RC, wanted '$2'): $OUT"
    fi
}

R="$WORK/release"

run_install "$R/$ASSET" "$R/SHA256SUMS" "$R/SHA256SUMS.sig" 1
if [ -n "$OPENSSL" ]; then
    expect_ok "valid archive, valid signature: installs"
else
    expect_ok "valid archive, no OpenSSL 3: installs with a warning"
fi

# A different archive under the same name: the hash in the signed list does not match.
cp "$R/$ASSET" "$WORK/tampered.tar.gz"
printf 'x' >> "$WORK/tampered.tar.gz"
run_install "$WORK/tampered.tar.gz" "$R/SHA256SUMS" "$R/SHA256SUMS.sig" 1
expect_refused "swapped archive: refused" "checksum mismatch"

# The same swap without a signature file, with the signature not required: the hash check still refuses.
run_install "$WORK/tampered.tar.gz" "$R/SHA256SUMS" "" 0
expect_refused "swapped archive, no signature file: refused" "checksum mismatch"

# An archive that the list does not name at all.
printf '%s  bandito-other.tar.gz\n' "$(sha256_of "$R/$ASSET")" > "$WORK/other-sums"
run_install "$R/$ASSET" "$WORK/other-sums" "" 0
expect_refused "archive not in the list: refused" "is not listed"

# Required mode: --archive without --sums is refused.
run_install "$R/$ASSET" "" "" 1
expect_refused "required, no --sums: refused" "needs --sums"

# Required mode: --sums without --sig is refused.
run_install "$R/$ASSET" "$R/SHA256SUMS" "" 1
expect_refused "required, no --sig: refused" "needs --sig"

# --sig without --sums is a usage error.
run_install "$R/$ASSET" "" "$R/SHA256SUMS.sig" 0
expect_refused "--sig without --sums: refused" "needs --sums"

# Not required and no --sums: the caller vouches for the archive, as before.
run_install "$R/$ASSET" "" "" 0
expect_ok "no --sums, not required: installs with a warning"

if [ -n "$OPENSSL" ]; then
    # Another key signs the list: the signature check refuses it.
    "$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/other.pem"
    "$OPENSSL" pkeyutl -sign -inkey "$WORK/other.pem" -rawin -in "$R/SHA256SUMS" -out "$WORK/other.bin"
    "$OPENSSL" base64 -A -in "$WORK/other.bin" -out "$WORK/foreign.sig"
    run_install "$R/$ASSET" "$R/SHA256SUMS" "$WORK/foreign.sig" 1
    expect_refused "signature from another key: refused" "signature check failed"

    # A list changed after signing: the hash is right for the archive, but the signature no longer fits.
    { cat "$R/SHA256SUMS"; echo "0000000000000000000000000000000000000000000000000000000000000000  bandito-extra.tar.gz"; } > "$WORK/changed-sums"
    run_install "$R/$ASSET" "$WORK/changed-sums" "$R/SHA256SUMS.sig" 1
    expect_refused "changed SHA256SUMS under a valid-looking signature: refused" "signature check failed"

    # A garbled signature file.
    printf 'not base64 at all !!\n' > "$WORK/garbled.sig"
    run_install "$R/$ASSET" "$R/SHA256SUMS" "$WORK/garbled.sig" 1
    expect_refused "garbled signature file: refused" "malformed|signature check failed"
else
    echo "skip: signature cases need OpenSSL 3 (install one to run them)"
fi

if [ "$FAILED" -ne 0 ]; then
    printf '%s check(s) failed\n' "$FAILED" >&2
    exit 1
fi
echo "install archive checks: all passed"
