import BanditoDesign
import BanditoL10n
import SwiftUI

/// The explanation before the system asks for notifications. Shown once, after the first server is connected; the
/// system's own question comes only when the person agrees here.
enum NotificationAsk {
    static let askedKey = "ios.notifications.askedAfterFirstServer"

    static var wasAsked: Bool { UserDefaults.standard.bool(forKey: askedKey) }

    static func markAsked() { UserDefaults.standard.set(true, forKey: askedKey) }
}

struct NotificationAskSheet: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s4) {
            Image(systemName: "bell.badge")
                .font(.system(size: 40))
                .foregroundStyle(Color.Bandito.signal)
                .accessibilityHidden(true)
            Text(L10n.Ios.Notifications.Ask.title)
                .font(BanditoFont.display(size: 20, weight: 700))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Ios.Notifications.Ask.body)
                .font(BanditoFont.text(size: 14))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Button(L10n.Ios.Settings.Notifications.allow) {
                Task {
                    _ = await SystemNotifications.requestPermission()
                    onDone()
                }
            }
            .buttonStyle(SignalButtonStyle())
            .accessibilityIdentifier("notifications.ask.allow")
            Button(L10n.Ios.Notifications.Ask.later, action: onDone)
                .buttonStyle(QuietButtonStyle())
                .accessibilityIdentifier("notifications.ask.later")
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.Bandito.bg.ignoresSafeArea())
    }
}
