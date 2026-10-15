import Foundation
import UserNotifications

/// The notification a push becomes. In the shared folder so the app's tests run what the extension runs.
enum PushContent {
    struct Outcome {
        var content: UNNotificationContent
        /// The identifier a local notice of the same event has, when this one stands in for it.
        var replacesKey: String?
    }

    /// The content to show for a push. Pure apart from the shared Keychain and the group's defaults (given), so the app's
    /// tests run it.
    static func make(for original: UNNotificationContent, keychain: PushKeychain, shared: PushShared) -> Outcome {
        let fallback = unopened(original)
        guard let handle = keychain.handle else { return Outcome(content: fallback) }
        guard let opened = PushCrypto.open(userInfo: original.userInfo, handle: handle, keys: keychain.allKeys()),
            let plan = PushNoticeBuilder.plan(
                plain: opened.plain, serverRef: opened.serverRef, riskyNeedsFaceID: shared.riskyNeedsFaceID)
        else { return Outcome(content: fallback) }
        let content = UNMutableNotificationContent()
        content.title = plan.fields.title
        content.body = plan.fields.body
        content.sound = original.sound ?? .default
        content.threadIdentifier = plan.fields.threadID
        content.categoryIdentifier = plan.fields.categoryID
        content.userInfo = plan.fields.userInfo
        content.badge = original.badge
        // The app reads this: the event has been shown, so it makes no second notice of it.
        if plan.seq > 0 { shared.noteSeq(plan.seq, for: plan.serverRef) }
        return Outcome(content: content, replacesKey: plan.seq > 0 ? plan.noticeKey : nil)
    }

    /// The cloud's text, with no buttons: the push could not be opened (no key for it, a damaged one, a newer format).
    static func unopened(_ original: UNNotificationContent) -> UNNotificationContent {
        let content = (original.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        content.categoryIdentifier = PushNoticeBuilder.unopenedCategory
        return content
    }
}
