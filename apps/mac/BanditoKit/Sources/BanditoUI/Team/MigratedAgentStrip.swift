import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The strip under the header of a moved agent: "Перенесён на <сервер>", with "Открыть там" (when that server is
/// connected) and "Удалить здесь" (only after a confirmation). The agent is paused on this server and stays so.
struct MigratedAgentStrip: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    let agent: Agent
    /// The server the agent was on: this one.
    let source: ServerModel
    /// The server the agent moved to, by the name this server kept (`migratedTo`).
    let movedTo: String

    @State private var confirmingDelete = false
    @State private var actionError: UserFacingMessage?

    var body: some View {
        let target = targetServer
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.Bandito.signal)
                Text(L10n.Migrate.Banner.title(server: movedTo))
                    .font(BanditoFont.text(size: 12.5, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActionRow(hugging: true) {
                    if let target, target.isConnected {
                        Button(L10n.Migrate.Banner.open) { open(target) }
                            .banditoButton(.quiet())
                    }
                    Button(L10n.Migrate.Banner.delete) { confirmingDelete = true }
                        .banditoButton(.quiet(tone: .danger))
                }
            }
            if let actionError {
                UserFacingErrorView(message: actionError)
            }
        }
        .padding(12)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .confirmationDialog(
            L10n.Migrate.Banner.deleteTitle(name: agent.name),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.Common.delete, role: .destructive) { delete() }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: {
            Text(L10n.Migrate.Banner.deleteMessage(server: movedTo))
        }
    }

    /// The server the agent went to: the one this Mac recorded when it moved the agent, else the only server with
    /// that name.
    private var targetServer: ServerModel? {
        if let link = MovedAgentLink.load(sourceServerID: source.id, agentID: agent.id),
            let server = app.servers.first(where: { $0.id == link.serverID })
        {
            return server
        }
        return MigrationTargets.server(named: movedTo, among: app.servers)
    }

    private func open(_ target: ServerModel) {
        app.selectedServerID = target.id
        if let agentID = newAgentID(on: target) {
            router.selectAgent(agentID, on: target)
        }
        router.select(mode: .team)
    }

    /// The agent's id on the target: from this Mac's record of the move, else the one agent there with its name.
    private func newAgentID(on target: ServerModel) -> String? {
        if let link = MovedAgentLink.load(sourceServerID: source.id, agentID: agent.id), link.serverID == target.id {
            return link.agentID
        }
        let sameName = target.agents.filter { $0.name == agent.name }
        return sameName.count == 1 ? sameName[0].id : nil
    }

    private func delete() {
        Task {
            do {
                try await source.deleteAgent(agent.id)
                router.drafts[agent.id] = nil
                router.forgetWorkbench(agentID: agent.id)
                if router.selectedAgentID == agent.id { router.selectedAgentID = nil }
            } catch {
                actionError = UserFacingError.message(for: error)
            }
        }
    }
}
