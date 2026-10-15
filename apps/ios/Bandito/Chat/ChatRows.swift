import BanditoKit
import BanditoL10n
import Foundation

// The rows of the chat's list: what each shows, as plain values. A row is `Equatable`, so the list can tell which rows
// changed; `version` changes with the row's facts, and a row is measured once per (id, version, width).

/// A reaction under a message: one emoji, put there by the person, the agent or both (the same chip as the Mac's).
struct ChatReactionChip: Equatable, Hashable, Codable, Sendable {
    var emoji: String
    var byUser: Bool
    var byAgent: Bool

    init(emoji: String, byUser: Bool, byAgent: Bool) {
        self.emoji = emoji
        self.byUser = byUser
        self.byAgent = byAgent
    }

    init(_ chip: ReactionChip) {
        self.init(emoji: chip.emoji, byUser: chip.byUser, byAgent: chip.byAgent)
    }
}

/// The message a reply answers, quoted at the top of the bubble.
struct ChatReplyQuote: Equatable, Hashable, Sendable {
    /// The `seq` of the original.
    var seq: Int64
    /// The name above the quote: the agent's, or "You".
    var name: String
    /// The first words of the original; nil while it is older than the history that is loaded.
    var excerpt: String?
}

/// A message bubble.
struct ChatMessage: Equatable, Sendable {
    enum Sender: Equatable, Sendable {
        case me
        case agent
        /// A teammate or a schedule; `from` is the name shown above the bubble.
        case crew(from: String?)
    }

    /// The small line under a message that is not simply delivered.
    enum Caption: Equatable, Sendable {
        /// The agent is busy with another turn; the message waits in the thread.
        case queued
        /// The daemon gave up on it.
        case notDelivered(seq: Int64)
        /// Written on this phone, not at the server yet.
        case waitingForConnection
        case sending
        /// The daemon refused it (or this device may not send); the queue item can be tried again or deleted.
        case notSent(id: String, why: QueuedSend.Failure?)
        /// The link dropped and the thread could not say whether the daemon took it: the person sends it again or
        /// removes it.
        case uncertain(id: String)
        /// The person pressed a button the agent offered.
        case viaButton
    }

    var sender: Sender
    var text: String
    var streaming: Bool
    var ts: Int64?
    var showsTime: Bool
    var files: [AgentAttachment]
    var caption: Caption?
    /// The message is the last of a run of its sender's: it has the tail corner.
    var tail: Bool
    var seq: Int64?
    /// The reactions under the bubble, the person's first.
    var reactions: [ChatReactionChip] = []
    /// What this message answers.
    var reply: ChatReplyQuote?
    /// The daemon takes a reaction on this message (it has a `seq` and the server has the feature).
    var canReact = false
    /// The daemon takes a reply to this message.
    var canReply = false

    var isMine: Bool { sender == .me }
    var markdown: Bool { sender != .me }
}

/// Consecutive tool calls as one folded line.
struct ChatToolGroup: Equatable, Sendable {
    enum Status: Equatable, Sendable { case running, failed, done }

    var tools: [ToolRow]
    var open: Bool
    var title: String
    var status: Status
}

/// A quiet centred line: a note, an answered request, a scheduled run, a quiet turn.
struct ChatLine: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case note, error, warning, muted }

    var symbol: String?
    var text: String
    var tone: Tone
    /// What a press opens: the prompt of a run, the steps of a quiet turn.
    var fold: Fold?

    struct Fold: Equatable, Sendable {
        var open: Bool
        var detail: String
    }
}

struct ChatChangesSummary: Equatable, Hashable, Sendable {
    var files: Int
    var additions: Int
    var deletions: Int

    var line: String { ChangesSummaryLine.stats(files: files, additions: additions, deletions: deletions) }
}

struct ChatWorking: Equatable, Sendable {
    var title: String
    var since: Int64?
}

enum ChatRowContent: Equatable, Sendable {
    case day(String)
    case chapter(text: String, warning: Bool)
    case message(ChatMessage)
    case tools(ChatToolGroup)
    case line(ChatLine)
    case approval(ApprovalRow)
    case form(FormRow)
    case connect(ConnectRow)
    case changes(ChatChangesSummary)
    case working(ChatWorking)

