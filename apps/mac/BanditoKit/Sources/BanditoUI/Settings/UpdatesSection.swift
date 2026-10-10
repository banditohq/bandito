import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Settings → Updates: how the app updates itself, the versions of the app and the daemon, and the newest release.
struct UpdatesSection: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var release = ReleaseStatus()
    // The app target reads these keys and configures Sparkle (AppUpdater).
    @AppStorage(AppUpdatePreferences.automaticChecksKey) private var autoCheckUpdates = true
    @AppStorage(AppUpdatePreferences.channelKey) private var updateChannel = AppUpdatePreferences.Channel.stable.rawValue

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
            // No label: the page title already says "Updates". The group title "Как обновляться" needs a new string.
            SettingsGroup(title: nil) {
                SettingsRow(
                    title: L10n.Settings.autoCheckUpdates, hint: L10n.Settings.autoCheckUpdatesHint,
                    icon: SettingsIcon(symbol: "arrow.down.circle", tint: BanditoPalette.badgeSlate),
                    keepsControlBeside: true
                ) {
                    Toggle("", isOn: $autoCheckUpdates)
                        .labelsHidden()
                        .toggleStyle(BanditoToggleStyle())
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.Updates.channel, hint: L10n.Settings.channelHint,
                    icon: SettingsIcon(symbol: "antenna.radiowaves.left.and.right", tint: BanditoPalette.badgePurple)
                ) {
                    BanditoSelect(
                        selection: $updateChannel,
                        sections: [
                            SelectSection(options: [
                                SelectOption(
                                    value: AppUpdatePreferences.Channel.stable.rawValue,
                                    title: L10n.Settings.Updates.stable, subtitle: L10n.Settings.Updates.stableDesc),
                                SelectOption(
                                    value: AppUpdatePreferences.Channel.beta.rawValue,
                                    title: L10n.Settings.Updates.beta, subtitle: L10n.Settings.Updates.betaDesc),
                            ])
                        ],
                        label: L10n.Settings.Updates.channel, placeholder: L10n.Settings.Updates.stable,
                        field: { SelectFieldView(option: $0?.titleOnly, placeholder: L10n.Settings.Updates.stable) },
                        footer: { _ in EmptyView() })
                        .frame(width: 220)
                }
            }
            SettingsGroup(title: L10n.Settings.Group.versions) {
                SettingsRow(
                    title: L10n.Settings.Updates.app, hint: nil,
                    icon: SettingsIcon(symbol: "app.badge", tint: BanditoPalette.badgeSlate)
                ) {
                    Text(appVersion).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.Bandito.text2)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.Updates.daemonServer, hint: nil,
                    icon: SettingsIcon(symbol: "server.rack", tint: BanditoPalette.badgeGreen)
                ) {
                    Text(daemon).font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.Bandito.text2)
                }
                Divider().padding(.horizontal, 16)
                SettingsRow(
                    title: L10n.Settings.Updates.latest, hint: nil,
                    icon: SettingsIcon(symbol: "sparkles", tint: BanditoPalette.badgeOrange)
                ) {
                    Text(latestValue.text)
                        .font(latestValue.isVersion ? .system(size: 13, design: .monospaced) : .system(size: 13))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
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
        }
        .task { await release.load() }
    }
}
