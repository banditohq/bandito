import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// One row of a thread. The rows are built by `ThreadRows.build`; this view only draws them.
struct ThreadRowView: View {
    var row: ThreadRow
    var agentName: String
    /// The agent's primary runtime, to tell a return from a limit switch.
    var primaryRuntime: String
    var server: ServerModel
    var chat = ThreadChat()
    /// The agent the thread belongs to, and its folder: where a relative file link in a message points.
    var agentID = ""
    var folder: String?
    var onError: (UserFacingMessage) -> Void

    var body: some View {
        switch row {
        case .day(let date):
            DayDivider(date: date)
        case .chapter(let number, let saved):
            ChapterDivider(number: number, saved: saved, agentName: agentName)
        case .toolGroup(let tools):
            ToolGroupCard(tools: tools, duration: nil)
        case .browserRun(let tools):
            BrowserRunCard(tools: tools, server: server, agentID: agentID)
        case .item(let item):
            ItemView(
                item: item, agentName: agentName, primaryRuntime: primaryRuntime, server: server, chat: chat,
                agentID: agentID, folder: folder, onError: onError)
        }
    }
}

/// What decides how a row looks, as plain values. Two rows with equal keys draw the same, so a row whose key did not
/// change is not built again when the thread is (a scroll across a threshold, a new message at the end, a stream).
/// The closures of `ThreadChat` are left out on purpose: they act on the thread through references and ids, so an old
/// copy of one still does the right thing.
struct ThreadRowKey: Equatable {
    var row: ThreadRow
    var agentName: String
    var primaryRuntime: String
    var agentID: String
    var folder: String?
    var reactionsOn: Bool
    var repliesOn: Bool
    var formsOn: Bool
    var accent: Color
    /// The parts of the chat state that belong to this row only.
    var reactions: MessageReactions?
    var quoted: ReplyTarget?
    var flashing: Bool
    var isLastAgent: Bool

    init(
        row: ThreadRow, agentName: String, primaryRuntime: String, agentID: String, folder: String?, chat: ThreadChat
    ) {
        self.row = row
        self.agentName = agentName
        self.primaryRuntime = primaryRuntime
        self.agentID = agentID
        self.folder = folder
        reactionsOn = chat.reactionsOn
        repliesOn = chat.repliesOn
        formsOn = chat.formsOn
        accent = chat.accent
        if case .item(let item) = row {
            let seq = item.messageSeq
            reactions = seq.flatMap { chat.reactions[$0] }
            quoted = (chat.repliesOn ? seq.flatMap { chat.replies[$0] } : nil).flatMap { chat.original($0) }
            flashing = chat.highlightedID == item.id
            isLastAgent = chat.lastAgentID == item.id
        } else {
            reactions = nil
            quoted = nil
            flashing = false
            isLastAgent = false
        }
    }
}

/// A row of the thread that is built again only when its key changes (see `ThreadRowKey`). The server and the
/// closures are not part of the comparison: the server is one object for the whole thread, and the cards that follow it
/// observe it themselves.
struct EquatableThreadRow: View, Equatable {
    var key: ThreadRowKey
    var server: ServerModel
    var chat: ThreadChat
    var onError: (UserFacingMessage) -> Void
    private nonisolated var serverID: AnyObject { server }

    nonisolated static func == (lhs: EquatableThreadRow, rhs: EquatableThreadRow) -> Bool {
        lhs.key == rhs.key && ObjectIdentifier(lhs.serverID) == ObjectIdentifier(rhs.serverID)
    }

    var body: some View {
        ThreadRowView(
            row: key.row, agentName: key.agentName, primaryRuntime: key.primaryRuntime, server: server, chat: chat,
            agentID: key.agentID, folder: key.folder, onError: onError)
    }
}

/// A single thread item that is not a tool call.
private struct ItemView: View {
    var item: ThreadItem
    var agentName: String
    var primaryRuntime: String
    var server: ServerModel
    var chat: ThreadChat
    var agentID: String
    var folder: String?
    var onError: (UserFacingMessage) -> Void

    /// The quote at the top of a reply, when the message answers another one.
    @ViewBuilder
    private func quote(forSeq seq: Int64?) -> some View {
        if chat.repliesOn, let seq, let to = chat.replies[seq] {
            let original = chat.original(to)
            ReplyQuoteView(
                name: original.map { $0.fromUser ? L10n.Reply.you : agentName } ?? "",
                text: original?.text, accent: chat.accent
            ) { chat.onJump(to) }
        }
    }