    /// The reuse identifier of the cell that shows the row. A row whose kind changes under the same id (an approval card
    /// that becomes a line once answered) needs a new cell, not a cell set up again.
    var cellKind: String {
        switch self {
        case .message: ChatCellID.message
        case .day, .chapter, .line: ChatCellID.line
        case .tools: ChatCellID.tools
        case .changes: ChatCellID.changes
        case .working: ChatCellID.working
        case .approval, .form, .connect: ChatCellID.hosted
        }
    }

    /// A card made of SwiftUI (its height is measured by hosting it).
    var isHosted: Bool {
        switch self {
        case .approval, .form, .connect: true
        default: false
        }
    }

    var groupKind: ChatGrouping.Kind {
        switch self {
        case .day, .chapter: .divider
        case .message(let message):
            switch message.sender {
            case .me: .mine(ts: message.ts)
            case .agent: .theirs(from: nil, ts: message.ts)
            case .crew(let from): .theirs(from: from ?? "", ts: message.ts)
            }
        case .tools, .line: .line
        case .approval, .form, .connect, .changes: .card
        case .working: .working
        }
    }
}

/// The reuse identifiers of the chat's cells (plain strings, readable from any thread).
enum ChatCellID {
    static let message = "ChatMessageCell"
    static let line = "ChatLineCell"
    static let tools = "ChatToolsCell"
    static let changes = "ChatChangesCell"
    static let working = "ChatWorkingCell"
    static let hosted = "ChatHostedCell"
}

/// One row of the list.
struct ChatRow: Identifiable, Equatable, Sendable {
    let id: String
    let content: ChatRowContent
    /// The space above the row.
    let spacing: Double
    /// Changes with anything the row shows.
    let version: Int

    init(id: String, content: ChatRowContent, spacing: Double) {
        self.id = id
        self.content = content
        self.spacing = spacing
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(spacing)
        Self.combine(content, into: &hasher)
        version = hasher.finalize()
    }

    private static func combine(_ content: ChatRowContent, into hasher: inout Hasher) {
        switch content {
        case .day(let text): hasher.combine(text)
        case .chapter(let text, let warning): hasher.combine(text); hasher.combine(warning)
        case .message(let message):
            hasher.combine(message.text)
            hasher.combine(message.streaming)
            hasher.combine(message.showsTime)
            hasher.combine(message.tail)
            hasher.combine(message.ts)
            hasher.combine(message.files)
            hasher.combine(message.caption.map { "\($0)" })
            hasher.combine(message.reactions)
            hasher.combine(message.reply)
            hasher.combine(message.canReact)
            hasher.combine(message.canReply)
        case .tools(let group): hasher.combine(group.tools); hasher.combine(group.open); hasher.combine(group.title)
        case .line(let line): hasher.combine(line.text); hasher.combine(line.tone == .error); hasher.combine(line.fold?.open)
        case .approval(let row): hasher.combine(row.approvalId); hasher.combine("\(row.state)")
        case .form(let row): hasher.combine(row.formId); hasher.combine(row.isPending)
        case .connect(let row): hasher.combine(row.requestId); hasher.combine(row.isPending)
        case .changes(let summary): hasher.combine(summary)
        case .working(let working): hasher.combine(working.title)
        }
    }
}

/// What the builder needs of the chat's state.
struct ChatRowInput {
    var thread: AgentThread
    var agentName: String
    var primaryRuntime: String
    /// The messages of this agent that wait in the send queue.
    var queued: [QueuedSend]
    var expanded: Set<String>
    var changes: ChatChangesSummary?
    /// The message each reply answers: `seq` of the reply to `seq` of the original.
    var replies: [Int64: Int64] = [:]
    /// The reactions on each message, by its `seq`.
    var reactions: [Int64: [ChatReactionChip]] = [:]
    /// The server takes reactions (`reactions`) and replies (`attachments`).
    var reactionsOn = false
    var repliesOn = false
    var calendar: Calendar = .current
    var now: Date = Date()
}

