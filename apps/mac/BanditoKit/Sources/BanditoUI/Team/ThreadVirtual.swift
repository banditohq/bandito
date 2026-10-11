import BanditoKit
import Foundation

#if os(macOS)
import AppKit
#endif

/// Which rows of a thread are built. A thread of hundreds of rows used to be one stack of all of them, and every step of a
/// scroll cost a little for each row, built or not on screen: the longer the thread, the slower the scroll (about 0.08 ms
/// per row and frame). Now only the rows near the screen are built; the rows before them and after them are each one empty
/// space as tall as they are. Pure value logic, so it is tested alone.
///
/// A row's height is known once it was built (`record`). Before that it is a guess made from the row's text
/// (`ThreadHeightGuess`), the same guess every time: a guess that moved would move the whole thread. A row that was only a
/// guess and is built above the screen is taller or shorter than the guess, which moves what is below it: `record` returns
/// by how much, so the scroll view can be moved by the same amount (see `ThreadScrollBridge`) and nothing seems to move.
struct ThreadVirtualWindow: Equatable {
    /// The space between two rows of the thread, and above the first one.
    static let rowSpacing: CGFloat = 12
    static let topPadding: CGFloat = 22
    /// At most this many rows are built when a thread is first shown (the newest ones). Fewer when their guessed
    /// heights already fill `firstScreen`: an agent switch builds what shows, and the rows around it come a few a frame
    /// (`rowsPerStep`), not all in the frame of the switch.
    static let initialRows = 16
    /// The height the newest rows of a thread shown for the first time must fill: the last thread's screen, with a
    /// margin. A guess until a thread was measured.
    nonisolated(unsafe) static var firstScreen: CGFloat = 900
    /// The guess for a row that has none.
    static let defaultEstimate: CGFloat = 100

    private(set) var ids: [String] = []
    private var index: [String: Int] = [:]
    private(set) var heights: [String: CGFloat] = [:]
    /// The guess of each row that was never built.
    private(set) var guesses: [String: CGFloat] = [:]
    /// The width the heights were measured at. Another width makes every height wrong.
    private(set) var width: CGFloat = 0
    /// The first and the last row built, by id: ids stay right when rows are added above or the thread slides.
    private(set) var lowID: String?
    private(set) var highID: String?
    /// The height each row had in the empty space when it was built above the old range: what `record` compares with.
    private var spaceUsed: [String: CGFloat] = [:]

    // MARK: rows

    /// Takes the ids of the rows of the thread, in order. The range of built rows follows its ids; a thread shown for the
    /// first time, or one whose range is gone, gets its newest rows.
    mutating func setRows(ids new: [String], guess: (Int) -> CGFloat) {
        // A guess is made once per row. The ones of rows that are gone are dropped when they outnumber the rows.
        if guesses.count > 2 * new.count + 64 { guesses = guesses.filter { index[$0.key] != nil } }
        for (i, id) in new.enumerated() where guesses[id] == nil { guesses[id] = guess(i) }
        guard new != ids else { return }
        let followsEnd = highID != nil && highID == ids.last
        ids = new
        index = Dictionary(uniqueKeysWithValues: new.enumerated().map { ($1, $0) })
        guard !new.isEmpty else {
            lowID = nil
            highID = nil
            return
        }
        guard let lowID, let highID, let lo = index[lowID], let hi = index[highID], lo <= hi else {
            showTail()
            return
        }
        if followsEnd { self.highID = new.last }
    }

    private mutating func showTail() {
        let count = ids.count
        var low = count - 1
        var filled: CGFloat = 0
        while low > 0, count - low < Self.initialRows, filled < Self.firstScreen {
            filled += height(of: ids[low]) + Self.rowSpacing
            low -= 1
        }
        lowID = ids[low]
        highID = ids[count - 1]
    }

    /// The built rows as indices of `ids`.
    var range: Range<Int> {
        guard let lowID, let highID, let lo = index[lowID], let hi = index[highID], lo <= hi else { return 0..<0 }
        return lo..<(hi + 1)
    }

    func height(of id: String) -> CGFloat { heights[id] ?? guesses[id] ?? Self.defaultEstimate }

    /// The height of the empty space standing for the rows before `lo`: their heights and the gaps between them, less the
    /// gap the stack puts between the space and the first built row.
    func spaceBefore(_ lo: Int) -> CGFloat {
        guard lo > 0 else { return 0 }
        var total: CGFloat = 0
        for i in 0..<lo { total += height(of: ids[i]) + Self.rowSpacing }
        return max(0, total - Self.rowSpacing)
    }

    /// The same for the rows from `hi` on.
    func spaceAfter(_ hi: Int) -> CGFloat {
        guard hi < ids.count else { return 0 }
        var total: CGFloat = 0
        for i in hi..<ids.count { total += height(of: ids[i]) + Self.rowSpacing }
        return max(0, total - Self.rowSpacing)
    }

    /// Where the row at `i` starts in the content (from its top edge).
    func top(of i: Int) -> CGFloat {
        var y = Self.topPadding
        for j in 0..<min(i, ids.count) { y += height(of: ids[j]) + Self.rowSpacing }
        return y
    }

