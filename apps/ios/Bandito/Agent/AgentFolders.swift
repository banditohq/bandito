import BanditoKit
import BanditoL10n
import Foundation

/// Makes an agent's own folder on the server, as the Mac does when Create is pressed: the first free name of the base
/// (`Forge`, then `Forge 2`, …) under the agents folder, created on the server.
@MainActor
enum AgentFolders {
    /// The agents folder on the server: the one saved for this server (the Mac's `AgentsRootStore`), else the one the agents
    /// already use, else `Bandito` in the home folder. Nil when none is known (the form then asks for nothing and cannot create).
    static func root(server: ServerModel) async -> String? {
        let home = (try? await server.stat("~"))?.path
        let projects = server.agents.compactMap { NewAgentFolderRules.projectFolder(cwd: $0.cwd, homeDir: $0.homeDir) }
        let saved = AgentsRootStore.load(serverID: server.id.uuidString)
        return NewAgentFolderRules.defaultRoot(saved: saved, projectFolders: projects, home: home)
    }

    /// Creates the first free folder for `base` under `root` and returns its path. A name that is in the folder already
    /// is skipped; the folder is listed (not stat-ed), so a name the server does not know reads as free.
    static func makeFree(root: String, base: String, server: ServerModel) async throws -> String {
        let names: Set<String>
        do {
            names = Set(try await server.list(root, hidden: true).entries.map(\.name))
        } catch {
            // The agents folder is not there yet: make it, and every name in it is free.
            _ = try await server.mkdir(root)
            names = []
        }
        for attempt in 1...NewAgentFolderRules.attemptLimit {
            let name = NewAgentFolderRules.candidate(base: base, attempt: attempt)
            guard !names.contains(name) else { continue }
            let path = NewAgentFolderRules.folderPath(root: root, name: name)
            _ = try await server.mkdir(path)
            return path
        }
        throw AgentFolderError.noFreeName
    }
}

/// A folder for an agent could not be found or made.
enum AgentFolderError: LocalizedError {
    case noFreeName

    var errorDescription: String? {
        L10n.AgentSheet.folderNoFreeName
    }
}
