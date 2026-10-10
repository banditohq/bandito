import Foundation

/// What to do when a server refuses this Mac's device key (`FailureKind.keyRejected`).
public enum KeyRepair {
    public enum Action: Equatable, Sendable {
        /// Nothing to do: the failure is not a refused key.
        case none
        /// This Mac's own daemon: pair with it again through `LocalDaemonPairing` and replace the stored token.
        case repairThisMac
        /// Tell the person and offer "Connect again" — the add-server flow for a remote server, or the same
        /// pairing by hand for this Mac after an automatic try did not work.
        case offerReconnect
    }

    /// - Parameters:
    ///   - alreadyTried: an automatic repair of this server already ran since it last connected (one try per event).
    ///   - isQA: a QA copy never pairs with the installed daemon of this Mac.
    public static func action(for kind: FailureKind, config: ServerConfig, alreadyTried: Bool, isQA: Bool) -> Action {
        guard kind == .keyRejected else { return .none }
        guard canRepairThisMac(config, isQA: isQA), !alreadyTried else { return .offerReconnect }
        return .repairThisMac
    }

    /// This Mac's daemon behind a token (a WebSocket on loopback): the one server whose key the app can renew itself.
    public static func canRepairThisMac(_ config: ServerConfig, isQA: Bool) -> Bool {
        guard !isQA, LocalDaemonUpgrade.isThisMac(config), case .webSocket = config.endpoint else { return false }
        return true
    }

    /// The address for the add-server flow of a remote server, as the person would type it; nil when the saved
    /// endpoint has no usable address.
    public static func reconnectAddress(for config: ServerConfig) -> String? {
        guard case .remote(let address) = ServerAddress(endpoint: config.endpoint), address != "—" else { return nil }
        return address
    }
}
