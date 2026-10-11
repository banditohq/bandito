import AppKit
import BanditoKit
import OSLog
import Sparkle

/// The app's own updates (Sparkle 2): the appcast at `SUFeedURL`, EdDSA-checked archives, and the settings of
/// Settings → General (`AppUpdatePreferences`). Only this target links Sparkle. Sparkle runs without its own
/// windows: `UpdateUserDriver` turns what it reports into the phases of `center`, which the sidebar banner and
/// Settings show.
@MainActor
final class AppUpdater {
    /// What the banner and Settings read; the app puts it into the environment of every window.
    let center = AppUpdateCenter()

    private static let log = Logger(subsystem: "dev.bandito", category: "updates")
    /// How long after launch the background check runs.
    private static let launchCheckDelay: Duration = .seconds(5)

    private let channels = UpdateChannelDelegate()
    private let driver: UpdateUserDriver
    private let updater: SPUUpdater
    /// False when Sparkle could not start (a broken bundle, a missing key): then there is no banner and the menu
    /// item does nothing.
    private var started = false
    private var preferencesObserver: NSObjectProtocol?
    private var launchCheck: Task<Void, Never>?

    init() {
        driver = UpdateUserDriver(center: center)
        updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: channels)
        do {
            try updater.start()
            started = true
        } catch {
            Self.log.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        updater.automaticallyChecksForUpdates = AppUpdatePreferences.automaticChecks()
        center.bind(
            install: { [driver] in driver.installTapped() },
            dismiss: { [driver] in driver.dismissTapped() },
            check: { [weak self] in self?.checkForUpdates() })
        // Settings writes the choice to UserDefaults; the updater follows it without a restart.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyAutomaticChecks() }
        }
        scheduleLaunchCheck()
    }

    /// "Check for Updates…" in the menu, Settings and "Try again": the answer shows in the banner.
    func checkForUpdates() {
        guard started else { return }
        updater.checkForUpdates()
    }

    /// A few seconds after launch, a quiet check, when the person left automatic checks on. Sparkle's own schedule
    /// would wait for the next interval; the banner should not.
    private func scheduleLaunchCheck() {
        guard AppUpdatePreferences.automaticChecks() else { return }
        launchCheck = Task { [weak self] in
            do { try await Task.sleep(for: Self.launchCheckDelay) } catch { return }
            guard let self, AppUpdatePreferences.automaticChecks() else { return }
            self.updater.checkForUpdatesInBackground()
        }
    }

    private func applyAutomaticChecks() {
        let wanted = AppUpdatePreferences.automaticChecks()
        if updater.automaticallyChecksForUpdates != wanted {
            updater.automaticallyChecksForUpdates = wanted
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
