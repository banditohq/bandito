import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Updates: the versions of this app and of the server's daemon, and the newest release.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var release = ReleaseStatus()

    private var installedAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var appVersion: String { installedAppVersion ?? "—" }

    /// The newest release, unless the installed version is already that one or newer: then the line says so, instead
    /// of showing an older "latest" next to a newer app.
    private var latestValue: (text: String, isVersion: Bool) {
        if ReleaseFeed.standing(installed: installedAppVersion, latest: release.latest) == .upToDate {
            return (L10n.Updates.mostRecent, false)
        }
        return (release.latest?.description ?? L10n.Updates.unknown, release.latest != nil)
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
                    Text(latestValue.text)
                        .font(latestValue.isVersion ? .system(size: 13, design: .monospaced) : .system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .banditoCard()
            if let server = app.currentServer {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ServerPicker.name(server))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ServerUpdateActions(server: server)
                    Button(L10n.Settings.Updates.moreOnServer) {
                        // The Server page is in the main window: Settings closes, and the page opens there.
                        SettingsHandoff.openMainWindow(router: router) { router in
                            router.select(mode: .server)
                            router.serverSection = .updates
                        }
                    }
                    .banditoButton(.link)
                    .fixedSize()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .banditoCard()
                .padding(.top, 16)
            }
            HStack(spacing: 10) {
                Spacer()
                Button(L10n.Settings.Updates.check) {
                    Task { await release.load() }
                }
                .banditoButton(.quiet())
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.top, 16)
        }
        .task { await release.load() }
    }
}
