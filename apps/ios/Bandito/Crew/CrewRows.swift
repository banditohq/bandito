import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Counts the bodies of the Crew rows that were evaluated: the speed test reads it (a streamed reply makes its row one
/// or two times at most, not one per token). Counted in every build; it is one increment.
@MainActor
enum CrewCounters {
    static var rowBodies = 0

    /// Called from a row's body: one more evaluation.
    static func rowBodyRan() {
        rowBodies += 1
    }
}

/// The time of a row: the clock for today, the day and month for an older reply.
enum CrewTime {
    static func date(ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    static func style(ms: Int64, now: Date = Date(), calendar: Calendar = .current) -> Date.FormatStyle {
        calendar.isDate(date(ms: ms), inSameDayAs: now) ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day()
    }
}

/// One agent of the team. `Equatable` over its facts: the list builds it again only when a fact it shows changed.
struct CrewAgentRow: View, Equatable {
    let facts: CrewAgentFacts

    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 13.5
    @ScaledMetric(relativeTo: .body) private var lineSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var timeSize: CGFloat = 11.5
    @Environment(\.dynamicTypeSize) private var typeSize

    nonisolated static func == (lhs: CrewAgentRow, rhs: CrewAgentRow) -> Bool {
        lhs.facts == rhs.facts
    }

    var body: some View {
        let _ = CrewCounters.rowBodyRan()
        AdaptiveRowLayout {
            CrewAvatar(name: facts.name, look: facts.look, mood: facts.mood, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(status: facts.status)
                        .offset(x: 3, y: 3)
                }
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(facts.name)
                        .font(BanditoFont.display(size: nameSize, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(2)
                    if facts.isLead {
                        Image(systemName: "crown.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text2)
                            .accessibilityHidden(true)
                    }
                    RoleChip(text: facts.role)
                }
                Text(facts.preview ?? L10n.Ios.Crew.noMessages)
                    .font(BanditoFont.text(size: lineSize, weight: facts.unread > 0 ? 500 : 400))
                    .foregroundStyle(facts.unread > 0 ? Color.Bandito.text2 : Color.Bandito.text3)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 1)
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 5) {
                Text(CrewTime.date(ms: facts.activityMs), format: CrewTime.style(ms: facts.activityMs))
                    .font(BanditoFont.text(size: timeSize, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .fixedSize()
                if facts.unread > 0 {
                    UnreadBadge(count: facts.unread)
                }
            }
        }
        .padding(.vertical, BanditoSpace.s1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(facts.name)
        .accessibilityValue(accessibilityValue)
    }

    /// Role, status word, unread count: what a VoiceOver user hears after the name.
    private var accessibilityValue: String {
        var parts = [facts.role, facts.status.label]
        if facts.unread > 0 { parts.append(L10n.Ios.Crew.unread(count: facts.unread)) }
        if facts.isLead { parts.append(L10n.Ios.Crew.lead) }
        return parts.joined(separator: ", ")
    }
}

/// A waiting agent: its avatar pulses in signal, one line says what it waits for, an arrow opens its chat. An approval
/// also has the two answers under the line. The top part is the button that opens the chat; the answers are its siblings
/// in the same card, so a tap on an answer never opens the chat.
struct NeedsYouCard: View {
    let facts: CrewAgentFacts
    /// The approval the two answers send; nil for a form, a question or a connect request (no answers, the card only opens).
    var approval: InboxItem?
    /// The answer to `approval` is on its way: the main answer shows a spinner.
    var answering = false
    /// Another card's answer is on its way: both answers are off.
    var disabled = false
    /// Why the last answer did not go through, under the answers.
    var problem: String?
    let onOpen: () -> Void
    var onAllow: () -> Void = {}
    var onDeny: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var nameSize: CGFloat = 13.5
    @ScaledMetric(relativeTo: .body) private var lineSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            Button(action: onOpen) {
                top
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.Ios.Crew.openChat(name: facts.name))

            if approval != nil {
                AnswerPair(
                    quiet: L10n.Approval.deny, main: L10n.Approval.approve,
                    quietID: "crew.card.deny", mainID: "crew.card.approve",
                    disabled: disabled || answering, mainBusy: answering,
                    quietAction: onDeny, mainAction: onAllow
                )
                if let problem {
                    Text(problem)
                        .font(BanditoFont.text(size: 12, weight: 500))
                        .foregroundStyle(Color.Bandito.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(BanditoSpace.s3)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.Bandito.surface1))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.text.opacity(0.08), lineWidth: 1))
    }

    private var top: some View {
        AdaptiveRowLayout {
            CrewAvatar(name: facts.name, look: facts.look, mood: .needsYou, size: 44)
                .overlay {
                    if !reduceMotion {
                        PulseRing(size: 44, color: UIColor(Color.Bandito.signal))
                            .accessibilityHidden(true)
                    }
                }
        } content: {
            VStack(alignment: .leading, spacing: 3) {
                Text(facts.name)
                    .font(BanditoFont.display(size: nameSize, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                // No line limit for a request: at large type sizes it wraps, it is not cut. A question is three lines at most
                // (four at accessibility sizes).
                Text(waitingLine)
                    .font(BanditoFont.text(size: lineSize, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.leading)
                    .lineLimit(isQuestion ? (typeSize.isAccessibilitySize ? 4 : 3) : nil)
            }
        } trailing: {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.Bandito.text)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.Bandito.surface3))
                .overlay(Circle().stroke(Color.Bandito.text.opacity(0.14), lineWidth: 1))
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The question the agent asks, when it asks one in text.
    private var isQuestion: Bool {
        if case .answer(let question?) = facts.waiting { return true }
        return false
    }

    /// The question itself when the agent asked one; else what it waits for, in words.
    private var waitingLine: String {
        switch facts.waiting {
        case .approval(let title): L10n.Ios.Crew.wantsToRun(name: facts.name, command: title)
        case .form: L10n.Ios.Crew.waitingForm(name: facts.name)
        case .connect(let service): L10n.Ios.Inbox.connect(name: facts.name, service: service)
        case .answer(let question?): question
        case .answer(nil), nil: L10n.Ios.Crew.waitingAnswer(name: facts.name)
        }
    }
}

/// The status dot on an avatar: 11 pt, its color and a ring of the surface, so it reads on the tile.
struct StatusDot: View {
    let status: AgentStatus

    var body: some View {
        Circle()
            .fill(status.tint)
            .frame(width: 11, height: 11)
            .overlay(Circle().stroke(Color.Bandito.bg, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// The unread replies of a chat: a cream capsule with the count in the ground color, "99+" above 99.
struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(BanditoFont.display(size: 10.5, weight: 600))
            .foregroundStyle(Color.Bandito.bg)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(Color.Bandito.text))
            .accessibilityLabel(L10n.Ios.Crew.unread(count: count))
    }
}

/// The role of an agent as a small chip.
struct RoleChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(BanditoFont.text(size: 11, weight: 500))
            .foregroundStyle(Color.Bandito.text2)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.Bandito.text.opacity(0.07)))
    }
}

/// A section heading of the Crew list: Unbounded, 10.5, tracked. Signal when it lists what waits for the person.
struct CrewSectionLabel: View {
    let title: String
    var waiting = false

    var body: some View {
        Text(title)
            .font(BanditoFont.display(size: 10.5, weight: 600))
            .tracking(0.6)
            .foregroundStyle(waiting ? Color.Bandito.signal : Color.Bandito.text3)
            .textCase(nil)
    }
}

extension AgentStatus {
    /// The word for the status, from the same strings as the Mac app.
    var label: String {
        switch self {
        case .idle: L10n.Status.idle
        case .working: L10n.Status.working
        case .needsYou: L10n.Status.needsYou
        case .error: L10n.Status.error
        case .offline: L10n.Status.offline
        }
    }

    /// The dot's color. Status is never color alone: the word is in the row's accessibility value.
    var tint: Color {
        switch self {
        case .working: Color.Bandito.ok
        case .needsYou: Color.Bandito.signal
        case .error: Color.Bandito.danger
        case .idle, .offline: Color.Bandito.text3
        }
    }
}
