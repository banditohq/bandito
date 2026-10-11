import Foundation
import Observation

/// The state of the app's own update, as the sidebar banner and Settings show it. It knows nothing about Sparkle:
/// the app target's driver (`UpdateUserDriver`) sets the phase and binds the three actions, and the views call
/// `install()`, `dismiss()` and `check()`. One center serves every window, so they all show the same phase.
@MainActor
@Observable
public final class AppUpdateCenter {
    public enum Phase: Equatable, Sendable {
        /// Nothing to show.
        case idle
        /// A check the person started is running.
        case checking
        /// A newer version is on offer.
        case available(version: String)
        /// The archive is coming down. The share is 0...1, nil while the length is not known.
        case downloading(fraction: Double?)
        /// The archive is unpacked and checked.
        case preparing
        /// The new version is being put in place; the app restarts.
        case installing
        /// A check the person started found nothing newer. Goes back to `idle` by itself.
        case upToDate
        /// Something the person started did not work; the text is the reason.
        case failed(String)
    }

    public private(set) var phase: Phase = .idle

    @ObservationIgnored private var installAction: (@MainActor () -> Void)?
    @ObservationIgnored private var dismissAction: (@MainActor () -> Void)?
    @ObservationIgnored private var checkAction: (@MainActor () -> Void)?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let upToDateDelay: Duration

    /// - Parameter upToDateDelay: how long "up to date" stays before the banner goes away.
    public init(upToDateDelay: Duration = .seconds(4)) {
        self.upToDateDelay = upToDateDelay
    }

    /// The app target hands over what the buttons do. Without it (Sparkle did not start) they do nothing.
    public func bind(
        install: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void,
        check: @escaping @MainActor () -> Void
    ) {
        installAction = install
        dismissAction = dismiss
        checkAction = check
    }

    // MARK: Actions for the views

    /// "Update": only while a version is on offer, so a second click does nothing.
    public func install() {
        guard AppUpdateRules.canInstall(phase) else { return }
        installAction?()
    }

    /// The cross: "later" for an offered version, a cancel while checking or downloading, a close otherwise.
    public func dismiss() {
        guard AppUpdateRules.canDismiss(phase) else { return }
        if let dismissAction {
            dismissAction()
        } else {
            setPhase(.idle)
        }
    }

    /// A check the person asks for (Settings, "Try again").
    public func check() {
        guard AppUpdateRules.canCheck(phase) else { return }
        checkAction?()
    }

    // MARK: For the driver

    /// Moves to a phase. The same phase again changes nothing (no re-render). Any phase cancels the pending
    /// "up to date" timer; `upToDate` starts a new one.
    public func setPhase(_ new: Phase) {
        guard new != phase else { return }
        expiry?.cancel()
        expiry = nil
        phase = new
        if new == .upToDate {
            let delay = upToDateDelay
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: delay) } catch { return }
                self?.expireUpToDate()
            }
        }
    }

    /// A new share of the download. Only while downloading, and only when the whole percent changed: Sparkle
    /// reports every chunk, and each write re-renders the sidebar.
    public func updateDownload(fraction: Double?) {
        guard case .downloading(let old) = phase, AppUpdateRules.shouldPublish(old: old, new: fraction) else { return }
        phase = .downloading(fraction: fraction)
    }

    private func expireUpToDate() {
        guard phase == .upToDate else { return }
        expiry = nil
        phase = .idle
    }
}
