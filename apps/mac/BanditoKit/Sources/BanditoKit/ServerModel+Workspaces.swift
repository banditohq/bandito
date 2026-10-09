import Foundation

// Workplaces: where agents run (`workspaces.*`, docs/ARCHITECTURE.md#workspaces). Failures come back as
// `RPCError` with code `RPCError.workspaceError`; `WorkspaceFailure(error)` names the reason.

extension ServerModel {
    /// Every workspace with the agents in it and its live status. The shared workspace comes first.
    public func listWorkspaces() async throws -> [Workspace] {
        try await rpc().call("workspaces.list", NoParams(), as: [Workspace].self)
    }

    /// Creates a container workspace (`workspaces.create`).
    public func createWorkspace(_ new: NewWorkspace) async throws -> Workspace {
        try await rpc().call("workspaces.create", new, as: Workspace.self)
    }

    /// Changes a workspace (`workspaces.update`). Limits and mounts apply when the container next starts.
    public func updateWorkspace(_ id: String, patch: WorkspacePatch) async throws -> Workspace {
        struct P: Encodable {
            var id: String
            var patch: WorkspacePatch

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: WorkspacePatch.Key.self)
                try patch.encodeFields(into: &c)
                try c.encode(id, forKey: .id)
            }
        }
        return try await rpc().call("workspaces.update", P(id: id, patch: patch), as: Workspace.self)
    }

    /// Deletes a workspace (`workspaces.delete`). The daemon removes its container first, and refuses the shared
    /// workspace and any workspace an agent still runs in.
    public func deleteWorkspace(_ id: String) async throws {
        struct P: Encodable { var id: String }
        try await rpc().call("workspaces.delete", P(id: id))
    }

    /// Starts the container of a workspace (`workspaces.start`). The next message would start it anyway.
    @discardableResult
    public func startWorkspace(_ id: String) async throws -> WorkspaceStatus {
        struct P: Encodable { var id: String }
        return try await rpc().call("workspaces.start", P(id: id), as: WorkspaceStatus.self)
    }

    /// Stops the container of a workspace (`workspaces.stop`). The next message starts it again.
    @discardableResult
    public func stopWorkspace(_ id: String) async throws -> WorkspaceStatus {
        struct P: Encodable { var id: String }
        return try await rpc().call("workspaces.stop", P(id: id), as: WorkspaceStatus.self)
    }
}
