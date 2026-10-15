import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// One thing that waits for the person: the agent's raccoon, what it wants in a line, the command in mono (two lines),
/// the time, and a risky mark. `Equatable` over the item, so the list builds it again only when a fact of it changed.
struct InboxRow: View, Equatable {
    let item: InboxItem

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 13.5
    @ScaledMetric(relativeTo: .body) private var lineSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var timeSize: CGFloat = 11.5

    nonisolated static func == (lhs: InboxRow, rhs: InboxRow) -> Bool {
        lhs.item == rhs.item
    }

    var body: some View {
        let _ = InboxCounters.rowBodyRan()
        HStack(alignment: .center, spacing: BanditoSpace.s3) {
            CrewAvatar(name: item.agentName, look: item.look, mood: item.mood, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BanditoFont.display(size: titleSize, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                detail
            }
            Spacer(minLength: BanditoSpace.s2)
            VStack(alignment: .trailing, spacing: 5) {
                Text(CrewTime.date(ms: item.ts), format: CrewTime.style(ms: item.ts))
                    .font(BanditoFont.text(size: timeSize, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize()
                if item.isRisky {
                    RiskMark()
                }
            }
        }
        .padding(.vertical, BanditoSpace.s1)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.Ios.Inbox.openHint)
    }

    private var title: String {
        switch item.kind {
        case .approval: L10n.Approval.wants(name: item.agentName)
        case .form: L10n.Ios.Inbox.form(name: item.agentName)
        case .connect(let row): L10n.Ios.Inbox.connect(name: item.agentName, service: row.service)
        case .question: L10n.Ios.Crew.waitingAnswer(name: item.agentName)
        }
    }

    /// The second line: the command (mono, at most two lines), the form's title, the reason of the service, or the
    /// agent's last words.
    @ViewBuilder private var detail: some View {
        switch item.kind {
        case .approval(let row):
            Text(row.command ?? row.title)
                .font(BanditoFont.mono(size: lineSize))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(2)
        case .form(let row):
            Text(row.spec.title)
                .font(BanditoFont.text(size: lineSize, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(2)
        case .connect(let row):
            Text(row.shownReason ?? row.service)
                .font(BanditoFont.text(size: lineSize, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(2)
        case .question:
            Text(item.questionLine ?? "")
                .font(BanditoFont.text(size: lineSize, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(2)
        }
    }
}

/// The "risky" mark of an approval: a signal capsule with its word (never color alone).
struct RiskMark: View {
    var body: some View {
        Text(L10n.Ios.Inbox.risky)
            .font(BanditoFont.text(size: 11, weight: 600))
            .foregroundStyle(Color.Bandito.signalGlow)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.Bandito.signal.opacity(0.13)))
            .overlay(Capsule().stroke(Color.Bandito.signal.opacity(0.3), lineWidth: 1))
            .fixedSize()
    }
}
