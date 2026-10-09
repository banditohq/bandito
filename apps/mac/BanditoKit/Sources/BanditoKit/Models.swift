import Foundation

// Wire models for the daemon's JSON-RPC API. Field names follow the daemon
// (snake_case on the wire, decoded with `.convertFromSnakeCase`).
// Source of truth: daemon/src/event.rs, daemon/src/store/*.rs, docs/ARCHITECTURE.md.

/// A string-backed wire enum that survives values this app version doesn't know:
/// an unknown raw value decodes to `fallback` instead of failing the whole response.
public protocol ForwardCompatibleEnum: RawRepresentable, Codable, Sendable where RawValue == String {
    /// Used when the daemon sends a value this app doesn't know. Pick the safe choice.
    static var fallback: Self { get }
}

extension ForwardCompatibleEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum RuntimeKind: String, ForwardCompatibleEnum, CaseIterable {
    case claude, codex, grok, api

    public static var fallback: RuntimeKind { .api }
}

public enum ApprovalMode: String, ForwardCompatibleEnum, CaseIterable {
    case risky, always, never

    /// `always` asks the human for every action, so it is the safe reading of an unknown mode.
    public static var fallback: ApprovalMode { .always }
}

/// How hard the model thinks. Mapped per runtime by the daemon.
public enum Effort: String, ForwardCompatibleEnum, CaseIterable {
    case low, medium, high, xhigh, max

    public static var fallback: Effort { .medium }
}

/// When an agent's chat starts a new chapter (a fresh CLI session).
public enum MemoryMode: String, ForwardCompatibleEnum, CaseIterable {
    case smart, daily, full

    public static var fallback: MemoryMode { .smart }
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
    /// `nil` = the runtime's default.
    public var effort: Effort?
    public var memoryMode: MemoryMode
    /// Tokens; `nil` = the daemon's default budget. Used by `smart` memory.
    public var contextBudget: Int?
    /// The agent's own folder for memory and files (absolute path on the server).
    public var homeDir: String?
    /// Size of the current chapter's context after the last turn, in tokens.
    public var contextTokens: Int
    /// Chapter number of the current session, from 1.
    public var chapter: Int
    /// Unix milliseconds of the last finished turn.
    public var lastTurnAt: Int64?
    /// The fallback subscription, used when the primary runtime's usage runs out. `nil` = none.
    public var fallbackRuntime: RuntimeKind?
    public var fallbackModel: String?
    /// The runtime the agent runs on now; `nil` = the primary `runtime`.
    public var activeRuntime: RuntimeKind?
    /// The workspace the agent's CLI runs in: `shared` (the server) or a container's id (see `Workspace`).
    public var workspaceId: String

    public init(
        id: String, name: String, role: String = "", runtime: RuntimeKind, model: String? = nil, cwd: String,
        approvalMode: ApprovalMode = .risky, systemPrompt: String? = nil, runtimeSessionId: String? = nil,
        createdAt: Int64 = 0, updatedAt: Int64 = 0,
        effort: Effort? = nil, memoryMode: MemoryMode = .smart, contextBudget: Int? = nil, homeDir: String? = nil,
        contextTokens: Int = 0, chapter: Int = 1, lastTurnAt: Int64? = nil,
        fallbackRuntime: RuntimeKind? = nil, fallbackModel: String? = nil, activeRuntime: RuntimeKind? = nil,
        workspaceId: String = "shared"
    ) {
        self.workspaceId = workspaceId
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
        self.effort = effort
        self.memoryMode = memoryMode
        self.contextBudget = contextBudget
        self.homeDir = homeDir
        self.contextTokens = contextTokens
        self.chapter = chapter
        self.lastTurnAt = lastTurnAt
        self.fallbackRuntime = fallbackRuntime
        self.fallbackModel = fallbackModel
        self.activeRuntime = activeRuntime
    }