    /// The row that holds the point `y` of the content (the last row when `y` is below all, the first when above).
    func rowIndex(atOffset y: CGFloat) -> Int {
        guard !ids.isEmpty else { return 0 }
        var top = Self.topPadding
        for i in 0..<ids.count {
            let bottom = top + height(of: ids[i])
            if y < bottom + Self.rowSpacing / 2 { return i }
            top = bottom + Self.rowSpacing
        }
        return ids.count - 1
    }

    /// The id of the row on top of what shows when the content is scrolled to `offset`.
    func rowID(atOffset offset: CGFloat) -> String? {
        ids.isEmpty ? nil : ids[rowIndex(atOffset: offset)]
    }

    // MARK: what to build

    /// Screens of rows built above and below the one on screen when the range is set.
    static let bufferScreens: CGFloat = 2
    /// The range is set again when what is built no longer reaches this many screens beyond the screen's edges.
    static let reachScreens: CGFloat = 1
    /// Rows added to the range by one step. A scroll asks for the next step at every frame, so the rows are built a few at a
    /// time as the screen moves, not all at once when it comes near the end of what is built (that was a pause of a
    /// quarter of a second in a fast scroll).
    static let rowsPerStep = 2

    /// The range to build for a screen of `viewport` points at `offset`, or nil when the range now built still does it. A
    /// range that is far larger than needed is cut back (a long scroll leaves a long range behind).
    func neededRange(offset: CGFloat, viewport: CGFloat) -> (low: String, high: String)? {
        guard !ids.isEmpty, viewport > 0 else { return nil }
        let wantLo = rowIndex(atOffset: max(0, offset - viewport * Self.bufferScreens))
        let wantHi = rowIndex(atOffset: offset + viewport * (1 + Self.bufferScreens))
        let needLo = rowIndex(atOffset: max(0, offset - viewport * Self.reachScreens))
        let needHi = rowIndex(atOffset: offset + viewport * (1 + Self.reachScreens))
        let current = range
        var lo = wantLo
        var hi = wantHi
        let overlaps = !current.isEmpty && wantHi >= current.lowerBound && wantLo < current.upperBound
        if overlaps {
            let covers = current.lowerBound <= needLo && current.upperBound > needHi
            if covers {
                // Much more than needed is built: cut back to the wanted rows.
                guard current.count > 4 * (wantHi - wantLo + 1) + 20 else { return nil }
            } else {
                // Grow a few rows at a time towards what is wanted; keep the rest of the range.
                lo = wantLo < current.lowerBound ? max(wantLo, current.lowerBound - Self.rowsPerStep) : current.lowerBound
                hi =
                    wantHi >= current.upperBound
                    ? min(wantHi, current.upperBound - 1 + Self.rowsPerStep) : current.upperBound - 1
                // The screen itself must be covered at once, whatever the step.
                lo = min(lo, needLo)
                hi = max(hi, needHi)
            }
        }
        let low = ids[lo]
        let high = ids[hi]
        if low == lowID, high == highID { return nil }
        return (low, high)
    }

    /// Sets the range to the rows from `low` to `high`. Rows built above the old range were an empty space until now: their
    /// height is noted, to be compared with the measured one.
    mutating func commit(low: String, high: String) {
        guard let lo = index[low], let hi = index[high], lo <= hi else { return }
        let old = range
        spaceUsed.removeAll()
        if !old.isEmpty, hi >= old.lowerBound, lo < old.lowerBound {
            // Built upwards from the old range: the rows above it were guesses (or old heights) in the empty space.
            for i in lo..<min(old.lowerBound, hi + 1) { spaceUsed[ids[i]] = height(of: ids[i]) }
        }
        lowID = low
        highID = high
    }

    /// Builds the range around a row, so that it exists when something scrolls to it. True when the range changed.
    mutating func reveal(id: String, margin: Int = 12) -> Bool {
        guard let i = index[id] else { return false }
        let current = range
        if current.contains(i) { return false }
        let lo = max(0, i - margin)
        let hi = min(ids.count - 1, i + margin)
        // A jump: no rows are compared, nothing is moved.
        spaceUsed.removeAll()
        lowID = ids[lo]
        highID = ids[hi]
        return true
    }

    // MARK: measuring

    /// Notes the height a built row has. Returns how far the thread moved below it when the row stood above the screen as a
    /// guess and is not as tall: the scroll offset is to be moved by that much.
    @discardableResult
    mutating func record(id: String, height: CGFloat) -> CGFloat? {
        guard height.isFinite, height >= 0 else { return nil }
        let rounded = (height * 2).rounded() / 2
        let before = heights[id]
        if before != rounded { heights[id] = rounded }
        guard let used = spaceUsed.removeValue(forKey: id) else { return nil }
        let delta = rounded - used
        return abs(delta) < 0.5 ? nil : delta
    }

    /// The width the rows are laid out at. Another width forgets every height: they all change (the guesses stay).
    mutating func setWidth(_ new: CGFloat) {
        guard new.isFinite, new > 0, abs(new - width) > 0.5 else { return }
        width = new
        heights.removeAll()
        spaceUsed.removeAll()
    }

