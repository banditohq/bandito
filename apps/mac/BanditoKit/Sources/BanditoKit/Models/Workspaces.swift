import Foundation

// Wire models for `workspaces.*` (docs/ARCHITECTURE.md#workspaces). Source: daemon/src/store/workspaces.rs,
// daemon/src/workspace.rs and daemon/src/rpc/workspaces.rs. Decoded with `.convertFromSnakeCase`.

/// Where an agent's CLI runs: on the server itself (`shared`) or in a Docker container.
public enum WorkspaceKind: String, ForwardCompatibleEnum, CaseIterable {
    case shared, container

    /// An unknown kind is treated as a container: it is never mistaken for the built-in shared workspace.
    public static var fallback: WorkspaceKind { .container }
}

/// Network of a container workspace. `offline` is wire `none`: no network at all.
public enum WorkspaceNetwork: String, ForwardCompatibleEnum, CaseIterable {
    case internet
    case offline = "none"

    public static var fallback: WorkspaceNetwork { .internet }
}

/// A host folder shown inside a container. `target` is where it appears there.
public struct WorkspaceMount: Codable, Sendable, Hashable {
    public var host: String
    public var target: String
    public var readOnly: Bool

    public init(host: String, target: String, readOnly: Bool = false) {
        self.host = host
        self.target = target
        self.readOnly = readOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        target = try c.decode(String.self, forKey: .target)
        readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
    }
}

/// CPU and memory limits of a container. `nil` means no limit for that value.
public struct WorkspaceLimits: Codable, Sendable, Hashable {
    /// CPU cores, 0.1 to 64 (daemon rule).
    public var cpus: Double?
    /// Memory in megabytes, 64 to 262144 (daemon rule).
    public var memoryMb: Int?

    /// What a new container gets when the person does not change the limits.
    public static let defaults = WorkspaceLimits(cpus: 2, memoryMb: 2048)
    public static let cpuRange: ClosedRange<Double> = 0.1...64
    public static let memoryRange: ClosedRange<Int> = 64...262_144

    public init(cpus: Double? = nil, memoryMb: Int? = nil) {
        self.cpus = cpus
        self.memoryMb = memoryMb
    }

    /// Both values are inside the daemon's ranges (or unset).
    public var isValid: Bool {
        (cpus.map { Self.cpuRange.contains($0) } ?? true) && (memoryMb.map { Self.memoryRange.contains($0) } ?? true)
    }
}

/// Live numbers of a container (`workspaces.list`, `workspaces.start`, `workspaces.stop`).
public struct WorkspaceStatus: Codable, Sendable, Hashable {
    public var running: Bool
    public var containerId: String?
    public var cpu: String?
    public var mem: String?
    /// Set when Docker could not answer (`running` is then false): the reason code, such as `docker_unavailable`.
    public var error: String?

    public init(running: Bool, containerId: String? = nil, cpu: String? = nil, mem: String? = nil, error: String? = nil) {
        self.running = running
        self.containerId = containerId
        self.cpu = cpu
        self.mem = mem
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        containerId = try c.decodeIfPresent(String.self, forKey: .containerId)
        cpu = try c.decodeIfPresent(String.self, forKey: .cpu)
        mem = try c.decodeIfPresent(String.self, forKey: .mem)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

/// A workspace. `workspaces.create` and `workspaces.update` send the row alone; `workspaces.list` adds
/// `agents` and `status`.
public struct Workspace: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: WorkspaceKind
    /// `nil` = the image Bandito builds.
    public var image: String?
    public var cpus: Double?
    public var memoryMb: Int?
    public var network: WorkspaceNetwork
    /// Folders the person added. The agents' own folders are added by the daemon at start.
    public var mounts: [WorkspaceMount]
    public var createdAt: Int64
    /// Ids of the agents that run here (`workspaces.list` only).
    public var agents: [String]
    /// Live state of a container; `nil` for the shared workspace (`workspaces.list` only).
    public var status: WorkspaceStatus?

    public init(
        id: String, name: String, kind: WorkspaceKind, image: String? = nil, cpus: Double? = nil,
        memoryMb: Int? = nil, network: WorkspaceNetwork = .internet, mounts: [WorkspaceMount] = [],
        createdAt: Int64 = 0, agents: [String] = [], status: WorkspaceStatus? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.image = image
        self.cpus = cpus
        self.memoryMb = memoryMb
        self.network = network
        self.mounts = mounts
        self.createdAt = createdAt
        self.agents = agents
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(WorkspaceKind.self, forKey: .kind)
        image = try c.decodeIfPresent(String.self, forKey: .image)
        cpus = try c.decodeIfPresent(Double.self, forKey: .cpus)
        memoryMb = try c.decodeIfPresent(Int.self, forKey: .memoryMb)
        network = try c.decodeIfPresent(WorkspaceNetwork.self, forKey: .network) ?? .internet
        mounts = try c.decodeIfPresent([WorkspaceMount].self, forKey: .mounts) ?? []
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        agents = try c.decodeIfPresent([String].self, forKey: .agents) ?? []
        status = try c.decodeIfPresent(WorkspaceStatus.self, forKey: .status)
    }

    /// The id of the shared workspace (the server itself). Agents default to it.
    public static let sharedID = "shared"

    public var limits: WorkspaceLimits {
        WorkspaceLimits(cpus: cpus, memoryMb: memoryMb)
    }

    /// Whether the container is up now.
    public var isRunning: Bool {
        status?.running == true
    }

    /// The daemon refuses to delete the shared workspace and any workspace an agent runs in. The app checks
    /// the same rule first, so the person sees the list of agents instead of an error.
    public var canDelete: Bool {
        kind == .container && agents.isEmpty
    }
}

/// `workspaces.create` params.
public struct NewWorkspace: Codable, Sendable, Hashable {
    public var name: String
    public var kind: WorkspaceKind
    /// `nil` = the image Bandito builds.
    public var image: String?
    public var cpus: Double?
    public var memoryMb: Int?
    public var network: WorkspaceNetwork
    public var mounts: [WorkspaceMount]

