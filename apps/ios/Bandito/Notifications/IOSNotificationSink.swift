import BanditoKit
import BanditoL10n
import Foundation
@preconcurrency import UserNotifications

/// The system side of the phone's notifications: registers the categories and their buttons, posts one request per
/// key, removes the delivered ones of an answered approval, and turns a press into an answer or a route into the app.
@MainActor
final class IOSNotificationSink: NSObject, NotificationService.Sink, UNUserNotificationCenterDelegate {
    /// Receives the answers from the buttons. Set once the service exists.
    weak var service: NotificationService?
    /// Whether a risky approval's Allow opens the app on its sheet (`IOSSettings.riskyNeedsFaceID`).
    var riskyNeedsFaceID: () -> Bool = { true }
    /// Receives where a press leads the app.
    var onRoute: ((IOSNotifications.Route) -> Void)?

    /// The category of a risky approval while `riskyNeedsFaceID` is on: its Allow opens the app (the sheet asks Face ID).
    static let riskyCategory = "bandito.approval.risky"
    static let questionCategory = NotificationContent.questionCategory

    /// Registers the categories. Call once at launch. Nothing is asked here: the permission is asked at the first
    /// notice that needs it (`post`).
    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Allow needs an unlocked phone (the system asks for the owner); Deny is destructive.
        let allow = UNNotificationAction(
            identifier: NotificationContent.allowAction, title: L10n.Notify.allow, options: [.authenticationRequired])
        let allowInApp = UNNotificationAction(
            identifier: NotificationContent.allowAction, title: L10n.Notify.allow,
            options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(
            identifier: NotificationContent.denyAction, title: L10n.Notify.deny, options: [.destructive])
        let reply = UNTextInputNotificationAction(
            identifier: NotificationContent.replyAction, title: L10n.Notify.reply, options: [],
            textInputButtonTitle: L10n.Notify.reply, textInputPlaceholder: L10n.Notify.replyPlaceholder)
        let placeholder = L10n.Notify.hiddenPreview
        func category(_ id: String, _ actions: [UNNotificationAction]) -> UNNotificationCategory {
            UNNotificationCategory(
                identifier: id, actions: actions, intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: placeholder,
                options: [])
        }
        center.setNotificationCategories([
            category(NotificationContent.approvalCategory, [allow, deny]),
            category(NotificationContent.approvalReviewCategory, [deny]),
            category(Self.riskyCategory, [allowInApp, deny]),
            category(NotificationContent.finishedCategory, []),
            category(NotificationContent.failedCategory, []),
            category(NotificationContent.formCategory, []),
            category(Self.questionCategory, [reply]),
        ])
    }

    /// The category a notice is posted with: a risky approval whose Allow asks for the app's sheet, else the shared one.
    static func categoryID(for content: NotificationContent, riskyNeedsFaceID: Bool) -> String? {
        if content.categoryID == NotificationContent.approvalCategory, content.risky, riskyNeedsFaceID {
            return riskyCategory
        }
        return content.categoryID
    }

    /// The identifier of the system request: the content's key (server and event), else its approval, else fresh.
    static func identifier(for content: NotificationContent) -> String {
        content.key ?? content.approvalID ?? UUID().uuidString
    }

    func post(_ content: NotificationContent) {
        Task { await deliver(content) }
    }

    private func deliver(_ content: NotificationContent) async {
        guard await permissionAllows() else { return }
        let request = UNMutableNotificationContent()
        request.title = Self.title(for: content)
        request.body = Self.body(for: content)
        request.sound = .default
        request.threadIdentifier = content.agentID
        request.categoryIdentifier = Self.categoryID(for: content, riskyNeedsFaceID: riskyNeedsFaceID()) ?? ""
        request.userInfo = [
            "agentID": content.agentID,
            "approvalID": content.approvalID ?? "",
            "formID": content.formID ?? "",
            "risky": content.risky,
        ]
        let identifier = Self.identifier(for: content)
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: request, trigger: nil))
    }

    /// An approval says "Forge хочет выполнить" (the agent's name); the other notices keep their own titles.
    static func title(for content: NotificationContent) -> String {
        if content.approvalID != nil, content.categoryID == NotificationContent.approvalCategory
            || content.categoryID == NotificationContent.approvalReviewCategory
        {
            return L10n.Notify.wantsToRun(name: content.agentName)
        }
        return content.title
    }

    /// The command itself, for an approval Allow can answer; the review sentence for a long or multi-line one.
    static func body(for content: NotificationContent) -> String {
        if content.categoryID == NotificationContent.approvalCategory, let command = content.command {
            return command
        }
        return content.body
    }

    /// Asks the system once, when the first notice needs it, and returns whether notices may be shown.
    private func permissionAllows() async -> Bool {
        switch await SystemNotifications.permission() {
        case .allowed: true
        case .denied: false
        case .notDetermined: await SystemNotifications.requestPermission() == .allowed
        }
    }

    func removeDelivered(approvalID: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let identifiers = delivered
                .filter { ($0.request.content.userInfo["approvalID"] as? String) == approvalID }
                .map(\.request.identifier)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// The app is open: the change shows in the app, so no banner.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let agentID = info["agentID"] as? String ?? ""
        let approvalID = info["approvalID"] as? String ?? ""
        let risky = info["risky"] as? Bool ?? false
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        let link = info[ShareReminder.userInfoKey] as? String ?? ""
        completionHandler()
        Task { @MainActor [weak self] in
            await self?.respond(
                action: action, agentID: agentID, approvalID: approvalID, risky: risky, typed: typed, link: link)
        }
    }

    /// What a press does: the body opens the app; a risky Allow opens the sheet (no answer is sent here); the other
    /// buttons and the reply answer through the service.
    func respond(
        action: String, agentID: String, approvalID: String, risky: Bool, typed: String, link: String = ""
    ) async {
        switch action {
        case UNNotificationDefaultActionIdentifier:
            if let url = URL(string: link), !link.isEmpty {
                onRoute?(.link(url))
                return
            }
            onRoute?(IOSNotifications.routeForPress(agentID: agentID, approvalID: approvalID))
        case NotificationContent.allowAction where risky && riskyNeedsFaceID():
            onRoute?(.approval(approvalID: approvalID, agentID: agentID))
        case NotificationContent.replyAction:
            await service?.handleReply(typed, agentID: agentID)
        default:
            await service?.handleAction(action, agentID: agentID, approvalID: approvalID)
        }
    }
}
