import BanditoKit
import BanditoL10n

/// Pause and resume from the sidebar, the Inspector, the menus, the palette and `/pause`. One switch:
/// each call flips the agent's state (see docs/ARCHITECTURE.md#pause).
@MainActor
enum PauseActions {
    /// Whether the server can pause at all. Older servers do not know the method.
    static func available(on server: ServerModel?) -> Bool {
        server?.supports("pause") == true
    }

    /// Pauses `agent`, or resumes it when it is paused. A failure is passed to `failure`.
    static func toggle(_ agent: Agent, on server: ServerModel, failure: @escaping (UserFacingMessage) -> Void = { _ in }) {
        Task {
            do {
                try await server.setPaused(agentID: agent.id, !agent.paused)
            } catch {
                failure(UserFacingError.message(for: error))
            }
        }
    }

    /// Whether every agent of the server is paused: then "pause all" resumes them.
    static func allPaused(_ server: ServerModel) -> Bool {
        !server.agents.isEmpty && server.agents.allSatisfy(\.paused)
    }

    /// Pauses every agent of the server, or resumes them all when all are paused already.
    static func toggleAll(on server: ServerModel, failure: @escaping (UserFacingMessage) -> Void = { _ in }) {
        let paused = !allPaused(server)
        Task {
            do {
                try await server.pauseAll(paused)
            } catch {
                failure(UserFacingError.message(for: error))
            }
        }
    }

    /// The title of the "pause all" item: it resumes when everything is paused.
    static func pauseAllTitle(_ server: ServerModel?) -> String {
        if let server, allPaused(server) { return L10n.Menubar.resumeAll }
        return L10n.Keys.pauseAll
    }
}
