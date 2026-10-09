import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Servers: the servers this app connects to, with their state, and add or remove one.
struct ServersSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var removing: ServerModel?

    var body: some View {
        SettingsPage(title: SettingsSection.servers.title, intro: L10n.Settings.Servers.intro) {
            VStack(spacing: 0) {
                ForEach(Array(app.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    SettingsRow(title: server.config.name, hint: server.config.description) {
                        HStack(spacing: 12) {
                            Chip(text: Self.stateText(server.state), tone: server.state == .connected ? .ok : .neutral)
                            Button(L10n.Common.delete) {
                                removing = server
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                }
                if app.servers.isEmpty {
                    Text(L10n.Server.noServer)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .padding(16)
                }
            }
            .banditoCard()
            HStack {
                Spacer()
                Button(L10n.Settings.Servers.add) {
                    router.sheet = .addServer
                }
                .buttonStyle(SignalButtonStyle())
            }
            .padding(.top, 16)
        }
        .confirmationDialog(
            L10n.Settings.Servers.deleteTitle(name: removing?.config.name ?? ""),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { server in
            Button(L10n.Common.delete, role: .destructive) {
                app.remove(server.id)
            }
            Button(L10n.Common.cancel, role: .cancel) {}
        } message: { _ in
            Text(L10n.Settings.Servers.deleteMessage)
        }
    }

    static func stateText(_ state: ConnectionState) -> String {
        switch state {
        case .connected: L10n.Server.Status.online
        case .connecting, .reconnecting: L10n.Settings.Servers.connecting
        case .disconnected, .failed: L10n.Server.Status.offline
        }
    }
}