    public init(
        name: String, kind: WorkspaceKind = .container, image: String? = nil, cpus: Double? = nil,
        memoryMb: Int? = nil, network: WorkspaceNetwork = .internet, mounts: [WorkspaceMount] = []
    ) {
        self.name = name
        self.kind = kind
        self.image = image
        self.cpus = cpus
        self.memoryMb = memoryMb
        self.network = network
        self.mounts = mounts
    }
}

/// The fields of `workspaces.update`. A `nil` field is not sent. `.clear` sends `null`, which the daemon reads
/// as "remove the limit" (for `image`, `cpus` and `memoryMb`).
public struct WorkspacePatch: Sendable {
    public var name: String?
    public var image: FieldChange<String>?
    public var cpus: FieldChange<Double>?
    public var memoryMb: FieldChange<Int>?
    public var network: WorkspaceNetwork?
    public var mounts: [WorkspaceMount]?

    public init(
        name: String? = nil, image: FieldChange<String>? = nil, cpus: FieldChange<Double>? = nil,
        memoryMb: FieldChange<Int>? = nil, network: WorkspaceNetwork? = nil, mounts: [WorkspaceMount]? = nil
    ) {
        self.name = name
        self.image = image
        self.cpus = cpus
        self.memoryMb = memoryMb
        self.network = network
        self.mounts = mounts
    }

    /// Keys on the wire (camelCase here; the RPC encoder makes them snake_case). `id` is added by the request.
    public enum Key: String, CodingKey {
        case id, name, image, cpus, memoryMb, network, mounts
    }

    /// Writes the set fields into an object that may also hold `id`.
    public func encodeFields(into c: inout KeyedEncodingContainer<Key>) throws {
        try c.encodeIfPresent(name, forKey: .name)
        try Self.encodeChange(image, forKey: .image, into: &c)
        try Self.encodeChange(cpus, forKey: .cpus, into: &c)
        try Self.encodeChange(memoryMb, forKey: .memoryMb, into: &c)
        try c.encodeIfPresent(network, forKey: .network)
        try c.encodeIfPresent(mounts, forKey: .mounts)
    }

    private static func encodeChange<T: Encodable & Sendable>(
        _ change: FieldChange<T>?, forKey key: Key, into c: inout KeyedEncodingContainer<Key>
    ) throws {
        switch change {
        case nil: break
        case .set(let value)?: try c.encode(value, forKey: key)
        case .clear?: try c.encodeNil(forKey: key)
        }
    }
}

extension WorkspacePatch: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try encodeFields(into: &c)
    }
}

/// A workspace failure (`error.code` -32028). `data.reason` says which; the app turns each into a sentence.
public enum WorkspaceFailure: Equatable, Sendable {
    /// Docker is missing or does not answer.
    case dockerUnavailable
    case notFound
    /// The shared workspace cannot be deleted or started.
    case builtin
    /// Agents still run in the workspace.
    case notEmpty
    /// Bad settings or a bad mount. `message` is the daemon's text.
    case invalid(message: String)
    /// Docker failed. `message` is its text.
    case docker(message: String)
    /// A reason this app does not know yet.
    case other(message: String)

    /// `nil` when the error is not a workspace failure.
    public init?(_ error: Error) {
        guard let rpc = error as? RPCError, rpc.code == RPCError.workspaceError else { return nil }
        let message = rpc.message
        switch rpc.reason ?? "" {
        case "docker_unavailable": self = .dockerUnavailable
        case "not_found": self = .notFound
        case "builtin": self = .builtin
        case "not_empty": self = .notEmpty
        case "invalid": self = .invalid(message: message)
        case "docker": self = .docker(message: message)
        default: self = .other(message: message)
        }
    }
}
