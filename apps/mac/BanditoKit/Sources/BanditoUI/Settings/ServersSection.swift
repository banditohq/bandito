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
                    SettingsRow(title: server.config.name, hint: Self.addressText(server.config.endpoint)) {
                        HStack(spacing: 12) {
                            Chip(text: Self.stateText(server.state), tone: server.state == .connected ? .ok : .neutral)
                                .fixedSize()
                            Button(L10n.Common.delete) {
                                removing = server
                            }
                            .banditoButton(.quiet())
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
                .banditoButton(.signal())
            }
            .padding(.top, 16)
            if app.currentServer?.supports("integrations") == true {
                integrationsCard
            }
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

    /// Where the Integrations page of the Server mode is opened from here.
    private var integrationsCard: some View {
        HStack(spacing: 16) {
            Text(L10n.Integrations.Settings.hint)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(L10n.Integrations.Settings.open) {
                // The Server page is in the main window: Settings closes, and the integrations page opens there.
                SettingsHandoff.openMainWindow(router: router) { router in
                    router.select(mode: .server)
                    router.serverSection = .integrations
                }
            }
            .banditoButton(.quiet())
            .fixedSize()
        }
        .padding(16)
        .banditoCard()
        .padding(.top, 16)
    }

    /// The human address under the name: `user@host`, `host:port`, or "This Mac". Never the id or the token.
    static func addressText(_ endpoint: ServerEndpoint) -> String {
        switch ServerAddress(endpoint: endpoint) {
        case .thisMac: L10n.Server.Add.thisMac
        case .remote(let text): text
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
