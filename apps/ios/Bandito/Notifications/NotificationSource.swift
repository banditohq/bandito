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
