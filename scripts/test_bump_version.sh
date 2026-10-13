#!/usr/bin/env bash
# Tests scripts/bump-version.sh on copies of the real files. No network, never touches the working tree.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
bump="$here/bump-version.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { pass=$((pass + 1)); }

fresh() {
  rm -rf "$work/root"
  mkdir -p "$work/root/apps/mac" "$work/root/apps/ios" "$work/root/daemon"
  cp "$repo/apps/mac/project.yml" "$work/root/apps/mac/"
  cp "$repo/apps/ios/project.yml" "$work/root/apps/ios/"
  cp "$repo/daemon/Cargo.toml" "$repo/daemon/Cargo.lock" "$work/root/daemon/"
}

cur_toml="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$repo/daemon/Cargo.toml" | head -n 1)"

fresh
"$bump" 9.8.7 --root "$work/root" > /dev/null
"$bump" 9.8.7 --check --root "$work/root" > /dev/null || fail "check after bump"
ok

# Exactly four files differ: the three desktop files by one line each, the iPhone project.yml by its two targets.
for f in apps/mac/project.yml daemon/Cargo.toml daemon/Cargo.lock; do
  changed="$(diff "$repo/$f" "$work/root/$f" | grep -c '^>' || true)"
  [ "$changed" = 1 ] || fail "$f: $changed lines changed, expected 1"
done
ok
changed="$(diff "$repo/apps/ios/project.yml" "$work/root/apps/ios/project.yml" | grep -c '^>' || true)"
[ "$changed" = 2 ] || fail "apps/ios/project.yml: $changed lines changed, expected 2"
ok
grep -q '^        MARKETING_VERSION: 9.8.7$' "$work/root/apps/mac/project.yml" || fail "project.yml line/indent"
ok
[ "$(grep -c '^        MARKETING_VERSION: 9.8.7$' "$work/root/apps/ios/project.yml")" = 2 ] || fail "ios: both targets not 9.8.7"
ok

# Only the bandito entry in the lock moved; the other packages keep their versions.
others_before="$(grep -c '^version = ' "$repo/daemon/Cargo.lock")"
others_after="$(grep -c '^version = ' "$work/root/daemon/Cargo.lock")"
[ "$others_before" = "$others_after" ] || fail "lock package count changed"
ok
[ "$(grep -c '"9.8.7"' "$work/root/daemon/Cargo.lock")" = 1 ] || fail "lock: 9.8.7 appears not once"
ok
# A dependency version line in Cargo.toml (not [package]) is untouched.
diff <(grep -v '^version = ' "$repo/daemon/Cargo.toml") <(grep -v '^version = ' "$work/root/daemon/Cargo.toml") > /dev/null \
  || fail "Cargo.toml changed outside the version line"
ok

# Idempotent: a second run is byte-identical.
cp -R "$work/root" "$work/snap"
"$bump" 9.8.7 --root "$work/root" > /dev/null
diff -r "$work/snap" "$work/root" > /dev/null || fail "second run changed files"
rm -rf "$work/snap"
ok

# Beta versions are accepted.
"$bump" 1.2.3-beta.4 --root "$work/root" > /dev/null
"$bump" 1.2.3-beta.4 --check --root "$work/root" > /dev/null || fail "beta check"
ok

# Bad versions are refused and nothing is written.
fresh
for bad in 1.2 v1.2.3 1.2.3.4 1.2.3-rc.1 "" abc; do
  if "$bump" "$bad" --root "$work/root" > /dev/null 2>&1; then fail "accepted '$bad'"; fi
done
diff "$repo/daemon/Cargo.toml" "$work/root/daemon/Cargo.toml" > /dev/null || fail "bad version wrote a file"
ok

# --check catches the "forgot Cargo.toml" mistake.
fresh
"$bump" 9.8.7 --root "$work/root" > /dev/null
awk -v v="$cur_toml" '!d && /^version = / { print "version = \"" v "\""; d = 1; next } { print }' \
  "$work/root/daemon/Cargo.toml" > "$work/stale" && cat "$work/stale" > "$work/root/daemon/Cargo.toml"
if "$bump" 9.8.7 --check --root "$work/root" > /dev/null 2>&1; then fail "check passed with a stale Cargo.toml"; fi
ok

# --check catches one iPhone target left behind (BanditoWidgets still on the old version).
fresh
"$bump" 9.8.7 --root "$work/root" > /dev/null
awk '!d && /^[[:space:]]*MARKETING_VERSION:/ { sub(/9\.8\.7/, "0.1.15"); d = 1 } { print }' \
  "$work/root/apps/ios/project.yml" > "$work/stale" && cat "$work/stale" > "$work/root/apps/ios/project.yml"
if "$bump" 9.8.7 --check --root "$work/root" > /dev/null 2>&1; then fail "check passed with a stale iPhone target"; fi
ok

# The two iPhone targets disagree before the run: refuse, write nothing.
fresh
awk '!d && /^[[:space:]]*MARKETING_VERSION:/ { sub(/0\.1\.15/, "9.9.9"); d = 1 } { print }' \
  "$work/root/apps/ios/project.yml" > "$work/split" && cat "$work/split" > "$work/root/apps/ios/project.yml"
if "$bump" 9.8.7 --root "$work/root" > /dev/null 2>&1; then fail "accepted iPhone targets with different versions"; fi
diff "$repo/apps/mac/project.yml" "$work/root/apps/mac/project.yml" > /dev/null || fail "partial write: targets disagree"
ok

# A malformed file stops the run before any write.
fresh
sed -i.bak '/MARKETING_VERSION/d' "$work/root/apps/mac/project.yml"
rm -f "$work/root/apps/mac/project.yml.bak"
if "$bump" 9.8.7 --root "$work/root" > /dev/null 2>&1; then fail "accepted project.yml without MARKETING_VERSION"; fi
diff "$repo/daemon/Cargo.toml" "$work/root/daemon/Cargo.toml" > /dev/null || fail "partial write on malformed input"
ok
fresh
sed -i.bak '/MARKETING_VERSION/d' "$work/root/apps/ios/project.yml"
rm -f "$work/root/apps/ios/project.yml.bak"
if "$bump" 9.8.7 --root "$work/root" > /dev/null 2>&1; then fail "accepted apps/ios/project.yml without MARKETING_VERSION"; fi
diff "$repo/apps/mac/project.yml" "$work/root/apps/mac/project.yml" > /dev/null || fail "partial write on malformed iPhone project.yml"
ok

# cargo metadata agrees (when cargo is there): bump a copy of the whole crate.
if command -v cargo > /dev/null 2>&1; then
  rm -rf "$work/crate"
  mkdir -p "$work/crate/apps/mac" "$work/crate/apps/ios"
  cp -R "$repo/daemon" "$work/crate/daemon"
  rm -rf "$work/crate/daemon/target"
  cp "$repo/apps/mac/project.yml" "$work/crate/apps/mac/"
  cp "$repo/apps/ios/project.yml" "$work/crate/apps/ios/"
  "$bump" 9.8.7 --root "$work/crate" > /dev/null
  got="$(cargo metadata --no-deps --offline --locked --format-version 1 --manifest-path "$work/crate/daemon/Cargo.toml" \
    | python3 -c 'import json,sys; print([p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="bandito"][0])')"
  [ "$got" = 9.8.7 ] || fail "cargo metadata says $got"
  ok
fi

echo "bump-version: $pass checks passed"
