import BanditoL10n
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// What the host app handed to the extension, read item by item.
struct SharedContent: Sendable {
    var text = ""
    var images: [PreparedImage] = []
}

/// One picture ready to send: the JPEG, and a small copy for the sheet.
struct PreparedImage: Identifiable, @unchecked Sendable {
    let id = UUID()
    let jpeg: Data
    let thumbnail: UIImage
}

/// What the sheet is doing.
enum ShareStage: Equatable {
    case editing
    case saving
    /// Saved. Opening Bandito from here is not reliable (iOS 18 and later), so the sheet always says so and waits for
    /// the person to press Done.
    case saved
    case failed
}

/// The state of the share sheet: the agents, the text, the pictures, and the send. Main actor, like the view.
@MainActor @Observable
final class ShareModel {
    private(set) var agents: [WidgetSnapshot.Listing]
    var selectedKey: String?
    var text = ""
    private(set) var images: [PreparedImage] = []
    private(set) var loading = true
    private(set) var stage: ShareStage = .editing

    /// Opens Bandito with a link; false when the extension has no way to. Set by the controller.
    var openApp: (URL) async -> Bool = { _ in false }
    /// Leaves a reminder that the task waits (a local notification). Replaced in tests and the preview.
    var remind: (SharedTask) async -> Void = { await ShareModel.scheduleReminder(for: $0) }
    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    private let inbox: ShareInbox?
    private let defaults: UserDefaults?

    init(
        agents: [WidgetSnapshot.Listing], inbox: ShareInbox?, defaults: UserDefaults?
    ) {
        let last = defaults?.string(forKey: ShareRules.lastKey)
        self.agents = ShareRules.order(agents, last: last)
        self.inbox = inbox
        self.defaults = defaults
        self.selectedKey = self.agents.first.map(ShareRules.key)
    }

    /// The model of the extension: the agents of the widget snapshot, the inbox and the defaults of the App Group.
    static func live() -> ShareModel {
        let directory = WidgetSnapshotStore.appGroup()?.read()?.directory ?? []
        return ShareModel(
            agents: directory, inbox: ShareInbox.appGroup(),
            defaults: UserDefaults(suiteName: WidgetAppGroup.identifier))
    }

    var chosen: WidgetSnapshot.Listing? {
        agents.first { ShareRules.key($0) == selectedKey }
    }

    var canSend: Bool {
        (stage == .editing || stage == .failed) && !loading
            && ShareRules.canSend(text: text, imageCount: images.count, agentChosen: chosen != nil)
    }

    func apply(_ content: SharedContent) {
        if text.isEmpty { text = content.text }
        images = content.images
        loading = false
    }

    #if DEBUG
    /// `-share-preview -share-saved`: the screen after Send, for the screenshots.
    func showSavedForPreview() {
        stage = .saved
    }
    #endif

    /// Writes the task to the App Group, then opens Bandito on it. The write comes first, always.
    func send() {
        guard canSend, let agent = chosen, let inbox else { return }
        stage = .saving
        Task { await save(agent: agent, inbox: inbox) }
    }

    private func save(agent: WidgetSnapshot.Listing, inbox: ShareInbox) async {
        let task = SharedTask(
            id: UUID(), serverID: agent.server, agentID: agent.id,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), images: [], createdAt: Date(),
            agentName: agent.name)
        do {
            try inbox.save(task, images: images.map(\.jpeg))
        } catch {
            stage = .failed
            return
        }
        defaults?.set(ShareRules.key(agent), forKey: ShareRules.lastKey)
        // The saved screen comes at once and stays. The reminder is set first (it is what brings the person back when
        // the app does not open), then Bandito is asked to open: if it does, good.
        stage = .saved
        await remind(task)
        _ = await openApp(BanditoLink.share(id: task.id).url)
    }

    /// A local notification one second from now, "Open to send the task to Forge", whose press opens the share link.
    /// Only when the app may show notifications (authorized or provisional): the extension never asks.
    static func scheduleReminder(for task: SharedTask) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "Bandito"
        content.body = L10n.Ios.Share.notify(name: task.displayName)
        content.sound = .default
        content.userInfo = [ShareReminder.userInfoKey: BanditoLink.share(id: task.id).url.absoluteString]
        let request = UNNotificationRequest(
            identifier: ShareReminder.identifier(for: task.id), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        try? await center.add(request)
    }

    func dismissFailure() {
        if stage == .failed { stage = .editing }
    }
}
