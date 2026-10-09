import BanditoDesign
import BanditoKit
import BanditoL10n
import Observation
import SwiftUI

/// "Update server": asks the daemon to install its newer release, then waits for the server to come back on it.
@MainActor
@Observable
final class DaemonUpdateModel {
    enum Phase: Equatable {
        case idle
        /// The daemon is downloading and checking the release.
        case updating
        /// The daemon has answered and restarts: the link drops and comes back.
        case restarting
        case done(version: String)
        /// Installed, but no service manager restarts the daemon, so the new binary waits for a manual restart.
        case manualRestart(version: String)
        case timedOut(version: String)
        case failed(UserFacingMessage)
    }

    private(set) var phase: Phase = .idle
    /// The release the last update installs, and the server it runs on.
    private(set) var target: DaemonUpdate?
    private(set) var serverID: UUID?

    /// How long to wait for the server to come back on the new version.
    static let returnTimeout: Duration = .seconds(120)

    var isBusy: Bool { phase == .updating || phase == .restarting }

    /// The offer the banner shows: the daemon's current offer, or, after an update on this server, that update's
    /// outcome until the user leaves the screen (the daemon no longer offers a release it has just installed).
    func shownOffer(current: DaemonUpdate?, serverID id: UUID) -> DaemonUpdate? {
        if let current { return current }
        guard phase != .idle, serverID == id else { return nil }
        return target
    }

    /// The line that reports the update's progress or outcome, or nil when there is nothing to say.
    static func statusText(for phase: Phase) -> String? {
        switch phase {
        case .idle: nil
        case .updating: L10n.Server.DaemonUpdate.updating
        case .restarting: L10n.Server.DaemonUpdate.restarting
        case .done(let version): L10n.Server.DaemonUpdate.done(version: version)
        case .manualRestart(let version): L10n.Server.DaemonUpdate.manualRestart(version: version)
        case .timedOut(let version): L10n.Server.DaemonUpdate.timedOut(version: version)
        case .failed(let message): L10n.Server.DaemonUpdate.failed(error: message.text)
        }
    }

    func run(_ server: ServerModel, offer: DaemonUpdate) async {
        guard !isBusy else { return }
        target = offer
        serverID = server.id
        phase = .updating
        do {
            guard try await server.updateDaemon(to: offer.latest) else {
                phase = .manualRestart(version: offer.latest)
                return
            }
            phase = .restarting
            let deadline = ContinuousClock.now.advanced(by: Self.returnTimeout)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(1))
                if DaemonUpdateOffer.isApplied(server.info, target: offer.latest) {
                    phase = .done(version: offer.latest)
                    return
                }
            }
            phase = .timedOut(version: offer.latest)
        } catch {
            phase = .failed(UserFacingError.message(for: error))
        }
    }
}

/// Server → Overview: the daemon's newer release, and the button that installs it after a confirmation.
/// It shows nothing when there is no offer and no update in progress.
struct DaemonUpdateBanner: View {
    let server: ServerModel
    let model: DaemonUpdateModel
    @State private var confirming = false

    var body: some View {
        let current = DaemonUpdateOffer.offer(for: server.info)
        if let offer = model.shownOffer(current: current, serverID: server.id) {
            let status = DaemonUpdateModel.statusText(for: model.phase)
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Bandito.signal)
                VStack(alignment: .leading, spacing: 2) {
                    // Once the daemon no longer offers the release, only its outcome is left to say.
                    Text(current == nil ? (status ?? "") : L10n.Server.DaemonUpdate.title(latest: offer.latest, current: offer.current))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                    if current != nil, case .failed(let failure) = model.phase {
                        UserFacingErrorView(message: failure.wrapped { L10n.Server.DaemonUpdate.failed(error: $0) })
                    } else if current != nil, let status {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Bandito.text2)
                    }
                }
                Spacer(minLength: 8)
                if current != nil, !model.isBusy {
                    Button(L10n.Server.DaemonUpdate.button) { confirming = true }
                        .buttonStyle(LightPillButtonStyle())
                }
            }
            .padding(14)
            .background(Color.Bandito.signal.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.Bandito.signal.opacity(0.28), lineWidth: 1))
            .confirmationDialog(
                L10n.Server.DaemonUpdate.confirmTitle(version: offer.latest),
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(L10n.Server.DaemonUpdate.confirm) {
                    Task { await model.run(server, offer: offer) }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Server.DaemonUpdate.confirmMessage)
            }
        }
    }
}
