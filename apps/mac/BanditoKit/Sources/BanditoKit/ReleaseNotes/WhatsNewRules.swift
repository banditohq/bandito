import Foundation

/// When the "What's new" sheet appears after an update, as one pure function (`WhatsNewRules.decide`).
public enum WhatsNewRules {
    /// What the app does with the launch.
    public enum Decision: Equatable, Sendable {
        /// Nothing: this version was seen, or there is nothing to tell.
        case nothing
        /// Remember the version without showing anything (a new person, or a version without notes).
        case remember
        /// Not now: something else is on screen. Ask again when it is gone. Nothing is remembered.
        case wait
        /// Show the sheet: the current version, and below it the versions with notes that were skipped.
        case show(skipped: [String])
    }

    /// - Parameters:
    ///   - current: this app's version.
    ///   - lastSeen: the version the sheet was last shown for (or remembered at), nil if never stored.
    ///   - library: the notes in the app.
    ///   - wasDoneAtLaunch: the introduction was not in front at launch. False: a new person, no sheet for them.
    ///   - introductionActive: the introduction is on screen now.
    ///   - otherDialogOpen: the statistics notice, the crash question, the notifications question or another sheet is open.
    public static func decide(
        current: String, lastSeen: String?, library: ReleaseNotesLibrary, wasDoneAtLaunch: Bool,
        introductionActive: Bool, otherDialogOpen: Bool
    ) -> Decision {
        guard let now = SemanticVersion(current) else { return .nothing }
        var skipped: [String] = []
        if let lastSeen {
            // An unreadable stored value is treated as never stored by the next line; a newer or equal one is a
            // downgrade or the same version: nothing.
            if let seen = SemanticVersion(lastSeen) {
                guard seen < now else { return .nothing }
                skipped = library.skipped(after: lastSeen, before: current)
            }
        } else if !wasDoneAtLaunch {
            // A new person: the first launch ever. The version is remembered so that the next update is told.
            return .remember
        }
        guard library.notes(for: current) != nil else { return .remember }
        if introductionActive || otherDialogOpen { return .wait }
        return .show(skipped: skipped)
    }
}
