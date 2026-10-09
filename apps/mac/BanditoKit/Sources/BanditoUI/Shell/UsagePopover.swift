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
            // Opening the popover asks the runtimes for fresh limits, unless they were asked a moment ago.
            await refresh(force: false)
        }
    }

    private func content(_ snapshot: UsageSnapshot, now: Date) -> some View {
        let server = app.currentServer
        let rows: [UsageRow] = snapshot.isExample
            ? snapshot.cards.map { .card($0, error: nil) }
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
                case .card(let card, let error):
                    UsageCardView(card: card, example: snapshot.isExample, now: now, error: error)
                case .waiting(_, let name, let text, let error):
                    UsageWaitingView(name: name, text: text, error: error)
                }
            }
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
        _ = try? await server.refreshUsage(force: force)
    }

    /// "now" or "N min ago", for the footnote.
    static func updatedText(_ updated: Date?, now: Date) -> String {
        guard let updated else { return L10n.Common.now }
        let minutes = Int(now.timeIntervalSince(updated) / 60)
        return minutes < 1 ? L10n.Common.now : L10n.Common.minutesAgo(count: minutes)
    }
}

/// A runtime that is installed but has no limits yet: its name and why there are none.
struct UsageWaitingView: View {
    var name: String
    var text: String
    var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(L10n.Usage.readFailed(reason: error))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
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
    /// The reason the last refresh could not read this runtime; shown in grey under the windows.
    var error: String? = nil

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
            if let error {
                Text(L10n.Usage.readFailed(reason: error))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(.system(size: 11.5, design: .monospaced))
            }
            .foregroundStyle(level == .ok ? Color.Bandito.text2 : level.color)
        }
    }
}
