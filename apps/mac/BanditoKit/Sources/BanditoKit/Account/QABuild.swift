import Foundation

/// The QA copies of the debug app: `dev.bandito.mac.debug.qa<n>`, made by `scripts/qa/app.sh`, next to the installed
/// Bandito. They are debug builds for every purpose that keeps data apart: their Keychain names and secret files
/// (`KeychainNamespace`) carry their own prefix. A QA copy never installs Bandito on this Mac (`LocalInstaller`), and
/// never talks to this Mac's daemon through a `.local` server (`AppModel`), so it cannot reach the owner's
/// `~/.local/bin/bandito`, `~/.bandito` or launchd service.
///
/// Only n = 1…5 are QA copies (the tooling accepts no other n). In a release build every answer is "not QA".
public enum QABuild {
    private static let prefix = "dev.bandito.mac.debug.qa"

    /// The `<n>` of a QA bundle id (`dev.bandito.mac.debug.qa3` → 3), or nil for any other bundle id, including
    /// `qa0`, `qa01`, `qa6` and `qa12`.
    public static func index(bundleID: String?) -> Int? {
        #if DEBUG
        guard let bundleID, bundleID.hasPrefix(prefix) else { return nil }
        let digits = bundleID.dropFirst(prefix.count)
        guard digits.count == 1, let n = Int(digits), (1...5).contains(n) else { return nil }
        return n
        #else
        return nil
        #endif
    }

    /// Whether `bundleID` belongs to a QA copy.
    public static func isQA(bundleID: String?) -> Bool {
        index(bundleID: bundleID) != nil
    }

    /// Whether this process is a QA copy of the app. Always false in a release build.
    public static var isRunningQA: Bool {
        isQA(bundleID: Bundle.main.bundleIdentifier)
    }
}
