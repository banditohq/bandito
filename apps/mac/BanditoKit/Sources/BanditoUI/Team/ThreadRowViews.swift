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
    var onError: (UserFacingMessage) -> Void

    var body: some View {
        switch row {
        case .day(let date):
            DayDivider(date: date)
        case .chapter(let number, let saved):
            ChapterDivider(number: number, saved: saved, agentName: agentName)
        case .toolGroup(let tools):
            ToolGroupCard(tools: tools, duration: nil)
        case .item(let item):
            ItemView(item: item, agentName: agentName, primaryRuntime: primaryRuntime, server: server, onError: onError)
        }
    }
}

/// A single thread item that is not a tool call.
private struct ItemView: View {
    var item: ThreadItem
    var agentName: String
    var primaryRuntime: String
    var server: ServerModel
    var onError: (UserFacingMessage) -> Void

    var body: some View {
        switch item {
        case .user(_, let text, let source, let from, _, _):
            if source == .user {
                UserBubble(text: text)
            } else {
                // Crew and schedule messages arrive as the agent's own input; name the sender above the bubble.
                VStack(alignment: .leading, spacing: 4) {
                    if let from {
                        Text(L10n.Thread.messageFrom(name: from))
                            .font(BanditoFont.font(size: 11.5, weight: 500))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    AgentBubble(text: text)
                }
            }
        case .assistant(_, let text, _):
            AgentBubble(text: text)
        case .streaming(let text):
            AgentBubble(text: text)
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

/// The user's message: right-aligned, on the raised surface.
struct UserBubble: View {
    var text: String

    var body: some View {
        HStack {
            Spacer(minLength: 120)
            Text(text)
                .font(BanditoFont.font(size: 14.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(
                    Color.Bandito.surface3,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
        }
    }
}

/// The agent's reply: left-aligned, with inline Markdown; inline code is drawn in the accent color.
struct AgentBubble: View {
    var text: String

    var body: some View {
        HStack {
            Text(Self.markdown(text))
                .font(BanditoFont.font(size: 14.5, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .lineSpacing(4)
                .textSelection(.enabled)
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
            Spacer(minLength: 120)
        }
    }

    /// Inline Markdown. Text that does not parse is shown verbatim.
    static func markdown(_ text: String) -> AttributedString {
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
