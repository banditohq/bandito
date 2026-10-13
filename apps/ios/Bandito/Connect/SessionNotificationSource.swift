import BanditoKit
import Foundation

/// The notifications' and the background check's servers: the ones the session holds (the paired ones, or the demo
/// world). The background check reads each server's events after its cursor straight from the server (`events.since`),
/// connecting it first when the app was woken without a connection.
@MainActor
final class SessionNotificationSource: NotificationSource {
    private let session: ServerSession

    init(session: ServerSession) {
        self.session = session
    }

    var servers: [ServerModel] { session.current }

    func events(after seq: Int64, serverID: UUID) async throws -> [Event] {
        guard let server = session.current.first(where: { $0.id == serverID }) else { return [] }
        if server.state != .connected { await server.connect() }
        return try await server.eventsSince(seq)
    }
}
