# Bandito design language

How the app looks and moves. This is the written twin of the **Design System** artifact (tokens, brand book, a live preview of every component): <https://claude.ai/artifact/CvD6mX6c7pwQtiMroCungY>. The two always agree. When a design change is approved, change this file, the artifact and the code in the same change.

Sources of truth in the repo: `brand/tokens/tokens.json` (generates `apps/mac/BanditoKit/Sources/BanditoDesign/*`), `brand/BRAND.md`, `brand/logo/`, `brand/icons/`, and the components in `apps/mac/BanditoKit/Sources/BanditoUI/Components/`.

## Principles

1. **Warm dark.** Ground `bg`, text `text`, hairlines instead of boxes. Light is a twin with the same token names.
2. **Cream is the accent you see most.** The primary button is a cream capsule (`text` fill, `bg` label) with a small orange dot. A selected state is a cream border, not an orange fill.
3. **Orange means you.** `signal` appears only where a person is needed: the needs-you status dot and glow, a section label that waits for the person, the keyboard focus ring, accent text. Never a button fill.
4. **Three faces.** Unbounded is the brand's voice (titles, big numbers, names, labels, the primary button), Onest is everything a person reads, JetBrains Mono is machine text (code, paths, commands, ids, keys). See Typography.
5. **The raccoon is the one mascot.** Avatars and empty states. No stock illustrations.
6. **Quiet.** Fills and hairlines. A shadow means "this floats" (composer, a hovered clickable card, a popover), never on rows of a list.

## Tokens

Use `Color.Bandito.*`, `BanditoSpace.*`, `BanditoRadius.*`, `BanditoType.*`, `BanditoMotion.*`. Never a literal hex in a view (the avatar and status colors live in `Components/Palette.swift`).

| Token | Dark | Light | Use |
| --- | --- | --- | --- |
| `bg` | `#12100E` | `#F6F1E8` | Window ground; label on the cream button |
| `surface1` / `2` / `3` | `#1A1714` / `#221E1A` / `#2C2722` | `#FFFDF9` / `#EFE8DC` / `#E6DDCE` | Cards and agent bubbles / inputs, composer, panels / raised cell, disabled fill |
| `line`, `lineStrong` | `text` 8% / 14% | ink 10% / 18% | Hairlines |
| `text`, `text2`, `text3` | `#F3EBDD` / `#BDB2A0` / `#867C6D` | `#1C1916` / `#5B544A` / `#736B5F` | Primary (and cream fill) / secondary / captions, placeholders |
| `signal` | `#FF8A1F` | `#E0670C` | Needs-you dot, focus ring, accent text |
| `signalGlow` | `#FFB067` | `#FF8A1F` | Focus glow, warning tone |
| `signalFill` | `#E4620E` | `#E4620E` | The dot in the cream button, radio ring, toggle track |
| `onSignal` | `#FFFFFF` | `#FFFFFF` | Knob and radio center on `signalFill` |
| `ok` / `info` / `danger` | `#A9C7A2` / `#A3BDEB` / `#F2A093` | `#457040` / `#41609E` / `#B4432F` | Working, scheduled, deny and error |

Translucent overlays are `Color.Bandito.text.opacity(x)` so they flip with the theme. The alphas in use: 3% icon-button fill, 4% mode-cell hover, 5% row hover and segmented track, 6% quiet fill and card highlight, 7% highlighted option, 8% hairline, 8% card border (solid: a gradient stroke is painted by the processor and doubled the cost of a card in a list), 12% quiet border, chip tint and ring track, 13% person bubble, 14% key hint border, 30% focused field border, 45% selected card border. Do not add new ones.

Space is a 4 pt scale (`BanditoSpace`: 4 8 12 16 20 24 32 40 48 64). Brand radii: 8, 12, 18, 24, pill. The components ship these off-scale radii and keep them: key hint 5, chip 6, icon button and raised cells 9, field 10, card 14, bubble 16 (tail 6). Corners are `.continuous`.

Motion (`BanditoMotion`): fast 0.12 s, base 0.2 s, slow 0.32 s, ease `(0.2, 0.8, 0.2, 1)`.

## Typography

Three families, all SIL OFL, bundled as variable TTFs in `apps/mac/BanditoKit/Sources/BanditoDesign/Fonts/` (each with its `OFL.txt`) and registered for the process by `BanditoFont.registerBundledFonts()` (called at app start; the first use registers them too). The weight is the `wght` axis, so any weight in the font's range is exact (Unbounded 200-900, Onest 100-900, JetBrains Mono 100-800).

