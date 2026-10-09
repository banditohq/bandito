import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Server → Updates: the daemon's version against the newest release, and how to update it.
struct UpdatesView: View {
    let server: ServerModel?
    @Environment(Router.self) private var router
    @State private var release = ReleaseStatus()

    var body: some View {
        ServerPage(title: L10n.Mode.serverUpdates) {
            if let server, let info = server.info {
                let available = release.updateAvailable(current: info.version)
                ServerCard {
                    row(L10n.Updates.daemonVersion, info.version)
                    row(L10n.Updates.latestVersion, release.latest?.description ?? L10n.Updates.unknown)
                    HStack {
                        Text(available ? L10n.Updates.available : L10n.Updates.upToDate)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Bandito.text)
                        Spacer(minLength: 8)
                        Chip(text: available ? L10n.Updates.badgeNew : L10n.Updates.badgeCurrent, tone: available ? .signal : .ok)
                    }
                }
                ServerCard {
                    SectionLabel(L10n.Updates.howTitle)
                    Text(L10n.Updates.howText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ReleaseFeed.installCommand)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack {
                        Spacer()
                        Button(L10n.Updates.howButton) {
                            router.requestTerminalCommand(ReleaseFeed.installCommand)
                        }
                        .banditoButton(.signal())
                    }
                }
            } else {
                ServerUnavailable(server: server)
            }
        }
        .task { await release.load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text3)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.Bandito.text)
        }
    }
}