/// Cuts a thread into the rows of the list. Pure.
enum ChatRowBuilder {
    static func build(_ input: ChatRowInput) -> [ChatRow] {
        var contents: [(id: String, content: ChatRowContent)] = []
        var taken: [String: Int] = [:]
        let thread = input.thread
        let waiting = thread.waitingSeqs
        let undelivered = thread.undeliveredSeqs
        let originals = quotedOriginals(input)

        for row in ThreadRows.build(thread.items, calendar: input.calendar) {
            switch row {
            case .day(let date):
                contents.append((row.id, .day(dayLabel(date, now: input.now, calendar: input.calendar))))
            case .chapter(let number, let saved):
                let text =
                    saved
                    ? L10n.Chapter.resumed(count: number, name: input.agentName)
                    : L10n.Thread.chapterNotSaved(chapter: "\(number)")
                contents.append((row.id, .chapter(text: text, warning: !saved)))
            case .toolGroup(let tools), .browserRun(let tools):
                // The key of a fold is the row's id after the ids are made unique (what the list toggles).
                var probe = taken
                let key = unique(row.id, &probe)
                contents.append((row.id, .tools(toolGroup(tools, open: input.expanded.contains(key)))))
                taken = probe
            case .item(let item):
                if let content = content(of: item, input: input, waiting: waiting, undelivered: undelivered, originals: originals) {
                    contents.append((item.id, content))
                }
            }
        }

        // Messages written on this phone that the thread does not show yet.
        for item in input.queued where !SendQueue.hasEcho(item, in: thread.items) {
            let caption: ChatMessage.Caption =
                switch item.state {
                case .waiting: .waitingForConnection
                case .sending, .sent: .sending
                case .failed: .notSent(id: item.id, why: item.failureKind)
                case .uncertain: .uncertain(id: item.id)
                }
            var message = ChatMessage(
                sender: .me, text: item.text, streaming: false, ts: item.createdAt, showsTime: false, files: item.attachments,
                caption: caption, tail: true, seq: nil)
            if let target = item.replyTo { message.reply = quote(target, input: input, originals: originals) }
            contents.append(("pending-\(item.id)", .message(message)))
        }

        // While the agent writes (a stream) the end of the thread is its text: no working row, no card under it.
        let streaming = contents.contains { isStreaming($0.content) }
        if thread.turnRunning, !streaming {
            contents.append(
                ("working", .working(ChatWorking(title: AgentActivity.current(in: thread.items).title, since: thread.turnStartedAt))))
        } else if let changes = input.changes, changes.files > 0, !thread.turnRunning, !streaming {
            contents.append(("changes", .changes(changes)))
        }
        return finish(contents)
    }

    /// `id` once only: the second row with an id gets `#2`, the third `#3`. The ids of a thread are not always unique (two day
    /// dividers of one day when the times are out of order, a group of commands whose first call has no id, a live
    /// message in the same millisecond as another), and a list with two rows of one id would crash.
    /// The numbers follow the order of the rows, so the same thread gives the same ids at every update.
    static func unique(_ id: String, _ taken: inout [String: Int]) -> String {
        let count = taken[id, default: 0] + 1
        taken[id] = count
        return count == 1 ? id : "\(id)#\(count)"
    }

    /// The gaps, the tails and the times, which depend on the rows around a row.
    static func finish(_ input: [(id: String, content: ChatRowContent)]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var taken: [String: Int] = [:]
        let contents = input.map { (id: unique($0.id, &taken), content: $0.content) }
        for (index, entry) in contents.enumerated() {
            var content = entry.content
            let previous = index > 0 ? contents[index - 1].content.groupKind : nil
            let next = index + 1 < contents.count ? contents[index + 1].content.groupKind : nil
            if case .message(var message) = content {
                message.showsTime = ChatGrouping.showsTime(content.groupKind, next: next) && message.ts != nil
                message.tail = !(next.map { ChatGrouping.sameGroup(content.groupKind, $0) } ?? false)
                content = .message(message)
            }
            let spacing = ChatGrouping.spacing(before: previous, after: content.groupKind)
            rows.append(ChatRow(id: entry.id, content: content, spacing: spacing))
        }
        return rows
    }

