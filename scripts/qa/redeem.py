#!/usr/bin/env python3
"""Exchanges a one-time pairing code for a device token, the way the app does (`pair.redeem`).

Used by scripts/qa/server.sh for the QA daemons on loopback only. The code is read as JSON from stdin
(`bandito --home <home> pair --json`). The token goes to <token-file> with mode 0600 and is never printed.

Usage: redeem.py <ws://127.0.0.1:PORT/v1/rpc> <token-file> <device-name>
"""

import json
import os
import sys
from urllib.parse import urlsplit

from websockets.sync.client import connect


def fail(message):
    print(f"redeem.py: {message}", file=sys.stderr)
    sys.exit(1)


def check_loopback_url(url):
    """Only ws://127.0.0.1:<port>: the pairing code is as good as a token, so it never leaves the loopback."""
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        fail("the URL has a bad port")
    if parts.scheme != "ws":
        fail("the URL must use the ws scheme")
    if parts.hostname != "127.0.0.1":
        fail("only a loopback daemon (127.0.0.1) is accepted")
    if port is None or not 1 <= port <= 65535:
        fail("the URL needs a port from 1 to 65535")


def write_secret(path, text):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def main():
    if len(sys.argv) != 4:
        fail("usage: redeem.py <ws-url> <token-file> <device-name>")
    url, token_path, device_name = sys.argv[1:]
    check_loopback_url(url)
    try:
        code = json.load(sys.stdin)["code"]
    except (ValueError, KeyError, TypeError):
        fail("stdin must be the JSON of `bandito pair --json`")

    # The wire names are snake_case: the daemon reads `device_name` (the app encodes its params the same way).
    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "pair.redeem",
        "params": {"code": code, "device_name": device_name},
    }
    with connect(url, open_timeout=5, close_timeout=2) as websocket:
        websocket.send(json.dumps(request))
        reply = json.loads(websocket.recv(timeout=10))

    if "error" in reply:
        fail(f"pair.redeem failed: {reply['error'].get('message', 'unknown error')}")
    result = reply["result"]
    write_secret(token_path, result["token"])
    print(f"paired device {result['device']['id']}")


if __name__ == "__main__":
    main()
