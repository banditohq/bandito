#!/usr/bin/env python3
"""Check the "What's new" notes in release-notes/<version>.json.

Every file must be valid: file name = `version`, a real `date`, 3 to 6 items, each with an SF Symbol name in `icon`
and a non-empty `title` and `text` in all nine languages of the app (no other keys). The same rules live in the app
(`ReleaseNotes.problems`), which refuses a broken file at run time.

  python3 scripts/check_release_notes.py                     check every file in release-notes/
  python3 scripts/check_release_notes.py --require-current   also demand the file of apps/mac/project.yml's
                                                             MARKETING_VERSION (a release must ship its notes)
  python3 scripts/check_release_notes.py --require 0.1.15    demand the file of that version
  python3 scripts/check_release_notes.py --root DIR          another repository root (tests)

Standard library only.
"""

import datetime
import json
import re
import sys
from pathlib import Path

LANGUAGES = ("en", "ru", "de", "es", "fr", "ja", "ko", "pt-BR", "zh-Hans")
MIN_ITEMS, MAX_ITEMS = 3, 6
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$")
SYMBOL_RE = re.compile(r"^[a-z0-9]+(\.[a-z0-9]+)*$")


def problems(path: Path) -> list[str]:
    """Everything wrong with one notes file, one line each (empty list = valid)."""
    out: list[str] = []
    try:
        doc = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"{path.name}: cannot read as JSON ({error})"]
    if not isinstance(doc, dict):
        return [f"{path.name}: the top level must be an object"]
    version = doc.get("version")
    if not isinstance(version, str) or not VERSION_RE.match(version):
        out.append(f"{path.name}: `version` must be X.Y.Z or X.Y.Z-beta.N")
    elif version + ".json" != path.name:
        out.append(f"{path.name}: `version` is {version}, the file name must be {version}.json")
    date = doc.get("date")
    try:
        if not isinstance(date, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
            raise ValueError
        datetime.date.fromisoformat(date)
    except ValueError:
        out.append(f"{path.name}: `date` must be a real date, YYYY-MM-DD")
    items = doc.get("items")
    if not isinstance(items, list) or not MIN_ITEMS <= len(items) <= MAX_ITEMS:
        out.append(f"{path.name}: `items` must be a list of {MIN_ITEMS} to {MAX_ITEMS}")
        return out
    for number, item in enumerate(items, 1):
        where = f"{path.name}: item {number}"
        if not isinstance(item, dict):
            out.append(f"{where}: must be an object")
            continue
        icon = item.get("icon")
        if not isinstance(icon, str) or not SYMBOL_RE.match(icon):
            out.append(f"{where}: `icon` must be an SF Symbol name such as sparkles or person.3.fill")
        for field in ("title", "text"):
            value = item.get(field)
            if not isinstance(value, dict):
                out.append(f"{where}: `{field}` must be an object with the nine languages")
                continue
            for code in LANGUAGES:
                text = value.get(code)
                if not isinstance(text, str) or not text.strip():
                    out.append(f"{where}: `{field}.{code}` is missing or empty")
            for code in value:
                if code not in LANGUAGES:
                    out.append(f"{where}: `{field}.{code}` is not one of the app's languages")
    return out


def marketing_version(root: Path) -> str:
    text = (root / "apps/mac/project.yml").read_text(encoding="utf-8")
    found = re.findall(r"^\s*MARKETING_VERSION:\s*\"?([^\"\s]+)\"?\s*$", text, re.M)
    if len(found) != 1:
        raise SystemExit(f"check_release_notes: expected one MARKETING_VERSION in project.yml, found {len(found)}")
    return found[0]


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parent.parent
    required: str | None = None
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--root" and args:
            root = Path(args.pop(0))
        elif arg == "--require" and args:
            required = args.pop(0)
        elif arg == "--require-current":
            required = marketing_version(root)
        else:
            print(__doc__, file=sys.stderr)
            return 2
    folder = root / "release-notes"
    failures: list[str] = []
    files = sorted(folder.glob("*.json")) if folder.is_dir() else []
    for path in files:
        failures += problems(path)
    if required is not None and not (folder / f"{required}.json").is_file():
        failures.append(
            f"release-notes/{required}.json is missing: write the 'What's new' notes of {required} "
            f"(copy release-notes/<an earlier version>.json, 3-6 items, all 9 languages)"
        )
    for line in failures:
        print(f"check_release_notes: {line}", file=sys.stderr)
    if failures:
        return 1
    print(f"release notes ok ({len(files)} file(s)" + (f", {required} present" if required else "") + ")")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
