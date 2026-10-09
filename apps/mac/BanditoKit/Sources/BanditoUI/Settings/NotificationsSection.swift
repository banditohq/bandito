import BanditoDesign
import BanditoL10n
import SwiftUI
import UserNotifications

/// Settings → Notifications: the system permission, and which events post a notification.
struct NotificationsSection: View {
    @AppStorage("notify.needsYou") private var needsYou = true
    @AppStorage("notify.finished") private var finished = true
    @AppStorage("notify.error") private var failed = true
    @State private var status: UNAuthorizationStatus = .notDetermined

    var body: some View {
        SettingsPage(title: SettingsSection.notifications.title, intro: L10n.Settings.Notifications.intro) {
            VStack(spacing: 0) {
                SettingsRow(title: L10n.Settings.Notifications.system, hint: Self.statusText(status)) {
                    if status == .notDetermined {
                        Button(L10n.Settings.Notifications.allow) {
                            Task { await request() }
                        }
                        .buttonStyle(SignalButtonStyle())
                    } else {
                        Chip(text: Self.statusText(status), tone: status == .authorized ? .ok : .neutral)
                    }
                }
                Divider().padding(.horizontal, 16)
                toggle(L10n.Settings.Notifications.needsYou, L10n.Settings.Notifications.needsYouHint, $needsYou)
                Divider().padding(.horizontal, 16)
                toggle(L10n.Settings.Notifications.finished, L10n.Settings.Notifications.finishedHint, $finished)
                Divider().padding(.horizontal, 16)
                toggle(L10n.Settings.Notifications.failed, L10n.Settings.Notifications.failedHint, $failed)
            }
            .banditoCard()
        }
        .task { await refresh() }
    }

    private func toggle(_ title: String, _ hint: String, _ isOn: Binding<Bool>) -> some View {
        SettingsRow(title: title, hint: hint) {
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

    static func statusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional, .ephemeral: L10n.Settings.Notifications.statusAllowed
        case .denied: L10n.Settings.Notifications.statusDenied
        case .notDetermined: L10n.Settings.Notifications.statusAsk
        @unknown default: L10n.Settings.Notifications.statusAsk
        }
    }
}
