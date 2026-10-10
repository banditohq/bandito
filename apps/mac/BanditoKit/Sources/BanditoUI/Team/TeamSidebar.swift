import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Team sidebar: pinned agents, the agents waiting for you, then the rest of the team.
struct TeamSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var pins = PinnedAgents()
    @State private var pendingDelete: Agent?
    @State private var actionError: UserFacingMessage?

    var body: some View {
        if let server = app.currentServer {
            content(server)
        } else {
            SidebarPlaceholder(mode: .team)
        }
    }

    @ViewBuilder
    private func content(_ server: ServerModel) -> some View {
        // The main agent goes first in the whole list, before the list is split into its groups.
        let lead = LeadAgentStore.shared.id(server: server.id.uuidString)
        let agents = LeadAgent.leadFirst(server.sortedAgents, id: \.id, lead: lead)
        let shown = TeamSelection.shownAgentID(server: server, selected: router.selectedAgentID, pinned: Set(pins.ids))
        let waiting = agents.filter { server.needsPerson($0.id) }
        let waitingIDs = Set(waiting.map(\.id))
        let others = agents.filter { !waitingIDs.contains($0.id) }
        // The pinned row holds up to `pinnedTiles`; further pins stay pinned but are not in the row.
        let pinned = Array(agents.filter { pins.isPinned($0.id) }.prefix(TeamSidebarOrder.pinnedTiles))

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if agents.isEmpty {
                    emptyState
                } else {
                    if !pinned.isEmpty {
                        SectionLabel(L10n.Sidebar.pinned)
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        pinnedGrid(pinned, server: server, shown: shown)
                    }
                    if !waiting.isEmpty {
                        SectionLabel(L10n.Sidebar.needsYou, tone: .signal)
                            .padding(.horizontal, 18)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                        VStack(spacing: 8) {
                            ForEach(waiting) { agent in
                                waitingCard(agent, thread: server.thread(for: agent.id), server: server)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    SectionLabel(L10n.Sidebar.agents)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    VStack(spacing: 2) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, agent in
                            teamRow(
                                agent, thread: server.thread(for: agent.id), server: server, selected: shown == agent.id,
                                isLead: lead == agent.id)
                                .banditoRise(delay: Double(index) * 0.06)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if let actionError {
                    UserFacingErrorView(message: actionError)
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                }
            }
            .padding(.bottom, 12)
        }
        .background(Color.Bandito.surface1)
        .confirmationDialog(
            pendingDelete.map { L10n.Agent.Delete.confirm(name: $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Team.Delete.action, role: .destructive) {
                if let agent = pendingDelete { delete(agent, on: server) }
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        }
    }

    // MARK: pinned

    /// Pinned agents as a row of round avatars, as pinned chats are shown: 36 pt, the name under each on one line, a
    /// status dot. A click opens the chat; the context menu has Unpin. No row without pinned agents.
    private func pinnedGrid(_ agents: [Agent], server: ServerModel, shown: String?) -> some View {
        // A row that scrolls sideways when the pins do not fit the sidebar.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(agents) { agent in
                    let thread = server.thread(for: agent.id)
                    let status = server.status(of: agent.id)
                    Button {
                        router.selectAgent(agent.id, on: server)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottomTrailing) {
                                AgentAvatar(
                                    name: agent.name, size: 36,
                                    mood: AvatarMood.make(status: status, turnRunning: thread.turnRunning, paused: agent.paused))
                                StatusDot(status: status, size: 10, ringColor: Color.Bandito.surface1)
                            }
                            Text(agent.name)
                                .font(BanditoFont.font(size: 11, weight: 500))
                                .foregroundStyle(shown == agent.id ? Color.Bandito.text : Color.Bandito.text2)
                                .lineLimit(1)
                                .frame(width: 60)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .banditoButton(.row(cornerRadius: 10, hoverOpacity: 0.06))
                    .help(agent.name)
                    .contextMenu { menu(for: agent, server: server) }
                }
            }
            .padding(.horizontal, 18)
            }
        .tourAnchor(.agents)
    }

    // MARK: waiting

    private func waitingCard(_ agent: Agent, thread: AgentThread, server: ServerModel) -> some View {
        Button {
            router.selectAgent(agent.id, on: server)
        } label: {
            HStack(spacing: 11) {
                AgentAvatar(name: agent.name, size: 40, mood: .needsYou)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(BanditoFont.font(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        if !agent.role.isEmpty { Chip(text: agent.role) }
                        Spacer(minLength: 4)
                        Text(lastActivityLabel(agent, thread: thread))
                            .font(BanditoFont.font(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    Text(thread.pendingApprovals.first?.title ?? AgentPreview.text(thread: thread, agent: agent) ?? "")
                        .font(BanditoFont.font(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.signalGlow)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Color.Bandito.signal.opacity(0.13), Color.Bandito.signal.opacity(0.04)],
                    startPoint: .leading, endPoint: .trailing),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color.Bandito.signal.opacity(0.28), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .banditoButton(.row(cornerRadius: 13))
        .contextMenu { menu(for: agent, server: server) }
    }

    // MARK: team

    private func teamRow(_ agent: Agent, thread: AgentThread, server: ServerModel, selected: Bool, isLead: Bool) -> some View {
        return Button {
            router.selectAgent(agent.id, on: server)
        } label: {
            AgentRow(
                agent: agent, thread: thread, status: server.status(of: agent.id), isSelected: selected,
                lastActivity: lastActivityLabel(agent, thread: thread), isLead: isLead)
                .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
        .contextMenu { menu(for: agent, server: server) }
    }

    private func lastActivityLabel(_ agent: Agent, thread: AgentThread) -> String {
        TeamTime.label(ms: AgentPreview.timestamp(thread: thread, agent: agent))
    }

    // MARK: menu

    @ViewBuilder
    private func menu(for agent: Agent, server: ServerModel) -> some View {
        Button(pins.isPinned(agent.id) ? L10n.Agent.Menu.unpin : L10n.Agent.Menu.pin) {
            pins.toggle(agent.id)
        }
        Button(agent.paused ? L10n.Agent.Menu.resume : L10n.Agent.Menu.pause) {
            PauseActions.toggle(agent, on: server) { actionError = $0 }
        }
        .disabled(!PauseActions.available(on: server))
        .help(PauseActions.available(on: server) ? "" : L10n.Team.pauseUnavailable)
        let serverKey = server.id.uuidString
        let isLead = LeadAgentStore.shared.id(server: serverKey) == agent.id
        Button(isLead ? L10n.Agent.Menu.removeLead : L10n.Agent.Menu.makeLead) {
            // One main agent per server: making another one main replaces the old choice.
            LeadAgentStore.shared.set(isLead ? nil : agent.id, server: serverKey)
        }
        Divider()
        Button(L10n.Agent.Menu.delete, role: .destructive) {
            pendingDelete = agent
        }
    }

    private func delete(_ agent: Agent, on server: ServerModel) {
        pendingDelete = nil
        Task {
            do {
                try await server.deleteAgent(agent.id)
                LeadAgentStore.shared.forget(agentID: agent.id, server: server.id.uuidString)
                router.drafts[agent.id] = nil
                if router.selectedAgentID == agent.id { router.selectedAgentID = nil }
            } catch {
                actionError = UserFacingError.message(for: error)
            }
        }
    }

    /// One line only: the way to make an agent is in the main area (`TeamWelcome`).
    private var emptyState: some View {
        Text(L10n.Team.emptyTitle)
            .font(BanditoFont.font(size: 12.5, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 24)
    }
}

/// One agent in the team list: avatar with its status dot, name, role, the time of the last event and a preview.
struct AgentRow: View {
    var agent: Agent
    var thread: AgentThread
    /// The status the team shows (see `ServerModel.status(of:)`); the thread may not be loaded.
    var status: AgentStatus
    var isSelected = false
    /// Time of the last event, already formatted.
    var lastActivity = ""
    /// The server's main agent: a crown on the avatar.
    var isLead = false

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            AgentAvatar(
                name: agent.name, size: 40,
                mood: AvatarMood.make(status: status, turnRunning: thread.turnRunning, paused: agent.paused))
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(status: status, size: 11, ringColor: Color.Bandito.surface1)
                        .offset(x: 2, y: 2)
                }
                .overlay(alignment: .topTrailing) {
                    if isLead {
                        LeadCrown(size: 14)
                            .offset(x: 4, y: -4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(BanditoFont.font(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    if agent.paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text3)
                            .accessibilityLabel(L10n.Inspector.statePaused)
                            .help(L10n.Inspector.statePaused)
                    }
                    if !agent.role.isEmpty { Chip(text: agent.role) }
                    Spacer(minLength: 4)
                    if !lastActivity.isEmpty {
                        Text(lastActivity)
                            .font(BanditoFont.font(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
                Text(AgentPreview.text(thread: thread, agent: agent) ?? L10n.Team.noMessages)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(status == .needsYou ? Color.Bandito.signalGlow : Color.Bandito.text3)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.Bandito.text.opacity(isSelected ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}
