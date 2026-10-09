import Foundation

/// Whether the server needs attention on the Server overview: a disk or the memory more than 90 % full.
public struct HostHealth: Sendable, Hashable {
    /// Share of a disk or of the memory above which it counts as full.
    public static let threshold = 0.9

    public var diskFull: Bool
    public var memoryFull: Bool

    public var isOK: Bool { !diskFull && !memoryFull }

    public init(diskFull: Bool, memoryFull: Bool) {
        self.diskFull = diskFull
        self.memoryFull = memoryFull
    }

    public static func evaluate(_ stats: HostStats) -> HostHealth {
        HostHealth(
            diskFull: stats.disks.contains { fraction(used: $0.used, total: $0.total) > threshold },
            memoryFull: fraction(used: stats.memUsed, total: stats.memTotal) > threshold)
    }

    /// `used / total` in 0...1, or 0 when `total` is not known.
    public static func fraction(used: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return Double(used) / Double(total)
    }
}
