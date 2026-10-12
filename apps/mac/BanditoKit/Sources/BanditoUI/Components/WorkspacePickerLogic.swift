import BanditoKit
import Foundation

/// What a row of the workplace picker says about a workplace: the shared server, or a container that runs or not.
enum WorkspaceLiveState: Equatable {
    /// The shared workplace: it is the server itself, so it always runs.
    case serverRunning
    case containerRunning
    case containerStopped
    /// Docker could not answer; the reason code is `docker_unavailable` and the like. Starting would fail the same way.
    case unavailable(String)
}

/// The rules behind the workplace picker of the Screen and the Browser: which workplace is chosen, and what a row
/// offers. Pure, so the view stays thin (see `WorkspacePicker`).
enum WorkspacePickerLogic {
    /// `UserDefaults` key of the choice for one mode (`screen` or `browser`) on one server.
    static func storageKey(mode: String, serverID: UUID) -> String {
        "workspace.\(mode).\(serverID.uuidString)"
    }

    /// The workplace id to show. The saved id stays while the workplace is listed, even when its container is stopped
    /// (the row offers "Запустить"). A saved id that is not listed (deleted, or the list is not loaded yet) falls back
    /// to the shared workplace, as does no saved choice at all.
    static func resolve(saved: String?, workspaces: [Workspace]) -> String {
        guard let saved, workspaces.contains(where: { $0.id == saved }) else {
            return Workspace.sharedID
        }
        return saved
    }

    static func liveState(_ workspace: Workspace) -> WorkspaceLiveState {
        guard workspace.kind == .container else { return .serverRunning }
        if let error = workspace.status?.error {
            return .unavailable(error)
        }
        return workspace.status?.running == true ? .containerRunning : .containerStopped
    }

    /// Only a stopped container offers "Запустить" (`workspaces.start`).
    static func canStart(_ workspace: Workspace) -> Bool {
        liveState(workspace) == .containerStopped
    }
}
