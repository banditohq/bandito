import BanditoL10n
import SwiftUI

/// The app menu's "Check for Updates…", right under About. The check itself is Sparkle's, which the app target runs,
/// so this view-layer command only takes the action it is given.
@MainActor
public struct AppUpdateCommands: Commands {
    private let check: () -> Void

    public init(check: @escaping () -> Void) {
        self.check = check
    }

    public var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L10n.Menu.checkForUpdates) { check() }
        }
    }
}