    private static func isStreaming(_ content: ChatRowContent) -> Bool {
        if case .message(let message) = content { return message.streaming }
        return false
    }

    static func toolGroup(_ tools: [ToolRow], open: Bool) -> ChatToolGroup {
        let status: ChatToolGroup.Status =
            tools.contains { $0.ok == nil } ? .running : (tools.contains { $0.ok == false } ? .failed : .done)
        return ChatToolGroup(tools: tools, open: open, title: ToolGroupTitle.text(oks: tools.map(\.ok)), status: status)
    }

    /// The words of the messages that replies quote, by `seq`: found once per build, in the loaded history.
    private static func quotedOriginals(_ input: ChatRowInput) -> [Int64: (text: String, fromMe: Bool)] {
        var wanted = Set(input.replies.values)
        for item in input.queued { if let target = item.replyTo { wanted.insert(target) } }
        guard !wanted.isEmpty else { return [:] }
        var found: [Int64: (text: String, fromMe: Bool)] = [:]
        for item in input.thread.items {
            guard let seq = item.messageSeq, wanted.contains(seq) else { continue }
            switch item {
            case .user(_, let text, _, _, _, _): found[seq] = (text, true)
            case .assistant(_, let text, _): found[seq] = (text, false)
            default: break
            }
        }
        return found
    }

    /// The quote of a reply to the message with `seq`.
    static func quote(_ seq: Int64, input: ChatRowInput, originals: [Int64: (text: String, fromMe: Bool)]) -> ChatReplyQuote {
        guard let original = originals[seq] else {
            return ChatReplyQuote(seq: seq, name: input.agentName, excerpt: nil)
        }
        let plain = original.fromMe ? original.text : MessageBlocks.plainText(original.text)
        let excerpt = MessageBlocks.excerpt(plain, limit: ReplyQuote.barLimit)
        return ChatReplyQuote(
            seq: seq, name: original.fromMe ? L10n.Reply.you : input.agentName, excerpt: excerpt.isEmpty ? nil : excerpt)
    }

