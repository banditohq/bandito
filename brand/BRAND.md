# Bandito brand book — Ember Signature

One system for the website, the Mac app and the iPhone app. Tokens live in [`tokens/tokens.json`](tokens/tokens.json); everything else is generated from them (`python3 brand/tokens/build.py`).

## Principles

1. **Warm dark.** Ember ground, cream text, quiet hairlines, a grid that fades out. Light mode is a twin with the same tokens, not an afterthought.
2. **Two voices.** Geist for people, Geist Mono for anything a machine wrote: commands, logs, paths, keys.
3. **Orange means you.** Signal orange appears only when a person is needed: approvals, the primary action, the "needs you" state. It is never decoration.

## Color

| Token | Dark | Light | Use |
|---|---|---|---|
| `bg` | `#12100E` | `#F6F1E8` | Page and window ground |
| `surface-1/2/3` | `#1A1714` / `#221E1A` / `#2C2722` | `#FFFDF9` / `#EFE8DC` / `#E6DDCE` | Cards, inputs, selected rows |
| `line`, `line-strong` | cream 8% / 14% | ink 10% / 18% | Hairlines, borders |
| `text`, `text-2`, `text-3` | `#F3EBDD` / `#BDB2A0` / `#867C6D` | `#1C1916` / `#5B544A` / `#736B5F` | Primary, secondary, captions |
| `signal` | `#FF8A1F` | `#E0670C` | Dots, glow, accent text, focus rings |
| `signal-fill` → `signal-fill-end` | `#E4620E` → `#C94F09` | same | Fill of buttons with white text |
| `ok` | `#A9C7A2` sage | `#457040` | Working, success |
| `info` | `#A3BDEB` sky | `#41609E` | Scheduled, later |
| `danger` | `#F2A093` rose | `#B4432F` | Deny, destructive |

Contrast (WCAG): body text ≥ 9:1 on dark; captions ≥ 4.6:1 in both themes. White on the button fill is 3.5:1 at the top and 4.6:1 at the bottom of the gradient, so button labels are 15px semibold or larger. Bright `#FF8A1F` never sits under white text.

## Type

Geist (sans) and Geist Mono, both SIL OFL. Headlines are Geist 700 with tight tracking; the accent line of a headline uses the signal gradient (`#FFC48A → #FF8A1F → #F06A14`).

| Style | Size / weight | Tracking | Use |
|---|---|---|---|
| display | 80 / 700 | −0.05em | Website hero |
| title | 44 / 700 | −0.045em | Section titles |
| heading | 22 / 600 | −0.02em | Cards, panels |
| body | 15 / 400, 1.6 | 0 | Prose |
| small | 13 / 500 | 0 | Meta, captions |
| mono | 13 / 400 | 0 | Commands, logs |
| label | 11 / 500, uppercase | +0.09em | Section labels (mono) |

## Shape, space, motion

Radius `sm 8 · md 12 · lg 18 · xl 24 · pill`. Space on a 4px scale. Motion 120 / 200 / 320 ms on `cubic-bezier(0.2, 0.8, 0.2, 1)`; respect reduced motion.

## Components (reference: design canvas, board 11)

- **Buttons:** primary (signal fill, white label), secondary (surface-3 + line), ghost, danger (rose tint). Sizes 36 / 46 / 54. Keyboard hint inside when an action has a key.
- **Status chips:** working (sage), needs you (signal), scheduled (sky), idle (surface-3). Always a dot plus a word, never color alone.
- **Approval card:** gradient signal border, agent name, the exact command in mono, Deny / Approve, "always allow" checkbox.
- **Agent avatar:** rounded square, pastel fill, initial in Geist 700.

## Icons

`icons/*.svg`: 24 grid, 1.6 stroke, round caps and joins, `currentColor`. Draw new icons the same way.

## Logo

`logo/`: the raccoon mark (eyes `>` and `–`, signal dot), icon, mono and lockups. Clear space around the mark = the width of the signal dot × 2. Do not recolor the mark except to the mono versions.

## Languages

Site and apps ship in English, 日本語, 简体中文, Español, Português (BR), Deutsch, Français and 한국어. English is the source; translations are generated with Claude in CI and reviewed in the pull request.
