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
    /// How often a quiet check runs while the app is open. Sparkle's own schedule does not go below an hour, so the
    /// app keeps its own: a new version shows in the banner within ten minutes of its release, and at once when the
    /// person comes back to the app or the Mac wakes (`quietCheck`).
    static let periodicCheckInterval: Duration = .seconds(10 * 60)
    /// The least time between two quiet checks, so switching apps back and forth does not fetch the feed each time.
    static let quietCheckGap: Duration = .seconds(2 * 60)

    private let channels = UpdateChannelDelegate()
    private let driver: UpdateUserDriver
    private let updater: SPUUpdater
    /// False when Sparkle could not start (a broken bundle, a missing key): then there is no banner and the menu
    /// item does nothing.
    private var started = false
    private var preferencesObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    /// When the last quiet check started (`quietCheck`).
    private var lastQuietCheck: ContinuousClock.Instant?
    private var launchCheck: Task<Void, Never>?
    private var periodicCheck: Task<Void, Never>?

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
        // Back to the app, or the Mac woke up: a release that came out meanwhile shows without a restart.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietCheck() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietCheck() }
        }
        scheduleLaunchCheck()
        schedulePeriodicChecks()
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
            self?.quietCheck()
        }
    }

    /// A background check when automatic checks are on, Sparkle is free (no check, offer or install under way) and
    /// the last quiet check is at least `quietCheckGap` old. A found update shows in the banner; nothing else does.
    private func quietCheck(now: ContinuousClock.Instant = .now) {
        guard started, AppUpdatePreferences.automaticChecks(), updater.canCheckForUpdates else { return }
        if let last = lastQuietCheck, now - last < Self.quietCheckGap { return }
        lastQuietCheck = now
        updater.checkForUpdatesInBackground()
    }

    /// Every ten minutes, a quiet check while automatic checks are on. Sparkle skips a check while another one or an
    /// install is under way, so a tick during an update does nothing.
    private func schedulePeriodicChecks() {
        periodicCheck = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: Self.periodicCheckInterval) } catch { return }
                guard let self else { return }
                self.quietCheck()
            }
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
