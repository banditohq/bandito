import BanditoL10n
import Foundation

/// One row in an agent's thread, built from events. See docs/MAC_APP_UX.md#thread.
public enum ThreadItem: Sendable, Hashable, Identifiable {
    /// `attachments` are the files the message carries; empty for a plain message.
    case user(id: String, text: String, source: MessageSource, from: String?, ts: Int64, attachments: [AgentAttachment] = [])
    case assistant(id: String, text: String, ts: Int64)
    /// Text still streaming in; replaced by `.assistant` when the message is final.
    case streaming(text: String)
    case tool(ToolRow)
    case approval(ApprovalRow)
    /// A quiet centered line: crew hand-offs, schedule runs, errors, session events.
    case note(id: String, text: String, kind: NoteKind, ts: Int64)
    /// The agent moved between runtimes. The app words it (it knows the agent's primary runtime).
    case runtimeSwitch(id: String, from: String, to: String, until: Int64?, ts: Int64)
    /// A new memory chapter began. `saved` is false when its memory could not be saved before it closed.
    /// The number comes from the event, not from any text.
    case chapter(id: String, number: Int, saved: Bool, ts: Int64)
    /// A form the agent asked the person (see docs/ARCHITECTURE.md#forms).
    case form(FormRow)

    public var id: String {
        switch self {
        case .user(let id, _, _, _, _, _), .assistant(let id, _, _), .note(let id, _, _, _): return id
        case .runtimeSwitch(let id, _, _, _, _): return id
        case .chapter(let id, _, _, _): return id
        case .streaming: return "streaming"
        case .tool(let t): return "tool-\(t.callId)"
        case .approval(let a): return "approval-\(a.approvalId)"
        case .form(let f): return "form-\(f.formId)"
        }
    }

    var isChapter: Bool {
        if case .chapter = self { return true }
        return false
    }

    /// The `seq` of the event this item is, when it is a message a person can react to or answer: a message from the
    /// person or the agent. A message finalized from a stream (`…-s`), and a crew or schedule message, have none.
    public var messageSeq: Int64? {
        switch self {
        case .user(let id, _, let source, _, _, _) where source == .user:
            return Self.seq(ofEventID: id)
        case .assistant(let id, _, _):
            return Self.seq(ofEventID: id)
        default:
            return nil
        }
    }

    /// `s123` is the event with `seq` 123. Ids of live-only or derived rows have no seq.
    static func seq(ofEventID id: String) -> Int64? {
        guard id.hasPrefix("s"), id.dropFirst().allSatisfy(\.isNumber), id.count > 1 else { return nil }
        return Int64(id.dropFirst())
    }

    /// The id of the row for the message with this `seq`.
    public static func messageID(seq: Int64) -> String { "s\(seq)" }
}

