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
}

/// The team home, shown in Team mode when no chat is open (the sidebar's TEAM label, ⌘0, a swipe to the right in a
/// chat): a greeting, the button for a new agent, the templates, the agents used last and a few ideas to hand off.
struct TeamHome: View {
    var server: ServerModel
    @Environment(Router.self) private var router

    private static let columns = [GridItem(.adaptive(minimum: 210, maximum: 400), spacing: 12, alignment: .top)]
    private static let ideaColumns = [GridItem(.adaptive(minimum: 260, maximum: 520), spacing: 12, alignment: .top)]

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
                        VStack(spacing: 2) {
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
                    LazyVGrid(columns: Self.ideaColumns, spacing: 12) {
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
            RaccoonAvatar(name: "Bandito", color: .peach, face: .chevronDash, size: 56)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.Team.Home.title)
                    .font(BanditoFont.font(size: 24, weight: 650))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(L10n.Team.Home.subtitle)
                    .font(BanditoFont.font(size: 13.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
        return Button {
            router.selectAgent(agent.id, on: server)
        } label: {
            AgentRow(
                agent: agent, server: server, thread: thread, status: server.status(of: agent.id),
                lastActivity: TeamTime.label(ms: AgentPreview.timestamp(thread: thread, agent: agent)),
                isLead: lead == agent.id)
                .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 13))
    }

    private func templateCard(_ template: AgentTemplate) -> some View {
        Button {
            router.pendingTemplate = template
            router.sheet = .newAgent
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(template.title)
                    .font(BanditoFont.font(size: 13.5, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(template.description)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .banditoCard()
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 14))
    }

    private func ideaCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.Bandito.signal)
                .frame(width: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            Text(text)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .banditoCard()
    }
}
