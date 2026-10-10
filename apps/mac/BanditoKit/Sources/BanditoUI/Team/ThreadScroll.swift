import Foundation

/// Where a thread was left: at its newest message, or at the row on top of the screen (by the row's id).
enum ThreadPlace: Equatable, Sendable {
    case bottom
    case row(String)
}

/// Rules of a thread's scroll: where to come back to, what to keep when it is left, when the "down" button shows, and
/// how many messages wait below. Pure, so tested alone.
enum ThreadScroll {
    /// The id of the marker at the end of the rows: the newest message is on screen when it is.
    static let bottomID = "bottom"

    /// Where a thread is shown again: where it was left. A thread never shown before (or left at the bottom) starts
    /// at its newest message.
    static func restoreTarget(_ place: ThreadPlace?) -> ThreadPlace {
        place ?? .bottom
    }

    /// The place to keep when the thread is left: the bottom while the newest message is on screen, else the row on
    /// top. An unknown top row is the bottom.
    static func place(atBottom: Bool, topRowID: String?) -> ThreadPlace {
        if atBottom { return .bottom }
        guard let topRowID, topRowID != bottomID else { return .bottom }
        return .row(topRowID)
    }

    /// Within this many points of the bottom the thread counts as "at the bottom".
    static let bottomSlack = 48
    /// The "down" button shows when the bottom is further away than this many points.
    static let jumpDistance = 120

    /// Whether the "down" button shows. With the distance to the bottom known, it shows when the person is not
    /// following the bottom and the bottom is more than `jumpDistance` away. Without it, it shows whenever the
    /// newest message is not on screen.
    static func showsJump(atBottom: Bool, distance: Int?) -> Bool {
        if let distance {
            return !atBottom && distance > jumpDistance
        }
        return !atBottom
    }

    /// What the thread keeps in state after a scroll geometry change: whether it follows the bottom and whether the
    /// "down" button shows. Equal values for a scroll that crosses no threshold: nothing is then written.
    static func flags(
        was: Bool, old: ThreadScrollMetrics?, new: ThreadScrollMetrics, pinned: Bool = false
    ) -> (atBottom: Bool, jump: Bool) {
        let at = atBottom(was: was, old: old, new: new, pinned: pinned)
        return (at, showsJump(atBottom: at, distance: new.distance))
    }

    /// Whether the thread is at the bottom after the scroll geometry changed from `old` to `new`.
    /// A thread at the bottom stays there while content grows below (a stream, a new row, an opened card) or the
    /// panel is resized: the bottom moves away without the person moving. A scroll up (the offset falls while the
    /// content did not shrink and the bottom is not reached) leaves it. From away, only the person's own scroll down
    /// (the offset rises) to within `bottomSlack` brings it back: content growing without a move never does.
    static func atBottom(was: Bool, old: ThreadScrollMetrics?, new: ThreadScrollMetrics, pinned: Bool = false) -> Bool {
        guard let old else { return new.distance <= bottomSlack || was || pinned }
        if leavesBottom(old: old, new: new) { return false }
        if was || pinned { return true }
        return new.offset > old.offset && new.distance <= bottomSlack
    }

    /// Whether this change is the person scrolling up, away from the bottom. A smaller offset is not enough: a screen
    /// that got taller (the composer shrank after a send, the panel was resized) moves the offset down by itself, and
    /// whole-point rounding of three separate numbers leaves a distance of 1 or so that no one scrolled. So the screen
    /// must keep its height, the content must not shrink, and the bottom must be more than a point away.
    static func leavesBottom(old: ThreadScrollMetrics, new: ThreadScrollMetrics) -> Bool {
        guard new.offset < old.offset else { return false }
        if new.height != old.height { return false }
        if new.contentHeight < old.contentHeight { return false }
        return new.distance > 1
    }

    /// Whether the thread should be brought to its bottom now: it is at the bottom, its layout changed (the content
    /// or the screen got another height), and the bottom is not on screen yet. A plain scroll never asks for it, so
    /// the scroll that follows cannot ask again.
    static func shouldFollow(atBottom: Bool, old: ThreadScrollMetrics?, new: ThreadScrollMetrics) -> Bool {
        guard atBottom, let old else { return false }
        let layoutChanged = new.contentHeight != old.contentHeight || new.height != old.height
        return layoutChanged && new.distance > 1
    }

