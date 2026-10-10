#!/usr/bin/env python3
"""Builds the screenshot gallery: one dark HTML page with a grid of the sweep's pictures, next to the PNGs.

Usage: gallery.py <dir-with-pngs> <title> [--markdown <file>]

Reads the names `sweep.sh` writes (`<mode>-<W>x<H>.png`, `sheet-<name>-<W>x<H>.png`), writes `<dir>/index.html`
and lists the files in the order of the app: modes, then sheets, each size together. With `--markdown` it also
writes the table for a pull request comment (file names only; a comment cannot hold the pictures).
A picture under 6 KB is flagged "may be blank": a screen capture without permission is an empty image.
"""

import html
import os
import re
import sys

MODE_ORDER = ["team", "files", "terminals", "browser", "screen", "market", "server"]
SHEET_ORDER = ["newAgent", "account", "addServer"]
BLANK_BYTES = 6 * 1024
NAME = re.compile(r"^(?:(sheet)-)?([A-Za-z]+)-(\d+)x(\d+)\.png$")

LABELS = {
    "team": "Team (main feed)",
    "files": "Files",
    "terminals": "Terminals",
    "browser": "Browser",
    "screen": "Screen",
    "market": "Marketplace",
    "server": "Server",
    "newAgent": "Sheet: new agent",
    "account": "Sheet: account",
    "addServer": "Sheet: add a server",
}


def entries(folder):
    found = []
    for name in sorted(os.listdir(folder)):
        match = NAME.match(name)
        if not match:
            continue
        sheet, what, width, height = match.groups()
        order = (SHEET_ORDER if sheet else MODE_ORDER)
        rank = order.index(what) if what in order else len(order)
        size = os.path.getsize(os.path.join(folder, name))
        found.append(
            {
                "file": name,
                "kind": "sheet" if sheet else "mode",
                "what": what,
                "label": LABELS.get(what, what),
                "size": f"{width}x{height}",
                "key": (int(width), 1 if sheet else 0, rank),
                "blank": size < BLANK_BYTES,
            }
        )
    found.sort(key=lambda e: e["key"])
    return found


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
:root {{ color-scheme: dark; --bg: #0e0e10; --card: #17171a; --line: #2a2a2f; --text: #ececee; --dim: #8d8d95; --warn: #e0a458; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; padding: 24px 16px 48px; background: var(--bg); color: var(--text); font: 14px/1.4 -apple-system, "Helvetica Neue", sans-serif; }}
h1 {{ font-size: 20px; margin: 0 0 4px; }}
h2 {{ font-size: 15px; margin: 32px 0 12px; color: var(--dim); font-weight: 600; }}
p.meta {{ margin: 0; color: var(--dim); }}
.grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 16px; }}
figure {{ margin: 0; background: var(--card); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; }}
figure a {{ display: block; background: #000; }}
figure img {{ display: block; width: 100%; height: auto; }}
figcaption {{ padding: 8px 12px 10px; display: flex; justify-content: space-between; gap: 8px; }}
figcaption span:last-child {{ color: var(--dim); font-variant-numeric: tabular-nums; }}
.warn {{ color: var(--warn); }}
</style>
</head>
<body>
<h1>{title}</h1>
<p class="meta">{count} pictures. Click one for full size.</p>
{sections}
</body>
</html>
"""


def build(folder, title):
    items = entries(folder)
    sizes = []
    for item in items:
        if item["size"] not in sizes:
            sizes.append(item["size"])
    sections = []
    for size in sizes:
        cards = []
        for item in (e for e in items if e["size"] == size):
            note = ' <span class="warn">may be blank</span>' if item["blank"] else ""
            cards.append(
                f'<figure><a href="{html.escape(item["file"])}"><img loading="lazy" src="{html.escape(item["file"])}" '
                f'alt="{html.escape(item["label"])} at {size}"></a>'
                f"<figcaption><span>{html.escape(item['label'])}{note}</span><span>{size}</span></figcaption></figure>"
            )
        sections.append(f"<h2>{size}</h2>\n<div class=\"grid\">\n" + "\n".join(cards) + "\n</div>")
    page = PAGE.format(title=html.escape(title), count=len(items), sections="\n".join(sections))
    with open(os.path.join(folder, "index.html"), "w", encoding="utf-8") as handle:
        handle.write(page)
    return items


def markdown(items):
    """A table of the four previews a reviewer looks at first; the rest is in the gallery."""
    wanted = {("mode", "team"), ("mode", "market"), ("mode", "server"), ("sheet", "addServer")}
    rows = []
    if not items:
        return "_No pictures were taken._\n"
    top = max(int(e["size"].split("x")[0]) for e in items)
    for item in items:
        if (item["kind"], item["what"]) in wanted and int(item["size"].split("x")[0]) == top:
            flag = " (may be blank)" if item["blank"] else ""
            rows.append(f"| {item['label']} | {item['size']} | `{item['file']}`{flag} |")
    head = "| Screen | Size | File in the artifact |\n| --- | --- | --- |\n"
    return head + "\n".join(rows) + "\n"


def main():
    args = sys.argv[1:]
    if len(args) not in (2, 4) or (len(args) == 4 and args[2] != "--markdown"):
        raise SystemExit("usage: gallery.py <dir-with-pngs> <title> [--markdown <file>]")
    folder, title = args[0], args[1]
    items = build(folder, title)
    if len(args) == 4:
        with open(args[3], "w", encoding="utf-8") as handle:
            handle.write(markdown(items))
    blank = [e["file"] for e in items if e["blank"]]
    print(f"{len(items)} pictures, {len(blank)} possibly blank")
    for name in blank:
        print(f"  blank? {name}")


if __name__ == "__main__":
    main()
