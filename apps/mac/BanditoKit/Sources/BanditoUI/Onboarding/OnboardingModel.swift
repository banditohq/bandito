import BanditoKit
import Foundation
import Observation

/// The steps of first-run onboarding, in order (docs/IOS_APP.md, "Onboarding (iPhone and Mac, one story)").
/// `approval` appears only for a device that waits for another device; it belongs to the account step in the bar.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, features, account, approval, server, runtimes, team, task, done

    /// How many dots the step bar has: intro, what you get, account, where it lives, who works, the crew, first task.
    public static let barCount = 7

    /// The number shown as "step N of 7". Approval belongs to the account step.
    public var position: Int {
        switch self {
        case .welcome: 1
        case .features: 2
        case .account, .approval: 3
        case .server: 4
        case .runtimes: 5
        case .team: 6
        case .task, .done: 7
        }
    }

    /// The steps that need a connected server in front of them.
    public var needsServer: Bool {
        switch self {
        case .runtimes, .team, .task: true
        default: false
        }
    }

    /// The raw value an older build saved for this step: "agent" was the subscriptions and the first agent in one.
    static func restored(_ raw: String?) -> OnboardingStep? {
        guard let raw else { return nil }
        if raw == "agent" { return .runtimes }
        return OnboardingStep(rawValue: raw)
    }
}

/// The navigation rules of the cards of "What you get" and of the later steps, as pure functions.
public enum OnboardingRules {
    /// "A crew, not a chat", "Nothing risky without you", "Works while you sleep".
    public static let cardCount = 3

    /// The card a saved number stands for, clamped to the cards there are.
    public static func clampedCard(_ saved: Int?) -> Int {
        min(max(saved ?? 0, 0), cardCount - 1)
    }

    /// Whether the runtimes step may go on: at least one agent program is installed and signed in. Others can wait.
    public static func canContinueRuntimes(signedIn: [RuntimeKind]) -> Bool {
        !signedIn.isEmpty
    }
}

/// State of the first-run flow. The current step, the card, the way back and the done flag live in UserDefaults
/// (`onboarding.*`), so a relaunch resumes where the person stopped.
@MainActor
@Observable
public final class OnboardingModel {
    public static let stepKey = "onboarding.step"
    public static let doneKey = "onboarding.done"
    public static let cardKey = "onboarding.card"
    public static let historyKey = "onboarding.history"
    public static let firstAgentKey = "onboarding.firstAgent"
    public static let firstTeamKey = "onboarding.firstTeam"

    public private(set) var step: OnboardingStep
    /// The card on screen at "What you get" (0-based).
    public private(set) var card: Int
    /// The steps the person came through, oldest first. "Back" returns to the last one.
    public private(set) var history: [OnboardingStep]
    /// The agent the crew step made first: the first task goes to it.
    public private(set) var firstAgentID: String?
    /// The ready team the crew step made (its bundle id), or nil for one agent: the first task's suggestions follow it.
    public private(set) var firstTeamID: String?
    /// Whether the flow is in front of the main window.
    public private(set) var isActive = false
    /// The tour over the main window runs after the first task is sent. Cleared by `endTour`.
    public private(set) var tourRequested = false
    /// True while the signed-in device waits for approval from another device.
    public private(set) var needsApproval = false

    @ObservationIgnored private let defaults: UserDefaults

    /// The launch decision, made once and for good here, from local data only:
    /// the main window when the flow is done or when servers are saved on this Mac; the flow otherwise.
    /// A person who quit after the server was connected (the flow was at the server step or later) comes back to the
    /// flow, at the step after the server. Connecting afterwards never switches it. If the person removes every
    /// server, nothing changes: the flow comes back only from the Help menu.
    /// - Parameter hasSavedServers: whether servers are stored on this Mac (read before connecting).
    public init(defaults: UserDefaults = .standard, hasSavedServers: Bool = false) {
        self.defaults = defaults
        let saved = OnboardingStep.restored(defaults.string(forKey: Self.stepKey))
        var start: OnboardingStep = .welcome
        // "done" without the done flag is inconsistent: start the flow again from the first step.
        if let saved, saved != .done { start = saved }
        var resumesAfterServer = false
        var remapped = false
        if hasSavedServers, start == .server || start.needsServer {
            // The server exists: the flow goes on after it.
            resumesAfterServer = true
            if start == .server {
                start = .runtimes
                remapped = true
            }
        } else if !hasSavedServers, start.needsServer {
            // A step that needs a server, and none is saved: back to the server step.
            start = .server
        }
        step = start
        card = OnboardingRules.clampedCard(defaults.object(forKey: Self.cardKey) as? Int)
        history = Self.readHistory(defaults.string(forKey: Self.historyKey), before: start)
        // The server step was passed by connecting: Back from the next step returns to it.
        if remapped { history.append(.server) }
        firstAgentID = defaults.string(forKey: Self.firstAgentKey)
        firstTeamID = defaults.string(forKey: Self.firstTeamKey)
        isActive = !defaults.bool(forKey: Self.doneKey) && (!hasSavedServers || resumesAfterServer)
    }

    /// True once the person has finished or skipped the flow.
    public var isDone: Bool {
        defaults.bool(forKey: Self.doneKey)
    }

    /// Back always works except on the first card of the first step.
    public var canGoBack: Bool {
        step != .welcome && step != .done
    }

