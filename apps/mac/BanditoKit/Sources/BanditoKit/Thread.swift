import Foundation

/// One row in an agent's thread, built from events. See docs/MAC_APP_UX.md#thread.
public enum ThreadItem: Sendable, Hashable, Identifiable {
    case user(id: String, text: String, source: MessageSource, from: String?, ts: Int64)
    case assistant(id: String, text: String, ts: Int64)
    /// Text still streaming in; replaced by `.assistant` when the message is final.
    case streaming(text: String)
    case tool(ToolRow)
    case approval(ApprovalRow)
    /// A quiet centered line: crew hand-offs, schedule runs, errors, session events.
    case note(id: String, text: String, kind: NoteKind, ts: Int64)
    /// The agent moved between runtimes. The app words it (it knows the agent's primary runtime).
    case runtimeSwitch(id: String, from: String, to: String, until: Int64?, ts: Int64)

    public var id: String {
        switch self {
        case .user(let id, _, _, _, _), .assistant(let id, _, _), .note(let id, _, _, _): return id
        case .runtimeSwitch(let id, _, _, _, _): return id
        case .streaming: return "streaming"
        case .tool(let t): return "tool-\(t.callId)"
        case .approval(let a): return "approval-\(a.approvalId)"
        }
    }
}

public enum NoteKind: String, Sendable, Hashable {
    case crew, schedule, error, info
}

public struct ToolRow: Sendable, Hashable {
    public var callId: String
    public var tool: String
    public var title: String
    /// `nil` while running.
    public var ok: Bool?
    public var output: String?
}

public enum ApprovalState: Sendable, Hashable {
    case pending
    case approved(by: DecidedBy, remember: Bool)
    case denied(by: DecidedBy)
}

public struct ApprovalRow: Sendable, Hashable {
    public var approvalId: String
    public var tool: String
    public var title: String
    public var command: String?
    public var diff: String?
    public var reason: String
    public var state: ApprovalState
}

/// The visible state of one agent, folded from its events.
public struct AgentThread: Sendable, Hashable {
    public var items: [ThreadItem] = []
    public var status: AgentStatus = .idle
    public var statusDetail: String?
    /// Last persisted event applied (deltas don't count).
    public var lastSeq: Int64 = 0
    public var turnRunning = false

    public init() {}

    public var pendingApprovals: [ApprovalRow] {
        items.compactMap {
            if case .approval(let a) = $0, a.state == .pending { return a }
            return nil
        }
    }

    /// The last thing worth showing in the sidebar preview.
    public var preview: String? {
        for item in items.reversed() {
            switch item {
            case .assistant(_, let t, _), .user(_, let t, _, _, _): return t
            case .streaming(let t): return t
            case .approval(let a) where a.state == .pending: return a.title
            default: continue
            }
        }
        return nil
    }

    /// Apply one event. Events with `seq <= lastSeq` (replays) are ignored.
    public mutating func apply(_ e: Event) {
        if e.seq > 0 {
            if e.seq <= lastSeq { return }
            lastSeq = e.seq
        }
        switch e.body {
        case .turnStarted:
            turnRunning = true
        case .messageUser(let text, let source, let from):
            switch source {
            case .user:
                dropStreaming()
                items.append(.user(id: e.id, text: text, source: source, from: nil, ts: e.ts))
            case .crew:
                dropStreaming()
                items.append(.note(id: e.id + "-n", text: "Message from \(from ?? "a teammate")", kind: .crew, ts: e.ts))
                items.append(.user(id: e.id, text: text, source: source, from: from, ts: e.ts))
            case .schedule:
                dropStreaming()
                items.append(.note(id: e.id + "-n", text: "Scheduled run", kind: .schedule, ts: e.ts))
                items.append(.user(id: e.id, text: text, source: source, from: nil, ts: e.ts))
            case .system:
                // Hidden wrap-up turn before a new chapter: no bubble, just a quiet line.
                finalizeStreaming(e)
                items.append(.note(id: e.id, text: "Saving memory before a new chapter", kind: .info, ts: e.ts))
            }
        case .messageDelta(let text):
            if case .streaming(let t)? = items.last {
                items[items.count - 1] = .streaming(text: t + text)
            } else {
                items.append(.streaming(text: text))
            }
        case .messageAssistant(let text):
            dropStreaming()
            items.append(.assistant(id: e.id, text: text, ts: e.ts))
        case .toolCall(let callId, let tool, let title, _):
            finalizeStreaming(e)
            if let i = toolIndex(callId) {
                if case .tool(var row) = items[i] {
                    row.title = title
                    items[i] = .tool(row)
                }
            } else {
                items.append(.tool(ToolRow(callId: callId, tool: tool, title: title, ok: nil, output: nil)))
            }
        case .toolResult(let callId, let ok, let output):
            if let i = toolIndex(callId), case .tool(var row) = items[i] {
                row.ok = ok
                row.output = output
                items[i] = .tool(row)
            } else {
                items.append(.tool(ToolRow(callId: callId, tool: "tool", title: "Tool", ok: ok, output: output)))
            }
        case .approvalRequested(let id, _, let tool, let title, let command, let diff, let reason):
            finalizeStreaming(e)
            items.append(
                .approval(
                    ApprovalRow(
                        approvalId: id, tool: tool, title: title, command: command, diff: diff, reason: reason,
                        state: .pending)))
        case .approvalResolved(let id, let decision, let by, let remember):
            if let i = items.firstIndex(where: { $0.id == "approval-\(id)" }), case .approval(var row) = items[i] {
                row.state = decision == .allow ? .approved(by: by, remember: remember) : .denied(by: by)
                items[i] = .approval(row)
            }
        case .turnCompleted(_, let status, _, _):
            turnRunning = false
            // A turn that ended without a final message leaves no half-streamed text behind.
            if case .streaming(let t)? = items.last {
                items[items.count - 1] = .assistant(id: e.id + "-s", text: t, ts: e.ts)
            }
            if status == .interrupted {
                items.append(.note(id: e.id, text: "Stopped", kind: .info, ts: e.ts))
            }
        case .agentStatus(let status, let detail):
            self.status = status
            statusDetail = detail
        case .error(let message):
            items.append(.note(id: e.id, text: message, kind: .error, ts: e.ts))
        case .sessionRotated(let chapter, _, _):
            items.append(.note(id: e.id, text: "Chapter \(chapter) · memory saved", kind: .info, ts: e.ts))
        case .runtimeSwitched(let from, let to, let until):
            items.append(.runtimeSwitch(id: e.id, from: from, to: to, until: until, ts: e.ts))
        case .usageLimits, .unknown:
            break
        }
    }

    /// A final message replaces the streamed text, so the stream is dropped.
    private mutating func dropStreaming() {
        if case .streaming? = items.last { items.removeLast() }
    }

    /// Something else starts after the stream (tool, approval, system line): the text
    /// streamed so far is kept as an assistant message instead of vanishing.
    private mutating func finalizeStreaming(_ e: Event) {
        if case .streaming(let t)? = items.last {
            items[items.count - 1] = .assistant(id: e.id + "-s", text: t, ts: e.ts)
        }
    }

    private func toolIndex(_ callId: String) -> Int? {
        items.lastIndex(where: { $0.id == "tool-\(callId)" })
    }
}
