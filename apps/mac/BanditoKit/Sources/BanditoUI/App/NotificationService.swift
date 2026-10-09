import BanditoKit
import BanditoL10n
import Foundation

/// An agent event that may become a system notification.
public enum AgentNotice: Equatable, Sendable {
    /// The agent waits for an approval.
    case approval(agentID: String, agentName: String, approvalID: String, title: String)
    /// The agent finished a turn.
    case finished(agentID: String, agentName: String)
    /// The agent's turn failed.
    case failed(agentID: String, agentName: String, message: String?)

    public var agentID: String {
        switch self {
        case .approval(let id, _, _, _), .finished(let id, _), .failed(let id, _, _): id
        }
    }
}

/// Which kinds of notice the user wants. Set in Settings → Notifications; all on by default.
public struct NotificationSettings: Equatable, Sendable {
    public var needsYou: Bool
    public var finished: Bool
    public var failed: Bool

    public init(needsYou: Bool = true, finished: Bool = true, failed: Bool = true) {
        self.needsYou = needsYou
        self.finished = finished
        self.failed = failed
    }

    /// Reads the keys the Notifications settings page writes.
    public init(defaults: UserDefaults) {
        needsYou = defaults.object(forKey: "notify.needsYou") as? Bool ?? true
        finished = defaults.object(forKey: "notify.finished") as? Bool ?? true
        failed = defaults.object(forKey: "notify.error") as? Bool ?? true
    }
}

/// Decides whether a notice is shown. Pure, so the rules can be tested without the system.
public enum NotificationRules {
    /// Approvals and failures are shown only when the window is in the background, since the user can see
    /// the thread otherwise. A finished turn is shown for another agent only, and only from the background.
    public static func shouldDeliver(
        _ notice: AgentNotice, settings: NotificationSettings, windowActive: Bool, selectedAgentID: String?
    ) -> Bool {
        if windowActive { return false }
        switch notice {
        case .approval: return settings.needsYou
        case .failed: return settings.failed
        case .finished(let agentID, _):
            return settings.finished && agentID != selectedAgentID
        }
    }
}

/// What a system notification says and which buttons it has.
public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String
    /// The category with the Allow and Deny buttons; nil when the notice has no buttons.
    public var categoryID: String?
    public var agentID: String
    /// The approval the buttons answer, for approval notices.
    public var approvalID: String?

    public static let approvalCategory = "bandito.approval"
    public static let allowAction = "bandito.approval.allow"
    public static let denyAction = "bandito.approval.deny"

    public static func make(_ notice: AgentNotice) -> NotificationContent {
        switch notice {
        case .approval(let agentID, let agentName, let approvalID, let title):
            return NotificationContent(
                title: L10n.Notify.needsYou(name: agentName, title: title), body: "",
                categoryID: approvalCategory, agentID: agentID, approvalID: approvalID)
        case .finished(let agentID, let agentName):
            return NotificationContent(
                title: L10n.Notify.finished(name: agentName), body: "",
                categoryID: nil, agentID: agentID, approvalID: nil)
        case .failed(let agentID, let agentName, let message):
            return NotificationContent(
                title: L10n.Notify.failed(name: agentName), body: message ?? "",
                categoryID: nil, agentID: agentID, approvalID: nil)
        }
    }

    /// The decision a button stands for, or nil for a plain click on the notification.
    public static func decision(forAction identifier: String) -> Decision? {
        switch identifier {
        case allowAction: .allow
        case denyAction: .deny
        default: nil
        }
    }
}

/// Posts notices and answers approvals from their buttons. The system part is behind `Sink`.
@MainActor
public final class NotificationService {
    /// Shows one notification. `UNUserNotificationSink` is the system one; tests use a fake.
    @MainActor
    public protocol Sink: AnyObject {
        func post(_ content: NotificationContent)
    }

    private let sink: Sink
    private let settings: () -> NotificationSettings
    private let windowActive: () -> Bool
    private let selectedAgentID: () -> String?
    private let resolve: (_ agentID: String, _ approvalID: String, _ decision: Decision) async -> Void

    public init(
        sink: Sink,
        settings: @escaping () -> NotificationSettings,
        windowActive: @escaping () -> Bool,
        selectedAgentID: @escaping () -> String?,
        resolve: @escaping (_ agentID: String, _ approvalID: String, _ decision: Decision) async -> Void
    ) {
        self.sink = sink
        self.settings = settings
        self.windowActive = windowActive
        self.selectedAgentID = selectedAgentID
        self.resolve = resolve
    }

    /// Shows the notice when the rules allow it.
    public func handle(_ notice: AgentNotice) {
        guard NotificationRules.shouldDeliver(
            notice, settings: settings(), windowActive: windowActive(), selectedAgentID: selectedAgentID())
        else { return }
        sink.post(NotificationContent.make(notice))
    }

    /// A button on an approval notification was pressed. Clicks on the body are ignored.
    public func handleAction(_ identifier: String, agentID: String, approvalID: String) async {
        guard let decision = NotificationContent.decision(forAction: identifier) else { return }
        await resolve(agentID, approvalID, decision)
    }
}
