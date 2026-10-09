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
    /// The tour over the main window runs after the first agent is created. Cleared by `endTour`.
    public private(set) var tourRequested = false
    /// True while the signed-in device waits for approval from another device.
    public private(set) var needsApproval = false

    @ObservationIgnored private let defaults: UserDefaults

    /// The launch decision, made once and for good here, from local data only:
    /// the main window when the flow is done or when servers are saved on this Mac; the flow otherwise.
    /// Connecting afterwards never switches it. If the person removes every server, nothing changes: the flow
    /// comes back only from the Help menu.
    /// - Parameter hasSavedServers: whether servers are stored on this Mac (read before connecting).
    public init(defaults: UserDefaults = .standard, hasSavedServers: Bool = false) {
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.stepKey).flatMap(OnboardingStep.init(rawValue:))
        // "done" without the done flag is inconsistent: start the flow again from the first step.
        if let saved, saved != .done {
            step = saved
        } else {
            step = .welcome
        }
        isActive = !(defaults.bool(forKey: Self.doneKey) || hasSavedServers)
    }

    /// True once the person has finished or skipped the flow.
    public var isDone: Bool {
        defaults.bool(forKey: Self.doneKey)
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
        tourRequested = false
        defaults.set(false, forKey: Self.doneKey)
        needsApproval = false
        set(.welcome)
        isActive = true
    }

    /// The first agent exists: the flow is done and the tour starts over the main window.
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
