import Foundation

// The models each agent CLI offers (`runtimes.models`). Source of truth: docs/ARCHITECTURE.md#runtime-models.

/// One model a runtime's CLI offers. `id` is the name the CLI takes as its model.
public struct RuntimeModel: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    /// The model the CLI uses when none is chosen. At most one model of a list is marked.
    public var isDefault: Bool
    /// Reasoning effort levels the model accepts, as the daemon names them. Empty when it takes none.
    public var efforts: [String]
    /// The context window in tokens, when the daemon knows it. Nil when the daemon's table does not list the model.
    public var contextWindow: Int?

    public init(
        id: String, name: String, description: String? = nil, isDefault: Bool = false, efforts: [String] = [],
        contextWindow: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.isDefault = isDefault
        self.efforts = efforts
        self.contextWindow = contextWindow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        description = try c.decodeIfPresent(String.self, forKey: .description)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
    }

    /// The effort levels this app knows that the model accepts, lowest first. Other names are ignored.
    public var supportedEfforts: [Effort] {
        Effort.allCases.filter { efforts.contains($0.rawValue) }
    }
}

/// What the app knows about the model lists of the daemon, as `ServerModel.runtimeModelsStatus`.
public enum RuntimeModelsStatus: Sendable, Equatable {
    /// Not asked yet, or asked while the daemon's info is still unknown (the request waits for it).
    case unknown
    /// The daemon predates `runtime_models`, so it cannot list models at all.
    case unsupported
    /// The request itself failed. The text is the reason: the daemon's message or the connection's.
    case failed(String)
    /// The daemon answered. Each runtime's list may still carry its own `error` (see `RuntimeModelList`).
    case loaded
}

/// What asking for the model lists does, given what is known about the daemon. Pure, so the gate is tested without
/// a server.
public enum RuntimeModelsGate: Equatable, Sendable {
    /// The daemon's info is not known yet: ask once it is.
    case wait
    /// The daemon predates `runtime_models`: do not ask.
    case unsupported
    /// Ask the daemon.
    case ask

    public static func decide(hasInfo: Bool, supportsModels: Bool) -> RuntimeModelsGate {
        guard hasInfo else { return .wait }
        return supportsModels ? .ask : .unsupported
    }
}

/// The models one runtime offers, as `runtimes.models` answers them.
public struct RuntimeModelList: Codable, Sendable, Hashable {
    public var runtime: RuntimeKind
    public var models: [RuntimeModel]
    /// `not_installed`, or the reason the CLI gave no list. Nil when the list is good.
    public var error: String?
    /// Unix milliseconds when the list was read from the CLI.
    public var fetchedAt: Int64

    public init(runtime: RuntimeKind, models: [RuntimeModel], error: String? = nil, fetchedAt: Int64) {
        self.runtime = runtime
        self.models = models
        self.error = error
        self.fetchedAt = fetchedAt
    }

    /// The model the runtime uses when none is chosen.
    public var defaultModel: RuntimeModel? {
        models.first { $0.isDefault }
    }
}
