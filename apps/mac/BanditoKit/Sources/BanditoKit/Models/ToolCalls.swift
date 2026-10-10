import Foundation

// The call journal and "Try" of the integrations (`integrations.calls`, `integrations.call_stats`, feature
// `integrations_calls`; `integrations.call_tool`, feature `integrations_call_tool`; docs/ARCHITECTURE.md#integrations).

/// The policy's word on a call an agent made.
public enum ToolCallDecision: String, ForwardCompatibleEnum, CaseIterable {
    case allowed, asked, denied

    /// A word this app does not know reads as the careful one.
    public static var fallback: ToolCallDecision { .asked }
}

/// One row of the call journal: a call an agent made to a tool of a service. Arguments and results are never kept.
public struct ToolCallRecord: Decodable, Sendable, Identifiable, Hashable {
    public var id: Int64
    /// Unix milliseconds of the start.
    public var atMs: Int64
    public var agentId: String
    /// The service's name (not its id).
    public var integration: String
    public var tool: String
    /// Nil until the result came, or when it never did.
    public var durationMs: Int64?
    /// Nil until the result came.
    public var ok: Bool?
    /// The first line of a failure's text, short; addresses and long numbers hidden by the daemon.
    public var error: String?
    /// Nil when the policy did not judge the call.
    public var decision: ToolCallDecision?

    public init(
        id: Int64, atMs: Int64, agentId: String, integration: String, tool: String, durationMs: Int64? = nil,
        ok: Bool? = nil, error: String? = nil, decision: ToolCallDecision? = nil
    ) {
        self.id = id
        self.atMs = atMs
        self.agentId = agentId
        self.integration = integration
        self.tool = tool
        self.durationMs = durationMs
        self.ok = ok
        self.error = error
        self.decision = decision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        atMs = try c.decodeIfPresent(Int64.self, forKey: .atMs) ?? 0
        agentId = try c.decodeIfPresent(String.self, forKey: .agentId) ?? ""
        integration = try c.decodeIfPresent(String.self, forKey: .integration) ?? ""
        tool = try c.decodeIfPresent(String.self, forKey: .tool) ?? ""
        durationMs = try c.decodeIfPresent(Int64.self, forKey: .durationMs)
        ok = try c.decodeIfPresent(Bool.self, forKey: .ok)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        decision = (try? c.decodeIfPresent(ToolCallDecision.self, forKey: .decision)).flatMap { $0 }
    }

    private enum CodingKeys: String, CodingKey {
        case id, atMs, agentId, integration, tool, durationMs, ok, error, decision
    }
}

/// How much a service was used lately (`integrations.call_stats`).
public struct IntegrationCallStats: Decodable, Sendable, Hashable {
    /// The service's name.
    public var integration: String
    public var calls24h: Int
    public var errors24h: Int
    public var calls7d: Int
    public var lastAt: Int64?

    public init(integration: String, calls24h: Int = 0, errors24h: Int = 0, calls7d: Int = 0, lastAt: Int64? = nil) {
        self.integration = integration
        self.calls24h = calls24h
        self.errors24h = errors24h
        self.calls7d = calls7d
        self.lastAt = lastAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        integration = try c.decode(String.self, forKey: .integration)
        calls24h = try c.decodeIfPresent(Int.self, forKey: .calls24h) ?? 0
        errors24h = try c.decodeIfPresent(Int.self, forKey: .errors24h) ?? 0
        calls7d = try c.decodeIfPresent(Int.self, forKey: .calls7d) ?? 0
        lastAt = try c.decodeIfPresent(Int64.self, forKey: .lastAt)
    }

    /// The decoder turns `calls_24h` into `calls24H` (it capitalizes the word after the underscore, digits and all), so the
    /// keys are spelled as it leaves them.
    private enum CodingKeys: String, CodingKey {
        case integration, lastAt
        case calls24h = "calls24H"
        case errors24h = "errors24H"
        case calls7d = "calls7D"
    }
}

/// A part of the answer of a tool: its text, or only its type for an image or a file.
public struct ToolContentPart: Decodable, Sendable, Hashable {
    public var type: String
    public var text: String?

    public init(type: String, text: String? = nil) {
        self.type = type
        self.text = text
    }
}

/// The answer of `integrations.call_tool`. A tool that fails by its own account (`isError`) is an answer, not an error
/// of the call.
public struct ToolCallResult: Decodable, Sendable, Hashable {
    public var isError: Bool
    public var content: [ToolContentPart]
    public var structured: JSONValue?

    public init(isError: Bool = false, content: [ToolContentPart] = [], structured: JSONValue? = nil) {
        self.isError = isError
        self.content = content
        self.structured = structured
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        content = try c.decodeIfPresent([ToolContentPart].self, forKey: .content) ?? []
        structured = try c.decodeIfPresent(JSONValue.self, forKey: .structured)
    }

    private enum CodingKeys: String, CodingKey {
        case isError, content, structured
    }
}

extension ServerModel {
    /// The calls agents made, newest first. `integration` is a service's name; `before` is the `id` of the last row of
    /// the page before.
    public func toolCalls(
        integration: String? = nil, agentID: String? = nil, limit: Int = 50, before: Int64? = nil
    ) async throws -> [ToolCallRecord] {
        struct P: Encodable {
            var integration: String?
            var agentId: String?
            var limit: Int
            var before: Int64?
        }
        return try await rpc().call(
            "integrations.calls", P(integration: integration, agentId: agentID, limit: limit, before: before),
            as: [ToolCallRecord].self)
    }

    /// One entry for each service that has calls in the journal.
    public func toolCallStats() async throws -> [IntegrationCallStats] {
        try await rpc().call("integrations.call_stats", NoParams(), as: [IntegrationCallStats].self)
    }

    /// Runs a tool of a service for the owner (`integrations.call_tool`). `arguments` is an object. The daemon gives
    /// the call 30 seconds; the app waits a little longer for the answer.
    public func callTool(_ id: String, tool: String, arguments: JSONValue) async throws -> ToolCallResult {
        struct P: Encodable {
            var id: String
            var tool: String
            var arguments: JSONValue
        }
        return try await rpc().call(
            "integrations.call_tool", P(id: id, tool: tool, arguments: arguments), as: ToolCallResult.self,
            timeout: .seconds(45))
    }
}