    private static func content(
        of item: ThreadItem, input: ChatRowInput, waiting: Set<Int64>, undelivered: Set<Int64>,
        originals: [Int64: (text: String, fromMe: Bool)]
    ) -> ChatRowContent? {
        let thread = input.thread
        switch item {
        case .user(_, let text, let source, let from, let ts, let files):
            if source == .user {
                let seq = item.messageSeq
                var caption: ChatMessage.Caption?
                if let seq {
                    if undelivered.contains(seq) {
                        caption = .notDelivered(seq: seq)
                    } else if waiting.contains(seq) {
                        caption = .queued
                    } else if thread.viaButton.contains(seq) {
                        caption = .viaButton
                    }
                }
                guard !text.isEmpty || !files.isEmpty else { return nil }
                var message = ChatMessage(
                    sender: .me, text: text, streaming: false, ts: ts, showsTime: false, files: files, caption: caption,
                    tail: true, seq: seq)
                decorate(&message, seq: seq, input: input, originals: originals)
                return .message(message)
            }
            return .message(
                ChatMessage(
                    sender: .crew(from: from), text: text, streaming: false, ts: ts, showsTime: false, files: files,
                    caption: nil, tail: true, seq: nil))
        case .assistant(_, let text, let ts):
            var message = ChatMessage(
                sender: .agent, text: text, streaming: false, ts: ts, showsTime: false, files: [], caption: nil,
                tail: true, seq: item.messageSeq)
            decorate(&message, seq: item.messageSeq, input: input, originals: originals)
            return .message(message)
        case .streaming(let text):
            return .message(
                ChatMessage(
                    sender: .agent, text: text, streaming: true, ts: nil, showsTime: false, files: [], caption: nil,
                    tail: true, seq: nil))
        case .tool:
            return nil
        case .approval(let row):
            if row.state == .pending { return .approval(row) }
            return .line(ChatLine(symbol: approvalSymbol(row.state), text: approvalText(row), tone: approvalTone(row.state), fold: nil))
        case .note(_, let text, let kind, _):
            return .line(ChatLine(symbol: kind == .error ? "exclamationmark.triangle" : nil, text: text, tone: kind == .error ? .error : .note, fold: nil))
        case .runtimeSwitch(_, let from, let to, let until, _):
            let text = RuntimeSwitchNote.text(from: from, to: to, until: until, primary: input.primaryRuntime)
            return .line(ChatLine(symbol: "arrow.triangle.swap", text: text, tone: .note, fold: nil))
        case .chapter:
            return nil
        case .form(let row):
            if row.isPending { return .form(row) }
            return .line(
                ChatLine(
                    symbol: "checkmark.circle", text: FormPresentation.line(spec: row.spec, outcome: row.outcome ?? .expired),
                    tone: .muted, fold: nil))
        case .connect(let row):
            if row.isPending { return .connect(row) }
            return .line(ChatLine(symbol: "link", text: connectText(row, agent: input.agentName), tone: .muted, fold: nil))
        case .scheduleRun(let id, let run, let prompt, _):
            let open = input.expanded.contains(ScheduleRunLine.runKey(id))
            return .line(
                ChatLine(
                    symbol: "clock", text: ScheduleRunLine.text(run, now: input.now, calendar: input.calendar), tone: .note,
                    fold: ChatLine.Fold(open: open, detail: prompt)))
        case .quietTurn(let id, let reason, let steps, _):
            let open = input.expanded.contains(ScheduleRunLine.quietKey(id))
            let detail = steps.compactMap { step -> String? in
                switch step {
                case .tool(let tool): return "$ " + tool.title
                case .assistant(_, let text, _): return text
                default: return nil
                }
            }.joined(separator: "\n")
            return .line(
                ChatLine(
                    symbol: "moon.zzz", text: ScheduleRunLine.quiet(reason: reason), tone: .muted,
                    fold: detail.isEmpty ? nil : ChatLine.Fold(open: open, detail: detail)))
        }
    }

    /// What a message with a `seq` carries beyond its text: the reactions under it, the quote it answers, and whether the
    /// person may react to it or answer it.
    private static func decorate(
        _ message: inout ChatMessage, seq: Int64?, input: ChatRowInput, originals: [Int64: (text: String, fromMe: Bool)]
    ) {
        guard let seq else { return }
        message.reactions = input.reactions[seq] ?? []
        if let target = input.replies[seq] { message.reply = quote(target, input: input, originals: originals) }
        message.canReact = input.reactionsOn
        message.canReply = input.repliesOn
    }

    private static func approvalSymbol(_ state: ApprovalState) -> String {
        switch state {
        case .approved: "checkmark.circle"
        case .denied: "xmark.circle"
        case .withdrawn: "minus.circle"
        case .pending: "questionmark.circle"
        }
    }

    private static func approvalTone(_ state: ApprovalState) -> ChatLine.Tone {
        if case .denied = state { return .warning }
        return .muted
    }

    static func approvalText(_ row: ApprovalRow) -> String {
        let title = row.command ?? row.title
        switch row.state {
        case .pending: return title
        case .approved(let by, _):
            return (by == .user ? L10n.Ios.Chat.Approval.allowed : L10n.Approval.approvedByPolicy) + " · " + title
        case .denied(let by):
            return (by == .user ? L10n.Ios.Chat.Approval.denied : L10n.Approval.deniedByPolicy) + " · " + title
        case .withdrawn:
            return L10n.Approval.withdrawn + " · " + title
        }
    }

    private static func connectText(_ row: ConnectRow, agent: String) -> String {
        switch row.outcome {
        case .connected?: L10n.AgentConnect.connected(service: row.service, agent: agent)
        case .declined?: L10n.AgentConnect.declined(service: row.service)
        default: L10n.AgentConnect.expired(service: row.service)
        }
    }

    /// "Today", "Yesterday" or the date.
    static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L10n.Thread.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.Thread.yesterday
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.day().month(.wide) : .dateTime.day().month(.wide).year())
    }
}
