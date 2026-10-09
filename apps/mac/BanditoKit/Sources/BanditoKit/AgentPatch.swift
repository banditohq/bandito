import Foundation

/// A change to one field that can also be cleared. `nil` in a patch means "leave it as it is";
/// `.clear` sends an explicit `null`, which the daemon reads as "remove it".
public enum FieldChange<Value: Sendable>: Sendable {
    case set(Value)
    case clear
}

/// The fields of `agents.update`. A `nil` field is not sent, so the daemon keeps its value.
public struct AgentPatch: Sendable {
    public var name: String?
    public var role: String?
    public var cwd: String?
    public var approvalMode: ApprovalMode?
    public var effort: Effort?
    public var memoryMode: MemoryMode?
    public var contextBudget: Int?
    public var systemPrompt: String?
    /// `.clear` goes back to the runtime's default model.
    public var model: FieldChange<String>?
    /// The primary runtime. The daemon starts a new chapter when it changes.
    public var runtime: RuntimeKind?
    public var fallbackRuntime: FieldChange<RuntimeKind>?
    public var fallbackModel: FieldChange<String>?
    /// Moves the agent to another workspace. The daemon starts a new chapter, and the reply carries a warning.
    public var workspaceId: String?
    /// Pauses (`true`) or resumes the agent. The daemon interrupts a running turn on pause.
    public var paused: Bool?

    public init(
        name: String? = nil, role: String? = nil, cwd: String? = nil, approvalMode: ApprovalMode? = nil,
        effort: Effort? = nil, memoryMode: MemoryMode? = nil, contextBudget: Int? = nil,
        systemPrompt: String? = nil, model: FieldChange<String>? = nil, runtime: RuntimeKind? = nil,
        fallbackRuntime: FieldChange<RuntimeKind>? = nil, fallbackModel: FieldChange<String>? = nil,
        workspaceId: String? = nil,
        paused: Bool? = nil
    ) {
        self.workspaceId = workspaceId
        self.name = name
        self.role = role
        self.cwd = cwd
        self.approvalMode = approvalMode
        self.effort = effort
        self.memoryMode = memoryMode
        self.contextBudget = contextBudget
        self.systemPrompt = systemPrompt
        self.model = model
        self.runtime = runtime
        self.fallbackRuntime = fallbackRuntime
        self.fallbackModel = fallbackModel
        self.paused = paused
    }

    /// Keys on the wire (camelCase here; the RPC encoder makes them snake_case). `id` is not a patch
    /// field: the request that carries a patch adds it.
    public enum Key: String, CodingKey {
        case id, name, role, cwd, approvalMode, effort, memoryMode, contextBudget, systemPrompt, model, runtime
        case fallbackRuntime, fallbackModel, workspaceId, paused
    }

    /// Writes the set fields into an object that may also hold other keys (such as `id`).
    public func encodeFields(into c: inout KeyedEncodingContainer<Key>) throws {
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(approvalMode, forKey: .approvalMode)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(memoryMode, forKey: .memoryMode)
        try c.encodeIfPresent(contextBudget, forKey: .contextBudget)
        try c.encodeIfPresent(systemPrompt, forKey: .systemPrompt)
        try Self.encodeChange(model, forKey: .model, into: &c)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try Self.encodeChange(fallbackRuntime, forKey: .fallbackRuntime, into: &c)
        try Self.encodeChange(fallbackModel, forKey: .fallbackModel, into: &c)
        try c.encodeIfPresent(workspaceId, forKey: .workspaceId)
        try c.encodeIfPresent(paused, forKey: .paused)
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

extension AgentPatch: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try encodeFields(into: &c)
    }
}

/// The answer to `agents.update`: the agent as it is now, and the notes about values the daemon changed
/// on its own (for example an effort the new runtime does not offer).
public struct AgentUpdate: Decodable, Sendable {
    public var agent: Agent
    public var warnings: [String]

    private enum WarningsKey: String, CodingKey { case warnings }

    public init(from decoder: Decoder) throws {
        agent = try Agent(from: decoder)
        let c = try decoder.container(keyedBy: WarningsKey.self)
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}
