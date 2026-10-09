import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Ports and previews: every port that something on the server listens on.
struct PortsView: View {
    let server: ServerModel?
    @Environment(Router.self) private var router
    @State private var reply: HostPorts?
    @State private var error: UserFacingMessage?

    var body: some View {
        ServerPage(title: L10n.Mode.serverPorts) {
            if let server, server.supports("host") {
                ServerCard {
                    HStack(spacing: 12) {
                        SectionLabel(L10n.Ports.columnPort).frame(width: 80, alignment: .leading)
                        SectionLabel(L10n.Ports.columnProcess).frame(maxWidth: .infinity, alignment: .leading)
                        SectionLabel(L10n.Ports.columnOwner).frame(width: 160, alignment: .leading)
                        SectionLabel(L10n.Ports.columnAddress).frame(width: 110, alignment: .leading)
                        Color.clear.frame(width: 90)
                    }
                    if let reply, !reply.supported {
                        Text(L10n.Server.Processes.unsupported).foregroundStyle(Color.Bandito.text2)
                    } else if let reply, reply.ports.isEmpty {
                        Text(L10n.Ports.empty).foregroundStyle(Color.Bandito.text2)
                    }
                    ForEach(sortedPorts, id: \.self) { port in
                        HStack(spacing: 12) {
                            PortBadge(port: port.port)
                                .frame(width: 80, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(port.process ?? "—")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.Bandito.text)
                                    .lineLimit(1)
                                if let pid = port.pid {
                                    Text("pid \(pid)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color.Bandito.text3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(ownerLabel(port, server: server))
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.Bandito.text2)
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                            Text(port.addr == "*" ? L10n.Ports.allInterfaces : port.addr)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.Bandito.text3)
                                .lineLimit(1)
                                .frame(width: 110, alignment: .leading)
                            Button(L10n.Server.Ports.open) {
                                router.pendingPreviewPort = port.port
                                router.select(mode: .browser)
                            }
                            .banditoButton(.quiet())
                            .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 4)
                        .overlay(alignment: .top) { Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1) }
                    }
                    if let error {
                        UserFacingErrorView(message: error)
                    }
                }
            } else {
                ServerUnavailable(server: server)
            }
        }
        .task(id: server?.info != nil) {
            guard let server, server.supports("host") else { return }
            while !Task.isCancelled {
                do {
                    reply = try await server.hostPorts()
                    error = nil
                } catch {
                    self.error = UserFacingError.message(for: error)
                }
                try? await Task.sleep(for: HostMonitor.interval)
            }
        }
    }

    private var sortedPorts: [ListeningPort] {
        (reply?.ports ?? []).sorted { $0.port < $1.port }
    }

    private func ownerLabel(_ port: ListeningPort, server: ServerModel) -> String {
        switch port.owner?.kind {
        case .agent: server.agents.first { $0.id == port.owner?.id }?.name ?? L10n.Server.Owner.agent
        case .terminal: L10n.Server.Owner.terminal
        case .daemon, nil: L10n.Server.Owner.daemon
        }
    }
}
