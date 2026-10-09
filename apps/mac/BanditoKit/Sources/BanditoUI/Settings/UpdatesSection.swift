import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Updates: the versions of this app and of the server's daemon, and the newest release.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var release = ReleaseStatus()

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        let daemon = app.currentServer?.info?.version ?? "—"
        SettingsPage(title: SettingsSection.updates.title, intro: L10n.Settings.Updates.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.Updates.app, hint: nil) {
                    Text(appVersion).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.Bandito.text2)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.Updates.daemonServer, hint: nil) {
                    Text(daemon).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.Bandito.text2)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(title: L10n.Settings.Updates.latest, hint: nil) {
                    Text(release.latest?.description ?? L10n.Updates.unknown)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            .banditoCard()
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.Settings.Updates.check) {
                    Task { await release.load() }
                }
                .buttonStyle(QuietButtonStyle())
                Button(L10n.Settings.Updates.openServer) {
                    router.select(mode: .server)
                    router.serverSection = .updates
                }
                .buttonStyle(SignalButtonStyle())
            }
            .padding(.top, 16)
        }
        .task { await release.load() }
    }
}
