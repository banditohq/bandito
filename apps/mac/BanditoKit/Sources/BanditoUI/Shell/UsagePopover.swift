import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The subscription limits popover, 344 pt wide, one card per runtime. Countdowns tick live:
/// every 30 s normally, every second while a limit is used up.
struct UsagePopover: View {
    @Environment(AppModel.self) private var app
    @Environment(DemoStore.self) private var demo
    @Environment(Router.self) private var router
    /// True while a refresh asks the runtimes; the refresh button shows a spinner meanwhile.
    @State private var refreshing = false

    var body: some View {
        let snapshot = UsageCards.snapshot(server: app.currentServer, demo: demo)
        TimelineView(.periodic(from: .now, by: snapshot.hasExhaustedWindow ? 1 : 30)) { context in
            content(snapshot, now: context.date)
        }
        .frame(width: 344)
        .task {
            // Opening the popover asks for fresh limits when the known ones are over two minutes old.
            await refresh(force: false)
        }
    }

    private func content(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let server = app.currentServer
        let rows: [UsageRow] = snapshot.isExample
            ? snapshot.cards.map { .card($0, problem: nil) }
            : UsageRow.make(cards: snapshot.cards, runtimes: server?.runtimes ?? [], errors: server?.usageErrors ?? [:])
        let noneInstalled = !snapshot.isExample && rows.isEmpty && !(server?.runtimes.isEmpty ?? true)
        return VStack(alignment: .leading, spacing: 10) {
            header(snapshot)
            if noneInstalled {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.Usage.noSubscriptions)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.Bandito.text2)
                    Button(L10n.Usage.createAgent) {
                        router.usagePopoverOpen = false
                        router.sheet = .newAgent
                    }
                    .banditoButton(.quiet(size: .regular))
                }
                .padding(.vertical, 12)
            } else if rows.isEmpty {
                Text(L10n.Usage.empty)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.vertical, 12)
            }
            ForEach(rows) { row in
                switch row {
                case .card(let card, let problem):
                    UsageCardView(card: card, example: snapshot.isExample, now: now, problem: problem)
                case .waiting(_, let name, let text, let problem):
                    UsageWaitingView(name: name, text: text, problem: problem)
                }
            }
            if snapshot.updatedAt != nil {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.Bandito.ok)
                        .padding(.top, 1)
                    Text(L10n.Usage.fallbackNote(time: Self.updatedText(snapshot.updatedAt, now: now)))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineSpacing(2)
                }
                .padding(.top, 10)
                .padding(.horizontal, 2)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.Bandito.text.opacity(0.07)).frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.Bandito.surface2))
    }

    private func header(_ snapshot: UsageSnapshot) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "gauge.medium")
                .font(.system(size: 17))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Usage.limits)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            if snapshot.isExample {
                ExampleChip()
            }
            Spacer()
            Button {
                Task { await refresh(force: true) }
            } label: {
                Group {
                    if refreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
            .foregroundStyle(Color.Bandito.text3)
            .disabled(refreshing)
            .help(L10n.Usage.refresh)
            .accessibilityLabel(L10n.Usage.refresh)
        }
        .padding(.horizontal, 2)
    }

    /// Reads the runtimes and asks them for fresh limits. `force` is the refresh button: it asks at once, but never
    /// in parallel with a request that runs. A failure is not shown as an error: the rows say why.
    private func refresh(force: Bool) async {
        guard let server = app.currentServer else { return }
        refreshing = true
        defer { refreshing = false }
        _ = try? await server.refreshRuntimes()
        if force {
            _ = try? await server.refreshUsage(force: true)
        } else {
            await server.refreshUsageIfStale()
        }
    }

    /// When the limits were received, for the footnote: "just now", "5 min ago", "2 h ago", "yesterday at 18:40",
    /// or the date and time for anything older.
    static func updatedText(
        _ updated: Date?, now: Date, calendar: Calendar = .current, locale: Locale = L10n.locale
    ) -> String {
        guard let updated else { return L10n.Common.now }
        let minutes = Int(now.timeIntervalSince(updated) / 60)
        if minutes < 1 { return L10n.Usage.Updated.justNow }
        if minutes < 60 { return L10n.Common.minutesAgo(count: minutes) }
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        if calendar.isDate(updated, inSameDayAs: now) {
            return L10n.Usage.Updated.hoursAgo(count: minutes / 60)
        }
        let time = updated.formatted(style.hour().minute())
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(updated, inSameDayAs: yesterday) {
            return L10n.Usage.Updated.yesterday(time: time)
        }
        return L10n.Usage.Updated.dateTime(date: updated.formatted(style.day().month(.abbreviated)), time: time)
    }
}

