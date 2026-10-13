import Foundation

/// Where a thread was left: at its newest message, or at the row on top of the screen (by the row's id).
public enum ThreadPlace: Equatable, Sendable {
    case bottom
    case row(String)
}

/// Rules of a thread's scroll: where to come back to, what to keep when it is left, when the "down" button shows, and
/// how many messages wait below. Pure, so tested alone.
public enum ThreadScroll {
    /// Where a thread is shown again: where it was left. A thread never shown before (or left at the bottom) starts
    /// at its newest message.
    public static func restoreTarget(_ place: ThreadPlace?) -> ThreadPlace {
        place ?? .bottom
    }

    /// The place to keep when the thread is left: the bottom while the newest message is on screen, else the row on
    /// top. An unknown top row is the bottom.
    public static func place(atBottom: Bool, topRowID: String?) -> ThreadPlace {
        if atBottom { return .bottom }
        guard let topRowID else { return .bottom }
        return .row(topRowID)
    }

    /// Within this many points of the bottom the thread counts as "at the bottom".
    public static let bottomSlack = 48
    /// The "down" button shows when the bottom is further away than this many points.
    public static let jumpDistance = 120

    /// Whether the "down" button shows. With the distance to the bottom known, it shows when the person is not
    /// following the bottom and the bottom is more than `jumpDistance` away. Without it, it shows whenever the
    /// newest message is not on screen.
    public static func showsJump(atBottom: Bool, distance: Int?) -> Bool {
        if let distance {
            return !atBottom && distance > jumpDistance
        }
        return !atBottom
    }

    /// What the thread keeps in state after a scroll geometry change: whether it follows the bottom and whether the
    /// "down" button shows. Equal values for a scroll that crosses no threshold: nothing is then written.
    public static func flags(
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
    public static func atBottom(was: Bool, old: ThreadScrollMetrics?, new: ThreadScrollMetrics, pinned: Bool = false) -> Bool {
        guard let old else { return new.distance <= bottomSlack || was || pinned }
        if leavesBottom(old: old, new: new) { return false }
        if was || pinned { return true }
        return new.offset > old.offset && new.distance <= bottomSlack
    }

    /// Whether this change is the person scrolling up, away from the bottom. A smaller offset is not enough: a screen
    /// that got taller (the composer shrank after a send, the panel was resized) moves the offset down by itself, and
    /// whole-point rounding of three separate numbers leaves a distance of 1 or so that no one scrolled. So the screen
    /// must keep its height, the content must not shrink, and the bottom must be more than a point away.
    public static func leavesBottom(old: ThreadScrollMetrics, new: ThreadScrollMetrics) -> Bool {
        guard new.offset < old.offset else { return false }
        if new.height != old.height { return false }
        if new.contentHeight < old.contentHeight { return false }
        return new.distance > 1
    }

    /// Whether the thread should be brought to its bottom now: it is at the bottom, its layout changed (the content
    /// or the screen got another height), and the bottom is not on screen yet. A plain scroll never asks for it, so
    /// the scroll that follows cannot ask again.
    public static func shouldFollow(atBottom: Bool, old: ThreadScrollMetrics?, new: ThreadScrollMetrics) -> Bool {
        guard atBottom, let old else { return false }
        let layoutChanged = new.contentHeight != old.contentHeight || new.height != old.height
        return layoutChanged && new.distance > 1
    }

    /// Within this many points of the top the thread asks for older rows.
    public static let topSlack = 300
    /// Whether the thread is near its top.
    public static func nearTop(offset: Double) -> Bool { offset <= Double(topSlack) }

    /// Where to show a thread again once its rows are loaded: a row that is not among them (older than the loaded
    /// history) falls back to the newest message.
    public static func resolved(_ target: ThreadPlace, rowIDs: [String]) -> ThreadPlace {
        if case .row(let id) = target, !rowIDs.contains(id) { return .bottom }
        return target
    }

    /// Messages that came in since the last look: the growth of the thread. Never negative.
    public static func unseenAdded(previousCount: Int, currentCount: Int) -> Int {
        max(0, currentCount - previousCount)
    }
}

/// When the thread last moved under the pointer. A reference-free global on purpose: rows read it in their hover
/// handler, and a scroll writes it on every step, without redrawing anything.
@MainActor
public enum ThreadScrollActivity {
    /// How long after the last step the thread still counts as scrolling.
    public static let settle: Double = 0.18
    private static var lastMove: Double = -.infinity

    public static func noteMove(at now: Double = ProcessInfo.processInfo.systemUptime) { lastMove = now }

    public static func isScrolling(at now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastMove < settle
    }
}

/// What the scroll view reports about its geometry, in whole points (so that sub-point noise is not a change).
public struct ThreadScrollMetrics: Equatable, Sendable {
    /// How far the bottom of the content is below the bottom of the screen.
    public var distance: Int
    /// The height of the screen (the scroll view).
    public var height: Int
    public var offset: Int
    public var contentHeight: Int

    public init(distance: Int, height: Int, offset: Int = 0, contentHeight: Int = 0) {
        self.distance = distance
        self.height = height
        self.offset = offset
        self.contentHeight = contentHeight
    }

    public init(offset: Double, contentHeight: Double, height: Double) {
        self.offset = Int(offset.rounded())
        self.contentHeight = Int(contentHeight.rounded())
        self.height = Int(height.rounded())
        self.distance = Int((contentHeight - offset - height).rounded())
    }
}
