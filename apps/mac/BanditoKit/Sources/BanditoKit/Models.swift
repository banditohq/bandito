import Foundation

// Wire models for the daemon's JSON-RPC API. Field names follow the daemon
// (snake_case on the wire, decoded with `.convertFromSnakeCase`).
// Source of truth: daemon/src/event.rs, daemon/src/store/*.rs, docs/ARCHITECTURE.md.

public enum RuntimeKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, grok, api
}

public enum ApprovalMode: String, Codable, Sendable, CaseIterable {
    case risky, always, never
}

public struct Agent: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var role: String
    public var runtime: RuntimeKind
    public var model: String?
    public var cwd: String
    public var approvalMode: ApprovalMode
    public var systemPrompt: String?
    public var runtimeSessionId: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String, name: String, role: String = "", runtime: RuntimeKind, model: String? = nil, cwd: String,
        approvalMode: ApprovalMode = .risky, systemPrompt: String? = nil, runtimeSessionId: String? = nil,
        createdAt: Int64 = 0, updatedAt: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.runtime = runtime
        self.model = model
        self.cwd = cwd
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
        self.runtimeSessionId = runtimeSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct NewAgent: Codable, Sendable {
    public var name: String
    public var role: String
    public var runtime: RuntimeKind
    public var model: String?
    public var cwd: String
    public var approvalMode: ApprovalMode
    public var systemPrompt: String?

    public init(
        name: String, role: String = "", runtime: RuntimeKind, model: String? = nil, cwd: String,
        approvalMode: ApprovalMode = .risky, systemPrompt: String? = nil
    ) {
        self.name = name
        self.role = role
        self.runtime = runtime
        self.model = model
        self.cwd = cwd
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
    }
}

public enum MessageSource: String, Codable, Sendable {
    case user, schedule, crew
}

public enum AgentStatus: String, Codable, Sendable {
    case idle, working, needsYou = "needs_you", error, offline
}

public enum TurnStatus: String, Codable, Sendable {
    case ok, error, interrupted
}

public enum Decision: String, Codable, Sendable {
    case allow, deny
}

public enum DecidedBy: String, Codable, Sendable {
    case user, policy
}

public struct Usage: Codable, Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
}

public struct LimitWindow: Codable, Sendable, Hashable {
    public var name: String
    /// 0...1
    public var utilization: Double
    /// Unix seconds.
    public var resetsAt: Int64?
}

/// The typed body of an event (`kind` + `payload` on the wire).
public enum EventBody: Sendable, Hashable {
    case turnStarted(turnId: String, source: MessageSource)
    case messageUser(text: String, source: MessageSource, fromAgent: String?)
    case messageAssistant(text: String)
    case messageDelta(text: String)
    case toolCall(callId: String, tool: String, title: String, input: JSONValue)
    case toolResult(callId: String, ok: Bool, output: String)
    case approvalRequested(
        approvalId: String, callId: String, tool: String, title: String, command: String?, diff: String?,
        reason: String)
    case approvalResolved(approvalId: String, decision: Decision, by: DecidedBy, remember: Bool)
    case turnCompleted(turnId: String, status: TurnStatus, usage: Usage?, costUsd: Double?)
    case agentStatus(status: AgentStatus, detail: String?)
    case usageLimits(runtime: String, windows: [LimitWindow])
    case error(message: String)
    /// A kind this app version doesn't know yet. Shown as nothing; kept for forward compatibility.
    case unknown(kind: String)
}

public struct Event: Sendable, Hashable, Identifiable {
    /// 0 for live-only events (deltas).
    public var seq: Int64
    public var agentId: String
    /// Unix milliseconds.
    public var ts: Int64
    public var body: EventBody

    public init(seq: Int64, agentId: String, ts: Int64, body: EventBody) {
        self.seq = seq
        self.agentId = agentId
        self.ts = ts
        self.body = body
    }

    public var id: String { seq > 0 ? "s\(seq)" : "d\(agentId)-\(ts)" }
}

extension Event: Decodable {
    private enum Keys: String, CodingKey { case seq, agentId, ts, kind, payload }

