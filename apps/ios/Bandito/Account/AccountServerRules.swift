import BanditoKit
import BanditoL10n
import Foundation

/// What to say about a server of the account that this iPhone is not connected to.
enum AccountServerNote: Equatable {
    /// A request is written and the Mac has not answered yet (the first minutes).
    case waitingForMac
    /// The Mac has not answered for a long while: it is off or asleep.
    case macOffline
    /// No device wrote a way in from a phone for this server.
    case noRemoteAccess
    /// The account service is older than this app.
    case updateNeeded

    var text: String {
        switch self {
        case .waitingForMac: L10n.Ios.AccountServers.waiting
        case .macOffline: L10n.Ios.AccountServers.macOffline
        case .noRemoteAccess: L10n.Ios.AccountServers.noAccess
        case .updateNeeded: L10n.Ios.Account.Servers.updateNeeded
        }
    }

    /// Whether the line has a spinner: something is still going on.
    var isWorking: Bool { self == .waitingForMac }
}

struct AccountServerRow: Identifiable, Equatable {
    var id: UUID
    var name: String
    var note: AccountServerNote
}

/// Pure rules for the lines under the connected servers (Settings) and on the Crew tab before any server is connected.
enum AccountServerRules {
    /// The note for a status, or nil when the server needs no line (connected, or hidden by the person).
    /// `fastPolling` is the iPhone's fast stretch: past it a server still waiting means the Mac is not answering.
    static func note(for status: AccessServerState.Status, fastPolling: Bool) -> AccountServerNote? {
        switch status {
        case .connected, .hidden: nil
        case .waitingForMac: fastPolling ? .waitingForMac : .macOffline
        case .noRemoteAccess: .noRemoteAccess
        case .updateNeeded: .updateNeeded
        }
    }

    /// The servers of the account to list: not connected, not hidden, and not already held here (by id or as the same
    /// daemon) so a server added by hand is not shown twice. In the account's order.
    static func rows(
        from servers: [AccessServerState], fastPolling: Bool, holds: (UUID, SyncedPhone?) -> Bool
    ) -> [AccountServerRow] {
        servers.compactMap { server in
            guard let note = note(for: server.status, fastPolling: fastPolling), !holds(server.id, server.phone) else {
                return nil
            }
            let cleaned = ServerNameRules.clean(server.name)
            return AccountServerRow(id: server.id, name: cleaned.isEmpty ? server.name : cleaned, note: note)
        }
    }
}
