import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// The workplaces of one server as the Screen, Browser, Terminals and Files modes need them: the list, and a start of
/// a stopped container. One per server (`WorkspaceDirectories`), so the modes share one list and one poll's worth of
/// requests. Lighter than `WorkspacesModel` (no Docker setup read), which stays the model of Server → Workplaces.
@MainActor
@Observable
final class WorkspaceDirectory {
    let server: ServerModel

    /// The shared server first, then the containers in the order they were made.
    private(set) var workspaces: [Workspace] = []
    /// The list has been read at least once.
    private(set) var isLoaded = false
    /// The workplace whose start is running now.
    private(set) var busyID: String?
    /// The last failure of a start, as a sentence. Cleared by the next successful read or start.
    private(set) var errorText: UserFacingMessage?
    @ObservationIgnored private var reading = false

    /// `workspaces` and `loaded` seed the list (tests, and a list read elsewhere).
    init(server: ServerModel, workspaces: [Workspace] = [], loaded: Bool = false) {
        self.server = server
        self.workspaces = workspaces
        self.isLoaded = loaded
    }

    /// The server knows workplaces (`workspaces` in `daemon.info.features`).
    var isSupported: Bool { server.supports("workspaces") }

    /// A poll tick should read now: always for the first read, then only while the app is the active one (a list nobody
    /// looks at costs no request; the next tick after the app comes back reads again).
    var shouldPoll: Bool { !isLoaded || AppActivity.isActive }

    func workspace(_ id: String) -> Workspace? {
        workspaces.first { $0.id == id }
    }

    /// Reads `workspaces.list`. A failed read keeps the list that was there; values are written only when they changed.
    func refresh() async {
        guard isSupported, !reading else { return }
        reading = true
        defer { reading = false }
        do {
            let list = try await server.listWorkspaces().sorted { lhs, rhs in
                (lhs.kind == .shared ? 0 : 1, lhs.createdAt) < (rhs.kind == .shared ? 0 : 1, rhs.createdAt)
            }
            if list != workspaces { workspaces = list }
            if !isLoaded { isLoaded = true }
        } catch {
            // A read that failed says nothing new about the workplaces; the next tick tries again.
        }
    }

    /// Starts a stopped container (`workspaces.start`) and reads the list again. A failure shows in `errorText`.
    func start(_ id: String) async {
        guard busyID == nil else { return }
        busyID = id
        errorText = nil
        defer { busyID = nil }
        do {
            _ = try await server.startWorkspace(id)
        } catch {
            errorText = WorkspaceText.message(for: error)
        }
        await refresh()
    }

    func clearError() {
        if errorText != nil { errorText = nil }
    }
}

/// One `WorkspaceDirectory` per server.
@MainActor
final class WorkspaceDirectories {
    static let shared = WorkspaceDirectories()
    private var directories: [UUID: WorkspaceDirectory] = [:]

    func directory(for server: ServerModel) -> WorkspaceDirectory {
        if let directory = directories[server.id] { return directory }
        let directory = WorkspaceDirectory(server: server)
        directories[server.id] = directory
        return directory
    }
}

/// Which workplace one mode (`screen`, `browser`, `terminals`) shows on one server. The choice is kept per server and
/// mode. `selectedID` is a stored value, written only when it changes: a poll of the list that changes nothing the mode
/// shows redraws nothing that reads it.
@MainActor
@Observable
final class WorkspaceSelection {
    let mode: String
    let serverID: UUID
    let directory: WorkspaceDirectory
    private(set) var selectedID: String
    @ObservationIgnored private var saved: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(mode: String, directory: WorkspaceDirectory, defaults: UserDefaults = .standard) {
        self.mode = mode
        self.serverID = directory.server.id
        self.directory = directory
        self.defaults = defaults
        let saved = defaults.string(forKey: WorkspacePickerLogic.storageKey(mode: mode, serverID: directory.server.id))
        self.saved = saved
        self.selectedID = WorkspacePickerLogic.effective(
            saved: saved, workspaces: directory.workspaces, loaded: directory.isLoaded)
    }

    var key: String { WorkspacePickerLogic.storageKey(mode: mode, serverID: serverID) }

    /// The chosen workplace, when the list holds it.
    var selected: Workspace? { directory.workspace(selectedID) }

    /// Reads the list and brings the choice in line with it.
    func refresh() async {
        await directory.refresh()
        reconcile()
    }

    /// A choice the list no longer holds (the container was deleted) is forgotten, and the shared workplace is shown.
    func reconcile() {
        let workspaces = directory.workspaces
        if WorkspacePickerLogic.isGone(saved: saved, workspaces: workspaces, loaded: directory.isLoaded) {
            saved = nil
            defaults.removeObject(forKey: key)
        }
        let next = WorkspacePickerLogic.effective(saved: saved, workspaces: workspaces, loaded: directory.isLoaded)
        if next != selectedID { selectedID = next }
    }

    func select(_ id: String) {
        guard id != selectedID else { return }
        saved = id
        defaults.set(id, forKey: key)
        selectedID = id
    }
}

/// One `WorkspaceSelection` per mode and server.
@MainActor
final class WorkspaceSelections {
    static let shared = WorkspaceSelections()
    private var selections: [String: WorkspaceSelection] = [:]

    func selection(mode: String, server: ServerModel) -> WorkspaceSelection {
        let key = WorkspacePickerLogic.storageKey(mode: mode, serverID: server.id)
        if let selection = selections[key] { return selection }
        let selection = WorkspaceSelection(
            mode: mode, directory: WorkspaceDirectories.shared.directory(for: server))
        selections[key] = selection
        return selection
    }
}