    private struct TurnStartedP: Decodable { var turnId: String; var source: MessageSource }
    private struct MessageUserP: Decodable { var text: String; var source: MessageSource; var fromAgent: String? }
    private struct TextP: Decodable { var text: String }
    private struct ToolCallP: Decodable { var callId: String; var tool: String; var title: String; var input: JSONValue? }
    private struct ToolResultP: Decodable { var callId: String; var ok: Bool; var output: String }
    private struct ApprovalRequestedP: Decodable {
        var approvalId: String; var callId: String; var tool: String; var title: String
        var command: String?; var diff: String?; var reason: String
    }
    private struct ApprovalResolvedP: Decodable {
        var approvalId: String; var decision: Decision; var by: DecidedBy; var remember: Bool
    }
    private struct TurnCompletedP: Decodable {
        var turnId: String; var status: TurnStatus; var usage: Usage?; var costUsd: Double?
    }
    private struct AgentStatusP: Decodable { var status: AgentStatus; var detail: String? }
    private struct UsageLimitsP: Decodable { var runtime: String; var windows: [LimitWindow] }
    private struct ErrorP: Decodable { var message: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = try c.decode(Int64.self, forKey: .seq)
        agentId = try c.decode(String.self, forKey: .agentId)
        ts = try c.decode(Int64.self, forKey: .ts)
        let kind = try c.decode(String.self, forKey: .kind)
        func p<T: Decodable>(_ t: T.Type) throws -> T { try c.decode(T.self, forKey: .payload) }
        switch kind {
        case "turn.started":
            let x = try p(TurnStartedP.self); body = .turnStarted(turnId: x.turnId, source: x.source)
        case "message.user":
            let x = try p(MessageUserP.self); body = .messageUser(text: x.text, source: x.source, fromAgent: x.fromAgent)
        case "message.assistant": body = .messageAssistant(text: try p(TextP.self).text)
        case "message.delta": body = .messageDelta(text: try p(TextP.self).text)
        case "tool.call":
            let x = try p(ToolCallP.self)
            body = .toolCall(callId: x.callId, tool: x.tool, title: x.title, input: x.input ?? .null)
        case "tool.result":
            let x = try p(ToolResultP.self); body = .toolResult(callId: x.callId, ok: x.ok, output: x.output)
        case "approval.requested":
            let x = try p(ApprovalRequestedP.self)
            body = .approvalRequested(
                approvalId: x.approvalId, callId: x.callId, tool: x.tool, title: x.title, command: x.command,
                diff: x.diff, reason: x.reason)
        case "approval.resolved":
            let x = try p(ApprovalResolvedP.self)
            body = .approvalResolved(approvalId: x.approvalId, decision: x.decision, by: x.by, remember: x.remember)
        case "turn.completed":
            let x = try p(TurnCompletedP.self)
            body = .turnCompleted(turnId: x.turnId, status: x.status, usage: x.usage, costUsd: x.costUsd)
        case "agent.status":
            let x = try p(AgentStatusP.self); body = .agentStatus(status: x.status, detail: x.detail)
        case "usage.limits":
            let x = try p(UsageLimitsP.self); body = .usageLimits(runtime: x.runtime, windows: x.windows)
        case "error": body = .error(message: try p(ErrorP.self).message)
        default: body = .unknown(kind: kind)
        }
    }
}

public enum ApprovalStatus: String, Codable, Sendable {
    case pending, resolved, expired
}

public struct Approval: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String
    public var callId: String
    public var tool: String
    public var title: String
    public var payload: JSONValue
    public var status: ApprovalStatus
    public var decision: Decision?
    public var createdAt: Int64
    public var resolvedAt: Int64?
}

public enum RuleAction: String, Codable, Sendable, CaseIterable {
    case allow, ask, deny
}

public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String?
    public var pattern: String
    public var action: RuleAction
    public var createdAt: Int64
}

public struct Schedule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var agentId: String
    public var cron: String
    public var tz: String
    public var prompt: String
    public var enabled: Bool
    public var lastRunAt: Int64?
    public var nextRunAt: Int64?
    public var createdAt: Int64
}

public struct RuntimeStatus: Codable, Sendable, Hashable {
    public var kind: RuntimeKind
    public var installed: Bool
    public var version: String?
    public var loggedIn: Bool?
    public var detail: String?
}

public struct DaemonInfo: Codable, Sendable, Hashable {
    public var version: String
    public var hostname: String
    public var os: String
    public var arch: String
    public var startedAt: Int64
    public var lastSeq: Int64
    /// What this daemon supports (e.g. "schedules", "crew"). Missing on very old daemons.
    public var features: [String]?

    public func supports(_ feature: String) -> Bool { features?.contains(feature) ?? false }
}

public struct Device: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var createdAt: Int64
    public var lastSeenAt: Int64?
}

public struct PairResult: Codable, Sendable {
    public var token: String
    public var device: Device
}
