import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The server button at the top of the sidebar: name, online state, a summary line, and a menu to switch.
struct ServerPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        if let server = app.currentServer {
            Menu {
                ForEach(app.servers) { candidate in
                    Button { app.selectedServerID = candidate.id } label: {
                        Self.menuLabel(candidate, isCurrent: candidate.id == server.id)
                    }
                }
                Divider()
                Button { router.sheet = .addServer } label: {
                    Label(L10n.Server.Picker.connect, systemImage: "plus")
                }
                Button {
                    SettingsNavigation.shared.requested = .servers
                    WindowActions.showSettings()
                } label: {
                    Label(L10n.Server.Picker.manage, systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(Self.statusColor(server))
                        .frame(width: 8, height: 8)
                        .shadow(color: Self.statusColor(server).opacity(0.6), radius: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Self.name(server))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text)
                        Text(Self.summary(server))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.text.opacity(0.035)))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.Bandito.text.opacity(0.08)))
            }
            .menuStyle(.button)
            .banditoButton(.row(cornerRadius: 12))
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(Self.name(server))
        } else {
            // No server yet: the place of the picker says so and offers the way to connect one.
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.Empty.NoServers.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Button(L10n.Empty.NoServers.action) {
                    router.sheet = .addServer
                }
                .banditoButton(.signal())
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static func name(_ server: ServerModel) -> String {
        server.info?.hostname ?? server.config.name
    }

    /// Where the server is: this Mac, the host of a WebSocket URL, or the ssh target.
    static func address(_ server: ServerModel) -> String {
        switch server.config.endpoint {
        case .local: L10n.Server.Add.thisMac
        case .webSocket(let url): url.host ?? url.absoluteString
        case .ssh(let target, _): target
        }
    }

    /// One server in the menu: the name and its address, a check on the current one, and a dot on a server whose
    /// daemon has a newer release to install.
    @ViewBuilder
    static func menuLabel(_ server: ServerModel, isCurrent: Bool) -> some View {
        let title = "\(name(server)) · \(address(server))"
        if isCurrent {
            Label(title, systemImage: "checkmark")
        } else if DaemonUpdateOffer.offer(for: server.info) != nil {
            Label(title, systemImage: "circle.fill")
        } else {
            Text(title)
        }
    }

    static func statusColor(_ server: ServerModel) -> Color {
        switch server.state {
        case .connected: Color.Bandito.ok
        case .connecting, .reconnecting: Color.Bandito.signal
        case .disconnected, .failed: Color.Bandito.text3
        }
    }

    static func summary(_ server: ServerModel) -> String {
        let working = server.agents.filter { server.thread(for: $0.id).status == .working }.count
        return "\(L10n.Common.agentCount(count: server.agents.count)) · \(L10n.Common.workingCount(count: working))"
    }
}
