import BanditoKit
import BanditoL10n
import Foundation

// The pure rules behind choosing a workplace in the Screen, Browser, Terminals and Files modes. The workplace picker
// itself (`WorkspacePicker`) and the stores (`WorkspaceDirectory`, `WorkspaceSelection`) stay thin on top of them.

extension WorkspacePickerLogic {
    /// The workplace to show now. Before the list has arrived, and on a server that has no workplaces feature, the
    /// saved choice stands (a container is not dropped just because the list is still loading); once the list is
    /// there, `resolve` decides: a choice that is gone falls back to the shared one.
    static func effective(saved: String?, workspaces: [Workspace], loaded: Bool) -> String {
        guard loaded, !workspaces.isEmpty else { return saved ?? Workspace.sharedID }
        return resolve(saved: saved, workspaces: workspaces)
    }

    /// A choice that the loaded list no longer holds. The saved value is then forgotten.
    static func isGone(saved: String?, workspaces: [Workspace], loaded: Bool) -> Bool {
        guard loaded, !workspaces.isEmpty, let saved, saved != Workspace.sharedID else { return false }
        return !workspaces.contains { $0.id == saved }
    }

    /// The picker is shown only when there is something to choose from.
    static func offersChoice(_ workspaces: [Workspace]) -> Bool {
        workspaces.count > 1
    }

    /// The `workspace` parameter of an RPC call: nothing for the shared workplace, so an older daemon is asked
    /// exactly as before.
    static func rpcParameter(_ id: String) -> String? {
        id == Workspace.sharedID ? nil : id
    }

    /// One row of the picker. Equatable, so a poll that changes nothing the row shows redraws nothing.
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let isContainer: Bool
        let live: WorkspaceLiveState
        let selected: Bool
        /// A start of this workplace is running now.
        let busy: Bool
        let canStart: Bool
    }

    static func rows(workspaces: [Workspace], selectedID: String, busyID: String?) -> [Row] {
        workspaces.map { workspace in
            Row(
                id: workspace.id, name: workspace.kind == .shared ? L10n.Workspace.Shared.title : workspace.name,
                isContainer: workspace.kind == .container,
                live: liveState(workspace), selected: workspace.id == selectedID, busy: workspace.id == busyID,
                canStart: canStart(workspace))
        }
    }

    /// The name of a workplace for a label (a terminal, an agent), or nil for the shared one, which needs none.
    /// A workplace missing from the list (not loaded, or gone) has no name to show either.
    static func label(workspaceID: String, workspaces: [Workspace]) -> String? {
        guard workspaceID != Workspace.sharedID else { return nil }
        return workspaces.first { $0.id == workspaceID }?.name
    }

    /// A new terminal in a stopped container starts the container first, so the person sees "starting" and not a wait.
    static func needsStartBeforeTerminal(_ workspace: Workspace?) -> Bool {
        workspace.map(canStart) ?? false
    }
}

/// What the Screen sidebar says about the screen of one workplace.
enum ScreenCardState: Equatable, Sendable {
    /// Not asked yet.
    case unknown
    case asleep
    case running
    /// The daemon cannot give this workplace a screen (an older daemon refuses the id), so the card explains instead.
    case unavailable
}

enum ScreenCardRules {
    /// Reads the answer of `screen.status` for a workplace. `refusal` is the error of a failed call. A refusal of the
    /// parameters (`invalidParams`) for a workplace other than the shared one means the daemon does not know screens
    /// of separate workplaces; any other failure leaves the card as it was (a dropped connection is not "unavailable").
    static func state(status: ScreenStatus?, refusal: RPCError?, workspaceID: String, previous: ScreenCardState)
        -> ScreenCardState
    {
        if let refusal {
            if refusal.code == RPCError.invalidParams, workspaceID != Workspace.sharedID { return .unavailable }
            return previous
        }
        guard let status else { return previous }
        return status.running ? .running : .asleep
    }
}

/// A folder a container workplace sees, for the Files sidebar group.
struct WorkspaceFolder: Equatable, Identifiable {
    enum Origin: Equatable {
        /// The folder or the own folder of an agent that runs there.
        case agent(name: String)
        /// A folder the person added to the container.
        case added
    }

    let path: String
    let origin: Origin
    let readOnly: Bool
    /// Also visible elsewhere: an added folder lives on the server itself, and a path another container sees too is
    /// shared with it.
    let shared: Bool

    var id: String { path }
}

enum WorkspaceFolders {
    /// The folders `workspace` (a container) sees: the folder and the own folder of every agent that runs in it, then
    /// the folders the person added. Each path once (an agent's name wins over "added" for the same path).
    static func folders(of workspace: Workspace, in workspaces: [Workspace], agents: [Agent]) -> [WorkspaceFolder] {
        guard workspace.kind == .container else { return [] }
        let others = workspaces.filter { $0.id != workspace.id && $0.kind == .container }
        var otherPaths = Set<String>()
        for other in others {
            for mount in other.mounts { otherPaths.insert(mount.host) }
            for agent in agents where agent.workspaceId == other.id {
                otherPaths.insert(agent.cwd)
                if let home = agent.homeDir { otherPaths.insert(home) }
            }
        }
        // A folder the person added to this container lives on the server itself, so it is shared even when an agent
        // works in it.
        let addedPaths = Set(workspace.mounts.map(\.host))
        var result: [WorkspaceFolder] = []
        var seen = Set<String>()
        let mine = agents.filter { $0.workspaceId == workspace.id }.sorted {
            ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id)
        }
        for agent in mine {
            for path in [agent.cwd, agent.homeDir ?? ""] where !path.isEmpty && seen.insert(path).inserted {
                result.append(
                    WorkspaceFolder(
                        path: path, origin: .agent(name: agent.name), readOnly: false,
                        shared: otherPaths.contains(path) || addedPaths.contains(path)))
            }
        }
        for mount in workspace.mounts.sorted(by: { $0.host < $1.host }) where seen.insert(mount.host).inserted {
            result.append(WorkspaceFolder(path: mount.host, origin: .added, readOnly: mount.readOnly, shared: true))
        }
        return result
    }
}
