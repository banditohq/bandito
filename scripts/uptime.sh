#!/usr/bin/env bash
# Uptime probe for bandito.dev. Runs the public checks and prints one line per check: "OK <name>" or
# "FAIL <name>: <what>". Exits 1 when any check failed after its retry. The uptime workflow turns the result into an
# issue and a Telegram message; this script sends nothing itself, so it can run on a laptop.
# Test override: UPTIME_BASE (the site root, default https://bandito.dev), e.g. UPTIME_BASE=https://bandito.dev/broken.
set -euo pipefail

BASE="${UPTIME_BASE:-https://bandito.dev}"
TIMEOUT=15
RETRY_PAUSE=10
APPCAST_LAG_LIMIT=$((3 * 3600))
DOWNLOAD_RE='^https://github\.com/banditohq/bandito/releases/download/[^/]+/Bandito-[^/]+\.dmg$'
INSTALL_RE='^https://github\.com/banditohq/bandito/releases/.+/install\.sh$'

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILED=0
DETAIL=""
CODE=""
LOCATION=""

# get URL BODY_FILE: sets CODE (000 when there is no answer) and LOCATION (redirect target, empty when none).
get() {
  local out
  out=$(curl -sS -m "$TIMEOUT" -o "$2" -w '%{http_code} %{redirect_url}' "$1" 2>/dev/null) || out="000 "
  read -r CODE LOCATION <<<"$out" || true
  LOCATION=${LOCATION:-}
}

# head_code URL: final HTTP code after following redirects (HEAD only, the dmg is not downloaded).
head_code() {
  local out
  out=$(curl -sSIL -m "$TIMEOUT" -o /dev/null -w '%{http_code}' "$1" 2>/dev/null) || out=000
  printf '%s' "$out"
}

http_detail() {
  if [ "$CODE" = 000 ]; then DETAIL="нет ответа"; else DETAIL="HTTP $CODE"; fi
}

check_home() {
  get "$BASE/" "$TMP/home.html"
  if [ "$CODE" != 200 ]; then http_detail; return 1; fi
  if ! grep -qi 'bandito' "$TMP/home.html"; then DETAIL="в HTML нет слова bandito"; return 1; fi
}

check_ru() {
  get "$BASE/ru/" "$TMP/ru.html"
  if [ "$CODE" != 200 ]; then http_detail; return 1; fi
}

check_appcast() {
  get "$BASE/appcast.xml" "$TMP/appcast.xml"
  if [ "$CODE" != 200 ]; then http_detail; return 1; fi

  # The newest item of the feed (highest sparkle:version) must be well-formed XML with a shortVersionString.
  local feed_ver
  if ! feed_ver=$(python3 -I - "$TMP/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

SP = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(sys.argv[1]).getroot()
best = None
for item in root.iter("item"):
    short = item.find(SP + "shortVersionString")
    build = item.find(SP + "version")
    if short is None or build is None or not (short.text or "").strip():
        continue
    key = int(build.text)
    if best is None or key > best[0]:
        best = (key, short.text.strip())
if best is None:
    sys.exit(1)
print(best[1])
PY
  ); then
    DETAIL="невалидный XML или нет sparkle:shortVersionString"
    return 1
  fi

  # The latest app release: the newest non-draft release that carries the Mac zip (server-only releases have none).
  local latest tag published
  if ! latest=$(gh api 'repos/banditohq/bandito/releases?per_page=30' --jq '
      [.[] | select(.draft == false and .prerelease == false)
           | select([.assets[].name | test("^Bandito-[0-9.]+\\.zip$")] | any)]
      | first | if . == null then empty else "\(.tag_name) \(.published_at)" end'); then
    DETAIL="GitHub API не ответил"
    return 1
  fi
  if [ -z "$latest" ]; then DETAIL="нет GitHub-релиза с приложением"; return 1; fi
  tag=${latest%% *}
  published=${latest#* }
  if [ "$feed_ver" = "${tag#v}" ]; then return 0; fi

  local age
  age=$(python3 -I -c '
import datetime as d, sys
p = d.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print(int((d.datetime.now(d.timezone.utc) - p).total_seconds()))' "$published")
  if [ "$age" -gt "$APPCAST_LAG_LIMIT" ]; then
    DETAIL="appcast отстаёт: в ленте $feed_ver, последний релиз ${tag#v} опубликован $published (больше 3 ч назад)"
    return 1
  fi
}

check_download() {
  get "$BASE/download/mac" "$TMP/download.out"
  if [ "$CODE" != 302 ]; then http_detail; return 1; fi
  if ! [[ "$LOCATION" =~ $DOWNLOAD_RE ]]; then DETAIL="редирект не на Bandito .dmg: $LOCATION"; return 1; fi
  local final
  final=$(head_code "$LOCATION")
  if [ "$final" != 200 ]; then DETAIL="dmg по Location: HTTP $final"; return 1; fi
}

check_install() {
  get "$BASE/install" "$TMP/install.out"
  if [ "$CODE" != 302 ]; then http_detail; return 1; fi
  if ! [[ "$LOCATION" =~ $INSTALL_RE ]]; then DETAIL="редирект не на install.sh: $LOCATION"; return 1; fi
  local final
  final=$(head_code "$LOCATION")
  if [ "$final" != 200 ]; then DETAIL="install.sh по Location: HTTP $final"; return 1; fi
}

# run_check NAME FUNCTION: a failed check waits 10 s and runs once more; only the second failure counts.
run_check() {
  local name=$1 fn=$2
  DETAIL=""
  if ! "$fn"; then
    sleep "$RETRY_PAUSE"
    DETAIL=""
    if ! "$fn"; then
      echo "FAIL $name: $DETAIL"
      FAILED=1
      return 0
    fi
  fi
  echo "OK   $name"
}

run_check "главная" check_home
run_check "/ru/" check_ru
run_check "appcast" check_appcast
run_check "/download/mac" check_download
run_check "/install" check_install
exit "$FAILED"
