import BanditoKit
import BanditoL10n

/// Where a new agent's CLI runs, as the sheets offer it: the shared server, a container that exists, or a container
/// made when the agent is created (see `NewWorkplaceDraft`). Pure: the sheets bind to it.
public enum WorkplaceChoice: Equatable, Sendable {
    case shared
    /// An existing container workspace, by id.
    case existing(String)
    /// A new container, made first when the agent is created.
    case new

    /// The two segments of the picker. "Separate" covers both an existing container and a new one.
    public enum Mode: Hashable, Sendable {
        case shared, separate
    }

    public var mode: Mode {
        self == .shared ? .shared : .separate
    }
}

/// The form of a new container, as the new agent sheet and the first agent step collect it. The limits start at
/// `WorkspaceLimits.defaults` and internet is on, because the CLIs need the network to reach their models.
public struct NewWorkplaceDraft: Equatable, Sendable {
    public var name = ""
    public var network: WorkspaceNetwork = .internet
    public var limits = WorkspaceLimits.defaults

    public init() {}

    public var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A name of 1 to 64 characters (the daemon's rule), and limits inside the daemon's ranges.
    public var canCreate: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 64 && limits.isValid
    }

    public func makeNewWorkspace() -> NewWorkspace {
        NewWorkspace(
            name: trimmedName, kind: .container, cpus: limits.cpus, memoryMb: limits.memoryMb, network: network)
    }

    /// "2 CPU, 2048 MB", for the hint under the form.
    public var limitsText: String {
        let cpu = limits.cpus.map { "\(Self.formatted($0)) CPU" } ?? L10n.Workspace.Create.unlimited
        let memory = limits.memoryMb.map { "\($0) MB" } ?? L10n.Workspace.Create.unlimited
        return "\(cpu), \(memory)"
    }

    static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// Creates what the choice needs on the server before an agent is created. Returns the workspace id to send, or nil
/// for the shared server (the daemon's default).
public enum WorkplaceCreation {
    public static func prepare(_ choice: WorkplaceChoice, new: NewWorkplaceDraft, on server: ServerModel) async throws -> String? {
        switch choice {
        case .shared:
            return nil
        case .existing(let id):
            return id
        case .new:
            return try await server.createWorkspace(new.makeNewWorkspace()).id
        }
    }
}