    /// Forgets everything of a thread that is not this one any more (another agent's rows).
    mutating func reset() {
        self = ThreadVirtualWindow()
    }
}

import SwiftUI

#if os(macOS)
/// Hands the scroll view the thread is in to its bridge. An invisible view inside the content: its enclosing scroll view is
/// the thread's own.
struct ThreadScrollFinder: NSViewRepresentable {
    var bridge: ThreadScrollBridge?

    func makeNSView(context: Context) -> NSView {
        let view = FinderView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? FinderView)?.bridge = bridge
        (view as? FinderView)?.claim()
    }

    final class FinderView: NSView {
        var bridge: ThreadScrollBridge?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            claim()
        }

        func claim() {
            guard let bridge, let scroll = enclosingScrollView else { return }
            Task { @MainActor in
                if bridge.scrollView !== scroll { bridge.scrollView = scroll }
            }
        }
    }
}
#else
struct ThreadScrollFinder: View {
    var bridge: ThreadScrollBridge?
    var body: some View { Color.clear.frame(width: 0, height: 0) }
}
#endif

#if os(macOS)
/// Moves the scroll view of the thread by hand, for the one thing SwiftUI cannot do: keeping what is on screen where it is
/// when rows above it turn out another height than guessed.
@MainActor
final class ThreadScrollBridge {
    weak var scrollView: NSScrollView?

    func adjust(by delta: CGFloat) {
        guard let scrollView, delta != 0 else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += delta
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}
#else
@MainActor
final class ThreadScrollBridge {
    func adjust(by delta: CGFloat) {}
}
#endif


/// What the thread view hands to the rows: how many rows to build and how tall the spaces before and after them are.
struct ThreadVirtualPlan {
    var range: Range<Int>
    var before: CGFloat
    var after: CGFloat
}

/// Counts the changes of the rows that are built. Only `ThreadRowsScope` reads it, so only it is drawn again at a change:
/// the header and the composer around the rows are not.
@MainActor
@Observable
final class ThreadVirtualTicker {
    private(set) var value = 0
    func bump() { value &+= 1 }
}

/// Draws its content again when the rows that are built change (see `ThreadVirtualTicker`).
struct ThreadRowsScope<Content: View>: View {
    var ticker: ThreadVirtualTicker
    @ViewBuilder var content: () -> Content

    var body: some View {
        let _ = ticker.value
        content()
    }
}

/// The window of built rows of one thread, with the scroll view it is kept right by. A reference: rows report their height
/// to it while they are drawn, and none of that is view state.
@MainActor
final class ThreadVirtualHost {
    var window = ThreadVirtualWindow()
    let bridge = ThreadScrollBridge()
    let ticker = ThreadVirtualTicker()

    /// The items the rows were last built from, and those rows. A scroll redraws the rows at every step of the range;
    /// building the rows of a long thread again each time (days, tool groups) was a millisecond a frame for nothing.
    private var builtFrom: [ThreadItem] = []
    private var built: [ThreadRow] = []

    /// The rows of `items`, built again only when the items changed.
    func rows(of items: [ThreadItem]) -> [ThreadRow] {
        if items.count == builtFrom.count, !built.isEmpty || items.isEmpty, items == builtFrom { return built }
        // A stream changes only the last item, and its row is that item: only the row is replaced.
        if let row = ThreadRows.replacingLast(built, from: builtFrom, to: items) {
            builtFrom = items
            built = row
            return built
        }
        builtFrom = items
        built = ThreadRows.build(items)
        return built
    }

    /// Takes the rows of the thread, and gives the plan for drawing them.
    func prepare(_ rows: [ThreadRow]) -> ThreadVirtualPlan {
        window.setRows(ids: rows.map(\.id)) { ThreadHeightGuess.height(of: rows[$0]) }
        let range = window.range
        return ThreadVirtualPlan(range: range, before: window.spaceBefore(range.lowerBound), after: window.spaceAfter(range.upperBound))
    }

    /// A row reports its height. When rows built above the screen are not as tall as guessed, the scroll view is moved so
    /// that what is on screen stays where it is.
    func record(id: String, height: CGFloat) {
        if let delta = window.record(id: id, height: height) { bridge.adjust(by: delta) }
    }

    func setWidth(_ width: CGFloat) { window.setWidth(width) }

    /// The range to build for the screen now, committed. True when it changed (the thread is to be drawn again).
    func update(offset: CGFloat, viewport: CGFloat) {
        if viewport > 0, abs(ThreadVirtualWindow.firstScreen - (viewport + 200)) > 1 {
            ThreadVirtualWindow.firstScreen = viewport + 200
        }
        guard let needed = window.neededRange(offset: offset, viewport: viewport) else { return }
        window.commit(low: needed.low, high: needed.high)
        ticker.bump()
    }

    /// Builds the rows around `id`. True when that changed the rows built.
    func reveal(_ id: String) -> Bool {
        guard window.reveal(id: id) else { return false }
        ticker.bump()
        return true
    }

    func rowID(atOffset offset: CGFloat) -> String? { window.rowID(atOffset: offset) }

    func reset() { window.reset() }
}
