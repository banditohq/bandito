import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Team mode: the chat with the agent selected in the sidebar, or a hint when none is.
struct TeamMode: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        if let server = app.currentServer, let agent = selectedAgent(on: server) {
            ThreadView(server: server, agent: agent)
        } else {
            EmptyTeam()
        }
    }

    private func selectedAgent(on server: ServerModel) -> Agent? {
        guard let id = router.selectedAgentID else { return nil }
        return server.agents.first { $0.id == id }
    }
}

private struct EmptyTeam: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            switch app.currentServer?.state {
            case .failed(let message):
                Text(message)
                    .foregroundStyle(Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                Button(L10n.Banner.retry) { Task { await app.currentServer?.connect() } }
                    .buttonStyle(QuietButtonStyle())
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
