import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Team sidebar: the agents of the current server. Those who need you come first, under their own heading.
struct TeamSidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        @Bindable var router = router
        if let server = app.currentServer {
            let agents = server.sortedAgents
            let waiting = agents.filter { server.thread(for: $0.id).status == .needsYou }
            let others = agents.filter { server.thread(for: $0.id).status != .needsYou }
            List(selection: $router.selectedAgentID) {
                if !waiting.isEmpty {
                    Section {
                        ForEach(waiting) { agent in
                            AgentRow(agent: agent, thread: server.thread(for: agent.id))
                                .tag(agent.id)
                        }
                    } header: {
                        SectionLabel(L10n.Sidebar.needsYou, tone: .signal)
                    }
                }
                Section {
                    ForEach(others) { agent in
                        AgentRow(agent: agent, thread: server.thread(for: agent.id))
                            .tag(agent.id)
                    }
                } header: {
                    SectionLabel(L10n.Sidebar.agents)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.Bandito.surface1)
        } else {
            Color.Bandito.surface1
        }
    }
}

struct AgentRow: View {
    var agent: Agent
    var thread: AgentThread

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatar(name: agent.name, size: 36)
                .overlay(alignment: .bottomTrailing) { StatusDot(status: thread.status) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                    if !agent.role.isEmpty { Chip(text: agent.role) }
                }
                Text(thread.preview ?? agent.cwd)
                    .font(.system(size: 12))
                    .foregroundStyle(thread.status == .needsYou ? Color.Bandito.signal : Color.Bandito.text3)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
