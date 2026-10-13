import UserNotifications

/// What the system allows for Bandito's notifications.
enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case denied
    case allowed

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral: self = .allowed
        case .notDetermined: self = .notDetermined
        default: self = .denied
        }
    }
}

/// Reads the notification permission and asks for it. Asking happens only after a press on the Settings button, never
/// on launch.
enum SystemNotifications {
    static func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationPermission(settings.authorizationStatus)
    }

    static func requestPermission() async -> NotificationPermission {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        return await permission()
    }
}
