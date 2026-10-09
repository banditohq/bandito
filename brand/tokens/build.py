#!/usr/bin/env python3
"""Generate platform files from tokens.json. Stdlib only.

Outputs (brand/tokens/dist/):
  tokens.css               CSS custom properties, dark default + light twin
  BanditoTokens.swift      SwiftUI spacing, radius, type and motion constants
  Colors.xcassets/         Asset-catalog color sets with dark and light appearances
"""
import json, os, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
T = json.load(open(os.path.join(HERE, "tokens.json")))
OUT = os.path.join(HERE, "dist")


def rgba(hexstr):
    h = hexstr.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    a = int(h[6:8], 16) / 255 if len(h) == 8 else 1.0
    return r, g, b, a


def css_color(hexstr):
    r, g, b, a = rgba(hexstr)
    return hexstr if a == 1.0 else f"rgba({r}, {g}, {b}, {a:.3f})"


def camel(name):
    head, *rest = name.split("-")
    return head + "".join(p.title() for p in rest)


def build_css():
    def block(theme):
        return "\n".join(f"  --color-{k}: {css_color(v)};" for k, v in T["color"][theme].items())
    lines = ["/* Generated from tokens.json — do not edit. */", ":root {", block("dark"),
             f"  --font-sans: '{T['font']['sans']}', ui-sans-serif, system-ui, sans-serif;",
             f"  --font-mono: '{T['font']['mono']}', ui-monospace, SFMono-Regular, monospace;"]
    lines += [f"  --space-{k}: {v}px;" for k, v in T["space"].items()]
    lines += [f"  --radius-{k}: {v}px;" for k, v in T["radius"].items()]
    for k, v in T["type"].items():
        lines += [f"  --type-{k}-size: {v['size']}px;", f"  --type-{k}-weight: {v['weight']};",
                  f"  --type-{k}-tracking: {v['tracking']}em;", f"  --type-{k}-leading: {v['leading']};"]
    m = T["motion"]
    lines += [f"  --motion-fast: {m['fast']}ms;", f"  --motion-base: {m['base']}ms;", f"  --motion-slow: {m['slow']}ms;",
              f"  --motion-ease: cubic-bezier({', '.join(str(x) for x in m['ease'])});",
              "  --signal-fill: linear-gradient(180deg, var(--color-signal-fill), var(--color-signal-fill-end));",
              "  color-scheme: dark;", "}",
              "@media (prefers-color-scheme: light) {", "  :root:not([data-theme='dark']) {", block("light").replace("\n  ", "\n    ").replace("  --", "    --", 1),
              "    color-scheme: light;", "  }", "}",
              "[data-theme='light'] {", block("light"), "  color-scheme: light;", "}", ""]
    open(os.path.join(OUT, "tokens.css"), "w").write("\n".join(lines))


def build_xcassets():
    root = os.path.join(OUT, "Colors.xcassets")
    os.makedirs(root, exist_ok=True)
    json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(root, "Contents.json"), "w"), indent=2)

    def comp(hexstr):
        r, g, b, a = rgba(hexstr)
        return {"color-space": "srgb", "components": {"red": f"{r / 255:.3f}", "green": f"{g / 255:.3f}",
                                                      "blue": f"{b / 255:.3f}", "alpha": f"{a:.3f}"}}
    for name, dark in T["color"]["dark"].items():
        light = T["color"]["light"][name]
        d = os.path.join(root, f"{name}.colorset")
        os.makedirs(d, exist_ok=True)
        json.dump({"colors": [
            {"idiom": "universal", "color": comp(light)},
            {"idiom": "universal", "appearances": [{"appearance": "luminosity", "value": "dark"}], "color": comp(dark)},
        ], "info": {"author": "xcode", "version": 1}}, open(os.path.join(d, "Contents.json"), "w"), indent=2)


def build_swift():
    s = ["// Generated from tokens.json — do not edit.", "import SwiftUI", "",
         "public extension Color {", "    enum Bandito {"]
    s += [f'        public static let {camel(k)} = Color("{k}", bundle: .module)' for k in T["color"]["dark"]]
    s += ["    }", "}", "", "public enum BanditoSpace {"]
    s += [f"    public static let s{k}: CGFloat = {v}" for k, v in T["space"].items()]
    s += ["}", "", "public enum BanditoRadius {"]
    s += [f"    public static let {k}: CGFloat = {v}" for k, v in T["radius"].items()]
    s += ["}", "", "public enum BanditoType {",
          f'    public static let sans = "{T["font"]["sans"]}"', f'    public static let mono = "{T["font"]["mono"]}"']
    for k, v in T["type"].items():
        s.append(f"    public static let {k} = (size: CGFloat({v['size']}), weight: {v['weight']}, tracking: CGFloat({v['tracking']}), leading: CGFloat({v['leading']}))")
    m = T["motion"]
    s += ["}", "", "public enum BanditoMotion {",
          f"    public static let fast = {m['fast'] / 1000}", f"    public static let base = {m['base'] / 1000}",
          f"    public static let slow = {m['slow'] / 1000}",
          f"    public static let ease = Animation.timingCurve({', '.join(str(x) for x in m['ease'])}, duration: base)", "}", ""]
    open(os.path.join(OUT, "BanditoTokens.swift"), "w").write("\n".join(s))


if __name__ == "__main__":
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    build_css(); build_xcassets(); build_swift()
    print("tokens: wrote", os.path.relpath(OUT))
