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

    /// Reads the saved servers when the app was woken without its screens, and connects the one that has the agent (its
    /// agent list is the saved copy until then, so the agent is found before the connection is up).
    func readyServer(forAgent agentID: String) async -> ServerModel? {
        session.loadIfNeeded()
        guard let server = servers.first(where: { server in server.agents.contains { $0.id == agentID } }) else { return nil }
        if server.state != .connected { await server.connect() }
        // A connection that was already under way (`connect` returns at once then) is waited for, for 15 seconds at most.
        for _ in 0..<100 where server.state != .connected {
            switch server.state {
            case .connecting, .reconnecting: try? await Task.sleep(for: .milliseconds(150))
            default: return server
            }
        }
        return server
    }
}
