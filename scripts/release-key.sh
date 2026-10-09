#!/bin/sh
# Make the release signing key (Ed25519), store the private half as the GitHub secret
# RELEASE_SIGNING_KEY of banditohq/bandito and put the public half into the files that verify
# releases (scripts/install.sh). Run it once, from the repository root, as the repository owner:
#
#   sh scripts/release-key.sh
#
# The private key never leaves this Mac except into the GitHub secret. A backup copy goes into
# the login keychain (service "dev.bandito.release-signing"); the temporary files are removed.
# Running it again makes a new key: releases signed with the old key stay valid only for apps
# and install.sh copies that still carry the old public key.
set -eu

REPO="banditohq/bandito"
KEYCHAIN_SERVICE="dev.bandito.release-signing"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[ -f scripts/install.sh ] || die "run this from the repository root"
command -v gh >/dev/null 2>&1 || die "need the GitHub CLI (brew install gh) signed in as an owner of $REPO"
gh auth status >/dev/null 2>&1 || die "gh is not signed in: run gh auth login first"

# An OpenSSL that knows Ed25519 (macOS ships LibreSSL, which may not).
OPENSSL=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" genpkey -algorithm ed25519 >/dev/null 2>&1; then
        OPENSSL="$candidate"
        break
    fi
done
[ -n "$OPENSSL" ] || die "need OpenSSL 3 with Ed25519 (brew install openssl@3)"

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/bandito-release-key.XXXXXX")"
cleanup() {
    if [ -f "$WORK/key.pem" ]; then
        rm -P "$WORK/key.pem" 2>/dev/null || rm -f "$WORK/key.pem"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

"$OPENSSL" genpkey -algorithm ed25519 -out "$WORK/key.pem"
"$OPENSSL" pkey -in "$WORK/key.pem" -pubout -out "$WORK/pub.pem"

# Check the pair before it goes anywhere: sign and verify a test message.
printf 'bandito release key check\n' > "$WORK/msg"
"$OPENSSL" pkeyutl -sign -inkey "$WORK/key.pem" -rawin -in "$WORK/msg" -out "$WORK/msg.sig"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$WORK/pub.pem" -rawin -in "$WORK/msg" -sigfile "$WORK/msg.sig" >/dev/null

gh secret set RELEASE_SIGNING_KEY --repo "$REPO" < "$WORK/key.pem"
printf 'Saved the private key as the GitHub secret RELEASE_SIGNING_KEY of %s.\n' "$REPO"

if command -v security >/dev/null 2>&1; then
    # -U updates an existing item; the value is the PEM in base64 so it stays on one line.
    security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$REPO" \
        -w "$(base64 < "$WORK/key.pem" | tr -d '\n')" >/dev/null
    printf 'Backup: login keychain, service %s.\n' "$KEYCHAIN_SERVICE"
fi

# Put the public key into install.sh, between its markers.
PUB_LINE="$(sed -n '2p' "$WORK/pub.pem")"
case "$PUB_LINE" in
    MCowBQYDK2VwAyEA*) ;;
    *) die "unexpected public key format: $PUB_LINE" ;;
esac
sed -i.bak "s|^RELEASE_PUBKEY=.*|RELEASE_PUBKEY=\"$PUB_LINE\"|" scripts/install.sh
rm -f scripts/install.sh.bak
grep -q "^RELEASE_PUBKEY=\"$PUB_LINE\"" scripts/install.sh || die "could not write the public key into scripts/install.sh"

printf '\nPublic key (safe to share): %s\n' "$PUB_LINE"
printf 'scripts/install.sh now carries it. Commit that change.\n'
