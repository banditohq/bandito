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
- The chat thread is an AppKit table (`ThreadList`, `NSTableView` with reused cells), not a SwiftUI stack: a stack laid
  out its whole window of rows at each scroll step, and `LazyVStack` looped on its estimates and hover (100% CPU). Each
  cell hosts the same SwiftUI row (`EquatableThreadRow`, keyed by `ThreadRowKey`), so bubbles, selection, menus,
  reactions and VoiceOver are the SwiftUI ones. A row is measured once per width (`ThreadListCell.height`), guessed
  (`ThreadHeightGuess`, once per line) until then; rows above the screen that change height move the offset with them.
  The lines are kept between updates (`ThreadListMemo`, handed over in a versioned box): a token makes and reconfigures
  the streamed line only. A thread just opened makes only the rows that show (`ThreadTableView.prepareOnlyVisible`).
  Message bodies are parsed once (`MessageRenderCache`).
- Live pictures (browser screencast) go to a `CALayer` (`BrowserFrameLayer`), never through `@Observable` per frame.
  Decode images off the main thread.
- No shadows, blurs or materials on every row of a long list; use them on hover or on single surfaces.
- A scroll step of a SwiftUI stack costs about 0.08 ms for every row that exists in it, built or not on screen: a long
  list is lazy or an AppKit table.
- Never pass a `Binding(get:set:)` that reads an `@Observable` into a child (`Composer` used to take one from `ThreadView`): the parent reads it while it builds the child, so each typed letter rebuilt the whole thread. The child reads and writes the model itself.
- Per-row work that repeats on every redraw (regex, `DateFormatter`, `ByteCountFormatter`, `NSRegularExpression(pattern:)`) is made once and kept (`PlainLineCache`, `DateFormatterCache`, static regexes in `ChatLinks`).
- A view that reads `server.thread(for:)` is rebuilt at every streamed token: read it in the row (`ThreadReader`), not in the list that holds the rows.
- A Marketplace shelf is a horizontal `ScrollView` with a `LazyHStack`: every card has one fixed width and the shelf one fixed height (a lazy row cannot ask unbuilt cards how tall they are), cards are `Equatable`, and the shelves sit in a plain `VStack` (a lazy stack of shelves moved heights while scrolling and spiked). The place of a row for its arrows comes from its `NSScrollView` (`onScrollGeometryChange` and `ScrollPosition` need macOS 15, the app runs on 14) into a model that writes its flags only when they change.
- Polling that only feeds a screen skips its tick while the app is not active (`AppActivity.isActive`).
- Repeating motion (an avatar's mood, a pulsing dot, a loading sweep, the typing dots) is a Core Animation layer (`LayerMotion`), never a SwiftUI `repeatForever` or `TimelineView`: each SwiftUI animation frame updates the whole window's graph, about 5 ms a frame at rest for the sidebar's avatars. A layer view stays while it scrolls away; only its animation stops.
- A window's content root is `.windowRoot(minWidth:minHeight:)`, never `.frame(minWidth:minHeight:)`: the hosting view asks the content for its smallest and largest size at every layout, and a frame passed that down every row of every list (30 % of the main thread while scrolling the Services page).
- No gradient strokes or fills on repeated elements (message bubbles, cards, rows): SwiftUI paints them with the processor over the whole element, which doubled what a message cost. Solid hairlines; a gradient only on a single surface. A full-window gradient is a `CAGradientLayer` (the main area's backdrop).
- Each agent's thread is observed on its own (`ServerModel.threads`, one `AgentThreadState` per agent). Views that show status, a running turn, waiting approvals, forms or the preview read `threadSummary(for:)`, whose fields change only with their values; only the rows (`ThreadRowsScope`) and `ThreadWatch` read the thread. A token used to rebuild the sidebar, the chat's header and the composer, for every agent's stream.
- A row that shows a few facts of a changing model is built from an `Equatable` key (`Memo`, `SidebarThreadFacts`): the reader may run at every change, the row only when what it shows changed.
- The composer's text is read only by its field (`ComposerTextField`); the composer reads `DraftFacts` (has text, command, `/word`, `@word`), written on change. Each letter used to rebuild the whole composer. Clipboard checks in a body are cached by `changeCount` and check types, not data.
- A streaming message parses only its last paragraph (`MessageRenderCache.streamingMessage`), and a stream replaces only its own row (`ThreadRows.replacingLast`): re-parsing the whole reply at every token grew with every word.
- Sorting and filtering in a body compute their keys once (`sortedAgents`), not inside the comparator.
- A preference read over the whole window (tour anchors) is read only while it is needed (`TourOverlay`).
- Lists of rows of one height are lazy (team sidebar, files sidebar, ⌘K palette); staggered entrances stop after the first rows (`SidebarRise`). `ViewThatFits` builds every candidate: try only the parts that differ (words), never a whole toolbar or anything with an avatar in it.
- A horizontal `ScrollView` per element is expensive (code blocks): only where the content needs it (`CodeBlockLayout`).
- `ViewThatFits` measures all its candidates again at every layout of the window: a header or a toolbar with a field
  and menus in its candidates cost 100–200 ms at each change of the page under it. Use `FirstFit` (candidates measured
  once out of sight, the choice from their widths) or a rule over measured widths (`MarketHeaderFit`).
- A page's header that does not change with the page is an `Equatable` view of its own (`MarketHeader`), and a search
  text lives in a reference that only the field and the results read (`MarketSearch`): a category or a letter rebuilt
  and measured the header with the page.
- An agent switch needs the chosen agent only: `TeamSelection.shownAgentID` does not sort the team when the chosen one
  is there (the sort read every agent's state).
- Measure with the smoothness check: Help → ⌥ Smoothness check… (release builds too) runs every page on demo daemons (`DemoDaemonTransport`, `PerfDemoWorld`) in a window of its own and shows the table. In a QA copy, `perf <scenario>` runs one page in that window and `perf check` all of them (`PerfScenarios.swift`; JSON in `~/.cache/bandito-qa/`: frames, the main thread's work and processor time per frame, stretches over 100 ms, `bodies` in debug builds, a verdict per page and part). A build for speed: `BANDITO_XCODE_EXTRA="SWIFT_OPTIMIZATION_LEVEL=-O" scripts/build.sh`. Hangs of the main thread of 250 ms or more are logged by `HangMonitor` (`dev.bandito` / `perf`) and counted as `perf.hang.<screen>`. An AppKit sheet slides in a run loop of its own: the monitor counts the slide as busy.

## Decoding replies

`RPCClient.decoder` uses `convertFromSnakeCase`. `CodingKeys` must be plain camelCase (`case imageRev`), never a raw
snake value (`case imageRev = "image_rev"` silently never matches). Test a wire type with `RPCClient.decoder`.

## Daemon features

Check a capability with `server.supports("<feature>")` before calling a newer RPC, so the app keeps working with an
older daemon. Feature names are listed in `daemon.info` (`docs/ARCHITECTURE.md`).
