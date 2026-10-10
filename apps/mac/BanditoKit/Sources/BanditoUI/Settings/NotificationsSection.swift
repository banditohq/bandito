import BanditoDesign
import BanditoL10n
import SwiftUI
import UserNotifications

#if os(macOS)
import AppKit
#endif

/// Settings → Notifications: the system permission, and which events post a notification.
struct NotificationsSection: View {
    @AppStorage("notify.needsYou") private var needsYou = true
    @AppStorage("notify.finished") private var finished = true
    @AppStorage("notify.error") private var failed = true
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        SettingsPage(title: SettingsSection.notifications.title, intro: L10n.Settings.Notifications.intro) {
            SettingsGroup(title: L10n.Settings.Group.system) {
                SettingsRow(
                    title: L10n.Settings.Notifications.system, hint: Self.statusText(status),
                    icon: SettingsIcon(symbol: "bell.badge", tint: BanditoPalette.badgeRed)
                ) {
                    if status == .notDetermined {
                        Button(L10n.Settings.Notifications.allow) {
                            Task { await request() }
                        }
                        .banditoButton(.signal())
                        .fixedSize()
                    } else if status == .denied {
                        // The hint already says it is off in System Settings: only the way there is shown.
                        Button(L10n.Settings.Notifications.openSystem) {
                            SystemActions.open(Self.systemSettingsURL)
                        }
                        .banditoButton(.quiet())
                        .fixedSize()
                    } else {
                        Chip(text: Self.statusText(status), tone: status == .authorized ? .ok : .neutral)
                            .fixedSize()
                    }
                }
            }
            SettingsGroup(title: L10n.Settings.Sounds.events) {
                toggle(
                    L10n.Settings.Notifications.needsYou, L10n.Settings.Notifications.needsYouHint, $needsYou,
                    symbol: "exclamationmark.bubble.fill", tint: BanditoPalette.badgeOrange)
                Divider().padding(.horizontal, 16)
                toggle(
                    L10n.Settings.Notifications.finished, L10n.Settings.Notifications.finishedHint, $finished,
                    symbol: "checkmark.circle.fill", tint: BanditoPalette.badgeGreen)
                Divider().padding(.horizontal, 16)
                toggle(
                    L10n.Settings.Notifications.failed, L10n.Settings.Notifications.failedHint, $failed,
                    symbol: "xmark.octagon.fill", tint: BanditoPalette.badgeRed)
            }
        }
        .task { await refresh() }
        #if os(macOS)
        // The person may have switched the permission in System Settings and come back: read it again.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        #endif
    }

    private func toggle(
        _ title: String, _ hint: String, _ isOn: Binding<Bool>, symbol: String, tint: Color
    ) -> some View {
        SettingsRow(
            title: title, hint: hint, icon: SettingsIcon(symbol: symbol, tint: tint), keepsControlBeside: true
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(BanditoToggleStyle())
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func request() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    /// The Notifications pane of System Settings.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!

    static func statusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: L10n.Settings.Notifications.statusAllowed
        case .denied: L10n.Settings.Notifications.statusDenied
        case .notDetermined: L10n.Settings.Notifications.statusAsk
        @unknown default: L10n.Settings.Notifications.statusAsk
        }
    }
}
