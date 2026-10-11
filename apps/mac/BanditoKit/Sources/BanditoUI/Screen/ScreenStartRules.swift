import Foundation

/// What the server screen area shows, from the start of the screen to its first picture. Every state has a line
/// on screen, so pressing "Запустить экран" never goes silent.
enum ScreenStartPhase: Equatable, Sendable {
    /// The daemon does not list the `screen` feature (an older daemon). The area says so and opens Server → Updates.
    case needsUpdate
    /// The screen is asleep and nothing is wrong: the start button.
    case idle
    /// The `screen.start` call is in flight. A spinner replaces the button.
    case starting
    /// The screen runs and the app is connecting to its picture.
    case connecting
    /// The screen runs, but its first picture did not come within `ScreenStartRules.frameTimeout`.
    case noFrame
    /// The start or the connection failed, with the sentence to show.
    case failed(UserFacingMessage)
    /// The picture is on the screen.
    case running
}

/// The rules that turn what the model knows into a `ScreenStartPhase`. Pure, so the states are tested without a server.
enum ScreenStartRules {
    /// How long a running screen may take to send its first picture before the app says it did not answer.
    static let frameTimeout: Duration = .seconds(20)

    /// What the model knows at one moment.
    struct Facts: Equatable {
        /// The daemon lists the `screen` feature.
        var supported: Bool
        /// A `screen.start` call has not returned yet.
        var startInFlight: Bool
        /// The daemon reports the screen as running.
        var running: Bool
        /// A picture has arrived since the screen was last connected.
        var hasFrame: Bool
        /// A connection has waited `frameTimeout` for its first picture and got none.
        var frameTimedOut: Bool
        /// The last start or connection failure, until a start or a connected picture clears it.
        var error: UserFacingMessage?
    }

    /// The first rule that holds wins: an old daemon first, then a call in flight, then a picture, then a failure,
    /// then the waiting states, then the start button.
    static func phase(_ facts: Facts) -> ScreenStartPhase {
        guard facts.supported else { return .needsUpdate }
        if facts.startInFlight { return .starting }
        if facts.running, facts.hasFrame { return .running }
        if let error = facts.error { return .failed(error) }
        guard facts.running else { return .idle }
        return facts.frameTimedOut ? .noFrame : .connecting
    }
}
