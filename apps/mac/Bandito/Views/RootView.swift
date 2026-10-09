import BanditoDesign
import BanditoKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            if let server = app.currentServer, let agent = app.selectedAgent {
                ThreadView(server: server, agent: agent)
            } else {
                EmptyDetail()
            }
        }
        .background(Color.Bandito.bg)
    }
}

private struct EmptyDetail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(Color.Bandito.text3)
            switch app.currentServer?.state {
            case .failed(let message):
                Text(message).foregroundStyle(Color.Bandito.text2).multilineTextAlignment(.center)
                Button("Retry") { Task { await app.currentServer?.connect() } }
                    .buttonStyle(QuietButtonStyle())
            case .connecting:
                ProgressView().controlSize(.small)
            default:
                Text("Pick an agent").foregroundStyle(Color.Bandito.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg)
    }
}
