import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The server button at the top of the sidebar: name, online state, a summary line, and a list to switch.
struct ServerPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    var body: some View {
        if let server = app.currentServer {
            BanditoSelect(
                selection: Binding(get: { server.id }, set: { id in
                    afterSelectPanelCloses { app.selectedServerID = id }
                }),
                sections: [SelectSection(options: Self.serverChoices(app.servers))],
                label: Self.name(server), placeholder: Self.name(server),
                field: { _ in serverField(server) },
                footer: { close in serverFooter(close: close) }
            )
            .accessibility(
                value: Self.isOnline(server) ? L10n.Server.Status.online : L10n.Server.Status.offline,
                hint: Self.hasUpdate(server) ? L10n.Updates.available : nil)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            // No server yet: the place of the picker is a card of the same height, with one way to connect one.
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(width: 28, height: 28)
                    .background(Color.Bandito.text.opacity(0.06), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.Sidebar.NoServer.title)
                        .font(BanditoFont.text(size: 13, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                    Text(L10n.Sidebar.NoServer.hint)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(L10n.Sidebar.NoServer.connect) {
                    router.sheet = .addServer
                }
                .banditoButton(.lightPill())
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.text.opacity(0.035)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.Bandito.text.opacity(0.08)))
        }
    }

    static func name(_ server: ServerModel) -> String {
        server.info?.hostname ?? server.config.name
    }

    /// Where the server is: this Mac (with its model), the host of a WebSocket URL, or the ssh target (user@host).
    static func address(_ server: ServerModel) -> String {
        if isThisMac(server) { return thisMacLabel }
        switch server.config.endpoint {
        case .local: return thisMacLabel
        case .webSocket(let url): return url.host ?? url.absoluteString
        case .ssh(let target, _): return target
        }
    }

    /// Whether the server is this Mac's own daemon.
    static func isThisMac(_ server: ServerModel) -> Bool {
        LocalDaemonUpgrade.isThisMac(server.config)
    }

    /// "This Mac · MacBook Pro", or "This Mac" when no model is known.
    static var thisMacLabel: String {
        guard let model = MacModel.current() else { return L10n.Server.Add.thisMac }
        return "\(L10n.Server.Add.thisMac) · \(model)"
    }

    /// What kind of device the server is, in the words of the switcher: "This Mac" or "Server".
    static func kindName(_ server: ServerModel) -> String {
        isThisMac(server) ? L10n.Server.Add.thisMac : L10n.Server.Picker.kindRemote
    }

    /// The symbol of the server's device: a laptop or a desktop for this Mac (by its model), a server rack otherwise.
    static func symbol(_ server: ServerModel) -> String {
        guard isThisMac(server) else { return "server.rack" }
        return DeviceIcon.symbol(platform: nil, name: MacModel.current() ?? "")
    }

    /// The servers to switch to, built by `SelectChoices.servers` from each server's name, address and state.
    static func serverChoices(_ servers: [ServerModel]) -> [SelectOption<UUID>] {
        SelectChoices.servers(
            servers.map { candidate in
                SelectChoices.ServerRow(
                    id: candidate.id, name: name(candidate), address: address(candidate),
                    isOnline: isOnline(candidate), hasUpdate: hasUpdate(candidate), icon: symbol(candidate))
            },
            updateText: L10n.Updates.available)
    }

    static func hasUpdate(_ server: ServerModel) -> Bool {
        DaemonUpdateOffer.offer(for: server.info) != nil
    }

    static func isOnline(_ server: ServerModel) -> Bool {
        server.state == .connected
    }

    /// The button's face: the status dot, the name, and the summary line.
    private func serverField(_ server: ServerModel) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Self.statusColor(server))
                .frame(width: 8, height: 8)
                .shadow(color: Self.statusColor(server).opacity(0.6), radius: 4)
            Image(systemName: Self.symbol(server))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.name(server))
                    .font(BanditoFont.text(size: 13, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(Self.summary(server))
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.Bandito.text3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.text.opacity(0.035)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.Bandito.text.opacity(0.08)))
    }

    private func footerLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.Bandito.text2)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Under the servers: connect a new one, or open the servers page in Settings. Each closes the panel first.
    private func serverFooter(close: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.vertical, 4)
            Button {
                close()
                afterSelectPanelCloses { router.sheet = .addServer }
            } label: {
                footerLabel(L10n.Server.Picker.connect, icon: "plus")
            }
            .banditoButton(.row(cornerRadius: 9))
            Button {
                close()
                afterSelectPanelCloses {
                    SettingsNavigation.shared.requested = .servers
                    WindowActions.showSettings()
                }
            } label: {
                footerLabel(L10n.Server.Picker.manage, icon: "gearshape")
            }
            .banditoButton(.row(cornerRadius: 9))
        }
    }

    static func statusColor(_ server: ServerModel) -> Color {
        switch server.state {
        case .connected: Color.Bandito.ok
        case .connecting, .reconnecting: Color.Bandito.signal
        case .disconnected, .failed: Color.Bandito.text3
        }
    }

    /// "This Mac · 1 agent" or "Server · 1 agent", under the name in the field.
    static func summary(_ server: ServerModel) -> String {
        "\(kindName(server)) · \(L10n.Common.agentCount(count: server.agents.count))"
    }
}
