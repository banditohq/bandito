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

    /// Whether the "down" button shows. With the distance to the bottom and the screen's height known, it shows when
    /// the bottom is more than one screen away. Without them, it shows whenever the newest message is not on screen.
    static func showsJump(atBottom: Bool, distance: Double?, screen: Double?) -> Bool {
        if let distance, let screen, screen > 0 {
            return distance > screen
        }
        return !atBottom
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
