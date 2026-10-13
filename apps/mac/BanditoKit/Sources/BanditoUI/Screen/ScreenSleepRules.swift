import BanditoKit
import BanditoL10n
import Foundation

/// When the person may put a workplace's screen to sleep by hand, and when the app asks first. Pure, so the button's
/// states are tested without a server.
enum ScreenSleepRules {
    /// Why the app asks before it stops the screen.
    enum Confirmation: Equatable, Sendable {
        /// An agent holds the screen: what it has open on the screen closes under it.
        case agentWorking
        /// The person holds the controls themselves.
        case personHolds

        var title: String {
            switch self {
            case .agentWorking: L10n.Screen.sleepAgentTitle
            case .personHolds: L10n.Screen.sleepUserTitle
            }
        }
    }

    /// The button is there while the screen runs, and not while it is being started or put to sleep.
    static func isAvailable(running: Bool, isStarting: Bool, isSleeping: Bool) -> Bool {
        running && !isStarting && !isSleeping
    }

    /// Whether to ask first: when somebody holds the screen's controls, the agent or the person. A screen nobody
    /// holds (watched, or idle) goes to sleep at once, the same as it does after the idle time.
    static func confirmation(for status: ScreenStatus?) -> Confirmation? {
        guard let holder = status?.controller else { return nil }
        switch holder {
        case .agent: return .agentWorking
        case .user: return .personHolds
        case .none: return nil
        }
    }
}
