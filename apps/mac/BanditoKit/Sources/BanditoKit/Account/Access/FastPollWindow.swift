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
    /// When the last window ended at its limit (not by running out), if one did.
    private var cappedAt: Date?

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
        let cap = begin.addingTimeInterval(limit)
        let wanted = now.addingTimeInterval(length)
        until = min(wanted, cap)
        if wanted > cap { cappedAt = cap }
    }

    /// Opens the window for a return to the front, which is no news: not while the last window ended at its limit less than
    /// `limit` ago (a server that has waited that long is waited for at the slow pace). Returns whether it opened.
    @discardableResult
    public mutating func openOnReturn(at now: Date) -> Bool {
        if !isOpen(at: now), let cappedAt, now.timeIntervalSince(cappedAt) < limit { return false }
        open(at: now)
        return true
    }

    public mutating func extendIfOpen(at now: Date) {
        guard isOpen(at: now) else { return }
        open(at: now)
    }

    public mutating func close() {
        started = nil
        until = nil
        cappedAt = nil
    }
}
