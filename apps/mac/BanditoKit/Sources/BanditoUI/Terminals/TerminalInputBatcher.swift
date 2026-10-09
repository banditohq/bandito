import Foundation

/// Joins keyboard bytes of one terminal into fewer `term.input` calls.
///
/// Bytes that arrive within `window` seconds of the first pending byte go out together, and anything
/// larger than `maxChunk` is cut into chunks at once. Times are in seconds on any monotonic clock.
/// The caller sends the returned chunks, and calls `flush()` when `deadline` has passed.
struct TerminalInputBatcher: Sendable {
    /// Largest chunk sent in one call (the daemon accepts 64 KiB; keep calls small).
    static let maxChunk = 4 << 10
    static let window: TimeInterval = 0.016

    private(set) var pending = Data()
    /// When the pending bytes must be flushed. `nil` when nothing is pending.
    private(set) var deadline: TimeInterval?

    /// Adds bytes. Returns the full chunks that are ready now; the rest waits for `deadline`.
    mutating func add(_ data: Data, now: TimeInterval) -> [Data] {
        guard !data.isEmpty else { return [] }
        if pending.isEmpty {
            deadline = now + Self.window
        }
        pending.append(data)
        var ready: [Data] = []
        while pending.count >= Self.maxChunk {
            ready.append(pending.prefix(Self.maxChunk))
            pending.removeFirst(Self.maxChunk)
        }
        if pending.isEmpty {
            deadline = nil
        }
        return ready
    }

    /// Returns everything still pending, or `nil` when there is nothing.
    mutating func flush() -> Data? {
        guard !pending.isEmpty else { return nil }
        let rest = pending
        pending = Data()
        deadline = nil
        return rest
    }
}
