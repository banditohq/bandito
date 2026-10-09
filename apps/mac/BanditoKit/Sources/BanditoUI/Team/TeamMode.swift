import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Team mode: the thread of the agent on screen, with the details panel on the right when it is open.
/// The agent on screen is the one chosen, else the one last chosen on this server, else the first in sidebar order
/// (see `TeamSelection`). A fallback becomes the chosen one, so it does not change under the person.
struct TeamMode: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        if let server = app.currentServer, let agent = shownAgent(on: server) {
            HStack(spacing: 0) {
                // Switching agents gives a fresh view. The composer text is not in the view: it is kept per agent id in
                // the Router (`Router.drafts`), so it stays with its agent.
                ThreadView(server: server, agent: agent, inspectorTab: Bindable(router).inspectorTab)
                    .id(agent.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if router.inspectorOpen {
                    InspectorView(
                        server: server, agent: agent, tab: Bindable(router).inspectorTab,
                        onClose: { router.inspectorOpen = false })
                        .frame(width: 400)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .banditoAnimation(BanditoMotion.ease, value: router.inspectorOpen)
            .background(Color.Bandito.bg)
            // The agent on screen stays the chosen one, so an approval or status change elsewhere does not move it.
            // Not remembered as the last opened agent: only an explicit choice is (Router.selectAgent).
            .task(id: "\(server.id.uuidString)|\(agent.id)") {
                if let kept = TeamSelection.keptChoice(shown: agent.id), router.selectedAgentID != kept {
                    router.selectedAgentID = kept
                }
            }
        } else if let server = app.currentServer, server.state == .connected, server.agents.isEmpty {
            TeamWelcome()
        } else {
            EmptyTeam()
        }
    }

    private func shownAgent(on server: ServerModel) -> Agent? {
        let id = TeamSelection.shownAgentID(
            server: server, selected: router.selectedAgentID, pinned: Set(PinnedAgents().ids))
        return server.agents.first { $0.id == id }
    }
}

private struct EmptyTeam: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.currentServer == nil {
            NoServerView(symbol: "bubble.left.and.text.bubble.right")
                .background(Color.Bandito.bg)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.Bandito.text3)
                switch app.currentServer?.state {
                case .failed(let kind):
                    UserFacingErrorView(message: UserFacingError.message(for: kind))
                        .frame(maxWidth: 420)
                    Button(L10n.Banner.retry) {
                        Task { await app.currentServer?.connect() }
                    }
                    .banditoButton(.quiet())
                case .connecting:
                    ProgressView().controlSize(.small)
                default:
                    Text(L10n.Team.pickAgent)
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.Bandito.bg)
        }
    }
}
