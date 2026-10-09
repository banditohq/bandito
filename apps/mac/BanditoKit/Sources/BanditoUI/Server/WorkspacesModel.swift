import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// The workplaces of one server: the list (`workspaces.list`), whether Docker is ready (`setup.status`), and the
/// changes the screens make. Used by Server → Workplaces, the new agent sheet, the first agent step and the Inspector.
@MainActor
@Observable
final class WorkspacesModel {
    let server: ServerModel

    /// The shared server first, then the containers in the order they were made.
    private(set) var workspaces: [Workspace] = []
    /// The `docker` component of `setup.status`, when the server reports it.
    private(set) var docker: SetupComponent?
    /// `features.containers` is ready: a container can be made and started.
    private(set) var dockerReady = false
    private(set) var loading = false
    /// The last failure of a change or a load, as a sentence.
    private(set) var errorText: UserFacingMessage?
    /// The workspace whose change is running (its buttons are disabled meanwhile).
    private(set) var busyID: String?

    init(server: ServerModel) {
        self.server = server
    }

    /// The server runs workplaces at all (`workspaces` in `daemon.info.features`).
    var supported: Bool {
        server.supports("workspaces")
    }

    /// A separate workplace can be chosen: the server has the feature and Docker is ready.
    var canCreateSeparate: Bool {
        supported && dockerReady
    }

    var shared: Workspace? {
        workspaces.first { $0.kind == .shared }
    }

    var containers: [Workspace] {
        workspaces.filter { $0.kind == .container }
    }

    func workspace(_ id: String) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    /// Reloads the list and the Docker state. Failures stay in `errorText`.
    func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await server.listWorkspaces()
            workspaces = list.sorted { lhs, rhs in
                (lhs.kind == .shared ? 0 : 1, lhs.createdAt) < (rhs.kind == .shared ? 0 : 1, rhs.createdAt)
            }
            errorText = nil
        } catch {
            errorText = WorkspaceText.message(for: error)
        }
        if let status = try? await server.setupStatus() {
            docker = status.components.first { $0.id == "docker" }
            dockerReady = status.features.containers == .ready
        }
    }

    /// Makes a container. Returns it, or nil with `errorText` set.
    @discardableResult
    func create(_ new: NewWorkspace) async -> Workspace? {
        do {
            let created = try await server.createWorkspace(new)
            errorText = nil
            await load()
            return created
        } catch {
            errorText = WorkspaceText.message(for: error)
            return nil
        }
    }

    func start(_ workspace: Workspace) async {
        await change(workspace.id) { _ = try await self.server.startWorkspace(workspace.id) }
    }

    func stop(_ workspace: Workspace) async {
        await change(workspace.id) { _ = try await self.server.stopWorkspace(workspace.id) }
    }

    /// Deletes a container. A workspace that still has agents is refused here, before the daemon is asked.
    func delete(_ workspace: Workspace) async {
        guard workspace.canDelete else {
            errorText = UserFacingMessage(text: L10n.Workspace.Error.notEmpty)
            return
        }
        await change(workspace.id) { try await self.server.deleteWorkspace(workspace.id) }
    }

    /// Adds a host folder to a container's mounts (read-write). The change applies when the container next starts.
    func addFolder(_ path: String, to workspace: Workspace) async {
        guard !workspace.mounts.contains(where: { $0.host == path }) else { return }
        let mounts = workspace.mounts + [WorkspaceMount(host: path, target: path)]
        await change(workspace.id) { _ = try await self.server.updateWorkspace(workspace.id, patch: WorkspacePatch(mounts: mounts)) }
    }

    func removeFolder(_ mount: WorkspaceMount, from workspace: Workspace) async {
        let mounts = workspace.mounts.filter { $0 != mount }
        await change(workspace.id) { _ = try await self.server.updateWorkspace(workspace.id, patch: WorkspacePatch(mounts: mounts)) }
    }

    /// Runs one change, shows its failure, and reloads the list.
    private func change(_ id: String, _ work: () async throws -> Void) async {
        busyID = id
        defer { busyID = nil }
        do {
            try await work()
            errorText = nil
        } catch {
            errorText = WorkspaceText.message(for: error)
        }
        await load()
    }
}