| Role | Family | API | Use |
| --- | --- | --- | --- |
| `display` | Unbounded | `BanditoFont.display(size:weight:)` | Page and sheet titles, big metric numbers and usage percents, agent names (list, chat header, menu bar), template titles, `SectionLabel`, the text of `.signal` and `.lightPill` buttons, avatar initials |
| `text` | Onest | `BanditoFont.text(size:weight:)` | Everything else: messages, descriptions, fields, menus, settings, hints, chips, captions |
| `mono` | JetBrains Mono | `BanditoFont.mono(size:weight:)` | Code in messages, paths, commands, ids, keys, monospaced fields, the terminal and the file editor (`appKitMono`, `appKitTerminalMono`) |

Rules:

- Always go through these functions (or `Font.bandito(_:)`); never `.font(.system(...))` for text. `.system` stays only for SF Symbols. `BanditoFont.font(size:weight:mono:)` is the helper for a role chosen at run time. Text with no explicit font gets Onest 13 from the scene root.
- Unbounded is wide: where it replaces a text face the size drops about 8% (page titles 26 to 24, big numbers 26 to 24, names 14 to 13.5 or 13 to 12.5, section label 11 to 10.5 with 0.6 pt tracking, button label 13.5 to 12.5 and 15 to 14). A single-line display text carries `.lineLimit(1)` and `.truncationMode(.tail)` (or `minimumScaleFactor` for numbers) so a long name or a translation is cut with an ellipsis and never breaks the layout. Titles that may wrap (onboarding) wrap.
- Chinese, Japanese and Korean: Onest and Unbounded have no CJK glyphs, CoreText substitutes the system font for those characters (tested with "设置 設定 설정").
- Terminal: pass the plain named font (`appKitTerminalMono`); SwiftTerm derives bold with `NSFontManager`, which works from the named instance but not from a font built on a variation.

Scale (`BanditoType`, tokens in `brand/tokens`): display 80/700, title 44/700, heading 22/600, body 15/400, small 13/500, mono 13/400, label 11/500. Sizes the app actually uses: button 13.5 (large 15; the `.signal` and `.lightPill` label is x0.92), field 13.5, message and composer 14.5, empty-state title 16.5 display, caption 12, option title 13, option subtitle 11.5, chip 11, section label 10.5/600 display with 0.6 pt tracking, key hint 10.5 mono, sheet title 15.5 to 18.5 display, page title 24 display, onboarding title 35 display.

## Components

Build only from these. Need something that is not here: add it to the system first (this file and the artifact), then build.

| Need | Use | Where |
| --- | --- | --- |
| Any button | `.banditoButton(.signal() / .quiet() / .lightPill() / .icon(label:) / .row() / .link / .brighten)` | `Components/Buttons.swift`, `Interaction.swift` |
| Bottom row of buttons in a sheet or dialog (a row that turns into a column when it does not fit) | `ActionRow` | `Components/ActionRow.swift` |
| Card or option surface | `.banditoCard(selected:hoverLift:)` | `Components/Card.swift` |
| Text input | `.banditoField(error:)`, `.banditoEditor(error:)` | `Components/BanditoField.swift` |
| Choose one of many | `BanditoSelect` (`.field`, `.compact`, `.regular`) | `Components/BanditoSelect.swift` |
| Choose one with an explanation | `RadioRow` | `Components/RadioRow.swift` |
| Two to five views of the same content (the Marketplace pages: Services, Bots, Skills) | `SegmentedPicker` | `Components/SegmentedPicker.swift` |
| Tile of a Marketplace entry (service, bot, skill) | `MarketTileSurface`, `MarketTile`, `BotTile`, `SkillTile`, `ServiceMiniLogo` | `Market/MarketView.swift`, `Market/BotViews.swift`, `Market/SkillViews.swift` |
| A row of Marketplace cards under a header (symbol, name, number, All), and the page that All opens | `MarketShelfView` (`MarketShelfHeader`, `MarketShelfLane`, `MarketShelfArrows`), `MarketPageHeader` | `Market/MarketShelfViews.swift` |
| Modal page inside the Marketplace (a bot, a skill, their create and install sheets) | `MarketPanel`, `MarketPanelFooter` | `Market/MarketPanel.swift` |
| On/off setting | `Toggle` + `BanditoToggleStyle` | `Components/BanditoToggleStyle.swift` |
| Empty pane | `EmptyState` | `Components/EmptyState.swift` |
| Group heading | `SectionLabel` (`.muted`, `.signal`) | `Components/SectionLabel.swift` |
| Role or state word | `Chip` (neutral, signal, ok, info, danger, warning) | `Components/Chip.swift` |
| Agent state | `StatusDot` | `Components/StatusDot.swift` |
| Unread replies | `UnreadBadge`, `UnreadDot` (team list) | `Team/UnreadBadge.swift` |
| Quota left | `UsageBar` | `Components/UsageBar.swift` |
| Context window fill | `ContextRing` | `Components/ContextRing.swift` |
| Shortcut hint | `KeyHint` | `Components/KeyHint.swift` |
| Mode switch | `ModeBar` | `Shell/ModeBar.swift` |
| App update (new version, progress, result) | `UpdateBanner` in `UpdateBannerSlot`, above `SidebarFooter` | `Shell/UpdateBanner.swift` |
| Chat bubbles | `BubbleLook`, `UserBubble`, `AgentBubble` | `Team/ThreadRowViews.swift` |
| Chat input | `Composer` | `Team/Composer.swift` |
| Back to the newest message | `ThreadJumpOverlay`, `ThreadJumpButton` (rules: `ThreadJumpRules`, `ThreadFollowRules`) | `Team/ThreadJumpButton.swift`, `Team/ThreadJumpRules.swift` |
| Menu above the composer (`/`, `@`) | `.composerMenuSurface()`, `ComposerMenuGroupTitle`, `.composerMenuRow(selected:)`, `ComposerMenuFooter` | `Team/ComposerMenuChrome.swift` |
| Mention of a service, teammate, file or tab | `MentionChip`, `MentionIcon` | `Team/MentionChips.swift`, `Team/MentionMenu.swift` |
| Agent identity | `RaccoonAvatar`, `AgentAvatar`, `AvatarArtView` | `Components/RaccoonAvatar.swift`, `Avatar/`; the raccoon's shapes and colors in `BanditoDesign/RaccoonShape.swift` (shared with iPhone) |
| Animation | `.banditoAnimation`, `.banditoRise` | `Components/Motion.swift`, `RiseIn.swift` |
| Hover fill for a gesture row | `.rowHighlight()` | `Components/Interaction.swift` |
| Focus ring on a custom control | `.brandFocusRing(shape:)` | `Components/Interaction.swift` |
| Recording indicator (dictation) | `dictationButton` in the composer | `Team/Composer.swift` |