    /// Optional: a thread drawn without the app's router (a preview) shows its items, and links do nothing.
    @Environment(Router.self) private var router: Router?

    var body: some View {
        content
            // Links in a message (file paths, web addresses) open here, in the workbench beside the chat.
            .environment(\.openURL, OpenURLAction { url in
                if let router {
                    ChatLinkText.open(url, agentID: agentID, folder: folder, server: server, router: router)
                }
                return .handled
            })
    }

    @ViewBuilder
    private var content: some View {
        switch item {
        case .user(let id, let text, let source, let from, _, let files):
            if source == .user {
                let seq = item.messageSeq
                if text.isEmpty, !files.isEmpty {
                    // Only files: no bubble, just the pictures and chips.
                    HStack {
                        Spacer(minLength: 120)
                        MessageFiles(files: files, agentID: agentID, server: server)
                    }
                } else {
                    MessageContainer(
                        itemID: id, seq: seq, text: text, fromUser: true, chat: chat, files: files, agentID: agentID,
                        server: server
                    ) {
                        UserBubble(text: text) { quote(forSeq: seq) }
                    }
                }
            } else {
                // Crew and schedule messages arrive as the agent's own input; name the sender above the bubble.
                VStack(alignment: .leading, spacing: 4) {
                    if let from {
                        Text(L10n.Thread.messageFrom(name: from))
                            .font(BanditoFont.font(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    HStack {
                        AgentBubble(text: text)
                        Spacer(minLength: 120)
                    }
                }
            }
        case .assistant(let id, let text, _):
            let seq = item.messageSeq
            MessageContainer(itemID: id, seq: seq, text: text, fromUser: false, chat: chat) {
                AgentBubble(text: text) { quote(forSeq: seq) }
            }
        case .streaming(let text):
            HStack {
                AgentBubble(text: text)
                Spacer(minLength: 120)
            }
        case .tool(let row):
            ToolGroupCard(tools: [row], duration: nil)
        case .approval(let row):
            ApprovalCard(row: row, agentName: agentName) { decision, remember in
                Task {
                    do {
                        try await server.resolve(row.approvalId, decision, remember: remember)
                    } catch {
                        onError(UserFacingError.message(for: error))
                    }
                }
            }
            .tourAnchor(.approvals)
        case .form(let row):
            if chat.formsOn {
                FormCard(row: row, agentName: agentName) { action, values, comment in
                    try await chat.onAnswerForm(row, action, values, comment)
                }
            }
        case .note(_, let text, let kind, _):
            NoteLine(text: text, isError: kind == .error)
        case .chapter:
            // Shown as a ChapterDivider between the rows (see ThreadRows.build), never as an item.
            EmptyView()
        case .runtimeSwitch(_, let from, let to, let until, _):
            NoteLine(
                text: RuntimeSwitchNote.text(from: from, to: to, until: until, primary: primaryRuntime),
                isError: false)
        }
    }
}

// MARK: - Bubbles

/// The user's message: on the raised surface. `ThreadItemsView` places it at the right (see `MessageContainer`).
/// `header` goes above the text inside the bubble: the quote of a reply.
struct UserBubble<Header: View>: View {
    var text: String
    var header: Header

    init(text: String, @ViewBuilder header: () -> Header) {
        self.text = text
        self.header = header()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            MessageBodyView(text: text, markdown: false)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(
            Color.Bandito.surface3,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
    }
}

extension UserBubble where Header == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// The agent's reply, with inline Markdown; inline code is drawn in the accent color, and a fenced code block has a
/// Copy button. `ThreadItemsView` places it at the left (see `MessageContainer`).
struct AgentBubble<Header: View>: View {
    var text: String
    var header: Header

    init(text: String, @ViewBuilder header: () -> Header) {
        self.text = text
        self.header = header()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            MessageBodyView(text: text, markdown: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color.Bandito.surface1,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18)
                .stroke(Color.Bandito.line, lineWidth: 1))
    }
}

extension AgentBubble where Header == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// Inline Markdown of the agent's text.
enum InlineMarkdown {
    /// Inline Markdown. Text that does not parse is shown verbatim.
    static func render(_ text: String) -> AttributedString {
        guard
            var rendered = try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else {
            return AttributedString(text)
        }
        let codeRanges = rendered.runs.compactMap { run -> Range<AttributedString.Index>? in
            run.inlinePresentationIntent?.contains(.code) == true ? run.range : nil
        }
        for range in codeRanges {
            rendered[range].font = .system(size: 12.5, design: .monospaced)
            rendered[range].foregroundColor = BanditoPalette.peach
        }
        return rendered
    }
}

/// The bubble shown while the agent's turn runs: three dots in a row that rise in a wave, the caption of what the agent
/// is doing, and how long the turn has run. Still dots when motion is reduced.
struct TypingIndicator: View {
    var activity: AgentActivity
    /// When the turn started (Unix ms); the elapsed time is not shown without it.
    var since: Int64?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// Repeating motion stands still: Reduce Motion, or "Less" / "Off" in settings.
    private var still: Bool { reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion }

    var body: some View {
        HStack(spacing: 9) {
            TimelineView(.animation(minimumInterval: 1.0 / 20, paused: still)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Color.Bandito.text2)
                            .frame(width: 6, height: 6)
                            .opacity(Self.opacity(time: time, index: index, still: still))
                            .offset(y: Self.lift(time: time, index: index, still: still))
                    }
                }
            }
            Text(activity.title)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if since != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let seconds = AgentActivity.elapsedSeconds(since: since, now: context.date) {
                        Text("· \(AgentActivity.elapsedText(seconds: seconds))")
                            .font(BanditoFont.font(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            Color.Bandito.surface1,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18))
        .overlay(
            UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 6, bottomTrailingRadius: 18, topTrailingRadius: 18)
                .stroke(Color.Bandito.line, lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Each dot brightens in turn, 0.2 s apart, over a 1.2 s cycle. Still dots stay at a middle level.
    static func opacity(time: Double, index: Int, still: Bool) -> Double {
        if still { return 0.6 }
        return 0.25 + 0.75 * peak(time: time, index: index)
    }

    /// The same wave as the brightness, lifting each dot by up to 3 pt. Still dots do not move.
    static func lift(time: Double, index: Int, still: Bool) -> Double {
        if still { return 0 }
        return -3 * peak(time: time, index: index)
    }

    /// 0...1 where a dot is at the top of its beat.
    private static func peak(time: Double, index: Int) -> Double {
        let fraction = (time + Double(index) * 0.2).truncatingRemainder(dividingBy: 1.2) / 1.2
        return max(0, 1 - abs(fraction - 0.4) / 0.4)
    }
}

// MARK: - Dividers and notes

/// A quiet centered line: crew hand-offs, scheduled runs, stops, errors.
private struct NoteLine: View {
    var text: String
    var isError: Bool

    var body: some View {
        Text(text)
            .font(BanditoFont.font(size: 12, weight: 400))
            .foregroundStyle(isError ? Color.Bandito.danger : Color.Bandito.text3)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
}

/// `Глава N · …` between two chapters of the memory. An unsaved chapter says so in peach, with a tooltip.
private struct ChapterDivider: View {
    var number: Int
    var saved: Bool
    var agentName: String

    var body: some View {
        HStack(spacing: 10) {
            Rule()
            Image(systemName: "book.closed")
                .font(.system(size: 12))
            Text(saved ? L10n.Chapter.resumed(count: number, name: agentName) : L10n.Thread.chapterNotSaved(chapter: "\(number)"))
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(saved ? Color.Bandito.text3 : BanditoPalette.peach)
                .lineLimit(1)
                .optionalHelp(saved ? nil : L10n.Thread.chapterNotSavedHelp)
            Rule()
        }
        .foregroundStyle(Color.Bandito.text3)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

/// Date caption between two days: "Today", "Yesterday" or the date.
private struct DayDivider: View {
    var date: Date

    var body: some View {
        Text(caption)
            .font(BanditoFont.font(size: 11.5, weight: 500))
            .foregroundStyle(Color.Bandito.text3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var caption: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return L10n.Thread.today }
        if calendar.isDateInYesterday(date) { return L10n.Thread.yesterday }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

private struct Rule: View {
    var body: some View {
        Rectangle()
            .fill(Color.Bandito.text.opacity(0.08))
            .frame(height: 1)
            .frame(maxWidth: 70)
    }
}
