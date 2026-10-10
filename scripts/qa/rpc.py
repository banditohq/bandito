#!/usr/bin/env python3
"""A tiny JSON-RPC client for a QA daemon (loopback only), the way the app talks to it.

As a tool:   rpc.py <ws://127.0.0.1:PORT/v1/rpc> <token-file> <method> [json-params]
As a module: `with Client(url, token_file) as c: c.call("agents.list")`
The device token is read from the file (mode 0600), sent as a bearer header and never printed.
"""

import json
import sys
from urllib.parse import urlsplit

from websockets.sync.client import connect


def check_loopback(url):
    """Only ws://127.0.0.1:<port>: the token never leaves the loopback."""
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise SystemExit("rpc.py: the URL has a bad port")
    if parts.scheme != "ws" or parts.hostname != "127.0.0.1" or port is None:
        raise SystemExit("rpc.py: only ws://127.0.0.1:<port> is accepted")


class Client:
    def __init__(self, url, token_file):
        check_loopback(url)
        with open(token_file, encoding="utf-8") as handle:
            self.token = handle.read().strip()
        self.url = url
        self.ws = None
        self.next_id = 1

    def __enter__(self):
        self.ws = connect(
            self.url,
            additional_headers={"Authorization": f"Bearer {self.token}"},
            open_timeout=5,
            close_timeout=2,
            max_size=64 * 1024 * 1024,
        )
        return self

    def __exit__(self, *_):
        if self.ws is not None:
            self.ws.close()

    def call(self, method, params=None):
        ident = self.next_id
        self.next_id += 1
        self.ws.send(json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params or {}}))
        while True:
            reply = json.loads(self.ws.recv(timeout=30))
            if reply.get("id") != ident:
                continue  # an event, or the reply to something else
            if "error" in reply:
                raise RuntimeError(f"{method}: {reply['error'].get('message', 'error')}")
            return reply.get("result")


def main():
    if len(sys.argv) < 4:
        raise SystemExit("usage: rpc.py <ws-url> <token-file> <method> [json-params]")
    url, token_file, method = sys.argv[1:4]
    params = json.loads(sys.argv[4]) if len(sys.argv) > 4 else {}
    with Client(url, token_file) as client:
        print(json.dumps(client.call(method, params), indent=2))


if __name__ == "__main__":
    main()
