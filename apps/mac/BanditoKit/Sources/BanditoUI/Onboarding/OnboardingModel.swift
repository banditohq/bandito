import Foundation
import Observation

/// The steps of first-run onboarding, in order. `approval` appears only for a device that waits for another device.
public enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome, account, approval, server, agent, done

    /// The number shown as "step N of 5" in the design. Approval belongs to the account step.
    public var position: Int {
        switch self {
        case .welcome: 1
        case .account, .approval: 2
        case .server: 3
        case .agent: 4
        case .done: 5
        }
    }
}

/// State of the first-run flow. The current step and the done flag live in UserDefaults
/// (`onboarding.step`, `onboarding.done`), so a relaunch resumes where the person stopped.
@MainActor
@Observable
public final class OnboardingModel {
    public static let stepKey = "onboarding.step"
    public static let doneKey = "onboarding.done"

    public private(set) var step: OnboardingStep
    /// Whether the flow is in front of the main window.
    public private(set) var isActive = false
    /// True until the servers are connected and `evaluate` has run, when saved servers exist and it is not known yet
    /// whether they have agents. The window shows a neutral background meanwhile, never the main window or the flow.
    public private(set) var isUndecided = false
    /// True while the signed-in device waits for approval from another device.
    public private(set) var needsApproval = false

    @ObservationIgnored private let defaults: UserDefaults
    /// The launch check runs once; after that only `replay()` brings the flow back.
    @ObservationIgnored private var evaluated = false

    /// The launch decision is made here from local data, so the first frame is already right:
    /// - done: the main window, at once;
    /// - not done, no saved servers: the flow, at once;
    /// - not done, saved servers: undecided until `evaluate` knows their agents.
    /// - Parameter hasSavedServers: whether the app has servers stored on this Mac (read before connecting).
    public init(defaults: UserDefaults = .standard, hasSavedServers: Bool = false) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.stepKey).flatMap(OnboardingStep.init(rawValue:))
        // "done" without the done flag is inconsistent: start the flow again from the first step.
        if let saved, saved != .done {
            step = saved
        } else {
            step = .welcome
        }
        let done = defaults.bool(forKey: Self.doneKey)
        isActive = !done && !hasSavedServers
        isUndecided = !done && hasSavedServers
    }

    /// True once the person has finished or skipped the flow.
    public var isDone: Bool {
        defaults.bool(forKey: Self.doneKey)
    }

    /// Launch check: the flow shows while it is not done and no server has an agent yet.
    public func evaluate(hasServerWithAgents: Bool) {
        guard !evaluated else { return }
        evaluated = true
        isActive = !isDone && !hasServerWithAgents
        isUndecided = false
    }

    /// Moves to the next step. Reaching `.done` finishes the flow.
    public func advance() {
        set(Self.nextStep(after: step, needsApproval: needsApproval))
        if step == .done { finish() }
    }

    /// The account step ended with a signed-in session. An unapproved device goes to the approval step.
    public func signedIn(deviceApproved: Bool) {
        needsApproval = !deviceApproved
        advance()
    }

    /// The session is too old for a reset (or was lost): back to the sign-in step.
    public func returnToSignIn() {
        needsApproval = false
        set(.account)
    }

    /// "Skip" on any step after welcome: the main window opens and the flow does not come back on launch.
    public func skip() {
        finish()
    }

    /// "Show the introduction again" from the Help menu: starts at welcome, whatever the server state.
    public func replay() {
        defaults.set(false, forKey: Self.doneKey)
        needsApproval = false
        set(.welcome)
        isActive = true
        isUndecided = false
    }

    /// The flow is over: the done flag is stored and the main window takes over.
    public func finish() {
        defaults.set(true, forKey: Self.doneKey)
        isActive = false
        set(.done)
    }

    private func set(_ next: OnboardingStep) {
        step = next
        defaults.set(next.rawValue, forKey: Self.stepKey)
    }

    /// The step after `step`. Approval is visited only when the device needs it.
    public static func nextStep(after step: OnboardingStep, needsApproval: Bool) -> OnboardingStep {
        switch step {
        case .welcome: .account
        case .account: needsApproval ? .approval : .server
        case .approval: .server
        case .server: .agent
        case .agent, .done: .done
        }
    }
}
