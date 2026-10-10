import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Updates a server's daemon from the Updates screens (Server → Updates and Settings → Updates). The button is the way
/// to update. This Mac's server takes the daemon of the app bundle, as the automatic upgrade does. A remote server gets
/// its daemon's own release through `daemon.update_apply`, after a confirmation. The install command for a terminal is
/// a secondary "Вручную" disclosure for a remote server only: this Mac is never offered `curl … | sh`.
struct ServerUpdateActions: View {
    let server: ServerModel
    /// Opens the install command in the Terminals mode. Nil where the page cannot leave the screen it is on.
    var openInTerminal: (() -> Void)?

    @Environment(AppModel.self) private var app
    @State private var daemonUpdate = DaemonUpdateModel()
    @State private var release = ReleaseStatus()
    @State private var confirming = false
    @State private var manualOpen = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if server.isThisMacServer {
                LocalDaemonUpgradeBanner(server: server, model: app.localUpgrade)
                thisMacStatus
            } else {
                remoteStatus
                manualDisclosure
            }
        }
        .task(id: server.id) {
            if server.isThisMacServer {
                await app.localUpgrade.readBundled()
            } else {
                await release.load()
            }
        }
    }

    // MARK: - This Mac

    @ViewBuilder
    private var thisMacStatus: some View {
        switch app.localUpgrade.standing(for: server) {
        case .checking:
            checkingLine
        case .unknown:
            failedLine { Task { await app.localUpgrade.readBundled() } }
        case .upToDate:
            statusLine(title: L10n.Updates.upToDate, action: nil)
        case .due:
            if localBusy {
                statusLine(title: L10n.Updates.available, action: nil)
            } else {
                statusLine(title: L10n.Updates.available, action: LineAction(title: L10n.Server.DaemonUpdate.button) {
                    Task { await app.localUpgrade.upgradeByRequest(server) }
                })
            }
        }
    }

    /// A button at the end of a status line.
    private struct LineAction {
        var title: String
        var run: () -> Void
    }

    /// The status of this Mac's server with its note, and one action when there is one.
    private func statusLine(title: String, action: LineAction?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.Updates.thisMacNote)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run)
                    .banditoButton(.lightPill())
                    .fixedSize()
                    .disabled(!server.isConnectedNow)
            }
        }
    }

    private var checkingLine: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.Updates.checking)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
        }
    }

    /// The check did not give an answer: say so, and offer a new check. Never "up to date" without a known version.
    private func failedLine(retry: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.Updates.checkFailed)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.Banner.retry, action: retry)
                .banditoButton(.lightPill())
                .fixedSize()
        }
    }

    /// The upgrade of this server is waiting for agents or running: its banner says so, the button steps back.
    private var localBusy: Bool {
        switch app.localUpgrade.phase {
        case .waitingForAgents(let id, _), .upgrading(let id, _): id == server.id
        case .idle, .failed: false
        }
    }

    // MARK: - Remote

    @ViewBuilder
    private var remoteStatus: some View {
        let offer = DaemonUpdateOffer.offer(for: server.info)
        if let offer {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(L10n.Server.DaemonUpdate.title(latest: offer.latest, current: offer.current))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if !daemonUpdate.isBusy {
                        Button(L10n.Server.DaemonUpdate.button) { confirming = true }
                            .banditoButton(.lightPill())
                            .fixedSize()
                    }
                }
                if let status = DaemonUpdateModel.statusText(for: daemonUpdate.phase) {
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let failure) = daemonUpdate.phase {
                    UserFacingErrorView(message: failure.wrapped { L10n.Server.DaemonUpdate.failed(error: $0) })
                }
            }
            .confirmationDialog(
                L10n.Server.DaemonUpdate.confirmTitle(version: offer.latest),
                isPresented: $confirming,
                titleVisibility: .visible
            ) {
                Button(L10n.Server.DaemonUpdate.confirm) {
                    Task { await daemonUpdate.run(server, offer: offer) }
                }
                Button(L10n.Common.cancel, role: .cancel) {}
            } message: {
                Text(L10n.Server.DaemonUpdate.confirmMessage)
            }
        } else if server.info == nil {
            Text(L10n.Server.notConnected)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
        } else {
            switch ReleaseFeed.standing(installed: server.info?.version, latest: release.latest) {
            case .available(let latest):
                // The server's daemon reports no release of its own: the newest one is only known from GitHub.
                Text(L10n.Server.Update.available(version: latest.description))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
            case .upToDate:
                Text(L10n.Updates.upToDate)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.text)
            case .unknown:
                if release.checked {
                    failedLine { Task { await release.load() } }
                } else {
                    checkingLine
                }
            }
        }
    }

    /// The install command for a terminal, behind "Вручную". Only for a remote server.
    private var manualDisclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                manualOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: manualOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(L10n.Updates.manual)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .banditoButton(.link)
            if manualOpen {
                Text(L10n.Updates.howText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReleaseFeed.installCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(spacing: 10) {
                    Button(L10n.Updates.copyCommand) {
                        SystemActions.copy(ReleaseFeed.installCommand)
                        copied = true
                    }
                    .banditoButton(.quiet())
                    .fixedSize()
                    if let openInTerminal {
                        Button(L10n.Updates.howButton, action: openInTerminal)
                            .banditoButton(.quiet())
                            .fixedSize()
                    }
                    if copied {
                        Text(L10n.Updates.copied)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
            }
        }
    }
}