    /// The rows drawn at most (the last ones); older ones are added when the top of the thread is reached.
    static let windowSize = 300
    /// Within this many points of the top the thread asks for older rows.
    static let topSlack = 300
    /// The names of the coordinate spaces: the scroll view's, and the rows' content.
    static let scrollSpace = "thread-scroll"
    static let contentSpace = "thread-content"

    /// Whether the thread is near its top.
    static func nearTop(offset: Double) -> Bool { offset <= Double(topSlack) }

    /// The row on top of what is on screen: of the `valid` rows, the highest one whose bottom edge is below `offset`.
    static func topRow(spans: [String: ThreadRowSpan], offset: Double, valid: Set<String>) -> String? {
        var best: (id: String, minY: Double)?
        for (id, span) in spans where valid.contains(id) && span.maxY > offset + 1 {
            if best == nil || span.minY < best!.minY { best = (id, span.minY) }
        }
        return best?.id
    }

    /// The first row drawn: `startID` if it is among `ids`, else the last `windowSize` of them.
    static func windowStart(ids: [String], startID: String?) -> Int {
        if let startID, let index = ids.firstIndex(of: startID) { return index }
        return max(0, ids.count - windowSize)
    }

    /// The start of the window when `count` items are there and the window starts at `start`. At the bottom, a window
    /// of more than twice `windowSize` is cut to the last `windowSize`: the rows dropped are far above the screen.
    /// Away from the bottom the start never moves (the rows on screen must stay).
    static func slidStart(count: Int, start: Int, atBottom: Bool) -> Int {
        guard atBottom, count - start > 2 * windowSize else { return start }
        return count - windowSize
    }

    /// The start of the window after it grows upward by one step from `start`. Zero when it reaches the first row.
    static func widenedStart(from start: Int) -> Int { max(0, start - windowSize) }

    /// Where to show a thread again once its rows are loaded: a row that is not among them (older than the loaded
    /// history) falls back to the newest message.
    static func resolved(_ target: ThreadPlace, rowIDs: [String]) -> ThreadPlace {
        if case .row(let id) = target, !rowIDs.contains(id) { return .bottom }
        return target
    }

    /// Whether the scroll geometry is known on this system (macOS 15 and later): the distance to the bottom is then
    /// measured, not guessed from the bottom marker.
    static var hasScrollGeometry: Bool {
        if #available(macOS 15.0, iOS 18.0, *) { return true }
        return false
    }

    /// Messages that came in since the last look: the growth of the thread. Never negative.
    static func unseenAdded(previousCount: Int, currentCount: Int) -> Int {
        max(0, currentCount - previousCount)
    }
}

/// When the thread last moved under the pointer. A reference-free global on purpose: rows read it in their hover
/// handler, and a scroll writes it on every step, without redrawing anything.
@MainActor
enum ThreadScrollActivity {
    /// How long after the last step the thread still counts as scrolling.
    static let settle: Double = 0.18
    private static var lastMove: Double = -.infinity

    static func noteMove(at now: Double = ProcessInfo.processInfo.systemUptime) { lastMove = now }

    static func isScrolling(at now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastMove < settle
    }
}

/// Where a row is in the content of the thread, from its top edge to its bottom edge.
struct ThreadRowSpan: Equatable, Sendable {
    var minY: Double
    var maxY: Double
}

/// What the scroll view reports about its geometry, in whole points (so that sub-point noise is not a change).
struct ThreadScrollMetrics: Equatable, Sendable {
    /// How far the bottom of the content is below the bottom of the screen.
    var distance: Int
    /// The height of the screen (the scroll view).
    var height: Int
    var offset: Int
    var contentHeight: Int

    init(distance: Int, height: Int, offset: Int = 0, contentHeight: Int = 0) {
        self.distance = distance
        self.height = height
        self.offset = offset
        self.contentHeight = contentHeight
    }

    init(offset: Double, contentHeight: Double, height: Double) {
        self.offset = Int(offset.rounded())
        self.contentHeight = Int(contentHeight.rounded())
        self.height = Int(height.rounded())
        self.distance = Int((contentHeight - offset - height).rounded())
    }
}
