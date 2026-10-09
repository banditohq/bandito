#!/usr/bin/env python3
"""Check that guide/ covers every mode, sheet, settings section, setting, command and onboarding step.

The source of truth is the Swift code of the Apple app (BanditoUI). This script extracts the real list
of those elements with regular expressions and compares it with the `covers:` keys written in guide/*.md:

    <!-- id: <unique-id>; covers: mode:team, command:team.stop -->

Rules:
  - every extracted element must be covered by at least one guide entry (missing -> exit 1);
  - every covers key must name an extracted element (stale or misspelled -> exit 1);
  - every `## ` entry in guide/*.md (except index.md) has a metadata line right under the heading,
    a unique id, and a `Где:` line;
  - the required guide files exist.

Standard library only. Paths are resolved from this script's location.

  python3 scripts/check_guide.py          check, exit 0 when everything is covered
  python3 scripts/check_guide.py --list   also print the extracted elements
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "apps/mac/BanditoKit/Sources"
UI = SOURCES / "BanditoUI"
GUIDE = ROOT / "guide"

REQUIRED_FILES = [
    "index.md",
    "getting-started.md",
    "team.md",
    "new-agent.md",
    "files.md",
    "terminals.md",
    "browser.md",
    "screen.md",
    "server.md",
    "settings.md",
    "keys.md",
    "account.md",
    "security.md",
    "troubleshooting.md",
]

KINDS = ("mode", "sheet", "settings", "setting", "command", "onboarding")

ENUM_CASE = re.compile(r"^ {4}case\s+(.+?)\s*$")
IDENT = re.compile(r"\s*([A-Za-z_]\w*)")
COMMAND_ID = re.compile(r'\bcommand\(\s*"([a-z][A-Za-z]*(?:\.[A-Za-z][A-Za-z0-9]*)+)"')
APP_STORAGE_LIT = re.compile(r'@AppStorage\(\s*"([^"]+)"')
APP_STORAGE_REF = re.compile(r"@AppStorage\(\s*([A-Za-z_][\w.]*)\s*[,)]")
FOR_KEY_LIT = re.compile(r'forKey:\s*"([^"]+)"')
FOR_KEY_REF = re.compile(r"forKey:\s*([A-Za-z_][\w.]*)")
TYPE_REF = re.compile(r"\b([A-Z][A-Za-z0-9]*)\.(?=[A-Za-z_])")
META = re.compile(r"^<!--(?P<body>.*)-->\s*$")


class Failure(Exception):
    pass


def swift_files(base):
    return sorted(base.rglob("*.swift"))


def read(path):
    return path.read_text(encoding="utf-8")


def split_top_level(text):
    """Splits `a, b(x: Int, y: Int), c` on commas outside parentheses."""
    parts, depth, current = [], 0, ""
    for ch in text:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current)
    return parts


def enum_cases(path, name):
    """Case names of `enum <name>` declared in `path`. Members sit at exactly 4 spaces of indent."""
    src = read(path)
    head = re.search(rf"^\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?enum\s+{name}\b[^\n]*\{{", src, re.M)
    if not head:
        raise Failure(f"enum {name} not found in {path.relative_to(ROOT)}")
    cases = []
    for line in src[head.end():].split("\n"):
        if line.startswith("}"):
            break
        match = ENUM_CASE.match(line)
        if not match:
            continue
        for piece in split_top_level(match.group(1)):
            ident = IDENT.match(piece)
            if ident:
                cases.append(ident.group(1))
    if not cases:
        raise Failure(f"enum {name}: no cases parsed (check the regular expression)")
    return cases


def find_decl(name):
    """Swift files that declare the type `name`."""
    pattern = re.compile(rf"\b(?:struct|enum|class|actor|extension)\s+{name}\b")
    return [p for p in swift_files(SOURCES) if pattern.search(read(p))]


def resolve(ref, path, src):
    """String value of a key reference like `languageKey` or `MotionLevel.storageKey`."""
    if "." in ref:
        owner, member = ref.rsplit(".", 1)
        scopes = [(p, read(p)) for p in find_decl(owner)]
    else:
        member = ref
        scopes = [(path, src)]
    value_re = re.compile(rf'\b(?:let|var)\s+{re.escape(member)}\s*(?::\s*[^=\n]+)?=\s*"([^"]+)"')
    for _, text in scopes:
        found = value_re.search(text)
        if found:
            return found.group(1)
    raise Failure(f"cannot resolve storage key `{ref}` in {path.relative_to(ROOT)}")


def setting_keys():
    """UserDefaults / @AppStorage keys read by the Settings views, plus the storage keys of the types they use."""
    keys = set()
    settings_dir = UI / "Settings"
    types = set()
    for path in swift_files(settings_dir):
        src = read(path)
        for lit in APP_STORAGE_LIT.findall(src) + FOR_KEY_LIT.findall(src):
            keys.add(lit)
        for ref in APP_STORAGE_REF.findall(src) + FOR_KEY_REF.findall(src):
            keys.add(resolve(ref, path, src))
        types.update(TYPE_REF.findall(src))
    # Types the Settings views use (environment models, enums such as MotionLevel) contribute their
    # storage keys: `static let storageKey = "..."`, `defaultsKey`, `showHiddenDefaultsKey`.
    storage_re = re.compile(r'\bstatic\s+let\s+(\w*(?:storageKey|defaultsKey|DefaultsKey))\s*(?::\s*[^=\n]+)?=\s*"([^"]+)"')
    for owner in sorted(types):
        for path in find_decl(owner):
            for _, value in storage_re.findall(read(path)):
                keys.add(value)
    return keys


def extract():
    """Map kind -> set of names that the guide must cover."""
    found = {}
    found["mode"] = set(enum_cases(UI / "App/Router.swift", "AppMode"))
    found["sheet"] = set(enum_cases(UI / "App/Router.swift", "Sheet"))
    found["settings"] = set(enum_cases(UI / "Settings/SettingsSection.swift", "SettingsSection"))
    found["onboarding"] = set(enum_cases(UI / "Onboarding/OnboardingModel.swift", "OnboardingStep"))
    found["setting"] = setting_keys()
    found["command"] = set(COMMAND_ID.findall(read(UI / "App/Keymap.swift")))
    for kind, names in found.items():
        if not names:
            raise Failure(f"no {kind} elements extracted (parser broken?)")
    return found


def parse_meta(line):
    """`<!-- id: x; covers: a:b, c:d; status: planned -->` -> {"id": "x", "covers": "a:b, c:d", "status": "planned"}."""
    match = META.match(line.strip())
    if not match:
        return None
    fields = {}
    for part in match.group("body").split(";"):
        key, sep, value = part.partition(":")
        if sep and key.strip() in ("id", "covers", "status"):
            fields[key.strip()] = value.strip()
    return fields


def parse_guide():
    """Entries of guide/*.md: list of (file, id, status, covers) and the list of problems found."""
    entries, problems = [], []
    if not GUIDE.is_dir():
        raise Failure("guide/ directory is missing")
    for name in REQUIRED_FILES:
        if not (GUIDE / name).is_file():
            problems.append(f"guide/{name}: required file is missing")
    for path in sorted(GUIDE.glob("*.md")):
        if path.name == "index.md":
            continue
        lines = read(path).split("\n")
        for index, line in enumerate(lines):
            if not line.startswith("## "):
                continue
            title = line[3:].strip()
            following = [l for l in lines[index + 1 :] if l.strip()]
            meta_line = following[0].strip() if following else ""
            fields = parse_meta(meta_line)
            if fields is None or "id" not in fields or "covers" not in fields:
                problems.append(f"{path.name}: `## {title}` has no metadata line `<!-- id: ...; covers: ... -->` under it")
                continue
            entry_id = fields["id"]
            covers = [c.strip() for c in fields["covers"].split(",") if c.strip()]
            status = fields.get("status")
            if status not in (None, "planned"):
                problems.append(f"{path.name}: `## {title}` has unknown status `{status}` (only `planned`)")
            section_end = next((i for i in range(index + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
            body = "\n".join(lines[index + 1 : section_end])
            if not re.search(r"^Где:", body, re.M):
                problems.append(f"{path.name}: `## {title}` has no `Где:` line")
            entries.append((path.name, entry_id, status, covers, title))
    return entries, problems


def check(expected):
    entries, problems = parse_guide()

    ids = {}
    covered = set()
    for file_name, entry_id, _status, covers, title in entries:
        if entry_id in ids:
            problems.append(f"{file_name}: duplicate id `{entry_id}` (also in {ids[entry_id]})")
        ids[entry_id] = file_name
        for key in covers:
            kind, _, name = key.partition(":")
            if kind not in KINDS or not name:
                problems.append(f"{file_name}: `## {title}` has a bad covers key `{key}` (expected kind:name, kind in {', '.join(KINDS)})")
                continue
            covered.add((kind, name))
            if name not in expected[kind]:
                problems.append(f"{file_name}: `## {title}` covers `{key}`, which does not exist in the app code (stale guide?)")

    missing = []
    for kind in KINDS:
        for name in sorted(expected[kind]):
            if (kind, name) not in covered:
                missing.append(f"{kind}:{name}")

    return problems, missing, len(entries)


def main(argv):
    try:
        expected = extract()
    except Failure as error:
        print(f"check_guide: {error}")
        return 1

    if "--list" in argv:
        for kind in KINDS:
            names = sorted(expected[kind])
            print(f"{kind} ({len(names)}): {', '.join(names)}")

    try:
        problems, missing, entries = check(expected)
    except Failure as error:
        print(f"check_guide: {error}")
        return 1

    for line in problems:
        print(f"PROBLEM {line}")
    for key in missing:
        print(f"MISSING {key}")

    if problems or missing:
        print(f"check_guide: FAILED — {len(missing)} not covered, {len(problems)} problems")
        return 1

    total = sum(len(v) for v in expected.values())
    print(f"check_guide: OK — {total} elements covered by {entries} guide entries")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