### Look of each (exact values)

- **Signal button**: cream capsule `text` fill, `bg` label 600, 7 pt `signalFill` dot with a 13 pt halo at 18%, gap 8 (large 10). Height 38 / large 46, padding 18 / 22, label 13.5 / 15. Hover: brightness +6% and a soft cream shadow. Disabled: `surface3` capsule, `text3` label and dot. One per view. `compact` (30 high, label 12.5, padding 14) is for a button inside a small card; `.quiet(size: .compact)` is its twin. `fillsWidth: true` stretches the capsule to the width on offer (a narrow panel's main action, label centred).
- **Quiet**: `text` 6% fill (10% hover), 1 pt `text` 12% border (22% hover), label 500. `tone: .danger` is for a destructive action (roll back, delete): label and border in `danger`, the same fill and border steps. **LightPill**: cream fill, `bg` label 600, brightness +8% on hover. **Icon**: 30 pt, radius 9, 3% fill and 8% border (8% and 14% hover), icon `text2` then `text`. **Row**: 5% fill on hover, radius 8. **Link**: underline on hover. **Brighten**: label brightens 7%.
- **All buttons**: hover fades in 0.12 s; press scales to 0.97; disabled is 40% opacity with no hover; keyboard focus is a 2 pt `signal` ring with a `signalGlow` glow along the shape, shown only after Tab or arrows (`FocusModeTracker`).
- **Card**: radius 14, `surface1`, 1 pt border gradient `text` 9% to 4% top to bottom, a 1 pt `text` 6% line inside the top edge. Selected: `signal` 8% tint and a `text` 45% border. `hoverLift`: up 1.5 pt with `black` 35% shadow (0 8 14) only while hovered, spring (0.25, 0.85).
- **Field**: radius 10, min height 36, padding 12 x 9, 13.5 text, `surface2`, 1 pt border `text` 8%; focus: border `text` 30% and a `signal` 8% glow (radius 8); error: `danger` 60% border, no glow.
- **EmptyState**: padding 28; mascot 72 pt peach on a 180 pt `signal` glow (26% to 0), visual 120 pt high; title 18/600; message 13.5 `text2`, 360 max; one `.signal` action 16 below. Fades in from 96% on a spring (0.42, 0.82); mascot floats 3 pt, 1.6 s each way.
- **Changes panel** (workbench tab): the header is two lines. First: avatar, "Changes" (display 15/600) and the agent's name (display 15/600 `text2`), the layout switch on the right. Second, quiet: the stats "N files · +X −Y" then the task in 12 `text3`; only the task is cut, the whole task on hover. The timeline dots are cream; the current one has a `signal` dot in its centre; every point has a tooltip with its full label. The footer is one row from 680 pt; narrower, the main button ("Keep N files") is full width on top and "Roll back all" and "Ask agent" sit side by side under it, stacked only when they do not fit. The quiet buttons take the short labels; the agent's name is in the tooltip of "Ask agent". Diffs are mono.
- **Chip**: 11/500, padding 7 x 2, radius 6, tone color on itself at 12% (neutral `text2` on `text` 7%).
- **StatusDot**: 11 pt; idle `BanditoPalette.idle`, working `ok` + glow, needsYou `signal` + glow + pulsing ring (size+4 to size+14, 1.8 s), error `danger`, offline idle at 40%.
- **Unread badge** (team list): a capsule 16 high, `text` (cream) fill with `bg` digits 10.5/600, "99+" above 99, next to the time; a pinned avatar gets a 9 pt `text` dot with a 2 pt `surface1` ring. The name goes 700 and the preview 500 in `text2` while it is above 0. Accent is cream, not `signal`: `signal` stays for "needs you". Shown only from the thread summary, written on change.
- **SegmentedPicker**: track radius 12, padding 3, gap 2, `text` 5%; segment 30 high, radius 9, 12.5 text; selected `surface3` raised with a 1 pt shadow.
- **Marketplace tile**: a rounded square (corner size x 0.28) in one colour, a vertical gradient (white 24% on top to black 14% at the bottom), a 1 pt highlight border (white 45% to 4%), a white symbol or letter with a 0.5 pt shadow; `glow` adds a soft shadow of its colour. Colours: a service's brand colour, a bot's `accent`, a skill's first letter on peach, sky, sage, rose or lilac (cream is left out: white does not read on it). Cards are `MarketCardFrame` (surface1, radius 14, hairline; on hover the border brightens to `text` 22% and the card lifts 2 pt). A bot card has the SF Symbol on its accent tile and a row of 22 pt service logos (optional ones at 60%); a skill card carries the author and licence in 11 pt `text3` and a warning in `peach` 11.5.
- **Marketplace grid**: on a category's page and in a search, cards share the page width evenly (2 to 4 columns, a card at least 232 wide, gap 14, margin 30 at both sides, inside the scroll view so nothing is cut), a row is as tall as its tallest card (services: fixed 156), rows are lazy (`LazyVStack`). `MarketCardFrame` has a hairline border; only the hovered card gets the lighter border, a 1.5 pt lift and a shadow. The whole card is the click target that opens the page (`marketCardOpens`: content shape, button trait, accessibility action); the foot has one control, a `.lightPill` Connect at the left, or the state of a connected service (`MarketFootRow` stacks several controls when they do not fit). The description is two lines, then an ellipsis. Cards are `Equatable` on what they draw, not on their closures. Tiles are drawn once and kept as bitmaps (`MarketTileImages`).
- **Marketplace shelf** (the page under All, like a store): a quiet header over one row of cards, no colour, no band, no background. Shelves: Connected, then Suited to the project (when there are suggestions), then one per category; on Bots the sets then one per category; on Skills your own skills then one per category. `MarketShelfHeader` (30 high, margin 30): the category's SF Symbol (`MarketCategory.symbol`, 13 `text3`), the name in `display` 15/600 (one line, tail ellipsis), the number of cards 12.5/500 `text3`, and at the right an optional control (the 24 pt cross of the suggestions) and the `.link` "All" with a 10 pt chevron (13/500 `text2`; VoiceOver reads "Show all in <name>"). The row (`MarketShelfLane`) is a horizontal `ScrollView` with a `LazyHStack` (only the cards near the window are built), `scrollTargetBehavior(.viewAligned)` (it stops at a card), the page margin as a content margin (cards pass under the window's edge, not under the margin) and room for the hover lift and shadow inside its box (6 above, 22 below). Every card is 260 wide and has the shelf's fixed height (catalog 156, suggestion 156, set 176, bot 200, skill 204 with the warning kept to one line, connected: the tallest of its cards by `MarketShelfMetrics.connectedCardHeight`); a lazy row cannot ask unbuilt cards how tall they are. Shelves are stacked in a plain `VStack` (about eight shelves, each lazy sideways; a lazy stack of shelves only moved heights while scrolling), 8 apart. Arrows (`MarketShelfArrows`): two 34 pt discs (`surface3`, 1 pt `text` 14% border, `black` 35% shadow (0 3 6), a `.brighten` button with a `chevron.left` or `chevron.right` 13/600) at the ends of the row, 8 from the edge and at the cards' middle, shown while the pointer is over the shelf and only on the side with more to see; a press scrolls by one screenful of whole cards (`MarketShelfScroll.pageIndex`), on the curve (0.2, 0.8, 0.2, 1) in 0.4 s, none under Reduce Motion. The row's place is read from its `NSScrollView` (the SwiftUI scroll callback needs macOS 15) into a model that writes its two flags only when they change. A trackpad or a horizontal wheel scrolls a row; a vertical wheel scrolls the page.
- **Marketplace category page** (All on a shelf, or a sidebar row): `MarketPageHeader` above a grid. A `.link` Back with a 11 pt chevron (13/500 `text2`), 12 under it the symbol (16 `text3`), the name in `display` 20/600 (one line) and the number of cards (13/500 `text3`); 18 below, the grid of the previous bullet. Connected's page uses the full connected cards (row as tall as its tallest), the others the catalog cards. On Bots a page shows the category's sets (a `SectionLabel` Bundles) and then its bots; the sets have a page of their own (the Bundles shelf's All). A search narrows the open page; a search under All is one flat grid without shelves. The sidebar lights the open page's row (a category row carries its symbol, 11.5 `text3`, `text` when lit); All is the shelves. Opening or leaving a page starts the scroll view again at its top.
- **Suggestion card** (the "suited to the project" shelf): a `MarketCardFrame` 260 wide and 156 high like any card of a shelf, padding 12; a 28 pt tile and the name 13.5/600, the reason in 11.5 `text2` (two lines kept), the file that showed it in mono 10.5 `text3` middle-truncated, one `.quiet` Connect. The shelf's header carries the 24 pt cross (`.icon`) at the right. A connected service's "update available" line is 12/500 in `info` with the arrows symbol and a `.quiet` Update; a skill's Update is a `.lightPill` in the place of its Installed label.
- **Tools section** (the page of a connected service): a `SegmentedPicker` of three modes (Everything, With confirmation, Read only), a 12.5 `text2` line under it that says what the mode does, then the tools in rows split by hairlines: the name in mono 12.5/500, a `Chip` for what it does (reads `neutral`, changes `warning`, deletes `danger`), one line of its description in 11.5 `text3`, and a `SegmentedPicker` of Allow, Ask, Deny at the right. The controls are disabled while a change is saved. An approval card of a service shows the call's title, the arguments as the diff block, and the reason "this service asks before it changes something".
- **Schema form** (Try, in the Tools section): under a tool's row, a stack of fields built from its input schema. A field is a label (name in mono 12/500, a `Chip` `required`), the schema's words in 11.5 `text3`, the control, and a problem line in 12 `danger`. Controls: `.banditoField` for text, number and integer; `BanditoSelect` for a yes or no and for a list of values (first option Not set); a multi-line mono `.banditoField` (2 to 8 lines) for JSON. One `.lightPill` Run. The answer is a box on `bg`, radius 10, hairline (`danger` 60% when the tool says it failed), mono 12, scrolling above 220 pt; the structured part is a second box under it. A tool that changes data asks in a confirmation dialog first.
- **Journal row** (Journal section): a 24 pt avatar, the tool in mono 12.5/500, a line in 11.5 `text3` (agent, time, duration), the failure's first line in 11.5 `danger`; at the right a tick (`ok`) or a cross (`danger`) or "No result", and the policy's word in 11 `text3`. Rows are split by hairlines; "Show more" is a `.quiet` button. A card's use line ("12 calls in 24 hours · 1 error") is 12 `text3`.
- **Import row** (Import from Claude Code): a `CheckBoxRow` with the name, a `Chip` for where it came from (Claude Code, Project x, Codex), and a `.link` Preview at the right; the description in 12 `text3` and the warnings in 11.5 `peach` under it, indented 25 pt past the box. A name that is taken shows a `warning` `Chip`, a `SegmentedPicker` Rename or Skip, and, for Rename, a mono `.banditoField` with the new name and its problem line in `danger`. The preview is a box on `bg`, radius 10, hairline, mono 11.5. The report is three `SectionLabel` groups (Created with an `ok` tick, Skipped with a quiet minus, Failed with a `danger` cross), each line the name in mono, a kind `Chip` and the reason in 12.
- **Marketplace panel**: for a page that must open sheets of its own (connecting a service, signing in in the browser), which a system sheet cannot do from the window behind it. A black 50% scrim over the page, a card of width 500 to 580 on `surface2`, radius 18, border `text` 12%, shadow black 50% (0 14 30). Header: a 48 pt tile with the name in display 18 and a line under it; hairline; body (scrolls above 460 pt); hairline; footer with Cancel or Close as `.quiet` and one `.signal`. Esc and a click on the scrim close it, except while a create or an install runs.
- **RadioRow**: a card; 16 pt mark, selected = `onSignal` center in a 5 pt `signalFill` ring; title 13.5/600; description 12 `text3`; optional `ok` badge chip.
- **Toggle**: 36 x 21 capsule, on `signalFill` with `onSignal` knob, off `text` 14% with `text2` knob; the whole row toggles.
- **Select**: field 40 high, radius 12, `bg` fill, `line` border; compact 28, regular 38; panel `surface2`, radius 14, padding 8, options radius 9, highlight `text` 7%, a `signal` check on the chosen one, search above eight options.
- **UsageBar**: 6 pt capsule on `text` 8%; fill `text`, `signal` under 25%, `danger` at 0. **ContextRing**: 16 pt, stroke max(1.5, size x 0.11), `ok` then `signalGlow` above 80%. **KeyHint**: mono 10.5 `text3`, radius 5, 1 pt `text` 14% border.
- **Update banner** (sidebar, between the list and the footer): a card of radius 14 on `signal` 8% with a 1 pt `signal` 12% border, padding 12, inset 14 like the footer. A 28 pt round badge at the left (`signal` 12% fill; `arrow.down.circle.fill` in `signal`, `checkmark.circle.fill` in `ok`, `exclamationmark.triangle.fill` in `danger`, or a small spinner while the app waits), the title 13/600 `text`, a line 11.5 `text3` (two lines at most), a 24 pt cross (`.icon`) at the right. Phases: available ("Version X is available", "New features and fixes", a `.signal(size: .compact)` Update and a `.link` "What's new" to the release page), checking, downloading (a 4 pt bar, `text` on `text` 8%, with the whole percent at the right; without a share a short piece runs along it, still in the middle when motion is off), preparing, installing (no cross), up to date (goes away after 4 s), failed (the reason and a `.quiet(size: .compact)` Try again). It slides up and fades in on a spring (0.42, 0.86), only fades with Reduce Motion. No shadow, no blur. The share is written only when the whole percent changes.
- **ModeBar**: `surface1`, radius 12, padding 3, gradient hairline; cells 32 high, radius 9, icon 16; active cell `surface3` with a `text` 10% border and a soft shadow, sliding on a spring (0.32, 0.86).
- **Bubbles**: corners 16 with a 6 pt tail on the speaker's side; padding 14 x 10; text 14.5. Person: `surface2` + `text` 13% + `text` 8% border. Agent: `surface1` with a solid `text` 6% border (a fading border was painted by the processor and doubled what a message cost to show). No shadows. A person's message that still waits for its turn (the agent is busy or saving its memory) carries a quiet line under the bubble, right-aligned: `Queued`, 11.5 pt `text3`; it goes away when the turn takes the message. A message the daemon gave up on (crash, stop, restart) carries `Not delivered` in the same style, and its context menu offers Send again.
- **Reaction chip and reply quote** (iPhone chat; the Mac has its own): a reaction is a capsule 24 high under the bubble on the speaker's side (wrapping to a new line), the emoji and, when two sides reacted, a `person.2.fill` glyph; the person's own is `signal` 12% with a `signal` 30% border, another's `text` 5% with a `line` border. A reply's quote sits at the top of the bubble: a panel `text` 6% (corners 8) with a 3 pt `lineStrong` bar, the name 12/600 `text2` and at most two lines of the original 13/400 `text3`; above the message box the same quote is one row 44 high with a cross. The long-press menu lifts the bubble itself (its own shape, no background of the system's) and has a palette of the 16 quick reactions over the actions, the person's own marked.
- **System line** (a scheduled run, a quiet turn): not a bubble but one centred line 26 high in the thread's column: an SF Symbol 11/500 in a 13 pt column (`clock` for a run, `moon.zzz` for a quiet turn), 6 apart the text 12/400 and a `chevron.right` 9/600, all `text3` (a quiet turn at 70%: a step quieter than a note). A run reads "Scheduled run · name · today, 20:45" (the name cut at 32 characters; the time never gives way); a quiet turn "Nothing new · reason" (the reason cut at 48). A click opens it (the chevron turns down, a fade in base): a run shows its prompt in mono 11.5 `text3` on `text` 3% with 10 pt corners, a quiet turn its steps (its tool calls as tool groups, the text it wrote in 12 `text3`). Folded by default; brightens on hover. Folded it is a native row (`NativeSystemLineView`), drawn as the SwiftUI one (`NativeRowLookTests`).
- **Jump capsule** (back to the newest message): a capsule 34 high over the composer, centred, 10 above the thread's bottom edge. A down arrow (12/600 `text`); with messages that came in, a 6 pt `signal` dot and "3 new" (12.5/500 `text`, "99+ new" above 99). Fill: `ultraThinMaterial` under `surface2` at 82%, 1 pt `text` 12% border, `black` 35% shadow (0 6 10), only on this surface. A 64 pt fade from `bg` 0% to 90% sits under it so text never meets the capsule edge. It comes up 14 pt with a fade on a spring (0.34, 0.86) and goes with a fade; under Reduce Motion or Motion "Off" it only fades (0.12 s). After the person's own send the thread slides to the bottom (0.32 s, the base curve) and keeps following until the person scrolls up more than 64 pt; the capsule stays away and counts nothing meanwhile.
- **Composer**: radius 24, `surface2`, border `line` (`text` 18% in focus), `black` 35% shadow (0 10 18), a `signal` 10% glow in focus; 14.5 text; 34 pt cream send disc with a `bg` arrow (stop while running with an empty field; with text or files while running, a 28 pt `text` 12% disc with a `text` stop glyph sits beside it).
- **Menu above the composer** (`/` and `@`): max 640 wide, radius 18, `#201C18` at 98%, 1 pt `text` 12% border, `black` 50% shadow (0 14 30); group title 10.5/600 with 0.8 tracking in `text3`; row radius 10, padding 10 x 7, selected = `peach` 10% fill and 30% edge; footer 11.5 `text3` under a `text` 7% hairline.
- **Mention chip**: a capsule 26 high, `surface3`, 0.5 pt `line` border (dashed `peach` 60% while the service is not connected), 18 pt picture on the left (a service's Marketplace tile, an agent's avatar, a file glyph, the browser mark), label 12.5/500 `text`, 260 max, middle-truncated. In the composer it sits in a strip above the field with a 18 pt cross; in the thread it sits right-aligned under the bubble, wrapping to the right edge. A file chip opens the file in the workbench.
- **Workplace picker** (Browser and Terminals sidebars; the Screen's cards are its richer form): a section label, then a row for the shared server and each container, shown only when there is more than one. Row: radius 11, padding 6 x 2; a 26 pt tile (radius 8, `text` 6%) with `house` (shared) or `shippingbox` (container) in `text2` (`signal` when chosen), the name 13/500 (600 when chosen, two lines at most), a 6 pt state dot (`ok` running, `idle` stopped, `danger` Docker not answering) with the state 11.5 `text3`; the chosen row is `signal` 10%. A stopped container has a `.quiet()` "Start" at the right. A **workplace chip** (10.5/600 `info` on `info` 12% capsule) names the container a terminal or an agent runs in; the shared server gets none. **Screen card**: a 60 x 38 preview tile (last picture, dimmed while asleep), the name with the same icon, the screen's state, and a 8 pt dot at the right; an unavailable screen adds its explanation under the card in 11.5 `text2`. Rows and cards are `Equatable`; nothing but a change of what they show redraws them.
- **Avatar**: tile corner size x 17/52; fixed tile colors (peach, sky, sage, rose, lilac, cream) and mask `#12100E`; nine faces; six moods (idle, working, needsYou, thinking, error, sleeping) that rest under reduced motion.

**Recording indicator (dictation).** The microphone button next to "+" is `text2` at rest. While it listens the icon is
the filled mic in `signal` (cream-orange) with a 7 pt `signal` dot at its top right. The dot is static, no pulse: it
shows a state, it is not a motion. The dot is hidden from VoiceOver; the button's label reads "Stop dictation".

## The server screen's desktop

The desktop the daemon draws on a server's screen (`daemon/src/desktop/`, see ARCHITECTURE.md#screen) wears the same system, from the same tokens, but it is drawn by the daemon, so its colors are copied into `desktop/paint.rs` and `desktop/theme.rs`: when a token changes, change them there too. Ground: `bg` with a lit center and a dot grid of `text` at 22% that fades out, never a flat black; the lockup in `text`, the site in `mono` `text3`. The dock is `surface1` with a hairline on top; its pills are `text` at 5% with an 8% hairline (hover 11% and 16%), radius 10; the window that is up has a `text` border at 34%, as a selected card does. Orange stays out of it (nobody is needed on a desktop); who holds the controls is a sage dot for an agent and a cream dot for the person. Windows and menus (openbox theme `Bandito`) use `surface1` and `surface2` frames, `text` and `text3` labels, Onest. The words on it are English (the server has no interface language); keep them to one word.

## Motion

- Use `.banditoAnimation(_:value:)`, never `.animation(_:value:)`, and `.banditoRise` for list rows. They honour Reduce Motion and the app's Motion level (Full, Less at half duration, Off). An action that animates a change (a button, a drop) uses `withBanditoAnimation`, never `withAnimation`.
- The set (`BanditoMotion`, `brand/tokens/tokens.json`): the curve `ease` (0.2, 0.8, 0.2, 1) at `fast` 0.12 s (hover, a tab's content, ⌘K, a hint), `base` 0.2 s (a mode, the sidebar, a section that opens) or `slow` 0.32 s (a flash, an empty state); `slide`, a spring (response 0.36, damping 0.9), for a surface that moves in and out (the workbench panel). The update banner (0.42, 0.86) and the jump capsule (0.34, 0.86) keep their own springs.
- Everything that comes also goes: a panel, a toast, a capsule, ⌘K, a hint, a tab's content leave the way they came (a slide out, a fade), on the same curve. A view that leaves a `ZStack` keeps its place in the order (`zIndex`), or it slides out under its neighbour and seems to vanish. Only transform and opacity move; a width or a height is set at once.
- Tabs and sections (the agent's panel, Settings, the Marketplace's pages) fade into each other in `fast`, both in one place.
- **Workbench panel**: it slides in from the right on a spring (0.36, 0.9) at a fixed width, only its position moves, no fade. The chat beside it changes its width once, at the first frame, never frame by frame: each bubble re-wraps its text on a width change, so an animated width re-laid out the whole thread on every frame.
- Repeating motion (pulse, float, blink, sparkline) runs only at Full and only in the active window.
- Durations are fast, base or slow. No new curves.
- `RiseIn` goes on list rows only, never on the cards inside them.

## Copy

Short, direct, human. Sentence case, verbs on buttons ("Create agent", "Approve", "Not now"), no exclamation marks, no "Oops". Say what happened and what to do next. Machine text is mono. Call an agent by its name, not "the AI". Every string goes through i18n in all 9 languages (`i18n/*.json`, `L10n.*`).

## Accessibility

Text is 4.5:1 or better (`text3` is the floor, 4.6:1 on `bg`); focus rings and meaningful borders 3:1. Status is never color alone (a word or shape too). Icon-only buttons carry a label (`.icon(label:)` gives both the tooltip and the VoiceOver name). Avatars are decorative; the name is next to them. Selected controls add `.isSelected`.

## Performance

- No shadows, blurs or materials on every row of a long list; use them on hover or on single surfaces.
- No `LazyVStack` in the chat thread (it looped at 100% CPU); the thread is an AppKit table of hosted SwiftUI rows
  (`ThreadList`), so the rows look exactly as before.
- Never write `@State` or model state from scroll, geometry, hover or timer callbacks unless the value changed.
- Live pictures go to a `CALayer`, not through `@Observable` per frame.

## Forbidden

- System controls for input and choice: no bare `TextField` look or `.roundedBorder`, system `Picker`, `Menu` as a select, or system `Toggle` style, and no blue system focus ring. A field on its own uses `.banditoField()`. `.textFieldStyle(.plain)` is right only in two cases: the field sits inside a container that already draws the fill and border (a search capsule, the ⌘K palette, a select's search, a list row being renamed), or it is text edited in place (the agent's name and role in its card). Never a field box inside another box.
- Own button looks: no `.buttonStyle(.plain)` on a clickable thing, no hand-drawn capsule. Use `.banditoButton`.
- Orange fills on buttons or large surfaces. Orange is a dot, a ring, a glow, or accent text.
- More than one `.signal` button in a view.
- Literal colors, sizes or durations that have a token. Opacity values outside the list above.
- `LazyVStack` in the thread; shadows on list rows; `.animation(_:value:)` without the reduce-motion wrapper; infinite animations that ignore the window state.
- Emoji as decoration, stock illustrations, a second mascot.
- A card inside a card.
- String literals in Swift.

## New screen checklist

1. Read this file and open the artifact's README and the components you will use.
2. Sketch the screen as parts: header, `SectionLabel` groups, cards and rows, one cream action.
3. Build from components only. Missing piece: add it to the system first.
4. Tokens for every color, size, radius and duration.
5. Every state: rest, hover, keyboard focus, disabled, selected, error, empty, loading.
6. Every string in i18n, a line in `guide/*.md` for each new control (`python3 scripts/check_guide.py`).
7. Motion through `.banditoAnimation` and `.banditoRise` only.
8. Logic in a small pure type next to the view, with tests in `Tests/BanditoUITests`.
9. Run it as a QA copy (`docs/qa/RUNBOOK.md`) and look at it, dark and light, at the minimum window. A screen is done when it was looked at running.

## Keeping the system current

An approved change goes in one change set: the code, this file, and the Design System artifact (tokens, README, component README and preview). If a look is approved in conversation, update all three first. `brand/tokens/tokens.json` stays the source for color, type, space, radius and motion tokens; run `python3 brand/tokens/build.py` after editing it.
