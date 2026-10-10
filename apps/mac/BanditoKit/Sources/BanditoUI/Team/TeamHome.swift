import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the team home picks to show. Pure, so the rules are easy to read and test.
enum TeamHomeLogic {
    /// The agents the home lists under "Recent agents".
    static let recentLimit = 6

    /// The `limit` items with the newest `timestamp` first. Items with the same time keep their order.
    static func recent<T>(_ items: [T], limit: Int = recentLimit, timestamp: (T) -> Int64) -> [T] {
        let indexed = items.enumerated().map { (index: $0.offset, item: $0.element, time: timestamp($0.element)) }
        let sorted = indexed.sorted { a, b in a.time != b.time ? a.time > b.time : a.index < b.index }
        return sorted.prefix(max(limit, 0)).map(\.item)
    }

    /// The tile of a template in the list: its palette color and its symbol. Each template has its own color, so the
    /// tiles tell them apart, as the marketplace tiles do.
    static func tile(for template: AgentTemplate) -> (color: AvatarColor, symbol: String) {
        switch template {
        case .builder: (.peach, "hammer")
        case .reviewer: (.sky, "checkmark.seal")
        case .oncall: (.sage, "bell")
        case .assistant: (.rose, "calendar")
        case .researcher: (.lilac, "magnifyingglass")
        case .scratch: (.cream, "plus")
        }
    }

    /// The status word of a recent agent: working, needs you, error, and "asleep" for an agent that waits or is offline.
    static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: L10n.Status.working
        case .needsYou: L10n.Status.needsYou
        case .error: L10n.Status.error
        case .idle, .offline: L10n.Team.Home.asleep
        }
    }
}

/// The team home, shown in Team mode when no chat is open (the sidebar's TEAM label, ⌘0, a swipe to the right in a
/// chat): a greeting, the button for a new agent, the agents used last, the templates and a few ideas to hand off.
struct TeamHome: View {
    var server: ServerModel
    @Environment(Router.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private static let columns = [GridItem(.adaptive(minimum: 210, maximum: 400), spacing: 12, alignment: .top)]
    private static let ideaColumns = [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 12, alignment: .top)]

    /// The mascot floats only when motion is allowed and the window is the active one (as in `EmptyState`).
    private var floats: Bool {
        !reduceMotion && MotionLevel(stored: motionLevel).allowsRepeatingMotion && controlActiveState == .active
    }

    var body: some View {
        let lead = server.leadAgentID
        let recent = TeamHomeLogic.recent(server.agents) { agent in
            AgentPreview.timestamp(thread: server.thread(for: agent.id), agent: agent)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if !recent.isEmpty {
                    section(L10n.Team.Home.recent) {
                        VStack(spacing: 8) {
                            ForEach(recent) { agent in
                                recentRow(agent, lead: lead)
                            }
                        }
                    }
                }
                section(L10n.Team.Home.templates) {
                    LazyVGrid(columns: Self.columns, spacing: 12) {
                        ForEach(AgentTemplate.allCases, id: \.self) { template in
                            templateCard(template)
                        }
                    }
                }
                section(L10n.Team.Home.ideas) {
                    LazyVGrid(columns: Self.ideaColumns, spacing: 10) {
                        ForEach(Self.ideas, id: \.self) { idea in
                            ideaCard(idea)
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }

    private static var ideas: [String] {
        [L10n.Team.Home.idea1, L10n.Team.Home.idea2, L10n.Team.Home.idea3, L10n.Team.Home.idea4]
    }

    // MARK: pieces

    private var header: some View {
        // The button drops under the text when the area is narrow.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 18) {
                greeting
                Spacer(minLength: 12)
                newAgentButton
            }
            VStack(alignment: .leading, spacing: 16) {
                greeting
                newAgentButton
            }
        }
    }

    private var greeting: some View {
        HStack(alignment: .center, spacing: 16) {
            mascot
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.Team.Home.title)
                    .font(BanditoFont.display(size: 22, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(L10n.Team.Home.subtitle)
                    .font(BanditoFont.text(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The raccoon on a soft signal glow, floating gently. The glow is drawn larger than the frame, so the header
    /// keeps the size of the avatar.
    private var mascot: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.Bandito.signal.opacity(0.26), Color.Bandito.signal.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 60))
                .frame(width: 120, height: 120)
            Floating(enabled: floats) {
                RaccoonAvatar(name: "Bandito", color: .peach, face: .chevronDash, size: 56)
            }
        }
        .frame(width: 56, height: 56)
        // Decorative: the title next to it says what the screen is.
        .accessibilityHidden(true)
    }

    private var newAgentButton: some View {
        Button(L10n.New.agent) {
            router.sheet = .newAgent
        }
        .banditoButton(.signal(size: .large))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
                .lineLimit(1)
                .padding(.horizontal, 2)
            content()
        }
    }

    private func recentRow(_ agent: Agent, lead: String?) -> some View {
        let thread = server.thread(for: agent.id)
        let status = server.status(of: agent.id)
        return Button {
            router.selectAgent(agent.id, on: server)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                AgentAvatarView(
                    agent: agent, server: server, size: 32,
                    mood: AvatarMood.make(status: status, turnRunning: thread.turnRunning, paused: agent.paused)
                )
                .overlay(alignment: .topTrailing) {
                    if lead == agent.id {
                        LeadCrown(size: 12)
                            .offset(x: 4, y: -4)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(BanditoFont.display(size: 13.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(AgentPreview.text(thread: thread, agent: agent) ?? L10n.Team.noMessages)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    StatusDot(status: status, size: 9, ringColor: Color.Bandito.surface1)
                    Text(TeamHomeLogic.statusWord(status))
                        .font(BanditoFont.text(size: 12, weight: 500))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                    Text(TeamTime.label(ms: AgentPreview.timestamp(thread: thread, agent: agent)))
                        .font(BanditoFont.text(size: 11, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .banditoCard(hoverLift: true)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 14))
    }

    private func templateCard(_ template: AgentTemplate) -> some View {
        let tile = TeamHomeLogic.tile(for: template)
        return Button {
            router.pendingTemplate = template
            router.sheet = .newAgent
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tile.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BanditoPalette.avatarMask)
                    .frame(width: 32, height: 32)
                    .background(tile.color.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(template.title)
                        .font(BanditoFont.display(size: 12.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(template.description)
                        .font(BanditoFont.text(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .banditoCard(hoverLift: true)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 14))
    }

    /// A hint to hand off. Quiet on purpose: the only orange on the home is the agent that needs the person.
    private func ideaCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 16)
                .padding(.top, 2)
                .accessibilityHidden(true)
            Text(text)
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard()
    }
}
