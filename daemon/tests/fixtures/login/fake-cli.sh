#!/bin/sh
# Fake agent CLI for the login probes (`claude auth status`, `codex login status`).
# `--version` answers the version probe. Any other call is a login probe: it is appended to
# $FAKE_CALLS (one line per call), waits $FAKE_SLEEP seconds, prints $FAKE_OUT on stdout,
# $FAKE_ERR on stderr, and exits with $FAKE_CODE (default 0).
if [ "$1" = "--version" ]; then
  echo "fake 1.0.0"
  exit 0
fi
if [ -n "$FAKE_CALLS" ]; then
  echo "$*" >> "$FAKE_CALLS"
fi
if [ -n "$FAKE_SLEEP" ]; then
  sleep "$FAKE_SLEEP"
fi
if [ -n "$FAKE_OUT" ]; then
  printf '%s\n' "$FAKE_OUT"
fi
if [ -n "$FAKE_ERR" ]; then
  printf '%s\n' "$FAKE_ERR" >&2
fi
exit "${FAKE_CODE:-0}"