/// A runtime that is installed but has no limits yet: its name, why there are none, and its problem, if any.
struct UsageWaitingView: View {
    var name: String
    var text: String
    var problem: UsageProblem?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                // A signed-out line already says "Sign-in needed"; only the command is added under it.
                UsageProblemDetail(problem: problem, showsTitle: problem.kind != .needsLogin)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.Bandito.text.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.Bandito.text.opacity(0.06)))
    }
}

/// One runtime: name, plan, who uses it, and a block per limit window.
struct UsageCardView: View {
    var card: UsageCard
    var example: Bool
    var now: Date
    /// What went wrong when the last refresh read this runtime; shown in grey under the windows.
    var problem: UsageProblem? = nil

    var body: some View {
        let warn = card.windows.contains(where: \.exhausted)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(card.color.color)
                    .frame(width: 8, height: 8)
                Text(card.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                if let plan = card.plan {
                    Text(plan)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(card.color.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(card.color.color.opacity(0.13)))
                }
                Spacer(minLength: 4)
                if let who = card.who {
                    Text(who)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            ForEach(card.windows) { line in
                UsageWindowRow(line: line, now: now)
            }
            if let problem {
                UsageProblemDetail(problem: problem, showsTitle: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(warn ? Color.Bandito.danger.opacity(0.05) : Color.Bandito.text.opacity(0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(warn ? Color.Bandito.danger.opacity(0.18) : Color.Bandito.text.opacity(0.06)))
    }
}

/// One window: "Used N%", the bar filled by the share used, the countdown on the left and the reset time on the right.
/// The colour of the number, the bar and the countdown comes from `UsageLevel`, the same as the sidebar button.
private struct UsageWindowRow: View {
    var line: UsageWindowLine
    var now: Date

    var body: some View {
        let level = UsageLevel(usedPercent: usedPercent)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(line.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer()
                Text(L10n.Usage.used(percent: "\(usedPercent)%"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(level.color)
            }
            UsageBar(fraction: line.used, tint: level.color, height: 5)
            HStack {
                bottomLeft(level: level)
                Spacer(minLength: 8)
                if let resetsAt = line.resetsAt {
                    Text(Countdown.resetText(to: resetsAt, now: now))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .font(.system(size: 11.5))
        }
    }

    private var usedPercent: Int { Int((line.used * 100).rounded()) }

    @ViewBuilder
    private func bottomLeft(level: UsageLevel) -> some View {
        if let note = line.note {
            Text(note).foregroundStyle(Color.Bandito.text3)
        } else if let resetsAt = line.resetsAt {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(Countdown.text(to: resetsAt, now: now, exhausted: line.exhausted))
                    .monospacedDigit()
            }
            .foregroundStyle(level == .ok ? Color.Bandito.text2 : level.color)
        }
    }
}

/// A usage problem in words people read: its title (unless the line above already says it) and the command that
/// fixes a login. The daemon's own text stays in the tooltip.
struct UsageProblemDetail: View {
    var problem: UsageProblem
    var showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsTitle {
                Text(problem.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let command = problem.loginCommand {
                UsageCommandLine(command: command)
            }
        }
        .help(problem.raw)
    }
}

/// A command the person runs on the server, in monospace and selectable.
struct UsageCommandLine: View {
    var command: String

    var body: some View {
        Text(command)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(Color.Bandito.text2)
            .textSelection(.enabled)
    }
}
