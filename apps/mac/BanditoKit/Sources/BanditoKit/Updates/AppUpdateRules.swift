import BanditoL10n
import Foundation

/// Pure rules of the in-app update banner: what is shown in each phase, what the buttons may do, and how the
/// download's share is worked out. The views and `AppUpdateCenter` only ask these functions.
public enum AppUpdateRules {
    /// Where the release notes of a version live. A version string with anything but letters, digits and `.-+_`
    /// gets no link: it comes from the appcast, and it ends up inside a URL.
    public static func releaseNotesURL(version: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+_")
        guard !version.isEmpty, version.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return URL(string: "https://github.com/banditohq/bandito/releases/tag/v\(version)")
    }

    // MARK: Visibility and actions

    /// The banner is on screen in every phase but `idle`.
    public static func isVisible(_ phase: AppUpdateCenter.Phase) -> Bool {
        phase != .idle
    }

    /// A person is waiting for something: a check, a download, a preparation or the restart.
    public static func isBusy(_ phase: AppUpdateCenter.Phase) -> Bool {
        switch phase {
        case .checking, .downloading, .preparing, .installing: true
        case .idle, .available, .upToDate, .failed: false
        }
    }

    /// "Update" works only while a version is on offer.
    public static func canInstall(_ phase: AppUpdateCenter.Phase) -> Bool {
        if case .available = phase { return true }
        return false
    }

    /// A new check may start from rest, after "up to date" and after a failure.
    public static func canCheck(_ phase: AppUpdateCenter.Phase) -> Bool {
        switch phase {
        case .idle, .upToDate, .failed: true
        case .checking, .available, .downloading, .preparing, .installing: false
        }
    }

    /// The cross: not while the app prepares the install or restarts, which cannot be taken back.
    public static func canDismiss(_ phase: AppUpdateCenter.Phase) -> Bool {
        switch phase {
        case .available, .checking, .downloading, .upToDate, .failed: true
        case .idle, .preparing, .installing: false
        }
    }

    /// The spinner stands for waiting without a share to show.
    public static func showsSpinner(_ phase: AppUpdateCenter.Phase) -> Bool {
        switch phase {
        case .checking, .preparing, .installing: true
        case .idle, .available, .downloading, .upToDate, .failed: false
        }
    }

    /// The "What's new" link: only for an offered version that has a release page.
    public static func releaseNotesURL(for phase: AppUpdateCenter.Phase) -> URL? {
        guard case .available(let version) = phase else { return nil }
        return releaseNotesURL(version: version)
    }

    /// Which layout the phase uses. The banner animates a change of layout, not each step of the download.
    public static func layoutKey(_ phase: AppUpdateCenter.Phase) -> Int {
        switch phase {
        case .idle: 0
        case .checking: 1
        case .available: 2
        case .downloading: 3
        case .preparing: 4
        case .installing: 5
        case .upToDate: 6
        case .failed: 7
        }
    }

    // MARK: Words and picture

    /// SF Symbol of the phase's round badge.
    public static func symbol(for phase: AppUpdateCenter.Phase) -> String {
        switch phase {
        case .upToDate: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .checking, .available, .downloading, .preparing, .installing: "arrow.down.circle.fill"
        }
    }

    /// The first line of the banner and of the Settings row.
    public static func title(for phase: AppUpdateCenter.Phase) -> String? {
        switch phase {
        case .idle: nil
        case .checking: L10n.AppUpdate.checking
        case .available(let version): L10n.AppUpdate.available(version: version)
        case .downloading: L10n.AppUpdate.downloading
        case .preparing: L10n.AppUpdate.preparing
        case .installing: L10n.AppUpdate.installing
        case .upToDate: L10n.AppUpdate.upToDate
        case .failed: L10n.AppUpdate.failed
        }
    }

    /// The second line: what is offered, or what went wrong (the error's text, or a plain hint when it has none).
    public static func subtitle(for phase: AppUpdateCenter.Phase) -> String? {
        switch phase {
        case .available: L10n.AppUpdate.availableHint
        case .failed(let message):
            message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L10n.AppUpdate.failedHint : message
        case .idle, .checking, .downloading, .preparing, .installing, .upToDate: nil
        }
    }

    // MARK: Download share

    /// The share of the download, 0 to 1. Nil when the length is not known (0), so the bar is indeterminate.
    public static func fraction(received: UInt64, expected: UInt64) -> Double? {
        guard expected > 0 else { return nil }
        return min(max(Double(received) / Double(expected), 0), 1)
    }

    /// Whole percent of a share, rounded down (so 100 only at the very end), clamped to 0...100. Nil without a share.
    public static func percent(_ fraction: Double?) -> Int? {
        guard let fraction, fraction.isFinite else { return nil }
        return Int((min(max(fraction, 0), 1) * 100).rounded(.down))
    }

    /// The label next to the bar ("45%"), or nil while the share is not known.
    public static func percentText(_ fraction: Double?) -> String? {
        percent(fraction).map { L10n.AppUpdate.percent(percent: String($0)) }
    }

    /// Whether a new share is worth a re-render: the whole percent changed, or the share became known or unknown.
    /// Sparkle reports every chunk of data; most of them move the bar by less than a percent.
    public static func shouldPublish(old: Double?, new: Double?) -> Bool {
        percent(old) != percent(new)
    }
}

/// Counts the bytes of one download and gives the share of it.
public struct AppUpdateDownload: Equatable, Sendable {
    public private(set) var expected: UInt64 = 0
    public private(set) var received: UInt64 = 0

    public init() {}

    /// The announced length of the file. A new download starts from zero bytes.
    public mutating func expect(_ length: UInt64) {
        expected = length
        received = 0
    }

    /// A chunk arrived. The sum never overflows.
    public mutating func receive(_ length: UInt64) {
        let (sum, overflow) = received.addingReportingOverflow(length)
        received = overflow ? UInt64.max : sum
    }

    public var fraction: Double? {
        AppUpdateRules.fraction(received: received, expected: expected)
    }
}
