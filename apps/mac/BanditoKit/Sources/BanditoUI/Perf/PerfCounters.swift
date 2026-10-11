import Foundation

/// How often the key views build their body, counted while a performance scenario runs (the report lists the
/// counts). Debug builds only; in a release build nothing is counted and `hit` costs nothing.
enum PerfCounters {
    #if DEBUG
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) static var counting = false

    static func hit(_ name: String) {
        guard counting else { return }
        lock.withLock { counts[name, default: 0] += 1 }
    }

    static func reset() { lock.withLock { counts.removeAll() } }

    static func snapshot() -> [String: Int] { lock.withLock { counts } }
    #else
    @inline(__always) static func hit(_ name: String) {}
    static var counting: Bool {
        get { false }
        set {}
    }
    static func reset() {}
    static func snapshot() -> [String: Int] { [:] }
    #endif
}
