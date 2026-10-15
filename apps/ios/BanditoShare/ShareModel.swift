import BanditoL10n
import Observation
import SwiftUI
import UIKit

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
    /// Saved, but the extension could not open Bandito: the person opens it.
    case savedNotOpened
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
    var openApp: (URL) -> Bool = { _ in false }
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
        stage == .editing && !loading
            && ShareRules.canSend(text: text, imageCount: images.count, agentChosen: chosen != nil)
    }

    func apply(_ content: SharedContent) {
        if text.isEmpty { text = content.text }
        images = content.images
        loading = false
    }

    /// Writes the task to the App Group, then opens Bandito on it. The write comes first, always.
    func send() {
        guard canSend, let agent = chosen, let inbox else { return }
        stage = .saving
        let task = SharedTask(
            id: UUID(), serverID: agent.server, agentID: agent.id,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), images: [], createdAt: Date())
        do {
            try inbox.save(task, images: images.map(\.jpeg))
        } catch {
            stage = .failed
            return
        }
        defaults?.set(ShareRules.key(agent), forKey: ShareRules.lastKey)
        if openApp(BanditoLink.share(id: task.id).url) {
            finish()
        } else {
            stage = .savedNotOpened
        }
    }

    func dismissFailure() {
        if stage == .failed { stage = .editing }
    }
}
