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
        let agents = server.sortedAgents
        let waiting = agents.filter { isWaiting(server.thread(for: $0.id)) }
        let waitingIDs = Set(waiting.map(\.id))
        let others = agents.filter { !waitingIDs.contains($0.id) }
        // The grid holds two tiles; further pins stay pinned but are not shown as tiles.
        let pinned = Array(agents.filter { pins.isPinned($0.id) }.prefix(2))

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
                        pinnedGrid(pinned, server: server)
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
                            teamRow(agent, thread: server.thread(for: agent.id), server: server)
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

    /// Needs a person: the status says so, or an approval is waiting.
    private func isWaiting(_ thread: AgentThread) -> Bool {
        thread.status == .needsYou || !thread.pendingApprovals.isEmpty
    }

    // MARK: pinned

    private func pinnedGrid(_ agents: [Agent], server: ServerModel) -> some View {
        HStack(spacing: 8) {
            ForEach(agents) { agent in
                let thread = server.thread(for: agent.id)
                Button {
                    router.selectedAgentID = agent.id
                } label: {
                    VStack(spacing: 8) {
                        AgentAvatar(
                            name: agent.name, size: 52,
                            mood: AvatarMood.make(
                                status: thread.status, turnRunning: thread.turnRunning, paused: agent.paused))
                        Text(agent.name)
                            .font(BanditoFont.font(size: 13, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                        if !agent.role.isEmpty {
                            Chip(text: agent.role)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Color.Bandito.text.opacity(router.selectedAgentID == agent.id ? 0.08 : 0.035),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.Bandito.line, lineWidth: 1))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .banditoButton(.row(cornerRadius: 16))
                .contextMenu { menu(for: agent, server: server) }
            }
            if agents.count == 1 {
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .tourAnchor(.agents)
    }

    // MARK: waiting

    private func waitingCard(_ agent: Agent, thread: AgentThread, server: ServerModel) -> some View {
        Button {
            router.selectedAgentID = agent.id
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
                    Text(thread.pendingApprovals.first?.title ?? thread.preview ?? "")
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

    private func teamRow(_ agent: Agent, thread: AgentThread, server: ServerModel) -> some View {
        let selected = router.selectedAgentID == agent.id
        return Button {
            router.selectedAgentID = agent.id
        } label: {
            AgentRow(agent: agent, thread: thread, isSelected: selected, lastActivity: lastActivityLabel(agent, thread: thread))
                .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
        .contextMenu { menu(for: agent, server: server) }
    }

    private func lastActivityLabel(_ agent: Agent, thread: AgentThread) -> String {
        let ts = thread.items.reversed().lazy.compactMap { ThreadRows.timestamp(of: $0) }.first
        return TeamTime.label(ms: ts ?? agent.lastTurnAt ?? agent.updatedAt)
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
                if router.selectedAgentID == agent.id { router.selectedAgentID = nil }
            } catch {
                actionError = UserFacingError.message(for: error)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26))
                .foregroundStyle(Color.Bandito.text3)
            Text(L10n.Team.emptyTitle)
                .font(BanditoFont.font(size: 13, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(L10n.Sidebar.empty)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .multilineTextAlignment(.center)
            Button(L10n.New.agent) {
                router.sheet = .newAgent
            }
            .banditoButton(.quiet())
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 60)
    }
}

/// One agent in the team list: avatar with its status dot, name, role, the time of the last event and a preview.
struct AgentRow: View {
    var agent: Agent
    var thread: AgentThread
    var isSelected = false
    /// Time of the last event, already formatted.
    var lastActivity = ""

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            AgentAvatar(
                name: agent.name, size: 40,
                mood: AvatarMood.make(status: thread.status, turnRunning: thread.turnRunning, paused: agent.paused))
                .overlay(alignment: .bottomTrailing) {
                    StatusDot(status: thread.status, size: 11, ringColor: Color.Bandito.surface1)
                        .offset(x: 2, y: 2)
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
                Text(thread.preview ?? L10n.Team.noMessages)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(thread.status == .needsYou ? Color.Bandito.signalGlow : Color.Bandito.text3)
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
