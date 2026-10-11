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
- Bottom action rows of sheets and dialogs use `ActionRow` (a row that turns into a column when it does not fit); check long languages (German) at the narrowest width.
- A new sheet, dialog or settings section gets an entry in `LayoutAuditSnapshots`; run it with `LAYOUT_AUDIT_DIR=$(mktemp -d)` and look at German at the minimum width before calling the screen done.
- Layout never breaks on a long text: no fixed-width columns that squeeze a text column below ~90 pt, no one-line titles that carry a user's name (allow two lines), no row of buttons outside `ActionRow`, no word that breaks letter by letter (give it `.lineLimit(1).fixedSize()` and let the neighbour give way).
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
- A scroll step costs about 0.08 ms for every row that exists in a non-lazy stack, built or not on screen. The thread builds only the rows near the screen and stands in empty spaces for the rest (`ThreadVirtualWindow`); a new long list does the same or is lazy.
- Never pass a `Binding(get:set:)` that reads an `@Observable` into a child (`Composer` used to take one from `ThreadView`): the parent reads it while it builds the child, so each typed letter rebuilt the whole thread. The child reads and writes the model itself.
- Per-row work that repeats on every redraw (regex, `DateFormatter`, `ByteCountFormatter`, `NSRegularExpression(pattern:)`) is made once and kept (`PlainLineCache`, `DateFormatterCache`, static regexes in `ChatLinks`).
- A view that reads `server.thread(for:)` is rebuilt at every streamed token: read it in the row (`ThreadReader`), not in the list that holds the rows.
- Polling that only feeds a screen skips its tick while the app is not active (`AppActivity.isActive`).
- Measure with the QA scenarios (`perf thread|threadfast|typing|switch|inspector|market|settings|modes`, `PerfScenarios.swift`; the JSON lists frames, the main thread's work per frame and `bodies`, how often key views built). A build for speed: `BANDITO_XCODE_EXTRA="SWIFT_OPTIMIZATION_LEVEL=-O" scripts/build.sh`. Hangs of the main thread of 250 ms or more are logged by `HangMonitor` (`dev.bandito` / `perf`) and counted as `perf.hang.<screen>`.

## Decoding replies

`RPCClient.decoder` uses `convertFromSnakeCase`. `CodingKeys` must be plain camelCase (`case imageRev`), never a raw
snake value (`case imageRev = "image_rev"` silently never matches). Test a wire type with `RPCClient.decoder`.

## Daemon features

Check a capability with `server.supports("<feature>")` before calling a newer RPC, so the app keeps working with an
older daemon. Feature names are listed in `daemon.info` (`docs/ARCHITECTURE.md`).
