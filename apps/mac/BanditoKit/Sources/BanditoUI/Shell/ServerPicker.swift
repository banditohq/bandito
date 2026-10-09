import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The server button at the top of the sidebar: name, online state, a summary line, and a menu to switch.
struct ServerPicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer {
            Menu {
                ForEach(app.servers) { candidate in
                    Button { app.selectedServerID = candidate.id } label: {
                        // A dot marks a server whose daemon has a newer release to install.
                        if DaemonUpdateOffer.offer(for: candidate.info) != nil {
                            Label(Self.name(candidate), systemImage: "circle.fill")
                        } else {
                            Text(Self.name(candidate))
                        }
                    }
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
        }
    }

    static func name(_ server: ServerModel) -> String {
        server.info?.hostname ?? server.config.name
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
