import Foundation
import Observation

/// The steps of the first run, in order. Steps 4 to 6 of docs/IOS_APP.md (CLI, first command, first task) come later.
enum OnboardingStep: String, CaseIterable, Sendable {
    /// The raccoon assembles, "Let's go" or "I already have a server".
    case welcome
    /// Three live cards: a crew, an approval, the night shift.
    case features
    /// Where the crew lives: scan, paste or type. Hands over to the pairing flow through `onConnect`.
    case connect

    /// The place of the step in the progress line (0-based).
    var index: Int {
        switch self {
        case .welcome: 0
        case .features: 1
        case .connect: 2
        }
    }

    static var count: Int { allCases.count }
}

/// How the person wants to connect a server on the connect step.
enum OnboardingConnectMode: String, CaseIterable, Sendable {
    case scanCode
    case pasteLink
    case typeAddress
}

/// Where the person is: a step, and on the features step the card (0-based).
struct OnboardingPosition: Equatable, Sendable {
    var step: OnboardingStep
    var card: Int

    static let start = OnboardingPosition(step: .welcome, card: 0)
}

/// The navigation rules of onboarding as pure functions, so the tests need no view. Back always has an answer except
/// on the first step; Skip jumps to the connect step from anywhere before it.
enum OnboardingRules {
    static let cardCount = 3

    /// The position after "Let's go", "Next" or the last card's "Next": nil on the last step.
    static func forward(from position: OnboardingPosition) -> OnboardingPosition? {
        switch position.step {
        case .welcome:
            OnboardingPosition(step: .features, card: 0)
        case .features:
            position.card < cardCount - 1
                ? OnboardingPosition(step: .features, card: position.card + 1)
                : OnboardingPosition(step: .connect, card: 0)
        case .connect:
            nil
        }
    }

    /// The position after "Back": the previous card, else the previous step. Nil on the first step.
    static func back(from position: OnboardingPosition) -> OnboardingPosition? {
        switch position.step {
        case .welcome:
            nil
        case .features:
            position.card > 0
                ? OnboardingPosition(step: .features, card: position.card - 1)
                : OnboardingPosition(step: .welcome, card: 0)
        case .connect:
            OnboardingPosition(step: .features, card: cardCount - 1)
        }
    }

    /// "Skip" and "I already have a server": straight to the connect step.
    static func skipToConnect() -> OnboardingPosition {
        OnboardingPosition(step: .connect, card: 0)
    }

    /// The saved position, or the start when nothing valid is saved. A card outside the range is clamped.
    static func restore(step: String?, card: Int?) -> OnboardingPosition {
        guard let step, let saved = OnboardingStep(rawValue: step) else { return .start }
        let clamped = min(max(card ?? 0, 0), cardCount - 1)
        return OnboardingPosition(step: saved, card: saved == .features ? clamped : 0)
    }
}

/// The onboarding's saved progress and whether it is shown. Kept in UserDefaults under `ios.onboarding.*`; nothing
/// leaves the phone. Once a server is paired the flow is done for good.
@MainActor
@Observable
final class OnboardingStore {
    enum Key {
        static let step = "ios.onboarding.step"
        static let card = "ios.onboarding.card"
        static let completed = "ios.onboarding.completed"
    }

    /// Launch arguments: `-onboarding` shows the flow whatever the servers are, `-onboarding-step <name>` starts it at a
    /// step, `-onboarding-card <n>` at a card. The flow then keeps its progress in a throwaway suite.
    static let forceArgument = "-onboarding"
    static let stepArgument = "-onboarding-step"
    static let cardArgument = "-onboarding-card"
    private static let throwawaySuite = "dev.bandito.ios.onboarding.throwaway"

    private(set) var position: OnboardingPosition
    private(set) var completed: Bool
    /// The flow is forced on by a launch argument (snapshots, UI tests).
    let forced: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults, forced: Bool, start: OnboardingPosition? = nil) {
        self.defaults = defaults
        self.forced = forced
        completed = defaults.bool(forKey: Key.completed)
        position = OnboardingRules.restore(
            step: defaults.string(forKey: Key.step), card: defaults.object(forKey: Key.card) as? Int)
        if let start { show(start) }
    }

    /// The store of a launch. `-onboarding` or `-demo` keep their progress in a throwaway suite, so a snapshot never
    /// leaves the flow marked as done on the person's phone.
    static func launch(arguments: [String], standard: UserDefaults = .standard) -> OnboardingStore {
        let forced = arguments.contains(forceArgument)
        let demo = arguments.contains(IOSDemo.launchArgument)
        let defaults: UserDefaults
        if forced || demo {
            defaults = UserDefaults(suiteName: throwawaySuite) ?? standard
            defaults.removePersistentDomain(forName: throwawaySuite)
        } else {
            defaults = standard
        }
        let start = requestedStart(in: arguments)
        return OnboardingStore(defaults: defaults, forced: forced, start: start)
    }

    /// The position a launch asks for, if it asks for one.
    static func requestedStart(in arguments: [String]) -> OnboardingPosition? {
        guard let index = arguments.firstIndex(of: stepArgument), arguments.indices.contains(index + 1),
              let step = OnboardingStep(rawValue: arguments[index + 1]) else { return nil }
        var card = 0
        if let cardIndex = arguments.firstIndex(of: cardArgument), arguments.indices.contains(cardIndex + 1),
           let number = Int(arguments[cardIndex + 1]) {
            card = number
        }
        return OnboardingPosition(step: step, card: card)
    }

    /// Whether the flow covers the app: forced, or no server is paired yet and the flow was never finished.
    func shows(hasServers: Bool) -> Bool {
        forced || (!completed && !hasServers)
    }

    func show(_ next: OnboardingPosition) {
        let clamped = OnboardingRules.restore(step: next.step.rawValue, card: next.card)
        position = clamped
        defaults.set(clamped.step.rawValue, forKey: Key.step)
        defaults.set(clamped.card, forKey: Key.card)
    }

    /// The first server is paired: the flow is never shown again.
    func markCompleted() {
        guard !completed else { return }
        completed = true
        defaults.set(true, forKey: Key.completed)
    }
}
