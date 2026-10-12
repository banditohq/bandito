import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Team sidebar: pinned agents, the agents waiting for you, then the rest of the team.
struct TeamSidebar: View {
    /// The server listed (one sidebar is kept built per server, as Team mode is); nil: none.
    let serverID: String?
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var pins = PinnedAgents()
    @State private var pendingDelete: Agent?
    @State private var actionError: UserFacingMessage?
    @Environment(\.modeHidden) private var hidden
    @State private var lastShown = TeamModeShown()

    var body: some View {
        if let server = serverID.flatMap({ id in app.servers.first { $0.id.uuidString == id } }) {
            content(server)
        } else {
            SidebarPlaceholder(mode: .team)
        }
    }

    private func markedAgent(_ server: ServerModel) -> String? {
        let id = router.showsTeamHome
            ? nil
            : TeamSelection.shownAgentID(server: server, selected: router.selectedAgentID, pinned: Set(pins.ids))
        lastShown.agentID = id
        return id
    }

    @ViewBuilder
    private func content(_ server: ServerModel) -> some View {
        let _ = PerfCounters.hit("TeamSidebar")
        // The main agent goes first in the whole list, before the list is split into its groups.
        let lead = server.leadAgentID
        let agents = LeadAgent.leadFirst(server.sortedAgents, id: \.id, lead: lead)
        // On the team home no chat is on screen, so no row is marked. Out of sight (another mode or server) the row
        // marked last stays: the router's choices are not read, so they rebuild nothing unseen.
        let shown = hidden ? lastShown.agentID : markedAgent(server)
        let waiting = agents.filter { server.needsPerson($0.id) }
        let waitingIDs = Set(waiting.map(\.id))
        let others = agents.filter { !waitingIDs.contains($0.id) }
        // The pinned row holds up to `pinnedTiles`; further pins stay pinned but are not in the row.
        let pinned = Array(agents.filter { pins.isPinned($0.id) }.prefix(TeamSidebarOrder.pinnedTiles))

        ScrollView {
            // Lazy: rows of the same height; a team of forty built forty rows (with their avatars) at every visit of the
            // team, and when the sidebar came back after another mode.
            LazyVStack(alignment: .leading, spacing: 0) {
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
                                ThreadReader(server: server, agentID: agent.id) { facts in
                                    Memo(key: SidebarRowKey(
                                        agent: agent, facts: facts, status: .needsYou, selected: false, isLead: false,
                                        pinned: pins.isPinned(agent.id))) {
                                        waitingCard(agent, facts: facts, server: server)
                                    }
                                    .equatable()
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    // The label opens the team home (also ⌘0).
                    Button {
                        router.showTeamHome()
                    } label: {
                        SectionLabel(L10n.Sidebar.agents)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .banditoButton(.row(cornerRadius: 8))
                    .help(L10n.Team.Home.open)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
                    ForEach(Array(others.enumerated()), id: \.element.id) { index, agent in
                            ThreadReader(server: server, agentID: agent.id) { facts in
                                let status = server.status(of: agent.id)
                                let place = WorkspacePickerLogic.label(
                                    workspaceID: agent.workspaceId,
                                    workspaces: WorkspaceDirectories.shared.directory(for: server).workspaces)
                                Memo(key: SidebarRowKey(
                                    agent: agent, facts: facts, status: status, selected: shown == agent.id,
                                    isLead: lead == agent.id, pinned: pins.isPinned(agent.id), place: place)) {
                                    teamRow(
                                        agent, facts: facts, status: status, server: server, selected: shown == agent.id,
                                        isLead: lead == agent.id, place: place)
                                }
                                .equatable()
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 2)
                            // The first rows rise in one after another; the rest (out of sight) are just there.
                            .modifier(SidebarRise(index: index))
                    }
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
        // The names of the containers label the agents that run in them. Read only while some agent does.
        .task(id: "\(agents.contains { $0.workspaceId != Workspace.sharedID }) \(server.supports("workspaces"))") {
            guard agents.contains(where: { $0.workspaceId != Workspace.sharedID }), server.supports("workspaces")
            else { return }
            let directory = WorkspaceDirectories.shared.directory(for: server)
            while !Task.isCancelled {
                if directory.shouldPoll { await directory.refresh() }
                try? await Task.sleep(for: .seconds(15))
            }
        }
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
                    ThreadReader(server: server, agentID: agent.id) { facts in
                    let status = server.status(of: agent.id)
                    Memo(key: SidebarRowKey(
                        agent: agent, facts: facts, status: status, selected: shown == agent.id, isLead: false,
                        pinned: true)) {
                    Button {
                        router.selectAgent(agent.id, on: server)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack(alignment: .bottomTrailing) {
                                AgentAvatarView(
                                    agent: agent, server: server, size: 36,
                                    mood: AvatarMood.make(status: status, turnRunning: facts.turnRunning, paused: agent.paused))
                                StatusDot(status: status, size: 10, ringColor: Color.Bandito.surface1)
                            }
                            Text(agent.name)
                                .font(BanditoFont.text(size: 11, weight: 500))
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
                    .equatable()
                    }
                }
            }
            .padding(.horizontal, 18)
            }
        .tourAnchor(.agents)
    }

    // MARK: waiting

    private func waitingCard(_ agent: Agent, facts: SidebarThreadFacts, server: ServerModel) -> some View {
        Button {
            router.selectAgent(agent.id, on: server)
        } label: {
            HStack(spacing: 11) {
                AgentAvatarView(agent: agent, server: server, size: 40, mood: .needsYou)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(BanditoFont.display(size: 12.5, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if !agent.role.isEmpty { Chip(text: agent.role) }
                        Spacer(minLength: 4)
                        Text(TeamTime.label(ms: facts.lastActivityMs))
                            .font(BanditoFont.text(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                    Text(facts.pendingTitle ?? facts.preview ?? "")
                        .font(BanditoFont.text(size: 12.5, weight: 400))
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

    private func teamRow(
        _ agent: Agent, facts: SidebarThreadFacts, status: AgentStatus, server: ServerModel, selected: Bool, isLead: Bool,
        place: String?
    ) -> some View {
        return Button {
            router.selectAgent(agent.id, on: server)
        } label: {
            AgentRow(
                agent: agent, server: server, facts: facts, status: status, isSelected: selected,
                lastActivity: TeamTime.label(ms: facts.lastActivityMs), isLead: isLead, place: place)
                .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
        .contextMenu { menu(for: agent, server: server) }
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
        // The main agent lives on the server. A daemon without the feature has no such thing: no item.
        if server.supports("lead") {
            let isLead = server.leadAgentID == agent.id
            Button(isLead ? L10n.Agent.Menu.removeLead : L10n.Agent.Menu.makeLead) {
                // One main agent per server: the daemon takes the role from the old one.
                Task {
                    do {
                        try await server.setLead(agentID: agent.id, !isLead)
                    } catch {
                        actionError = UserFacingError.message(for: error)
                    }
                }
            }
        }
        Button(L10n.Agent.Menu.schedules) {
            // The schedules are a section of the details tab: the agent is chosen and its details are shown.
            router.selectAgent(agent.id, on: server)
            router.inspectorTab = .details
            router.showInWorkbench(.details, agentID: agent.id)
        }
        // Moving needs another connected server with the feature; a moved agent is not moved again from here.
        if agent.migratedTo == nil, !MigrationTargets.eligible(source: server, among: app.servers).isEmpty {
            Button(L10n.Migrate.menu) {
                router.sheet = .moveAgent(agentID: agent.id, serverID: server.id)
            }
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
                router.drafts[agent.id] = nil
                router.forgetWorkbench(agentID: agent.id)
                if router.selectedAgentID == agent.id { router.selectedAgentID = nil }
            } catch {
                actionError = UserFacingError.message(for: error)
            }
        }
    }

    /// One line only: the way to make an agent is in the main area (`TeamWelcome`).
    private var emptyState: some View {
        Text(L10n.Team.emptyTitle)
            .font(BanditoFont.text(size: 12.5, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 24)
    }
}

/// Reads what a row of the sidebar shows of one agent's thread. The sidebar itself does not read threads: a stream
/// writes a thread several times a second, and every view that read it was built again. This reader reads the thread's
/// summary (`AgentThreadState`), which a token does not change once the preview line is full, and hands the row its
/// facts (`SidebarThreadFacts`); a row whose facts did not change is not built again (`Memo`).
private struct ThreadReader<Content: View>: View {
    let server: ServerModel
    let agentID: String
    @ViewBuilder var content: (SidebarThreadFacts) -> Content

    var body: some View {
        content(
            SidebarThreadFacts(summary: server.threadSummary(for: agentID), agent: server.agents.first { $0.id == agentID }))
    }
}

/// The entrance of the first rows of the team list. Rows further down are not staggered: forty rows rising one after
/// another kept the window redrawing for nearly three seconds at every return to the team.
private struct SidebarRise: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 10 {
            content.banditoRise(delay: Double(index) * 0.05)
        } else {
            content
        }
    }
}

/// What a row of the sidebar shows of an agent's thread.
struct SidebarThreadFacts: Equatable {
    /// The last message as one line, or nil.
    var preview: String?
    /// When the agent last did something (Unix ms).
    var lastActivityMs: Int64
    var turnRunning: Bool
    /// The title of the oldest approval that waits, if any.
    var pendingTitle: String?

    /// From the thread's summary: a streamed token changes none of it once the preview is full.
    @MainActor init(summary: AgentThreadState, agent: Agent?) {
        preview = agent.flatMap { AgentPreview.text(summary: summary, agent: $0) }
        lastActivityMs = agent.map { AgentPreview.timestamp(summary: summary, agent: $0) } ?? 0
        turnRunning = summary.turnRunning
        pendingTitle = summary.firstPendingApprovalTitle
    }

    init(thread: AgentThread, agent: Agent?) {
        preview = agent.flatMap { AgentPreview.text(thread: thread, agent: $0) }
        lastActivityMs = agent.map { AgentPreview.timestamp(thread: thread, agent: $0) } ?? 0
        turnRunning = thread.turnRunning
        pendingTitle = thread.pendingApprovals.first?.title
    }
}

/// Builds `content` again only when `key` changes (with `.equatable()`).
struct Memo<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content

    nonisolated static func == (lhs: Memo, rhs: Memo) -> Bool { lhs.key == rhs.key }

    var body: some View { content() }
}

/// Everything a row of the team list depends on.
private struct SidebarRowKey: Equatable {
    var agent: Agent
    var facts: SidebarThreadFacts
    var status: AgentStatus
    var selected: Bool
    var isLead: Bool
    var pinned: Bool
    var place: String?
}

/// One agent in the team list: avatar with its status dot, name, role, the time of the last event and a preview.
struct AgentRow: View {
    var agent: Agent
    /// The server the agent lives on, for its picture.
    var server: ServerModel?
    /// What the row shows of the thread.
    var facts: SidebarThreadFacts
    /// The status the team shows (see `ServerModel.status(of:)`); the thread may not be loaded.
    var status: AgentStatus
    var isSelected = false
    /// Time of the last event, already formatted.
    var lastActivity = ""
    /// The server's main agent: a crown on the avatar.
    var isLead = false
    /// The name of the container the agent runs in; nil for the shared server.
    var place: String?

    init(
        agent: Agent, server: ServerModel? = nil, facts: SidebarThreadFacts, status: AgentStatus,
        isSelected: Bool = false, lastActivity: String = "", isLead: Bool = false, place: String? = nil
    ) {
        self.agent = agent
        self.server = server
        self.facts = facts
        self.status = status
        self.isSelected = isSelected
        self.lastActivity = lastActivity
        self.isLead = isLead
        self.place = place
    }

    /// A row made from the whole thread (pictures of the row in tests).
    init(agent: Agent, server: ServerModel? = nil, thread: AgentThread, status: AgentStatus, isSelected: Bool = false) {
        self.init(
            agent: agent, server: server, facts: SidebarThreadFacts(thread: thread, agent: agent), status: status,
            isSelected: isSelected)
    }

    var body: some View {
        let _ = PerfCounters.hit("AgentRow")
        HStack(alignment: .center, spacing: 11) {
            AgentAvatarView(
                agent: agent, server: server, size: 40,
                mood: AvatarMood.make(status: status, turnRunning: facts.turnRunning, paused: agent.paused))
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
                        .font(BanditoFont.display(size: 12.5, weight: 600))
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
                    if let place { WorkspaceChip(text: place) }
                    Spacer(minLength: 4)
                    if !lastActivity.isEmpty {
                        Text(lastActivity)
                            .font(BanditoFont.text(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                    }
                }
                Text(facts.preview ?? L10n.Team.noMessages)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
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
