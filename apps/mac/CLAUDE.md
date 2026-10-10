# Bandito Mac app — notes for agents

SwiftUI, macOS, dark theme. The app is a thin shell (`apps/mac/Bandito`); all code is the SwiftPM package
`apps/mac/BanditoKit`:

- `BanditoKit` — models, RPC client (`RPC.swift`), `ServerModel` (one per server), connect/install, account.
- `BanditoUI` — every view, by area: `Shell/` (window, sidebar, mode bar), `Team/` (chat, inspector, composer),
  `Files/`, `Terminals/`, `Browser/`, `Screen/`, `Market/`, `Server/`, `Settings/`, `Account/`, `Avatar/`,
  `Onboarding/`, `Components/` (shared controls).
- `BanditoDesign` — color and type tokens, generated from `brand/tokens/tokens.json`. `BanditoL10n` — generated strings.

## Build and test

- `cd apps/mac/BanditoKit && swift test` — both suites. In a worktree on a nearly full disk pass
  `--scratch-path <a folder outside the repo>` and delete it after.
- The app bundle: `apps/mac/scripts/build.sh` (xcodegen + xcodebuild, Debug). Release: `apps/mac/scripts/release-app.sh`.
- After building: `git checkout -- apps/mac/BanditoKit/Package.resolved`.
- Run the app only as a QA copy (`docs/qa/RUNBOOK.md`), never against the person's own daemon or defaults.

## Rules

- Strings: add keys to every `i18n/*.json` (9 languages, real translations), run `python3 i18n/build.py`, use
  `L10n.*`. Remove keys that nothing uses any more. A string with a parameter uses `{name}` in JSON.
- Guide: a new control or screen gets a line in `guide/*.md`; `python3 scripts/check_guide.py` must pass.
- Buttons: only the styles in `Components/Buttons.swift` — `.signal` (the cream primary, one per view), `.quiet`,
  `.lightPill`, `.icon(label:)`, `.row`, `.link`. No hand-made button looks.
- Fonts: only `BanditoFont.display/text/mono(size:weight:)` (Unbounded, Onest, JetBrains Mono; bundled in `BanditoDesign/Fonts`). `.font(.system(...))` is for SF Symbols only. Roles: `docs/DESIGN_LANGUAGE.md`, Typography.
- Look and motion: `docs/DESIGN_LANGUAGE.md`. Every animation honours `accessibilityReduceMotion`.
- Logic lives in small pure types next to the view (`…Rules`, `…Layout`, `…Logic`) and has tests in
  `Tests/BanditoUITests`. Views stay thin.

## Performance rules (each one came from a real freeze or lag)

- Never write `@State`/model state from `onScrollGeometryChange`, `onGeometryChange`, hover or a timer unless the
  value changed (compare first). One write per frame re-renders the whole subtree.
- No `LazyVStack` in the chat thread: its estimates and hover updates looped at 100% CPU. The thread renders a
  `VStack` window of the newest items (`ThreadScroll`), rows are `Equatable` (`ThreadRowKey`), message bodies are
  parsed once (`MessageRenderCache`).
- Live pictures (browser screencast) go to a `CALayer` (`BrowserFrameLayer`), never through `@Observable` per frame.
  Decode images off the main thread.
- No shadows, blurs or materials on every row of a long list; use them on hover or on single surfaces.

## Decoding replies

`RPCClient.decoder` uses `convertFromSnakeCase`. `CodingKeys` must be plain camelCase (`case imageRev`), never a raw
snake value (`case imageRev = "image_rev"` silently never matches). Test a wire type with `RPCClient.decoder`.

## Daemon features

Check a capability with `server.supports("<feature>")` before calling a newer RPC, so the app keeps working with an
older daemon. Feature names are listed in `daemon.info` (`docs/ARCHITECTURE.md`).
