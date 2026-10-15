import Foundation
import UserNotifications

/// Opens a push from the Bandito cloud and makes the notification the app would have made from the same event
/// (docs/IOS_APP.md, Push payload). It reads the keys of the servers from the shared Keychain, never talks to a
/// server, and never drops a push: one it cannot open is shown with the cloud's own text and no buttons.
final class NotifyService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        lock.withLock {
            handler = contentHandler
            best = request.content
        }
        let result = PushContent.make(for: request.content, keychain: .shared, shared: .shared)
        // The reminder of the same event that the app made itself (the app was just in the background) is replaced.
        if let key = result.replacesKey {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [key])
        }
        finish(with: result.content)
    }

    /// The system is about to end the extension: what there is, is shown.
    override func serviceExtensionTimeWillExpire() {
        finish(with: nil)
    }

    private func finish(with content: UNNotificationContent?) {
        let (handler, shown) = lock.withLock { () -> (((UNNotificationContent) -> Void)?, UNNotificationContent?) in
            let pair = (self.handler, content ?? self.best)
            self.handler = nil
            return pair
        }
        if let handler, let shown { handler(shown) }
    }
}
