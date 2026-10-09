import Foundation

/// When a dropped browser connection is opened again: at most one attempt per `minimumInterval`, and at most
/// `maxAttempts` in a row. Time is passed in (seconds on any clock), so a test can drive it.
public struct BrowserReconnectPolicy: Sendable, Equatable {
    public static let minimumInterval: TimeInterval = 2
    public static let maxAttempts = 5

    /// Attempts made since the last success.
    public private(set) var attempts = 0
    private var lastAttempt: TimeInterval?

    public enum Step: Sendable, Equatable {
        /// Connect now. `attempt` counts from 1 since the last success.
        case attempt(Int)
        /// Too soon after the last attempt: try again at `time`, on the clock that was passed in.
        case wait(until: TimeInterval)
        /// `maxAttempts` failed in a row. Stop, and let the person start the browser again.
        case giveUp
    }

    public init() {}

    /// What to do now that the connection is down and the model wants to reconnect.
    public mutating func next(at now: TimeInterval) -> Step {
        if attempts >= Self.maxAttempts { return .giveUp }
        if let last = lastAttempt, now - last < Self.minimumInterval {
            return .wait(until: last + Self.minimumInterval)
        }
        attempts += 1
        lastAttempt = now
        return .attempt(attempts)
    }

    /// The connection came up and showed something: the count starts over.
    public mutating func succeeded() {
        attempts = 0
        lastAttempt = nil
    }
}
