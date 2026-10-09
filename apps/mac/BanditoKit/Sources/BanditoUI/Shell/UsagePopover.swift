import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The subscription limits popover, 344 pt wide, one card per runtime. Countdowns tick live:
/// every 30 s normally, every second while a limit is used up.
struct UsagePopover: View {
    @Environment(AppModel.self) private var app
    @Environment(DemoStore.self) private var demo

    var body: some View {
        let snapshot = UsageCards.snapshot(server: app.currentServer, demo: demo)
        TimelineView(.periodic(from: .now, by: snapshot.hasExhaustedWindow ? 1 : 30)) { context in
            content(snapshot, now: context.date)
        }
        .frame(width: 344)
        .task {
            // Cached limits are read from the server; a refresh asks the runtimes themselves.
            _ = try? await app.currentServer?.usageLimits()
        }
    }

    private func content(_ snapshot: UsageSnapshot, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(snapshot)
            if snapshot.cards.isEmpty {
                Text(L10n.Usage.empty)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.vertical, 12)
            }
            ForEach(snapshot.cards) { card in
                UsageCardView(card: card, example: snapshot.isExample, now: now)
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
                Task { _ = try? await app.currentServer?.refreshUsage() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
            .foregroundStyle(Color.Bandito.text3)
            .help(L10n.Usage.refresh)
            .accessibilityLabel(L10n.Usage.refresh)
        }
        .padding(.horizontal, 2)
    }

    /// "now" or "N min ago", for the footnote.
    static func updatedText(_ updated: Date?, now: Date) -> String {
        guard let updated else { return L10n.Common.now }
        let minutes = Int(now.timeIntervalSince(updated) / 60)
        return minutes < 1 ? L10n.Common.now : L10n.Common.minutesAgo(count: minutes)
    }
}

/// One runtime: name, plan, who uses it, and a block per limit window.
struct UsageCardView: View {
    var card: UsageCard
    var example: Bool
    var now: Date

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

/// One window: "Remaining N%", the bar, the countdown on the left and the reset time on the right.
private struct UsageWindowRow: View {
    var line: UsageWindowLine
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(line.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer()
                Text(leftText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(leftColor)
            }
            UsageBar(fraction: line.remaining, height: 5)
            HStack {
                bottomLeft
                Spacer(minLength: 8)
                if let resetsAt = line.resetsAt {
                    Text(Countdown.resetText(to: resetsAt, now: now))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .font(.system(size: 11.5))
        }
    }

    @ViewBuilder
    private var bottomLeft: some View {
        if let note = line.note {
            Text(note).foregroundStyle(Color.Bandito.text3)
        } else if let resetsAt = line.resetsAt {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(Countdown.text(to: resetsAt, now: now, exhausted: line.exhausted))
                    .font(.system(size: 11.5, design: .monospaced))
            }
            .foregroundStyle(line.exhausted ? Color.Bandito.danger : (line.remaining < 0.25 ? Color.Bandito.signal : Color.Bandito.text2))
        }
    }

    private var leftText: String {
        line.exhausted
            ? L10n.Usage.exhausted
            : L10n.Usage.left(percent: "\(Int((line.remaining * 100).rounded()))%")
    }

    private var leftColor: Color {
        if line.exhausted { return Color.Bandito.danger }
        return line.remaining < 0.25 ? Color.Bandito.signal : Color.Bandito.text
    }
}
