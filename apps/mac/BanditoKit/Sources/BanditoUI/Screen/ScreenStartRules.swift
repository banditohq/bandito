import BanditoL10n
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
    /// The server lacks programs the screen needs. The area names them and offers "Установить", which installs them
    /// and starts the screen again.
    case missingComponents([String])
    /// The missing programs are being installed. The area shows the install's progress.
    case installing
    /// The screen runs and the app is connecting to its picture.
    case connecting
    /// The screen runs, but its first picture did not come within `ScreenStartRules.frameTimeout`.
    case noFrame
    /// The start or the connection failed, with the sentence to show.
    case failed(UserFacingMessage)
    /// The picture is on the screen.
    case running
}

/// What a failed `screen.start` means for the area: the programs the server lacks, or a failure to show.
enum ScreenStartFailure: Equatable, Sendable {
    case missingComponents([String])
    case failed(UserFacingMessage)
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
        /// The programs the last start said are missing. Empty when nothing is missing.
        var missing: [String] = []
        /// The install of the missing programs is running.
        var installing: Bool = false
    }

    /// The first rule that holds wins: an old daemon first, then a call in flight, then an install, then a picture,
    /// then the missing programs, then a failure, then the waiting states, then the start button.
    static func phase(_ facts: Facts) -> ScreenStartPhase {
        guard facts.supported else { return .needsUpdate }
        if facts.startInFlight { return .starting }
        if facts.installing { return .installing }
        if facts.running, facts.hasFrame { return .running }
        if !facts.missing.isEmpty { return .missingComponents(facts.missing) }
        if let error = facts.error { return .failed(error) }
        guard facts.running else { return .idle }
        return facts.frameTimedOut ? .noFrame : .connecting
    }

    /// The components one install of the screen runs: the programs the start named, then the rest of the screen feature
    /// that is missing and that Bandito installs here (`window_manager`, `fonts`). Each id once, in that order.
    static func installIds(required: [String], feature: [String]) -> [String] {
        var ids = required
        for id in feature where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// Reads a failed `screen.start`: the RPC `reason`, `data.components` and `data.component`, and the daemon's
    /// message. `missing_component` gives the list of programs; an older daemon sends only `data.component`, which
    /// makes a list of one. Any other failure, or a missing-component error without a name, is `.failed`: the sentence
    /// "Не удалось запустить экран" with the daemon's message under "Подробнее".
    static func failure(reason: String?, components: [String], component: String?, message: String) -> ScreenStartFailure {
        if reason == "missing_component" {
            let names = components.isEmpty ? [component].compactMap(\.self) : components
            let named = names.filter { !$0.isEmpty }
            if !named.isEmpty { return .missingComponents(named) }
        }
        return .failed(UserFacingMessage(text: L10n.Screen.startFailed, technical: message, canRetry: true))
    }
}
