import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// A scheduled run and a quiet turn are lines of the thread, not messages: a run of a schedule was a bubble with the
// whole prompt every hour, and a run with nothing to report showed its steps as if it had. Each is one quiet centred
// line (`SystemLine`) that opens what it holds: the prompt, or the quiet turn's steps. Folded (the default) they are
// native rows (`NativeSystemLineView`); open they are these SwiftUI rows.

/// What the lines say. Pure, for the tests.
enum ScheduleRunLine {
    /// A schedule's name is cut to this many characters on its line (the line stays one line in a narrow chat).
    static let nameLimit = 32

    /// "Scheduled run · Morning digest · today, 20:45" (the name left out when the schedule has none).
    static func text(_ run: ScheduleRun, now: Date = Date(), calendar: Calendar = .current) -> String {
        head(run) + separator + time(run.firedAt, now: now, calendar: calendar)
    }

    /// "Scheduled run · Morning digest": the part of the line that gives way in a narrow chat (the time never does).
    static func head(_ run: ScheduleRun) -> String {
        var parts = [L10n.Thread.scheduledRun]
        let name = run.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append(name.count > nameLimit ? String(name.prefix(nameLimit - 1)) + "…" : name) }
        return parts.joined(separator: separator)
    }

    static let separator = " · "

    /// "today, 20:45", "yesterday, 08:00", or the date and the time.
    static func time(_ ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let clock = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return L10n.Thread.ScheduleRun.today(time: clock) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.Thread.ScheduleRun.yesterday(time: clock)
        }
        return L10n.Thread.ScheduleRun.date(date: date.formatted(.dateTime.day().month(.abbreviated)), time: clock)
    }

    /// A quiet turn's reason is cut to this many characters on its line.
    static let reasonLimit = 48

    /// "Nothing new", with the agent's reason after it when it gave one (cut: the line stays one line).
    static func quiet(reason: String?) -> String {
        let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reason.isEmpty else { return L10n.Thread.QuietTurn.title }
        let cut = reason.count > reasonLimit ? String(reason.prefix(reasonLimit - 1)) + "…" : reason
        return L10n.Thread.QuietTurn.title + separator + cut
    }

    /// The keys of the two folds in `ThreadDisclosure`.
    static func runKey(_ id: String) -> String { "schedule-\(id)" }
    static func quietKey(_ id: String) -> String { "quiet-\(id)" }

    /// The line of a run or a quiet turn, or nil for any other item.
    static func spec(of item: ThreadItem, now: Date = Date()) -> SystemLineSpec? {
        switch item {
        case .scheduleRun(let id, let run, _, _):
            return SystemLineSpec(
                key: runKey(id), symbol: "clock", text: head(run), tail: separator + time(run.firedAt, now: now),
                muted: false, opens: L10n.Thread.ScheduleRun.showPrompt)
        case .quietTurn(let id, let reason, _, _):
            return SystemLineSpec(
                key: quietKey(id), symbol: "moon.zzz", text: quiet(reason: reason), tail: nil, muted: true,
                opens: L10n.Thread.QuietTurn.showSteps)
        default:
            return nil
        }
    }
}

/// One system line: an SF Symbol, the text, a chevron; centred in the line's column. The text gives way (a tail ellipsis)
/// in a narrow chat, `tail` (" · today, 20:45") never does. `opens`: what a click shows (for VoiceOver).
struct SystemLineSpec: Equatable {
    var key: String
    var symbol: String
    var text: String
    var tail: String?
    var muted: Bool
    var opens: String

    /// The whole line, for VoiceOver.
    var spoken: String { text + (tail ?? "") }
}

/// The metrics both drawings of a system line share (`SystemLine`, `NativeSystemLineView`).
enum SystemLineMetrics {
    static let height: CGFloat = 26
    /// The symbol's column, and the space between the parts.
    static let symbolColumn: CGFloat = 13
    static let spacing: CGFloat = 6
    static let textSize: CGFloat = 12
    static let symbolSize: CGFloat = 11
    static let chevronSize: CGFloat = 9

    /// A muted line (a quiet turn) is a step quieter than a note.
    static func color(muted: Bool) -> Color { muted ? Color.Bandito.text3.opacity(0.7) : Color.Bandito.text3 }
}

/// The line itself, in SwiftUI: a button that opens or folds what it holds.
struct SystemLine: View {
    var spec: SystemLineSpec
    var open: Bool

    var body: some View {
        let color = SystemLineMetrics.color(muted: spec.muted)
        Button {
            withBanditoAnimation(BanditoMotion.ease) { ThreadDisclosure.shared.toggle(spec.key) }
        } label: {
            HStack(spacing: SystemLineMetrics.spacing) {
                Image(systemName: spec.symbol)
                    .font(.system(size: SystemLineMetrics.symbolSize, weight: .medium))
                    .frame(width: SystemLineMetrics.symbolColumn)
                HStack(spacing: 0) {
                    Text(spec.text)
                        .lineLimit(1)
                    if let tail = spec.tail {
                        Text(tail)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .font(BanditoFont.text(size: SystemLineMetrics.textSize, weight: 400))
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: SystemLineMetrics.chevronSize, weight: .semibold))
            }
            .foregroundStyle(color)
            .frame(height: SystemLineMetrics.height)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .banditoButton(.brighten)
        .accessibilityLabel(spec.spoken)
        .accessibilityHint(spec.opens)
        .accessibilityValue(open ? L10n.Thread.ScheduleRun.open : L10n.Thread.ScheduleRun.folded)
    }
}

/// A scheduled run: its line, and open, its prompt in small monospaced type.
struct ScheduleRunRow: View {
    var item: ThreadItem

    var body: some View {
        if case .scheduleRun(_, _, let prompt, _) = item, let spec = ScheduleRunLine.spec(of: item) {
            let open = ThreadDisclosure.shared.isOpen(spec.key)
            VStack(spacing: 4) {
                SystemLine(spec: spec, open: open)
                if open {
                    Text(prompt)
                        .font(BanditoFont.mono(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .transition(.opacity)
                }
            }
        }
    }
}

/// A quiet turn: its muted line, and open, its steps (the tool calls as their groups, the text it wrote, muted).
struct QuietTurnRow: View {
    var item: ThreadItem

    var body: some View {
        if case .quietTurn(_, _, let steps, _) = item, let spec = ScheduleRunLine.spec(of: item) {
            let open = ThreadDisclosure.shared.isOpen(spec.key)
            VStack(spacing: 6) {
                SystemLine(spec: spec, open: open)
                if open {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ThreadRows.build(steps)) { row in
                            switch row {
                            case .toolGroup(let tools), .browserRun(let tools):
                                ToolGroupCard(tools: tools, duration: nil)
                            case .item(.assistant(_, let text, _)):
                                Text(AgentPreview.plainLine(text) ?? text)
                                    .font(BanditoFont.text(size: 12, weight: 400))
                                    .foregroundStyle(Color.Bandito.text3)
                                    .lineLimit(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                            default:
                                EmptyView()
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}
