#!/usr/bin/env bash
# Sets (or checks) the Bandito version in the three places that must agree:
#   apps/mac/project.yml   MARKETING_VERSION
#   daemon/Cargo.toml      [package] version
#   daemon/Cargo.lock      the `bandito` package entry
#
#   scripts/bump-version.sh X.Y.Z [--root DIR]            rewrite the three files
#   scripts/bump-version.sh X.Y.Z --check [--root DIR]    fail unless all three already say X.Y.Z
#
# X.Y.Z or X.Y.Z-beta.N. Idempotent: a second run changes nothing. --root defaults to the repository root (tests
# point it at a copy).
set -euo pipefail

usage() {
  echo "usage: bump-version.sh X.Y.Z [--check] [--root DIR]" >&2
  exit 2
}

version=""
check=0
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1 ;;
    --root)
      [ $# -ge 2 ] || usage
      root="$2"
      shift
      ;;
    -*) usage ;;
    *)
      [ -z "$version" ] || usage
      version="$1"
      ;;
  esac
  shift
done
[ -n "$version" ] || usage
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' \
  || { echo "bump-version: '$version' is not X.Y.Z or X.Y.Z-beta.N" >&2; exit 2; }

yml="$root/apps/mac/project.yml"
toml="$root/daemon/Cargo.toml"
lock="$root/daemon/Cargo.lock"
for f in "$yml" "$toml" "$lock"; do
  [ -f "$f" ] || { echo "bump-version: missing $f" >&2; exit 1; }
done

# Prints the current version of each file; fails when the file does not have exactly one place to read it from.
read_yml() {
  local n
  n="$(grep -cE '^[[:space:]]*MARKETING_VERSION:' "$yml" || true)"
  [ "$n" = 1 ] || { echo "bump-version: expected one MARKETING_VERSION in $yml, found $n" >&2; return 1; }
  grep -E '^[[:space:]]*MARKETING_VERSION:' "$yml" | sed -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\1/'
}
read_toml() {
  awk '
    /^\[/ { in_pkg = ($0 == "[package]") }
    in_pkg && /^version[[:space:]]*=/ { n++; v = $0; sub(/^version[[:space:]]*=[[:space:]]*"/, "", v); sub(/".*$/, "", v) }
    END { if (n != 1) exit 1; print v }
  ' "$toml" || { echo "bump-version: expected one [package] version in $toml" >&2; return 1; }
}
read_lock() {
  awk '
    /^\[\[package\]\]/ { in_bandito = 0 }
    /^name = "bandito"$/ { in_bandito = 1; next }
    in_bandito && /^version = / { n++; v = $0; sub(/^version = "/, "", v); sub(/".*$/, "", v); in_bandito = 0 }
    END { if (n != 1) exit 1; print v }
  ' "$lock" || { echo "bump-version: expected one bandito package in $lock" >&2; return 1; }
}

if [ "$check" = 1 ]; then
  bad=0
  for pair in "project.yml:$(read_yml)" "Cargo.toml:$(read_toml)" "Cargo.lock:$(read_lock)"; do
    if [ "${pair#*:}" != "$version" ]; then
      echo "bump-version: ${pair%%:*} says ${pair#*:}, expected $version" >&2
      bad=1
    fi
  done
  [ "$bad" = 0 ] || exit 1
  echo "all three files say $version"
  exit 0
fi

# Read first (this fails on a malformed file before anything is written).
read_yml > /dev/null
read_toml > /dev/null
read_lock > /dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

sed -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*)\"?[^\"[:space:]]+\"?[[:space:]]*$/\1$version/" "$yml" > "$tmp/yml"
awk -v v="$version" '
  /^\[/ { in_pkg = ($0 == "[package]") }
  in_pkg && !done && /^version[[:space:]]*=/ { print "version = \"" v "\""; done = 1; next }
  { print }
' "$toml" > "$tmp/toml"
awk -v v="$version" '
  /^\[\[package\]\]/ { in_bandito = 0 }
  /^name = "bandito"$/ { in_bandito = 1; print; next }
  in_bandito && /^version = / { print "version = \"" v "\""; in_bandito = 0; next }
  { print }
' "$lock" > "$tmp/lock"

cat "$tmp/yml" > "$yml"
cat "$tmp/toml" > "$toml"
cat "$tmp/lock" > "$lock"

"$0" "$version" --check --root "$root" > /dev/null
echo "version set to $version in project.yml, Cargo.toml, Cargo.lock"
