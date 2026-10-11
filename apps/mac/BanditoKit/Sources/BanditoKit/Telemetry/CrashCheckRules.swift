import Foundation

/// What to do with the crash reports found at a launch. Pure: the app runs the action.
public enum CrashCheck: Equatable, Sendable {
    /// The first check on this Mac: remember the time, report nothing. Old crashes are not sent.
    case baseline
    /// New reports, and the person was never asked: ask once. Nothing is remembered yet, so an unanswered question
    /// comes back at the next launch.
    case ask
    /// New reports and consent: send these (oldest first), then remember the newest time.
    case send([CrashReportFile])
    /// Declined, or nothing new. Remember `until` (the newest report) when there is one.
    case skip(until: Date?)
}

public enum CrashCheckRules {
    /// - Parameters:
    ///   - reports: the reports written after `seenAt` (see `CrashReportScanner.reports`).
    ///   - seenAt: the newest report handled so far, nil before the first check.
    ///   - consent: nil when the person was never asked.
    public static func plan(reports: [CrashReportFile], seenAt: Date?, consent: Bool?) -> CrashCheck {
        guard seenAt != nil else { return .baseline }
        let newest = reports.map(\.modified).max()
        guard !reports.isEmpty else { return .skip(until: nil) }
        switch consent {
        case nil: return .ask
        case false?: return .skip(until: newest)
        case true?: return .send(reports)
        }
    }
}