extension ThreadItem {
    /// Unix milliseconds, for the items that carry a time.
    public var timestamp: Int64? {
        switch self {
        case .user(_, _, _, _, let ts, _), .assistant(_, _, let ts), .note(_, _, _, let ts): ts
        case .runtimeSwitch(_, _, _, _, let ts): ts
        case .chapter(_, _, _, let ts): ts
        case .form(let f): f.ts
        case .streaming, .tool, .approval: nil
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
    /// Unix milliseconds when the call started; `nil` when the event did not say.
    public var startedAt: Int64? = nil
}

public enum ApprovalState: Sendable, Hashable {
    case pending
    case approved(by: DecidedBy, remember: Bool)
    case denied(by: DecidedBy)
    /// The runtime took the request back before anyone decided it.
    case withdrawn
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
    /// When the running turn began (Unix ms, the time of its `turn.started`); nil when no turn runs or its start is
    /// not in the loaded history. The "Thinking · N min" counter counts from here, not from the last message.
    public internal(set) var turnStartedAt: Int64?
    /// Seqs of the messages that were shown while they waited for their turn (`queued`); for each message whose turn
    /// began (named by `turn.started.messageSeq`) the seq of that `turn.started`; for each message that will get no
    /// turn (`message.dropped`) the seq of that event. A message waits while it is queued and in neither of the
    /// others. The sets grow only with the loaded events and are rebuilt with the thread.
    private var queuedSeqs: Set<Int64> = []
    private var startedAt: [Int64: Int64] = [:]
    private var droppedAt: [Int64: Int64] = [:]
    /// Undelivered messages the person sent again: they lose their "Not delivered" line, so a second click cannot
    /// make a second copy. Kept in the model only.
    private var resentSeqs: Set<Int64> = []
    /// Reactions by the `seq` of the message they are on.
    public private(set) var reactions: [Int64: MessageReactions] = [:]
    /// The message each reply answers: `seq` of the reply to `seq` of the original.
    public private(set) var replies: [Int64: Int64] = [:]
    /// The files each message carries, by its `seq`.
    public private(set) var attachments: [Int64: [MessageAttachment]] = [:]
    /// How each form ended, by form id. Kept apart from the rows because a page of history may hold the answer and not
    /// the question (the question comes with an older page).
    private var formOutcomes: [String: FormOutcome] = [:]
    /// Between the hidden memory-save turn and the chapter rotation that ends it.
    private var memorySaveRunning = false
    /// The memory-save turn ended with an error, so the chapter closes with its memory unsaved.
    private var memorySaveFailed = false

    public init() {}

    /// The messages that are in the thread but not yet taken by a turn.
    public var waitingSeqs: Set<Int64> {
        queuedSeqs.filter { startedAt[$0] == nil && droppedAt[$0] == nil }
    }

    /// The messages shown as waiting that the daemon gave up on: no turn will take them.
    public var undeliveredSeqs: Set<Int64> {
        queuedSeqs.filter { startedAt[$0] == nil && droppedAt[$0] != nil && !resentSeqs.contains($0) }
    }

    public mutating func markResent(_ seq: Int64) { resentSeqs.insert(seq) }
    public mutating func unmarkResent(_ seq: Int64) { resentSeqs.remove(seq) }

    /// The daemon closes a chapter with "… memory not saved" when it could not run the memory-save turn at all
    /// (see `unsaved` in daemon/src/supervisor.rs).
    static func closedUnsaved(reason: String) -> Bool {
        reason.hasSuffix("memory not saved")
    }

    public var pendingApprovals: [ApprovalRow] {
        items.compactMap {
            if case .approval(let a) = $0, a.state == .pending { return a }
            return nil
        }
    }

    /// The forms that wait for the person, oldest first.
    public var pendingForms: [FormRow] {
        items.compactMap {
            if case .form(let f) = $0, f.isPending { return f }
            return nil
        }
    }

    /// The reactions on a message, empty when it has none.
    public func chips(forMessage seq: Int64) -> [ReactionChip] {
        reactions[seq]?.chips ?? []
    }

    /// Text of the newest message in the thread: a user or assistant message, or the reply still streaming.
    /// Approvals and notes are not messages.
    public var lastMessageText: String? {
        for item in items.reversed() {
            switch item {
            case .assistant(_, let t, _), .user(_, let t, _, _, _, _), .streaming(let t): return t
            default: continue
            }
        }
        return nil
    }

    /// The last thing worth showing in the sidebar preview.
    public var preview: String? {
        for item in items.reversed() {
            switch item {
            case .assistant(_, let t, _), .user(_, let t, _, _, _, _): return t
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
        case .turnStarted(_, _, let messageSeq):
            turnRunning = true
            turnStartedAt = e.ts
            if let messageSeq { startedAt[messageSeq] = e.seq }
        case .messageDropped(let seq, _):
            droppedAt[seq] = e.seq
        case .messageUser(let text, let source, let from, let replyTo, let files, let queued):
            if queued, source != .system, e.seq > 0 { queuedSeqs.insert(e.seq) }
            if source != .system {
                if let replyTo { replies[e.seq] = replyTo }
                if !files.isEmpty { attachments[e.seq] = files }
            }
            switch source {
            case .user:
                dropStreaming()
                items.append(.user(id: e.id, text: text, source: source, from: nil, ts: e.ts, attachments: files))
            case .crew:
                dropStreaming()
                items.append(.note(id: e.id + "-n", text: L10n.Thread.messageFrom(name: from ?? L10n.Thread.aTeammate), kind: .crew, ts: e.ts))
                items.append(.user(id: e.id, text: text, source: source, from: from, ts: e.ts, attachments: files))
            case .schedule:
                dropStreaming()
                items.append(.note(id: e.id + "-n", text: L10n.Thread.scheduledRun, kind: .schedule, ts: e.ts))
                items.append(.user(id: e.id, text: text, source: source, from: nil, ts: e.ts, attachments: files))
            case .system:
                // Hidden wrap-up turn before a new chapter: no bubble, just a quiet line.
                finalizeStreaming(e)
                memorySaveRunning = true
                memorySaveFailed = false
                items.append(.note(id: e.id, text: L10n.Thread.savingMemory, kind: .info, ts: e.ts))
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
                items.append(
                    .tool(ToolRow(callId: callId, tool: tool, title: title, ok: nil, output: nil, startedAt: e.ts)))
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
        case .approvalWithdrawn(let id):
            if let i = items.firstIndex(where: { $0.id == "approval-\(id)" }), case .approval(var row) = items[i] {
                row.state = .withdrawn
                items[i] = .approval(row)
            }
        case .turnCompleted(_, let status, _, _):
            turnRunning = false
            turnStartedAt = nil
            if memorySaveRunning {
                memorySaveRunning = false
                // An interrupted wrap-up did not save the memory either.
                memorySaveFailed = status != .ok
            }
            // A turn that ended without a final message leaves no half-streamed text behind.
            if case .streaming(let t)? = items.last {
                items[items.count - 1] = .assistant(id: e.id + "-s", text: t, ts: e.ts)
            }
            if status == .interrupted {
                items.append(.note(id: e.id, text: L10n.Thread.stopped, kind: .info, ts: e.ts))
            }
        case .agentStatus(let status, let detail):
            self.status = status
            statusDetail = detail
        case .error(let message):
            items.append(.note(id: e.id, text: message, kind: .error, ts: e.ts))
        case .sessionRotated(let chapter, let reason, _):
            let unsaved = memorySaveFailed || Self.closedUnsaved(reason: reason)
            memorySaveRunning = false
            memorySaveFailed = false
            items.append(.chapter(id: e.id, number: chapter, saved: !unsaved, ts: e.ts))
            reorderWaitingAcrossChapters()
        case .runtimeSwitched(let from, let to, let until):
            items.append(.runtimeSwitch(id: e.id, from: from, to: to, until: until, ts: e.ts))
        case .formRequested(let formId, let spec):
            finalizeStreaming(e)
            if !items.contains(where: { $0.id == "form-\(formId)" }) {
                let known = formOutcomes[formId].map { Self.restored($0, fields: spec.fields) }
                items.append(.form(FormRow(formId: formId, spec: spec, outcome: known, ts: e.ts)))
            }
        case .formAnswered(let formId, let action, let values, let comment):
            let outcome: FormOutcome
            switch action {
            case .submit: outcome = .submitted(values: values ?? [:])
            case .reject: outcome = .rejected(comment: comment)
            case .expired: outcome = .expired
            }
            close(form: formId, with: outcome)
        case .reaction(let seq, let emoji, let by):
            reactions[seq, default: MessageReactions()].set(by: by, emoji: emoji, eventSeq: e.seq)
        case .usageLimits, .agentChanged, .unknown:
            // Not part of a thread: the team's agent list reads its own records.
            break
        }
    }

    /// An outcome with its answers keyed by the form's field ids (the RPC decoder rewrites `snake_case` keys).
    private static func restored(_ outcome: FormOutcome, fields: [FormField]) -> FormOutcome {
        if case .submitted(let values) = outcome {
            return .submitted(values: FormKeys.restoring(values, fields: fields))
        }
        return outcome
    }

    /// Ends a form: its row, if loaded, and the table that serves a row loaded later.
    public mutating func close(form formId: String, with outcome: FormOutcome) {
        formOutcomes[formId] = outcome
        if let i = items.firstIndex(where: { $0.id == "form-\(formId)" }), case .form(var row) = items[i] {
            row.outcome = Self.restored(outcome, fields: row.spec.fields)
            items[i] = .form(row)
        }
    }

    /// Adds a form the daemon still holds open that the loaded history does not show (its request is older than the
    /// page). It goes where its time puts it among the dated rows.
    public mutating func addPending(form row: FormRow) {
        let id = "form-\(row.formId)"
        guard !items.contains(where: { $0.id == id }), formOutcomes[row.formId] == nil else { return }
        let at = items.firstIndex { item in
            guard let ts = item.timestamp else { return false }
            return ts > row.ts
        }
        items.insert(.form(row), at: at ?? items.endIndex)
    }

    /// A message that waited through a memory save is read by the agent in the new chapter, so it sits right below that
    /// chapter's divider: the thread shows the order the agent works in. One copy, never a second (see
    /// docs/ARCHITECTURE.md, Chapters). The place is worked out from everything loaded (queued, started and dropped
    /// seqs, and the dividers in `items`), so it does not depend on which page of history held which event; the
    /// function gives the same result when it runs again.
    private mutating func reorderWaitingAcrossChapters() {
        let dividers: [Int64] = items.compactMap {
            if case .chapter(let id, _, _, _) = $0 { return ThreadItem.seq(ofEventID: id) }
            return nil
        }
        guard !dividers.isEmpty else { return }
        var placed: [Int64: Int] = [:]
        for seq in queuedSeqs.sorted() {
            // The message waited through every divider between its arrival and the end of its wait.
            let end = min(startedAt[seq] ?? .max, droppedAt[seq] ?? .max)
            guard let divider = dividers.filter({ $0 > seq && $0 < end }).max() else { continue }
            let id = ThreadItem.messageID(seq: seq)
            // A crew or schedule message has a quiet line of its own in front of it.
            let wanted: Set<String> = [id, id + "-n"]
            let moving = items.filter { wanted.contains($0.id) }
            guard !moving.isEmpty else { continue }
            items.removeAll { wanted.contains($0.id) }
            guard let at = items.firstIndex(where: { $0.id == ThreadItem.messageID(seq: divider) }) else {
                items.append(contentsOf: moving)
                continue
            }
            items.insert(contentsOf: moving, at: at + 1 + placed[divider, default: 0])
            placed[divider, default: 0] += moving.count
        }
    }

    /// Folds in what another reading of the same thread knew about reactions, replies, files and forms: the older page
    /// of history, or the live events that came while a page was loading.
    public mutating func mergeMessageMeta(from other: AgentThread) {
        queuedSeqs.formUnion(other.queuedSeqs)
        resentSeqs.formUnion(other.resentSeqs)
        startedAt.merge(other.startedAt) { mine, _ in mine }
        droppedAt.merge(other.droppedAt) { mine, _ in mine }
        reorderWaitingAcrossChapters()
        for (seq, theirs) in other.reactions { reactions[seq, default: MessageReactions()].merge(theirs) }
        for (seq, to) in other.replies where replies[seq] == nil { replies[seq] = to }
        for (seq, files) in other.attachments where attachments[seq] == nil { attachments[seq] = files }
        for (id, outcome) in other.formOutcomes where formOutcomes[id] == nil { formOutcomes[id] = outcome }
        for (i, item) in items.enumerated() {
            guard case .form(var row) = item, row.outcome == nil, let outcome = formOutcomes[row.formId] else { continue }
            row.outcome = Self.restored(outcome, fields: row.spec.fields)
            items[i] = .form(row)
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
