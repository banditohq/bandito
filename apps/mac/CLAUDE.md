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
  The release is universal (arm64 + x86_64, macOS 14+): `release-app.sh` checks every Mach-O file for both slices; locally, `rustup target add x86_64-apple-darwin`, then `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` on the xcodebuild line, and `lipo -archs` on `Contents/MacOS/Bandito` and `Contents/Helpers/bandito`.
- After building: `git checkout -- apps/mac/BanditoKit/Package.resolved`.
- Tests never show a window on the screen of whoever runs them (the person's Mac): no `orderFront`,
  `makeKeyAndOrderFront`, `showWindow` or `activate`. A test that needs a window makes it borderless, off every screen
  (origin −20000), with `alphaValue = 0` and `ignoresMouseEvents`, and draws through `cacheDisplay` or `ImageRenderer`.
  A measurement that needs a window on a screen (frames, a display link) runs only in the QA VM, never on the host.
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

The bar: 120 fps on a 120 Hz Mac (each frame's work under 8.3 ms), never under 60, no stretch over 50 ms while
scrolling, typing or streaming, none over 100 ms anywhere. It holds for new work too. Before a new page, panel, sheet,
list or animation is done:
1. Build it from the fast parts that exist: `ThreadList`/`NativeRow` for chat-like lists, lazy stacks or an AppKit
   table for long lists, `FirstFit` instead of `ViewThatFits` in headers and toolbars, `LayerMotion` for repeating
   motion, `Equatable` rows
   keyed by the facts they show, state written only on change, heavy work (parsing, sizing, images) off the main thread.
2. Add a scenario (or a part) for it to the smoothness check (`Perf/PerfScenarios.swift`) on the demo daemons, and a
   work budget to `WorkBudgetTests`: a new screen gets its counters (`PerfCounters.hit` in its bodies and AppKit
   cells) and a step with budgets, so a change that makes it rebuild more fails `swift test` before it is merged.
3. Run it in a speed build (`-O`) in the QA VM and compare with the page next to it; a page under the bar is not done.
4. A new lag you find and fix becomes a rule below, with the number it cost.

- Never write `@State`/model state from `onScrollGeometryChange`, `onGeometryChange`, hover or a timer unless the
  value changed (compare first). One write per frame re-renders the whole subtree.
- The chat thread is an AppKit table (`ThreadList`, `NSTableView` with reused cells), not a SwiftUI stack: a stack laid
  out its whole window of rows at each scroll step, and `LazyVStack` looped on its estimates and hover (100% CPU). Each
  cell hosts the same SwiftUI row (`EquatableThreadRow`, keyed by `ThreadRowKey`), so bubbles, selection, menus,
  reactions and VoiceOver are the SwiftUI ones. A row is measured once per width (`ThreadListCell.height`), guessed
  (`ThreadHeightGuess`, once per line) until then; rows above the screen that change height move the offset with them.
  The lines are kept between updates (`ThreadListMemo`, handed over in a versioned box): a token makes and reconfigures
  the streamed line only. A thread just opened makes only the rows that show (`ThreadTableView.prepareOnlyVisible`). The lists of the last four agents are kept (`ThreadListHost`): going back to one shows it at once, where it was. Only the list on screen follows the width; a kept one takes it when it comes back (each of the four measured its rows again at a panel toggle).
  Message bodies are parsed once (`MessageRenderCache`).
- The frequent rows are AppKit, not SwiftUI (`NativeRow`: a plain message of the person or the agent, a stream, a
  day, a note, a folded finished tool group): text views over a layer of the bubble's own SwiftUI shape, measured off
  the main thread (`NativeSizeCache.prefetch`), one shared bar of actions for the hovered message and a faint one for
  the agent's last (`NativeActionsBar`). A SwiftUI row in its own hosting view cost 5–8 ms to make without a GPU.
  They must look as the SwiftUI rows do: `NativeRowLookTests` draws both and compares the pixels. Rows with more than a
  bubble (a quote, files, mentions, reactions, a web link, a running or opened tool group, a row rising in) stay SwiftUI.
- Live pictures (browser screencast) go to a `CALayer` (`BrowserFrameLayer`), never through `@Observable` per frame.
  Decode images off the main thread.
- No shadows, blurs or materials on every row of a long list; use them on hover or on single surfaces.
- A scroll step of a SwiftUI stack costs about 0.08 ms for every row that exists in it, built or not on screen: a long
  list is lazy or an AppKit table.
- Never pass a `Binding(get:set:)` that reads an `@Observable` into a child (`Composer` used to take one from `ThreadView`): the parent reads it while it builds the child, so each typed letter rebuilt the whole thread. The child reads and writes the model itself.
- Per-row work that repeats on every redraw (regex, `DateFormatter`, `ByteCountFormatter`, `NSRegularExpression(pattern:)`) is made once and kept (`PlainLineCache`, `DateFormatterCache`, static regexes in `ChatLinks`).
- A view that reads `server.thread(for:)` is rebuilt at every streamed token: read it in the row (`ThreadReader`), not in the list that holds the rows.
- A Marketplace shelf is a horizontal `ScrollView` with a `LazyHStack`: every card has one fixed width and the shelf one fixed height (a lazy row cannot ask unbuilt cards how tall they are), cards are `Equatable`, and the shelves sit in a plain `VStack` (a lazy stack of shelves moved heights while scrolling and spiked). The place of a row for its arrows comes from its `NSScrollView` (`onScrollGeometryChange` and `ScrollPosition` need macOS 15, the app runs on 14) into a model that writes its flags only when they change. The first four shelves of a page are built with it, each one below a frame later (`MarketShelfReveal`, a space of its height until then): all the shelves in the first frame cost 170 ms for Bots without a GPU.
- Polling that only feeds a screen skips its tick while the app is not active (`AppActivity.isActive`).
- Repeating motion (an avatar's mood, a pulsing dot, a loading sweep, the typing dots) is a Core Animation layer (`LayerMotion`), never a SwiftUI `repeatForever` or `TimelineView`: each SwiftUI animation frame updates the whole window's graph, about 5 ms a frame at rest for the sidebar's avatars. A layer view stays while it scrolls away; only its animation stops.
- A window's content root is `.windowRoot(minWidth:minHeight:)`, never `.frame(minWidth:minHeight:)`: the hosting view asks the content for its smallest and largest size at every layout, and a frame passed that down every row of every list (30 % of the main thread while scrolling the Services page).
- No gradient strokes or fills on repeated elements (message bubbles, cards, rows): SwiftUI paints them with the processor over the whole element, which doubled what a message cost. Solid hairlines; a gradient only on a single surface. A full-window gradient is a `CAGradientLayer` (the main area's backdrop).
- Each agent's thread is observed on its own (`ServerModel.threads`, one `AgentThreadState` per agent). Views that show status, a running turn, waiting approvals, forms or the preview read `threadSummary(for:)`, whose fields change only with their values; only the rows (`ThreadRowsScope`) and `ThreadWatch` read the thread. A token used to rebuild the sidebar, the chat's header and the composer, for every agent's stream.
- The preview of a streaming reply (`AgentThreadState.lastMessageHead`) is written at most once per `streamPreviewInterval` (300 ms), the settled message at once: the team list's rows were rebuilt at every token of a reply's first 240 characters (36 times in 100 pieces).
- A row that shows a few facts of a changing model is built from an `Equatable` key (`Memo`, `SidebarThreadFacts`): the reader may run at every change, the row only when what it shows changed.
- The composer's text is read only by its field (`ComposerTextField`); the composer reads `DraftFacts` (has text, command, `/word`, `@word`), written on change. Each letter used to rebuild the whole composer. Clipboard checks in a body are cached by `changeCount` and check types, not data.
- A streaming message parses only its last paragraph (`MessageRenderCache.streamingMessage`), and a stream replaces only its own row (`ThreadRows.replacingLast`): re-parsing the whole reply at every token grew with every word.
- Sorting and filtering in a body compute their keys once (`sortedAgents`), not inside the comparator.
- A preference read over the whole window (tour anchors) is read only while it is needed (`TourOverlay`).
- Lists of rows of one height are lazy (team sidebar, files sidebar, ⌘K palette); staggered entrances stop after the first rows (`SidebarRise`). `ViewThatFits` builds every candidate: try only the parts that differ (words), never a whole toolbar or anything with an avatar in it.
- A horizontal `ScrollView` per element is expensive (code blocks): only where the content needs it (`CodeBlockLayout`).
- `ViewThatFits` measures all its candidates again at every layout of the window: a header or a toolbar with a field
  and menus in its candidates cost 100–200 ms at each change of the page under it. Use `FirstFit` (candidates measured
  once out of sight, the choice from their widths) or a rule over measured widths (`MarketHeaderFit`). Only for a
  header or a toolbar: in a row that is made often (action rows, settings rows, card feet) `FirstFit` builds its
  candidates twice in its first frame and made pages open slower (a settings page 65 → 108 ms); rows keep a small
  `ViewThatFits` of the words, or a `Layout` that makes the same choice over one copy of each view
  (`SettingsRowLayout`, the same pixels in the layout audit; a server's settings page 59 → 45 ms). A toolbar made
  again at each visit gives `FirstFit` a `memory` key (and `persists` for the first visit after a launch): the widths
  are kept (`FirstFitMemory`), nothing is measured again, and the first frame builds the remembered choice only, checked
  against the width as soon as it is known (Files 87 → 59 ms a visit). A picture made in one pass (audit, snapshot)
  turns that off (`firstFitRememberedFirst`): it has no second frame to correct a choice made for another width. A `ViewThatFits` next to a `Spacer` in an `HStack` (the Journal's header) still costs about
  40 ms a layout; replacing it changes where it switches, so it waits for a decision.
- A page's header that does not change with the page is an `Equatable` view of its own (`MarketHeader`), and a search
  text lives in a reference that only the field and the results read (`MarketSearch`): a category or a letter rebuilt
  and measured the header with the page.
- Team mode and its sidebar stay built under the other modes, for the last two servers (`KeptMode`,
  `Router.teamServers`): building them again cost 70–130 ms at each return. Kept out of sight they are faded, disabled
  (no shortcuts, no focus), out of hit testing, VoiceOver and the tour; AppKit views in them are hidden by hand (a fade
  leaves pointer shapes and hover live: `ThreadList.hidden`); they read none of the router's choices (`TeamModeShown`),
  or a home opened or an agent chosen elsewhere rebuilds them unseen; the composer gives up the focus and takes it back.
  A chat with its workbench panel open is not kept (a terminal or a browser would go on running). The chat stays built
  under the team home too. Other modes are made at each visit: they hold live views (terminals, the screen, the
  browser) or poll.
- The Marketplace's Bots and Skills pages stay built under the page in front once shown, and are built ahead a moment
  after the Marketplace opens, their shelves one a frame (`MarketView.keptPage`, `marketShelvesAhead`): the first
  switch to Bots built the whole page in the frame of the click (140 ms). A kept page is an `Equatable` view of what it
  shows (`KeptMarketPage`) and reads no search while hidden: otherwise a category opened on Services rebuilt both pages
  and every shelf in them.
- A popover's open state belongs to the view that shows it (`OpenableMetricTile`): one `@State` in the Server overview
  rebuilt the passport, the banners and every card in the frame the popover opened.
- First-use costs that no click should pay (Swift Charts' first chart) are paid once, offscreen, when nobody has
  touched the Mac for a second shortly after launch (`IdleWarmup`); the smoothness check runs what is left before it
  measures.
- A side list that reads things from the server at each visit starts from what the last visit read (`FilesSidebarExtras`)
  and writes a value only when it changed: the places and the disk came in one by one, each a new layout.
- A symbol drawn tinted in an AppKit row is made once (`NativeSymbols`), not tinted at each draw.
- An agent switch needs the chosen agent only: `TeamSelection.shownAgentID` does not sort the team when the chosen one
  is there (the sort read every agent's state).
- `WorkBudgetTests` (in `swift test`, so in CI) counts work, never time: bodies evaluated, the thread's cells made,
  reconfigured and measured, width changes, for one step of the main screens (scroll the thread, type 20 letters,
  stream 100 pieces, switch agents and back, open and close the agent's panel, open Marketplace categories) on the demo
  world in a window nobody sees (`WorkBudgetHarness`). A budget is today's count with a little room; a failure names
  the counter, the step and where to look, and `WORK_BUDGET_PRINT=1` prints every count. A step starts when the window is at rest and ends when its own late work is done (`WorkBudgetHarness.quiet`/`rest`: steps with nothing counted, twice around a 0.4 s wait), so a slow runner does not move one step's work into the next. Counts that depend on frames
  (rows reconfigured during an animation) are left out. Tests that draw thread rows or the main window sit in
  `ScreenWorkSuites` (run one after the other: the counters are global).
- Measure with the smoothness check: Help → ⌥ Smoothness check… (release builds too) runs every page on demo daemons (`DemoDaemonTransport`, `PerfDemoWorld`) in a window of its own and shows the table. In a QA copy, `perf <scenario>` runs one page in that window and `perf check` all of them (`PerfScenarios.swift`; JSON in `~/.cache/bandito-qa/`: frames, the main thread's work and processor time per frame, stretches over 100 ms, `bodies` in debug builds, a verdict per page and part). A build for speed: `BANDITO_XCODE_EXTRA="SWIFT_OPTIMIZATION_LEVEL=-O" scripts/build.sh`. On anyone's Mac without touching their Bandito: `scripts/perf-build.sh` makes "Bandito Perf" (Release, its own id `dev.bandito.mac.perf`, ad hoc, no daemon), and `"Bandito Perf.app/Contents/MacOS/Bandito" --perf-check` runs only the check (`PerfStandalone`: no saved servers, pairing, Keychain, account, statistics or updates) and saves the JSON in `~/Library/Application Support/dev.bandito.mac.perf/`. A build setting on the `xcodebuild` command line reaches every target: never pass the bundle id there (resource bundles with the app's id lose their colours). Hangs of the main thread of 250 ms or more are logged by `HangMonitor` (`dev.bandito` / `perf`) and counted as `perf.hang.<screen>`. An AppKit sheet slides in a run loop of its own that no observer sees: in a stretch where a sheet came or went, only the main thread's processor time counts as work (`SheetSlideRule`), and the slide's gap is counted apart (`sheetSlides`), not as a late frame. A frame can come right after the slide, before the stretch ends: the stretch in progress already counts as a slide then (`SheetSlideRule.part`); the sheets' 345–395 ms "frames" were that. Each part of the JSON lists its frames over 50 ms (`longFrames`: gap, work, processor time, slide).

## Decoding replies

`RPCClient.decoder` uses `convertFromSnakeCase`. `CodingKeys` must be plain camelCase (`case imageRev`), never a raw
snake value (`case imageRev = "image_rev"` silently never matches). Test a wire type with `RPCClient.decoder`.

## Daemon features

Check a capability with `server.supports("<feature>")` before calling a newer RPC, so the app keeps working with an
older daemon. Feature names are listed in `daemon.info` (`docs/ARCHITECTURE.md`).
