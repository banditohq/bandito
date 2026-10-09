import BanditoDesign
import BanditoKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedAgentID) {
            if let server = app.currentServer {
                Section {
                    ForEach(server.sortedAgents) { agent in
                        AgentRow(agent: agent, thread: server.thread(for: agent.id))
                            .tag(agent.id)
                    }
                } header: {
                    ServerHeader(server: server)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.surface1)
    }
}

private struct ServerHeader: View {
    var server: ServerModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(server.state == .connected ? Color.Bandito.ok : Color.Bandito.text3)
                .frame(width: 6, height: 6)
            Text(server.info?.hostname ?? server.config.name)
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .foregroundStyle(Color.Bandito.text3)
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
