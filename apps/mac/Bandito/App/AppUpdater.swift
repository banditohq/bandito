import AppKit
import BanditoKit
import Sparkle

/// The app's own updates (Sparkle 2): the appcast at `SUFeedURL`, EdDSA-checked archives, and the settings of
/// Settings → General (`AppUpdatePreferences`). Only this target links Sparkle.
@MainActor
final class AppUpdater {
    private let channels = UpdateChannelDelegate()
    private let controller: SPUStandardUpdaterController
    private var preferencesObserver: NSObjectProtocol?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: channels, userDriverDelegate: nil)
        controller.updater.automaticallyChecksForUpdates = AppUpdatePreferences.automaticChecks()
        // Settings writes the choice to UserDefaults; the updater follows it without a restart.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAutomaticChecks() }
        }
    }

    /// The menu's "Check for Updates…": shows Sparkle's own window for the check and the install.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    private func applyAutomaticChecks() {
        let wanted = AppUpdatePreferences.automaticChecks()
        if controller.updater.automaticallyChecksForUpdates != wanted {
            controller.updater.automaticallyChecksForUpdates = wanted
        }
    }
}

/// Which appcast items this Mac may take: stable only, or stable plus the `beta` channel. Items without a channel
/// are stable releases and always allowed.
private final class UpdateChannelDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppUpdatePreferences.channel() == .beta ? [AppUpdatePreferences.Channel.beta.rawValue] : []
    }
}
