import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Servers: the servers this app connects to, with their state, and add or remove one. A server opens its
/// settings page (`ServerSettingsPage`); the Back button returns here.
struct ServersSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var removing: ServerModel?
    /// The server whose settings page is open; nil shows the list.
    @State private var detail: UUID?
    @Environment(\.settingsNavigation) private var ownNavigation

    private var navigationRequests: SettingsNavigation { ownNavigation ?? .shared }

    var body: some View {
        if let server = app.servers.first(where: { $0.id == detail }) {
            ServerSettingsPage(server: server, onBack: { detail = nil })
        } else {
            list
                .onAppear(perform: takeRequestedServer)
                .onChange(of: navigationRequests.requestedServer) { _, _ in takeRequestedServer() }
        }
    }

    private var list: some View {
        SettingsPage(title: SettingsSection.servers.title, intro: L10n.Settings.Servers.intro) {
            VStack(spacing: 0) {
                ForEach(Array(app.servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 {
                        Divider().padding(.horizontal, 16)
                    }
                    serverRow(server)
                }
                if app.servers.isEmpty {
                    Text(L10n.Server.noServer)
                        .font(BanditoFont.text(size: 13, weight: 400))
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

    /// One server: its name and address (the whole part opens its settings page), its state, and Delete.
    private func serverRow(_ server: ServerModel) -> some View {
        HStack(spacing: 12) {
            Button {
                detail = server.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.config.name)
                            .font(BanditoFont.text(size: 13, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Self.addressText(server.config.endpoint))
                            .font(BanditoFont.text(size: 12, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text3)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 8))
            Chip(text: Self.stateText(server.state), tone: server.state == .connected ? .ok : .neutral)
                .fixedSize()
            Button(L10n.Common.delete) {
                removing = server
            }
            .banditoButton(.quiet())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }

    /// Opens the settings page of the server the Server screen asked for.
    private func takeRequestedServer() {
        guard let id = navigationRequests.requestedServer else { return }
        detail = id
        navigationRequests.requestedServer = nil
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
