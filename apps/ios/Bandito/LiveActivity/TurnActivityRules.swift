import BanditoKit
import Foundation

/// When a long turn gets a Live Activity and what it says: pure rules, no ActivityKit, so the tests can run them.
/// `TurnActivities` applies them.
enum TurnActivityRules {
    typealias Phase = TurnActivityAttributes.Phase

    /// A turn shorter than this never shows an activity.
    static let startAfter: TimeInterval = 30
    /// The line "what it does now" changes at most this often.
    static let doingInterval: TimeInterval = 5
    /// At most this many activities run (or wait for the person) at once; more are not started.
    static let maxRunning = 3
    /// The system removes an ended activity after this long: 15 minutes, and an hour when it ends on "needs you".
    static let finalStay: TimeInterval = 15 * 60
    static let needsYouStay: TimeInterval = 60 * 60
    /// The longest line the activity carries (its state is capped at 4 KB by the system).
    static let doingLimit = 120

    /// What to do when a turn may be due an activity.
    enum StartAction: Equatable {
        case none
        /// No activity of this agent yet: request one.
        case start
        /// An activity of this agent ended (done, failed, waiting): take it off and start a fresh one, so one agent has one.
        case restart
    }

    /// Whether a turn that has run for `elapsed` seconds gets an activity now.
    /// - existing: the phase of this agent's activity, nil without one.
    /// - running: how many activities are running or waiting for the person (all agents).
    /// - dismissedThisTurn: the person swiped this turn's activity away; it does not come back for the same turn.
    static func startAction(
        elapsed: TimeInterval, appActive: Bool, enabled: Bool, existing: Phase?, running: Int, dismissedThisTurn: Bool
    ) -> StartAction {
        guard enabled, appActive, !dismissedThisTurn, elapsed >= startAfter else { return .none }
        switch existing {
        case nil:
            return running < maxRunning ? .start : .none
        case .running, .needsYou:
            // The turn still has its activity (a turn that waits for the person is the same turn).
            return .none
        case .done, .failed:
            return .restart
        }
    }

    /// Seconds until a turn that began at `startedAt` is due its activity, never negative.
    static func delayUntilDue(startedAt: Date, now: Date) -> TimeInterval {
        max(0, startedAt.addingTimeInterval(startAfter).timeIntervalSince(now))
    }

    /// A start in the future (the server's clock is ahead of the phone's) counts as now, so the timer never shows a
    /// negative time.
    static func clampedStart(_ startedAt: Date, now: Date) -> Date {
        min(startedAt, now)
    }

    /// Whether the "doing" line is replaced now: only when the text changed and the last change was `doingInterval` ago.
    static func shouldUpdateDoing(current: String, new: String, lastUpdate: Date?, now: Date) -> Bool {
        guard new != current else { return false }
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) >= doingInterval
    }

    /// Seconds until a changed line may be shown (0: now). The controller waits that long, then shows the newest line.
    static func doingWait(lastUpdate: Date?, now: Date) -> TimeInterval {
        guard let lastUpdate else { return 0 }
        return max(0, doingInterval - now.timeIntervalSince(lastUpdate))
    }

    /// The line as the activity carries it: one line, trimmed, capped.
    static func clean(_ doing: String) -> String {
        let oneLine = doing.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(doingLimit))
    }

    /// The phase an event moves the turn to; nil when the event does not change it.
    /// `stillWaiting`: the agent still has an approval, form or connect request of the person's to answer.
    static func phase(after body: EventBody, stillWaiting: Bool) -> Phase? {
        switch body {
        case .turnCompleted(_, let status, _, _):
            if status != .ok { return .failed }
            return stillWaiting ? .needsYou : .done
        case .approvalRequested, .formRequested:
            return .needsYou
        case .agentStatus(let status, _):
            switch status {
            case .needsYou: return .needsYou
            case .working: return stillWaiting ? .needsYou : .running
            case .idle, .error, .offline: return nil
            }
        case .approvalResolved, .approvalWithdrawn, .formAnswered:
            return stillWaiting ? .needsYou : .running
        default:
            return nil
        }
    }

    /// Whether the phase ends the turn's activity.
    static func isFinal(_ phase: Phase) -> Bool {
        phase == .done || phase == .failed
    }

    /// How long the system keeps an activity that ended in `phase`; nil while it is not over.
    static func dismissal(for phase: Phase) -> TimeInterval? {
        switch phase {
        case .running: nil
        case .done, .failed: finalStay
        case .needsYou: needsYouStay
        }
    }

    /// An activity left by an app the system killed: its server is gone, or its server is connected and the agent has no
    /// turn running. A server that is not connected tells nothing yet, so its activities stay.
    static func isOrphan(phase: Phase, serverKnown: Bool, serverConnected: Bool, turnRunning: Bool) -> Bool {
        guard phase == .running || phase == .needsYou else { return false }
        if !serverKnown { return true }
        return serverConnected && !turnRunning
    }
}
