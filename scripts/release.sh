#!/usr/bin/env bash
# Starts a release: bumps the version in all three places, pushes branch release/X and opens the release PR with a
# draft of the notes. Merging that PR is the release: .github/workflows/release-flow.yml does the rest.
#
#   scripts/release.sh X.Y.Z [--dry-run]
#
# Safe to run again: if the PR for X is already open it only prints its link. Your own working tree is never touched
# (the branch is made in a temporary worktree). See docs/RELEASING.md.
set -euo pipefail

usage() {
  echo "usage: scripts/release.sh X.Y.Z [--dry-run]" >&2
  exit 2
}
die() {
  echo "release: $*" >&2
  exit 1
}

version=""
dry=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    -h | --help) usage ;;
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
  || die "'$version' is not X.Y.Z or X.Y.Z-beta.N"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
tag="v$version"
branch="release/$version"
title="release: Bandito $version"

command -v git > /dev/null || die "git is required"
if [ "$dry" = 0 ]; then command -v gh > /dev/null || die "gh (GitHub CLI) is required"; fi

[ -z "$(git status --porcelain)" ] || die "the working tree is not clean; commit or stash first"
git fetch --quiet origin main --tags
base="$(git rev-parse origin/main)"

# --- Refuse what cannot be a new release ---
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null || [ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]; then
  die "tag $tag already exists"
fi
if [ "$dry" = 0 ]; then
  pr_url="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty')"
  if [ -n "$pr_url" ]; then
    echo "The release PR for $version is already open: $pr_url"
    exit 0
  fi
  merged="$(gh pr list --head "$branch" --state merged --json url --jq '.[0].url // empty')"
  [ -z "$merged" ] || die "the release PR for $version was already merged ($merged); rerun the release-flow workflow (docs/RELEASING.md) instead"
fi

case "$version" in
  *-beta.*) prev_pattern='^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' ;;
  *) prev_pattern='^v[0-9]+\.[0-9]+\.[0-9]+$' ;;
esac
prev="$(git tag --list 'v*' --sort=-v:refname | grep -E "$prev_pattern" | head -n 1 || true)"
if [ -n "$prev" ]; then
  top="$(printf '%s\n%s\n' "${prev#v}" "$version" | sort -V | tail -n 1)"
  { [ "$top" = "$version" ] && [ "${prev#v}" != "$version" ]; } || die "$version is not newer than the last release $prev"
fi

# --- Work in a temporary worktree cut from origin/main ---
tmp="$(mktemp -d)"
wt="$tmp/wt"
cleanup() {
  git -C "$repo_root" worktree remove --force "$wt" > /dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
git worktree add --quiet --detach "$wt" "$base"

"$repo_root/scripts/bump-version.sh" "$version" --root "$wt" > /dev/null
if git -C "$wt" diff --quiet; then
  die "origin/main already says $version in all three files; nothing to bump (was this released already?)"
fi

# --- The "What's new" notes of the version must already be on main (release-notes/X.Y.Z.json) ---
if ! git cat-file -e "$base:release-notes/$version.json" 2> /dev/null; then
  msg="release-notes/$version.json is not on origin/main. Write the 'What's new' notes (3-6 items, all 9 languages; copy an earlier file, check with scripts/check_release_notes.py --require $version), merge them to main, then release."
  if [ "$dry" = 1 ]; then echo "release: WARNING: $msg" >&2; else die "$msg"; fi
fi

# --- Notes draft: commit titles since the previous tag, grouped by type ---
notes="$tmp/notes.md"
range="${prev:+$prev..}$base"
{
  echo "<!-- Edit this text before merging: it becomes the GitHub release notes. -->"
  echo "Bandito $version"
  echo
  git log "$range" --no-merges --format='%s' | awk '
    function add(group, text) { items[group] = items[group] "- " text "\n" }
    {
      line = $0
      if (line ~ /^release: /) next
      type = ""; text = line
      if (match(line, /^[a-z0-9]+(\([^)]*\))?!?: /)) {
        head = substr(line, 1, RLENGTH - 2)
        text = substr(line, RLENGTH + 1)
        sub(/\(.*$/, "", head); sub(/!$/, "", head)
        type = head
      }
      sub(/ \(#[0-9]+\)$/, "", text)
      text = toupper(substr(text, 1, 1)) substr(text, 2)
      if (type == "feat") add("Features", text)
      else if (type == "fix") add("Fixes", text)
      else if (type == "perf") add("Performance", text)
      else if (type == "i18n") add("Translations", text)
      else if (type == "docs") add("Documentation", text)
      else if (type == "refactor") add("Refactoring", text)
      else add("Other", text)
    }
    END {
      n = split("Features Fixes Performance Translations Documentation Refactoring Other", order, " ")
      for (i = 1; i <= n; i++) if (items[order[i]] != "") printf "**%s**\n%s\n", order[i], items[order[i]]
    }'
} > "$notes"

if [ "$dry" = 1 ]; then
  echo "Dry run. Base: origin/main $(git rev-parse --short "$base"), previous release: ${prev:-none}."
  echo "Would create branch $branch, commit \"$title version\", open PR \"$title\"."
  echo
  git -C "$wt" --no-pager diff
  echo "----- release notes draft (PR body) -----"
  cat "$notes"
  exit 0
fi

# cargo metadata must see the new version (a wrong Cargo.toml fails the release-flow check later; fail now instead).
if command -v cargo > /dev/null 2>&1; then
  seen="$(cd "$wt/daemon" && cargo metadata --no-deps --offline --locked --format-version 1 \
    | python3 -c 'import json,sys; print([p["version"] for p in json.load(sys.stdin)["packages"] if p["name"]=="bandito"][0])')"
  [ "$seen" = "$version" ] || die "cargo metadata says $seen, expected $version"
else
  echo "release: cargo not found; skipping the cargo metadata check" >&2
fi

git -C "$wt" checkout --quiet -B "$branch"
git -C "$wt" add apps/mac/project.yml apps/ios/project.yml daemon/Cargo.toml daemon/Cargo.lock
git -C "$wt" commit --quiet -m "$title version"
# A branch left from an earlier run without a PR is replaced (it is always cut from origin/main).
git -C "$wt" push --quiet --force -u origin "$branch"

url="$(gh pr create --base main --head "$branch" --title "$title" --body-file "$notes")"
echo "Release PR: $url"
echo "Edit the PR description (it becomes the release notes), wait for CI, then squash-merge."
echo "After the merge, release-flow builds and publishes the server; approve the app run in GitHub Actions."
