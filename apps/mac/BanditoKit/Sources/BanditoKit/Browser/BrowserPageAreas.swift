import Foundation

/// The picture areas that show the browser page now, one per view: the workbench panel and Browser mode each keep
/// their own size. The page takes the size of the area that changed last. When that view goes, the page takes the
/// size of the area still on screen. Pure, so the rule is easy to read and test.
public struct BrowserPageAreas: Equatable, Sendable {
    /// The size of one picture area in points, and the screen's pixels per point.
    public struct Area: Equatable, Sendable {
        public var width: Double
        public var height: Double
        public var scale: Double

        public init(width: Double, height: Double, scale: Double) {
            self.width = width
            self.height = height
            self.scale = scale
        }
    }

    private struct Entry: Equatable, Sendable {
        var id: UUID
        var area: Area
    }

    /// The areas on screen, the one that changed last at the end.
    private var entries: [Entry] = []

    public init() {}

    /// No picture area is on screen.
    public var isEmpty: Bool { entries.isEmpty }

    /// Records the size of the area `id`. Its entry moves to the end: it is now the one the page follows.
    public mutating func report(_ area: Area, for id: UUID) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, area: area))
    }

    /// The area `id` is gone from the screen.
    public mutating func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// The viewport the page should take: the newest area that has a usable size. Nil when none has one.
    public var active: BrowserViewport? {
        entries.reversed().lazy.compactMap { entry in
            BrowserViewport.fitting(width: entry.area.width, height: entry.area.height, scale: entry.area.scale)
        }.first
    }
}
