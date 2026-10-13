import Foundation

/// Keeps what the person is looking at in place when rows come in above it (an older page of history) or change height
/// above it. The list remembers the row on top of the screen and how far below the top of the screen it was; after the
/// change it puts that row at the same distance again. Pure, so tested alone.
public struct ThreadAnchor: Equatable, Sendable {
    /// The id of the row that was on top of the screen.
    public var rowID: String
    /// How far the row's top was below the top of the visible area (negative when the row began above it).
    public var distanceFromTop: Double

    public init(rowID: String, distanceFromTop: Double) {
        self.rowID = rowID
        self.distanceFromTop = distanceFromTop
    }

    /// The anchor of a screen: the first row whose bottom is below the top of the visible area.
    /// - Parameters:
    ///   - rows: the visible rows in order, with their top and height in the list's content.
    ///   - visibleTop: the content offset of the top of the visible area.
    public static func capture(rows: [(id: String, minY: Double, height: Double)], visibleTop: Double) -> ThreadAnchor? {
        for row in rows where row.minY + row.height > visibleTop {
            return ThreadAnchor(rowID: row.id, distanceFromTop: row.minY - visibleTop)
        }
        return nil
    }

    /// The content offset that puts the anchor row back at its distance, given where the row stands now. Never above
    /// the start of the content.
    public func offset(rowMinY: Double, minOffset: Double = 0) -> Double {
        max(minOffset, rowMinY - distanceFromTop)
    }

    /// Whether the anchor can be used: its row is still in the list.
    public func isKept(in ids: [String]) -> Bool {
        ids.contains(rowID)
    }
}

/// Which rows a new list adds above the old one.
public enum ThreadPrepend {
    /// How many rows of `new` come before the first row of `old` that `new` still has: the rows prepended. Zero when
    /// the lists share no row, or the list did not grow at its start.
    public static func count(old: [String], new: [String]) -> Int {
        guard let first = old.first(where: { id in new.contains(id) }), let index = new.firstIndex(of: first) else {
            return 0
        }
        let known = Set(old)
        return new[..<index].filter { !known.contains($0) }.count
    }
}
