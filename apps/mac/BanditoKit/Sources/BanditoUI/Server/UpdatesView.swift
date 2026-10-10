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
                    row(L10n.Updates.latestVersion, latestText(current: info.version), mono: latestIsVersion(current: info.version))
                    HStack {
                        Text(available ? L10n.Updates.available : L10n.Updates.upToDate)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.Bandito.text)
                        Spacer(minLength: 8)
                        Chip(text: available ? L10n.Updates.badgeNew : L10n.Updates.badgeCurrent, tone: available ? .signal : .ok)
                            .fixedSize()
                    }
                }
                ServerCard {
                    SectionLabel(L10n.Updates.howTitle)
                    ServerUpdateActions(server: server) {
                        router.requestTerminalCommand(ReleaseFeed.installCommand)
                    }
                }
            } else {
                ServerUnavailable(server: server)
            }
        }
        .task { await release.load() }
    }

    /// The newest release, unless the daemon already runs it or a newer one: then the line says so.
    private func latestText(current: String) -> String {
        if latestIsVersion(current: current) { return release.latest?.description ?? "" }
        return release.latest == nil ? L10n.Updates.unknown : L10n.Updates.mostRecent
    }

    /// Whether the line shows a version number (monospaced) rather than a word.
    private func latestIsVersion(current: String) -> Bool {
        release.latest != nil && ReleaseFeed.standing(installed: current, latest: release.latest) != .upToDate
    }

    /// A label and a value. Versions are monospaced; the words for "unknown" are regular text.
    private func row(_ label: String, _ value: String, mono: Bool = true) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.Bandito.text3)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? .system(size: 13, design: .monospaced) : .system(size: 13))
                .foregroundStyle(Color.Bandito.text)
        }
    }
}
