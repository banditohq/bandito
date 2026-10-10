import BanditoKit
import BanditoL10n
import SwiftUI

/// What the notice for a refused key shows. A pure function of the server and the repair state, so the choice of
/// words and button is tested without a view.
struct KeyRejectedContent: Equatable {
    enum Button: Equatable {
        /// This Mac's server: pair with the daemon again, started by the person.
        case repairThisMac
        /// A remote server: the add-server flow, started with this address (nil: empty).
        case addServer(address: String?)
    }

    var message: UserFacingMessage
    /// The pairing is running: a spinner instead of the button.
    var busy: Bool
    var button: Button?

    static func make(for config: ServerConfig, repair: AppModel.KeyRepairPhase?, isQA: Bool) -> KeyRejectedContent {
        guard KeyRepair.canRepairThisMac(config, isQA: isQA) else {
            return KeyRejectedContent(
                message: UserFacingMessage(text: L10n.Failure.keyRejected), busy: false,
                button: .addServer(address: KeyRepair.reconnectAddress(for: config)))
        }
        switch repair {
        case .repairing?:
            return KeyRejectedContent(
                message: UserFacingMessage(text: L10n.Failure.keyRepairing), busy: true, button: nil)
        case .failed(let failure)?:
            return KeyRejectedContent(message: failure, busy: false, button: .repairThisMac)
        case nil:
            // The automatic try has not started yet (or was used up): the person can start it by hand.
            return KeyRejectedContent(
                message: UserFacingMessage(text: L10n.Failure.keyRejectedThisMac), busy: false,
                button: .repairThisMac)
        }
    }
}

/// "The server did not accept this Mac's key" with "Connect again". Replaces the plain "server does not answer" text.
struct KeyRejectedNotice: View {
    let server: ServerModel
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        let content = KeyRejectedContent.make(
            for: server.config, repair: app.keyRepair[server.id], isQA: QABuild.isRunningQA)
        VStack(spacing: 14) {
            UserFacingErrorView(message: content.message)
                .frame(maxWidth: 420)
            if content.busy {
                ProgressView().controlSize(.small)
            } else if let button = content.button {
                Button(L10n.Failure.connectAgain) { perform(button) }
                    .banditoButton(.quiet())
            }
        }
    }

    private func perform(_ button: KeyRejectedContent.Button) {
        switch button {
        case .repairThisMac:
            let id = server.id
            Task { await app.repairThisMac(id: id) }
        case .addServer(let address):
            router.addServerAddress = address
            router.sheet = .addServer
        }
    }
}
