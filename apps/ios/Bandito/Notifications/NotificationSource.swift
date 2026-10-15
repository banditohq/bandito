import BanditoKit
import Foundation

/// Where the phone's notifications and the background check get their servers. Now: the servers the launch gives
/// (the demo world, or none). The paired servers come with the pairing work (docs/IOS_APP.md, Key flows).
@MainActor
protocol NotificationSource: AnyObject {
    /// The servers of this launch, each with its agents and threads.
    var servers: [ServerModel] { get }

    /// The events of one server after `seq`, read from the server for the background check (`events.since`).
    /// Throws when the server cannot be reached. The default source reads nothing.
    func events(after seq: Int64, serverID: UUID) async throws -> [Event]

    /// The server a press on a notification's button is for, ready to be spoken to: the button can wake the app with no screen
    /// and no connection. `serverRef` is the server's id that the notification carries (`userInfo["server"]`): the server is
    /// that one, even when its agent list is not known yet (the saved copy lacks the agent) and when another server has an
    /// agent with the same id. A notification without it (an older local one) finds the server by its agent.
    func readyServer(serverRef: String?, agentID: String) async -> ServerModel?
}

extension NotificationSource {
    func readyServer(serverRef: String?, agentID: String) async -> ServerModel? {
        Self.pick(from: servers, serverRef: serverRef, agentID: agentID)
    }

    /// The server named by `serverRef`, else the first that has the agent.
    static func pick(from servers: [ServerModel], serverRef: String?, agentID: String) -> ServerModel? {
        if let serverRef, !serverRef.isEmpty, let named = servers.first(where: { $0.id.uuidString == serverRef }) {
            return named
        }
        return servers.first { server in server.agents.contains { $0.id == agentID } }
    }
}

/// A fixed list of servers. With none, no notice is made and the background check does nothing.
@MainActor
final class StaticNotificationSource: NotificationSource {
    let servers: [ServerModel]

    init(servers: [ServerModel] = []) {
        self.servers = servers
    }

    func events(after seq: Int64, serverID: UUID) async throws -> [Event] {
        []
    }
}
