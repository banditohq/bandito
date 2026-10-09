import BanditoL10n
import Foundation
import UserNotifications

/// The system side of notifications: asks for permission, registers the categories and their buttons, posts
/// requests, removes delivered ones, and passes button presses back to `NotificationService`.
@MainActor
public final class SystemNotificationSink: NSObject, NotificationService.Sink, UNUserNotificationCenterDelegate {
    /// Receives button presses. Set once the service exists.
    public weak var service: NotificationService?

    private let center = UNUserNotificationCenter.current()

    /// Registers the categories and asks for permission. Call once at launch.
    public func start() {
        center.delegate = self
        // Allow needs an unlocked device (the system asks for authentication); Deny is destructive.
        let allow = UNNotificationAction(
            identifier: NotificationContent.allowAction, title: L10n.Notify.allow, options: [.authenticationRequired])
        let deny = UNNotificationAction(
            identifier: NotificationContent.denyAction, title: L10n.Notify.deny, options: [.destructive])
        // With "show previews only when unlocked", the system shows this placeholder instead of the body.
        let placeholder = L10n.Notify.hiddenPreview
        let categories: [UNNotificationCategory] = [
            UNNotificationCategory(
                identifier: NotificationContent.approvalCategory, actions: [allow, deny], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: placeholder, options: []),
            UNNotificationCategory(
                identifier: NotificationContent.approvalReviewCategory, actions: [deny], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: placeholder, options: []),
            UNNotificationCategory(
                identifier: NotificationContent.finishedCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: placeholder, options: []),
            UNNotificationCategory(
                identifier: NotificationContent.failedCategory, actions: [], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: placeholder, options: []),
        ]
        center.setNotificationCategories(Set(categories))
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
        // An approval's notification is identified by the approval, so it can be removed once answered.
        let identifier = content.approvalID ?? UUID().uuidString
        center.add(UNNotificationRequest(identifier: identifier, content: request, trigger: nil))
    }

    public func removeDelivered(approvalID: String) {
        center.removeDeliveredNotifications(withIdentifiers: [approvalID])
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