    /// Fields added after the first daemon release are optional on the wire; old daemons send none of them.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        runtime = try c.decode(RuntimeKind.self, forKey: .runtime)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        cwd = try c.decode(String.self, forKey: .cwd)
        approvalMode = try c.decodeIfPresent(ApprovalMode.self, forKey: .approvalMode) ?? .risky
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        runtimeSessionId = try c.decodeIfPresent(String.self, forKey: .runtimeSessionId)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        effort = try c.decodeIfPresent(Effort.self, forKey: .effort)
        memoryMode = try c.decodeIfPresent(MemoryMode.self, forKey: .memoryMode) ?? .smart
        contextBudget = try c.decodeIfPresent(Int.self, forKey: .contextBudget)
        homeDir = try c.decodeIfPresent(String.self, forKey: .homeDir)
        contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 0
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter) ?? 1
        lastTurnAt = try c.decodeIfPresent(Int64.self, forKey: .lastTurnAt)
        fallbackRuntime = try c.decodeIfPresent(RuntimeKind.self, forKey: .fallbackRuntime)
        fallbackModel = try c.decodeIfPresent(String.self, forKey: .fallbackModel)
        activeRuntime = try c.decodeIfPresent(RuntimeKind.self, forKey: .activeRuntime)
        workspaceId = try c.decodeIfPresent(String.self, forKey: .workspaceId) ?? "shared"
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
    public var effort: Effort?
    public var memoryMode: MemoryMode
    public var contextBudget: Int?
    /// Optional fallback subscription; omitted from the request when `nil`.
    public var fallbackRuntime: RuntimeKind?
    public var fallbackModel: String?
    /// The workspace to run in; omitted from the request when `nil` (the daemon uses `shared`).
    public var workspaceId: String?

    public init(
        name: String, role: String = "", runtime: RuntimeKind, model: String? = nil, cwd: String,
        approvalMode: ApprovalMode = .risky, systemPrompt: String? = nil,
        effort: Effort? = nil, memoryMode: MemoryMode = .smart, contextBudget: Int? = nil,
        fallbackRuntime: RuntimeKind? = nil, fallbackModel: String? = nil, workspaceId: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.fallbackRuntime = fallbackRuntime
        self.fallbackModel = fallbackModel
        self.name = name
        self.role = role
        self.runtime = runtime
        self.model = model
        self.cwd = cwd
        self.approvalMode = approvalMode
        self.systemPrompt = systemPrompt
        self.effort = effort
        self.memoryMode = memoryMode
        self.contextBudget = contextBudget
    }
}

public enum MessageSource: String, ForwardCompatibleEnum, CaseIterable {
    case user, schedule, crew
    /// Hidden wrap-up turn the daemon sends before a new chapter (save memory).
    case system

    public static var fallback: MessageSource { .user }
}

public enum AgentStatus: String, ForwardCompatibleEnum, CaseIterable {
    case idle, working, needsYou = "needs_you", error, offline

    public static var fallback: AgentStatus { .idle }
}

public enum TurnStatus: String, ForwardCompatibleEnum, CaseIterable {
    case ok, error, interrupted

    public static var fallback: TurnStatus { .error }
}

public enum Decision: String, ForwardCompatibleEnum, CaseIterable {
    case allow, deny

    public static var fallback: Decision { .deny }
}

public enum DecidedBy: String, ForwardCompatibleEnum, CaseIterable {
    case user, policy

    public static var fallback: DecidedBy { .policy }
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

/// The subscription an account is on, as the runtime's CLI names it (e.g. "Max ×20").
public struct Plan: Codable, Sendable, Hashable {
    /// Stable id from the CLI, e.g. `max_20x`.
    public var id: String
    /// Name to show, e.g. `Max ×20`.
    public var label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// Rate-limit windows of one runtime, as the app last learned them.
public struct UsageEntry: Codable, Sendable, Hashable {
    public var runtime: String
    public var windows: [LimitWindow]
    /// Unix milliseconds when the app received these limits.
    public var updatedAt: Int64
    /// The subscription the runtime is on. `nil` when unknown (API keys, or a CLI that does not say).
    public var plan: Plan?

    public init(runtime: String, windows: [LimitWindow], updatedAt: Int64, plan: Plan? = nil) {
        self.runtime = runtime
        self.windows = windows
        self.updatedAt = updatedAt
        self.plan = plan
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try c.decode(String.self, forKey: .runtime)
        windows = try c.decodeIfPresent([LimitWindow].self, forKey: .windows) ?? []
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? Int64(Date().timeIntervalSince1970 * 1000)
        plan = try c.decodeIfPresent(Plan.self, forKey: .plan)
    }
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
    /// The agent closed one chapter (its session) and started the next.
    case sessionRotated(chapter: Int, reason: String, contextTokens: Int)
    /// The agent moved to another runtime: to its fallback when the limit ran out, or back to the primary.
    /// `until` is when the limit resets (Unix seconds), if the daemon knows it.
    case runtimeSwitched(from: String, to: String, until: Int64?)
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
    private struct SessionRotatedP: Decodable { var chapter: Int; var reason: String; var contextTokens: Int }
    private struct RuntimeSwitchedP: Decodable { var from: String; var to: String; var until: Int64? }
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
        case "session.rotated":
            let x = try p(SessionRotatedP.self)
            body = .sessionRotated(chapter: x.chapter, reason: x.reason, contextTokens: x.contextTokens)
        case "runtime.switched":
            let x = try p(RuntimeSwitchedP.self)
            body = .runtimeSwitched(from: x.from, to: x.to, until: x.until)
        case "error": body = .error(message: try p(ErrorP.self).message)
        default: body = .unknown(kind: kind)
        }
    }
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
