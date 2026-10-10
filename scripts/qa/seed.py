#!/usr/bin/env python3
"""Fills a QA daemon with something to look at: agents, threads, an image attachment, a browser tool card.

Usage: seed.py <ws://127.0.0.1:PORT/v1/rpc> <token-file> <daemon-home>

What goes through the daemon's RPC: the agents (`agents.create`), the person's messages (`agents.send`) and the
image (`attachments.upload`). The agents are paused first, so no message starts a CLI session: no CLI, login or
network is needed.

A paused agent never answers, so the answers, tool calls and results are written straight into the daemon's
event table (`<daemon-home>/bandito.db`, the same rows `Store::append_event` writes). That is a QA-only shortcut for
a daemon nobody else uses; it never touches a real home. Run this only against a fresh QA daemon.
"""

import base64
import json
import os
import sqlite3
import struct
import sys
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rpc import Client  # noqa: E402


def png(width, height):
    """A small gradient picture (stdlib only), so the thread has a real image attachment."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows += bytes((40 + 180 * x // width, 60 + 120 * y // height, 160 - 90 * x // width))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(rows), 9))
        + chunk(b"IEND", b"")
    )


class Events:
    """Writes events into the daemon's table, stamped with the time of the write."""

    def __init__(self, home):
        self.db = sqlite3.connect(os.path.join(home, "bandito.db"), timeout=20)

    def add(self, agent_id, kind, payload):
        self.db.execute(
            "INSERT INTO events (agent_id, ts, kind, payload) VALUES (?, ?, ?, ?)",
            (agent_id, int(time.time() * 1000), kind, json.dumps(payload)),
        )
        self.db.commit()

    def say(self, agent_id, text):
        self.add(agent_id, "message.assistant", {"text": text})

    def tool(self, agent_id, call_id, tool, title, tool_input, output, ok=True):
        self.add(agent_id, "tool.call", {"call_id": call_id, "tool": tool, "title": title, "input": tool_input})
        self.add(agent_id, "tool.result", {"call_id": call_id, "ok": ok, "output": output})


AGENTS = [
    ("Ada", "Lead engineer", "claude", "Owns the release branch and reviews every pull request."),
    ("Rex", "Backend", "codex", "Writes the daemon and its tests."),
    ("Mira", "Designer", "grok", "Keeps the app looking like the design language."),
    ("Orbit", "Researcher", "claude", "Reads the web and brings back short answers."),
]


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: seed.py <ws-url> <token-file> <daemon-home>")
    url, token_file, home = sys.argv[1:]
    events = Events(home)
    ids = {}
    with Client(url, token_file) as rpc:
        for name, role, runtime, prompt in AGENTS:
            made = rpc.call(
                "agents.create",
                {"name": name, "role": role, "runtime": runtime, "system_prompt": prompt, "cwd": ""},
            )
            ids[name] = made["id"]
        rpc.call("agents.pause_all", {"paused": True})

        def send(name, text, attachments=()):
            rpc.call("agents.send", {"agent_id": ids[name], "text": text, "attachments": list(attachments)})

        ada, rex, mira, orbit = (ids[n] for n in ("Ada", "Rex", "Mira", "Orbit"))

        send("Ada", "What is left before we cut 0.1.6?")
        events.say(ada, "Three things:\n\n1. The gallery workflow needs one green run.\n2. `i18n` has two untranslated keys.\n3. The release notes.\n\nI can take the first two.")
        send("Ada", "Take both. Rex, please check the daemon side.")
        events.tool(ada, "t1", "Bash", "Run python3 i18n/build.py --check", {"command": "python3 i18n/build.py --check"}, "generated strings are up to date")
        events.say(ada, "`i18n` is clean, the two keys were already merged. Only the gallery is left.")

        send("Rex", "Add a test for the pairing code expiry.")
        events.tool(rex, "t1", "Read", "Read daemon/src/pairing.rs", {"file_path": "daemon/src/pairing.rs"}, "pub fn redeem(...) -> Result<Device>")
        events.tool(
            rex,
            "t2",
            "Edit",
            "Edit daemon/src/pairing.rs",
            {"file_path": "daemon/src/pairing.rs"},
            "ok",
        )
        events.say(rex, "Added `redeem_after_expiry_is_refused`. It fails on the old code and passes now.")
        send("Rex", "Run the whole suite.")
        events.tool(rex, "t3", "Bash", "Run cargo test", {"command": "cargo test -q"}, "test result: ok. 412 passed; 0 failed")
        events.say(rex, "All 412 tests pass.")

        image = png(640, 400)
        shot = rpc.call(
            "attachments.upload",
            {"agent_id": mira, "name": "sidebar-draft.png", "data_base64": base64.b64encode(image).decode()},
        )
        send("Mira", "Here is the new sidebar draft. Does the spacing match the design language?", [shot["path"]])
        events.say(mira, "The rows are 36 pt high and the gap is 4 pt, which is what the tokens say. The selected row could use the signal color a little less.")
        send("Mira", "Good, keep it. Check how it looks in the store listing too.")

        send("Orbit", "Open the SwiftUI docs and tell me what changed in the toolbar API.")
        events.tool(
            orbit,
            "b1",
            "mcp__bandito__browser_navigate",
            "Open developer.apple.com/documentation/swiftui/toolbar",
            {"url": "https://developer.apple.com/documentation/swiftui/toolbar"},
            "Loaded: Toolbar | Apple Developer Documentation",
        )
        events.tool(
            orbit,
            "b2",
            "mcp__bandito__browser_snapshot",
            "Read the page",
            {},
            "Toolbar(content:) builds a toolbar from toolbar items.",
        )
        events.say(orbit, "The toolbar now takes `ToolbarSpacer` for grouping and a `defaultCustomization` option. Nothing breaks for existing code.")

        listed = rpc.call("agents.list")
    count = events.db.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    print(f"seeded {len(listed)} agents, {count} events")


if __name__ == "__main__":
    main()