    /// Moves to the next step. Reaching `.done` finishes the flow.
    public func advance() {
        go(to: Self.nextStep(after: step, needsApproval: needsApproval))
        if step == .done { finish() }
    }

    /// "Next" on a card of "What you get": the next card, and on the last one the next step.
    public func nextCard() {
        guard step == .features else { return }
        if card < OnboardingRules.cardCount - 1 {
            setCard(card + 1)
        } else {
            advance()
        }
    }

    /// "Skip" on "What you get": past the cards, to the next step.
    public func skipFeatures() {
        guard step == .features else { return }
        advance()
    }

    /// Shows a card by number (the dots, the arrow keys).
    public func showCard(_ number: Int) {
        guard step == .features else { return }
        setCard(OnboardingRules.clampedCard(number))
    }

    /// "Back": the previous card on "What you get", else the step the person came from.
    public func back() {
        guard canGoBack else { return }
        if step == .features, card > 0 {
            setCard(card - 1)
            return
        }
        if step == .approval {
            // Back from the approval waits for nobody: the sign-in step again.
            needsApproval = false
        }
        if let last = history.popLast() {
            persistHistory()
            set(last)
        } else {
            set(Self.previousStep(before: step))
        }
    }

    /// "I already have a server" on Welcome: the account step is skipped, the server step comes next (as on iPhone).
    public func haveServer() {
        needsApproval = false
        go(to: .server)
    }

    /// The account step ended with a signed-in session. An unapproved device goes to the approval step.
    public func signedIn(deviceApproved: Bool) {
        needsApproval = !deviceApproved
        advance()
    }

    /// The session is too old for a reset (or was lost): back to the sign-in step.
    public func returnToSignIn() {
        needsApproval = false
        // The way back to the sign-in step forgets what came after it.
        if let index = history.lastIndex(of: .account) {
            history = Array(history[..<index])
            persistHistory()
        }
        set(.account)
    }

    /// The crew step made its first agent: the first task is sent to it, and a relaunch remembers it.
    public func rememberFirstAgent(_ id: String, team: String?) {
        firstAgentID = id
        firstTeamID = team
        defaults.set(id, forKey: Self.firstAgentKey)
        defaults.set(team, forKey: Self.firstTeamKey)
    }

    /// "Choose a server" on a step that found none: back to the server step, forgetting the steps after it.
    public func returnToServer() {
        needsApproval = false
        if let index = history.lastIndex(of: .server) {
            history = Array(history[..<index])
            persistHistory()
        }
        set(.server)
    }

    /// "Set up later" on any step after welcome: the main window opens and the flow does not come back on launch.
    public func skip() {
        finish()
    }

    /// "Show the introduction again" from the Help menu: starts at welcome, whatever the server state.
    public func replay() {
        tourRequested = false
        defaults.set(false, forKey: Self.doneKey)
        needsApproval = false
        history = []
        persistHistory()
        firstAgentID = nil
        firstTeamID = nil
        defaults.removeObject(forKey: Self.firstAgentKey)
        defaults.removeObject(forKey: Self.firstTeamKey)
        setCard(0)
        set(.welcome)
        isActive = true
    }

    /// The first task is sent: the flow is done and the tour starts over the main window.
    public func finishWithTour() {
        tourRequested = true
        finish()
    }

    /// The tour ended, by "Finish", "Skip", or because there was nothing to point at.
    public func endTour() {
        tourRequested = false
    }

    /// The flow is over: the done flag is stored and the main window takes over.
    public func finish() {
        defaults.set(true, forKey: Self.doneKey)
        isActive = false
        history = []
        persistHistory()
        set(.done)
    }

    // MARK: steps

    /// The step after `step`. Approval is visited only when the device needs it.
    public static func nextStep(after step: OnboardingStep, needsApproval: Bool) -> OnboardingStep {
        switch step {
        case .welcome: .features
        case .features: .account
        case .account: needsApproval ? .approval : .server
        case .approval: .server
        case .server: .runtimes
        case .runtimes: .team
        case .team: .task
        case .task, .done: .done
        }
    }

    /// The step before `step` in the usual order, for a flow resumed without a saved way back.
    static func previousStep(before step: OnboardingStep) -> OnboardingStep {
        switch step {
        case .welcome, .features: .welcome
        case .account: .features
        case .approval: .account
        case .server: .account
        case .runtimes: .server
        case .team: .runtimes
        case .task: .team
        case .done: .task
        }
    }

    private func go(to next: OnboardingStep) {
        guard next != step else { return }
        if step != .done {
            history.append(step)
            persistHistory()
        }
        set(next)
    }

    private func set(_ next: OnboardingStep) {
        step = next
        defaults.set(next.rawValue, forKey: Self.stepKey)
    }

    private func setCard(_ number: Int) {
        guard number != card else { return }
        card = number
        defaults.set(number, forKey: Self.cardKey)
    }

    private func persistHistory() {
        defaults.set(history.map(\.rawValue).joined(separator: ","), forKey: Self.historyKey)
    }

    /// The saved way back, without anything that is not a step before `current` in a sane order.
    private static func readHistory(_ raw: String?, before current: OnboardingStep) -> [OnboardingStep] {
        guard let raw, !raw.isEmpty else { return [] }
        let steps = raw.split(separator: ",").compactMap { OnboardingStep.restored(String($0)) }
        return steps.filter { $0 != .done && $0 != current }
    }
}
