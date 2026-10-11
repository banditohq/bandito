import Foundation

/// How often the key views build their body, counted while a QA performance scenario runs (the report lists the
/// counts). Debug builds only; in a release build `hit` is empty and costs nothing.
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
    #endif
}
