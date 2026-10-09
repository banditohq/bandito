import BanditoL10n
import Foundation
import UserNotifications

/// The system side of notifications: asks for permission, registers the Allow/Deny buttons, posts requests,
/// and passes button presses back to `NotificationService`.
@MainActor
public final class SystemNotificationSink: NSObject, NotificationService.Sink, UNUserNotificationCenterDelegate {
    /// Receives button presses. Set once the service exists.
    public weak var service: NotificationService?

    private let center = UNUserNotificationCenter.current()

    /// Registers the category and asks for permission. Call once at launch.
    public func start() {
        center.delegate = self
        let allow = UNNotificationAction(
            identifier: NotificationContent.allowAction, title: L10n.Notify.allow, options: [])
        let deny = UNNotificationAction(
            identifier: NotificationContent.denyAction, title: L10n.Notify.deny, options: [.destructive])
        let category = UNNotificationCategory(
            identifier: NotificationContent.approvalCategory, actions: [allow, deny], intentIdentifiers: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    public func post(_ content: NotificationContent) {
        let request = UNMutableNotificationContent()
        request.title = content.title
        request.body = content.body
        request.sound = .default
        if let categoryID = content.categoryID {
            request.categoryIdentifier = categoryID
        }
        request.userInfo = ["agentID": content.agentID, "approvalID": content.approvalID ?? ""]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: request, trigger: nil))
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let agentID = info["agentID"] as? String ?? ""
        let approvalID = info["approvalID"] as? String ?? ""
        let action = response.actionIdentifier
        completionHandler()
        Task { @MainActor [weak self] in
            await self?.service?.handleAction(action, agentID: agentID, approvalID: approvalID)
        }
    }
}
