import Foundation

/// A stretch of time in which the access cycle runs fast (seconds, not half a minute), so the servers of an account show
/// up on a new device within seconds of its approval. Pure values: the caller passes the clock.
///
/// `open` starts a window, or lengthens the one that is running; `extendIfOpen` lengthens only a running one (a cycle that
/// still sees a server waiting). A window never runs longer than `limit` in a row: after that it closes, and only a
/// new event (`open`) starts another.
public struct FastPollWindow: Equatable, Sendable {
    /// How long one `open` keeps the window.
    public let length: TimeInterval
    /// The longest a window may run in a row.
    public let limit: TimeInterval
    private var started: Date?
    private var until: Date?

    public init(length: TimeInterval, limit: TimeInterval) {
        self.length = length
        self.limit = max(limit, length)
    }

    public func isOpen(at now: Date) -> Bool {
        guard let until else { return false }
        return now < until
    }

    public mutating func open(at now: Date) {
        if !isOpen(at: now) { started = nil }
        let begin = started ?? now
        started = begin
        until = min(now.addingTimeInterval(length), begin.addingTimeInterval(limit))
    }

    public mutating func extendIfOpen(at now: Date) {
        guard isOpen(at: now) else { return }
        open(at: now)
    }

    public mutating func close() {
        started = nil
        until = nil
    }
}
