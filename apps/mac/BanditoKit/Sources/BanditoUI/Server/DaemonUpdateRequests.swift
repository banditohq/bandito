import BanditoKit
import BanditoL10n
import SwiftUI

// The one way to update a remote server's daemon: every screen that offers it (Server → Overview, Server → Updates,
// the sidebar banner, the server menu) asks for the same confirmation and runs `AppModel.daemonUpdate`.

/// An update the person was asked to confirm: the server and the release it would install.
struct DaemonUpdateAsk: Identifiable {
    let server: ServerModel
    let offer: DaemonUpdate
    var id: UUID { server.id }
}

extension AppModel {
    /// The daemon update a server offers now: its live offer when it is connected, or the outcome of the update this app
    /// ran on it. `isLive` is false for the outcome. Nothing for this Mac, whose daemon is replaced from the app bundle.
    func daemonOffer(for server: ServerModel) -> (offer: DaemonUpdate, isLive: Bool)? {
        guard !localUpgrade.replacesOffer(for: server) else { return nil }
        let live = server.isConnectedNow ? server.daemonUpdateOffer : nil
        guard let offer = daemonUpdate.shownOffer(current: live, serverID: server.id) else { return nil }
        return (offer, live != nil)
    }

    /// The servers as the banner rule reads them (see `UpdateBannerRule`).
    var serverUpdateCandidates: [ServerUpdateCandidate] {
        servers.map { server in
            let shown = daemonOffer(for: server)
            return ServerUpdateCandidate(
                id: server.id, name: ServerPicker.name(server), version: shown?.offer.latest, isLive: shown?.isLive ?? false)
        }
    }

    /// Asks the person to confirm `offer` on `server`. The main window shows the dialog (`PendingDaemonUpdateDialog`).
    func askDaemonUpdate(_ server: ServerModel, offer: DaemonUpdate) {
        guard !daemonUpdate.isBusy else { return }
        daemonUpdateAsk = DaemonUpdateAsk(server: server, offer: offer)
    }

    /// The person confirmed the pending update: it runs, with the progress shown by every banner of that server.
    func confirmDaemonUpdate() {
        guard let ask = daemonUpdateAsk else { return }
        daemonUpdateAsk = nil
        Task { await daemonUpdate.run(ask.server, offer: ask.offer) }
    }
}

/// The confirmation before a daemon update: its title names the version, then Update or Cancel.
struct DaemonUpdateConfirmation: ViewModifier {
    @Binding var isPresented: Bool
    let version: String
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            L10n.Server.DaemonUpdate.confirmTitle(version: version),
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button(L10n.Server.DaemonUpdate.confirm, action: onConfirm)
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Server.DaemonUpdate.confirmMessage)
        }
    }
}

/// The confirmation of an update asked from the sidebar or the server menu. Attached to the main window only: the
/// Settings window has its own screens, which confirm with `DaemonUpdateConfirmation` where they stand.
struct PendingDaemonUpdateDialog: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        let ask = app.daemonUpdateAsk
        content.modifier(DaemonUpdateConfirmation(
            isPresented: Binding(
                get: { ask != nil },
                set: { if !$0 { app.daemonUpdateAsk = nil } }),
            version: ask?.offer.latest ?? "",
            onConfirm: { app.confirmDaemonUpdate() }))
    }
}
