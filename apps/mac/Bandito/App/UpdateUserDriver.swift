import AppKit
import BanditoKit
import Sparkle

/// Sparkle's user interface, without Sparkle's windows: every call of the updater becomes a phase of the
/// `AppUpdateCenter`, which the sidebar banner and Settings draw. The person's choices come back through
/// `installTapped()` and `dismissTapped()`.
///
/// Every reply Sparkle hands over is kept in one place and cleared the moment it is used, so a double click or a
/// late call cannot answer twice.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    private let center: AppUpdateCenter

    /// The answer to "an update was found", while the banner offers it.
    private var foundReply: ((SPUUserUpdateChoice) -> Void)?
    /// The answer to "ready to install", kept only if the person did not ask for the install yet.
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var checkCancellation: (() -> Void)?
    private var downloadCancellation: (() -> Void)?
    private var foundStage: SPUUserUpdateStage = .notDownloaded
    private var offeredVersion = ""
    /// Set by "Update"; until then nothing downloads or installs on its own account.
    private var installRequested = false
    private var download = AppUpdateDownload()

    init(center: AppUpdateCenter) {
        self.center = center
        super.init()
    }

    // MARK: What the person does

    /// "Update". Answers the offer with "install"; a second call finds no reply and does nothing.
    func installTapped() {
        if let reply = foundReply {
            foundReply = nil
            installRequested = true
            switch foundStage {
            case .notDownloaded: center.setPhase(.downloading(fraction: nil))
            case .downloaded: center.setPhase(.preparing)
            case .installing: center.setPhase(.installing)
            @unknown default: center.setPhase(.downloading(fraction: nil))
            }
            reply(.install)
        } else if let reply = readyReply {
            readyReply = nil
            installRequested = true
            center.setPhase(.installing)
            reply(.install)
        }
    }

    /// The cross. "Later" for an offer (Sparkle reminds at the next planned check), a cancel while checking or
    /// downloading, a plain close for "up to date" and for a failure.
    func dismissTapped() {
        if let reply = foundReply {
            foundReply = nil
            installRequested = false
            reply(.dismiss)
            center.setPhase(.idle)
        } else if let reply = readyReply {
            readyReply = nil
            installRequested = false
            reply(.dismiss)
            center.setPhase(.idle)
        } else {
            switch center.phase {
            case .checking:
                let cancel = checkCancellation
                checkCancellation = nil
                center.setPhase(.idle)
                cancel?()
            case .downloading:
                let cancel = downloadCancellation
                downloadCancellation = nil
                installRequested = false
                center.setPhase(.idle)
                cancel?()
            case .upToDate, .failed, .available:
                center.setPhase(.idle)
            case .idle, .preparing, .installing:
                break
            }
        }
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // The switch in Settings is the person's answer; nothing about this Mac is sent.
        reply(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: AppUpdatePreferences.automaticChecks(), sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        checkCancellation = cancellation
        center.setPhase(.checking)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        foundReply = reply
        foundStage = state.stage
        offeredVersion = appcastItem.displayVersionString
        installRequested = false
        download = AppUpdateDownload()
        center.setPhase(.available(version: offeredVersion))
    }

    // The banner links to the release page; the notes themselves are not shown.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // "You have the latest version" only answers a check the person started.
        if center.phase == .checking {
            center.setPhase(.upToDate)
        } else {
            settleQuietly()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        // A failure is news only for someone who asked for something. A background check without a network says
        // nothing.
        if AppUpdateRules.isBusy(center.phase) {
            center.setPhase(.failed(error.localizedDescription))
        } else {
            settleQuietly()
        }
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        downloadCancellation = cancellation
        download = AppUpdateDownload()
        if installRequested { center.setPhase(.downloading(fraction: nil)) }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        download.expect(expectedContentLength)
        center.updateDownload(fraction: download.fraction)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        download.receive(length)
        center.updateDownload(fraction: download.fraction)
    }

    func showDownloadDidStartExtractingUpdate() {
        downloadCancellation = nil
        if installRequested { center.setPhase(.preparing) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installRequested {
            // The person already pressed "Update": go on without asking again.
            center.setPhase(.installing)
            reply(.install)
        } else {
            readyReply = reply
            center.setPhase(.available(version: offeredVersion))
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        center.setPhase(.installing)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {
        NSApp.activate()
    }

    func dismissUpdateInstallation() {
        foundReply = nil
        readyReply = nil
        checkCancellation = nil
        downloadCancellation = nil
        installRequested = false
        settleQuietly()
    }

    /// Back to nothing, except a result the person has not read yet ("up to date", a failure).
    private func settleQuietly() {
        switch center.phase {
        case .upToDate, .failed: break
        default: center.setPhase(.idle)
        }
    }
}
