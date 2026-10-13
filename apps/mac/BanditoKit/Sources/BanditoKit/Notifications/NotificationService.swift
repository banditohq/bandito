import BanditoL10n
import Foundation
import os

/// An agent event that may become a system notification.
public enum AgentNotice: Equatable, Sendable {
    /// The agent waits for an approval. `command` is the full command, which the notification never shows
    /// (only the approval's short title), so multi-line or long commands are reviewed in the app.
    /// `reviewOnly`: the request must be read on its own card (a creation of an agent), so the notification never
    /// offers Allow, whatever its text looks like.
    case approval(
        agentID: String, agentName: String, approvalID: String, title: String, command: String? = nil,
        reviewOnly: Bool = false)
    /// The agent finished a turn.
    case finished(agentID: String, agentName: String)
    /// The agent's turn failed.
    case failed(agentID: String, agentName: String, message: String?)
    /// The Allow/Deny answer could not be sent: the request is already answered, or it is stale.
    case resolveFailed(agentID: String)
    /// The agent asked the person to fill in a form. The notification opens the app; it has no buttons.
    case form(agentID: String, agentName: String, formID: String)
    /// The agent waits for an answer. `text` is its last message (the notification's body).
    case question(agentID: String, agentName: String, text: String?)

    public var agentID: String {
        switch self {
        case .approval(let id, _, _, _, _, _), .finished(let id, _), .failed(let id, _, _), .resolveFailed(let id),
            .form(let id, _, _), .question(let id, _, _):
            id
        }
    }

    /// The kind a server's notification scope is checked against. An answer that did not go through concerns a
    /// waiting approval, so it counts as `needsYou`.
    public var kind: ServerNoticeKind {
        switch self {
        case .approval, .resolveFailed, .form, .question: .needsYou
        case .finished: .finished
        case .failed: .failed
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
    /// An answer that failed is always shown: the user pressed a button and must learn it did not go through.
    public static func shouldDeliver(
        _ notice: AgentNotice, settings: NotificationSettings, windowActive: Bool, selectedAgentID: String?
    ) -> Bool {
        switch notice {
        case .resolveFailed:
            return true
        case .approval, .form, .question:
            return settings.needsYou && !windowActive
        case .failed:
            return settings.failed && !windowActive
        case .finished(let agentID, _):
            return settings.finished && !windowActive && agentID != selectedAgentID
        }
    }
}

/// What a system notification says and which buttons it has.
///
/// Lock-screen privacy: the title never contains the command. The body (the command's short title) is hidden
/// on a locked screen by the category's placeholder (see `SystemNotificationSink`).
public struct NotificationContent: Equatable, Sendable {
    public var title: String
    public var body: String
    /// The category with the buttons. Every notice has one, except the answer-failed notice.
    public var categoryID: String?
    public var agentID: String
    /// The approval the buttons answer, for approval notices. Also the notification's identifier.
    public var approvalID: String?
    /// The form a form notice asks about.
    public var formID: String?
    /// The server the notice came from, when the app knows it (`handle(_:serverID:)` sets it).
    public var serverID: UUID?
    /// The daemon marks the request as risky (`ApprovalReason.isRisky`). Set by the caller that read the reason.
    public var risky: Bool = false
    /// The identifier of the system notification, when the caller has one (the event's sequence number on iOS):
    /// a notice with the same key replaces the delivered one instead of adding a second. Nil: a fresh identifier.
    public var key: String?
    /// The agent's name, for the iPhone's title ("Forge хочет выполнить"); the Mac's title does not use it.
    public var agentName: String = ""
    /// The full command of an approval, for the iPhone's body. Nil when the notice has none.
    public var command: String?

    /// Allow and Deny.
    public static let approvalCategory = "bandito.approval"
    /// Deny and open only: for a multi-line or long command, Allow is not offered from the notification.
    public static let approvalReviewCategory = "bandito.approval.review"
    public static let finishedCategory = "bandito.finished"
    public static let failedCategory = "bandito.failed"
    /// A form: no buttons, the notification opens the app.
    public static let formCategory = "bandito.form"
    /// A question: a text reply (`replyAction`) and opening the app.
    public static let questionCategory = "bandito.question"
    public static let allowAction = "bandito.approval.allow"
    public static let denyAction = "bandito.approval.deny"
    public static let replyAction = "bandito.question.reply"
    /// Commands longer than this many characters are reviewed in the app, not allowed from the notification.
    public static let longCommandLimit = 160

    /// Whether the command must be reviewed in the app: it has a line break, or it is long.
    public static func needsReview(_ command: String) -> Bool {
        command.contains(where: \.isNewline) || command.count > longCommandLimit
    }

    /// The category for an approval. No command means the plain one (Allow and Deny).
    public static func approvalCategoryID(command: String?, reviewOnly: Bool = false) -> String {
        if reviewOnly { return approvalReviewCategory }
        guard let command, needsReview(command) else { return approvalCategory }
        return approvalReviewCategory
    }

    public static func make(_ notice: AgentNotice) -> NotificationContent {
        switch notice {
        case .approval(let agentID, let agentName, let approvalID, let title, let command, let reviewOnly):
            let reviewed = reviewOnly || (command.map(needsReview) ?? false)
            var content = NotificationContent(
                title: L10n.Notify.needsApproval(name: agentName),
                body: reviewed ? reviewBody(command ?? "") : title,
                categoryID: approvalCategoryID(command: command, reviewOnly: reviewOnly), agentID: agentID, approvalID: approvalID)
            content.agentName = agentName
            content.command = command
            return content
        case .finished(let agentID, let agentName):
            return NotificationContent(
                title: L10n.Notify.finished(name: agentName), body: "",
                categoryID: finishedCategory, agentID: agentID, approvalID: nil, agentName: agentName)
        case .failed(let agentID, let agentName, let message):
            return NotificationContent(
                title: L10n.Notify.failed(name: agentName), body: message ?? "",
                categoryID: failedCategory, agentID: agentID, approvalID: nil, agentName: agentName)
        case .resolveFailed(let agentID):
            return NotificationContent(
                title: L10n.Notify.resolveFailed, body: "", categoryID: nil, agentID: agentID, approvalID: nil)
        case .form(let agentID, let agentName, let formID):
            return NotificationContent(
                title: L10n.Notify.form(name: agentName), body: "", categoryID: formCategory, agentID: agentID,
                approvalID: nil, formID: formID, agentName: agentName)
        case .question(let agentID, let agentName, let text):
            return NotificationContent(
                title: L10n.Notify.question(name: agentName), body: text ?? "", categoryID: questionCategory,
                agentID: agentID, approvalID: nil, agentName: agentName)
        }
    }

    /// "Команда из N строк — откройте, чтобы проверить" for a multi-line command, a sentence about its length otherwise.
    public static func reviewBody(_ command: String) -> String {
        let lines = command.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        if lines > 1 {
            return L10n.Notify.reviewLines(count: lines)
        }
        return L10n.Notify.reviewLong
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

/// The agent is no longer known to the app, so an answer cannot be sent to it.
public struct AgentNotFoundError: Error, Equatable {
    public init() {}
}

/// Posts notices and answers approvals from their buttons. The system part is behind `Sink`.
@MainActor
public final class NotificationService {
    /// Shows one notification and removes the delivered one of an approval. `SystemNotificationSink` is the
    /// system one; tests use a fake.
    @MainActor
    public protocol Sink: AnyObject {
        func post(_ content: NotificationContent)
        /// Removes the delivered notification of this approval: it was answered, here or on another device.
        func removeDelivered(approvalID: String)
    }

    private static let logger = Logger(subsystem: "app.bandito", category: "notifications")

    private let sink: Sink
    private let settings: () -> NotificationSettings
    private let windowActive: () -> Bool
    private let selectedAgentID: () -> String?
    private let resolve: (_ agentID: String, _ approvalID: String, _ decision: Decision) async throws -> Void
    private let reply: (_ agentID: String, _ text: String) async throws -> Void
    private let scope: (UUID) -> NotificationScope

    /// `scope` says which notifications each server sends (`ServerConfig.notifications`). The default lets all through.
    /// `reply` sends a text answer to a question (iOS); nil means the platform does not offer one.
    public init(
        sink: Sink,
        settings: @escaping () -> NotificationSettings,
        windowActive: @escaping () -> Bool,
        selectedAgentID: @escaping () -> String?,
        resolve: @escaping (_ agentID: String, _ approvalID: String, _ decision: Decision) async throws -> Void,
        reply: @escaping (_ agentID: String, _ text: String) async throws -> Void = { _, _ in throw AgentNotFoundError() },
        scope: @escaping (UUID) -> NotificationScope = { _ in .all }
    ) {
        self.sink = sink
        self.settings = settings
        self.windowActive = windowActive
        self.selectedAgentID = selectedAgentID
        self.resolve = resolve
        self.reply = reply
        self.scope = scope
    }

    /// Shows the notice when the rules allow it. With a `serverID`, the server's notification scope is checked first.
    /// `key` names the system notification (see `NotificationContent.key`); `risky` marks a risky approval.
    public func handle(_ notice: AgentNotice, serverID: UUID? = nil, key: String? = nil, risky: Bool = false) {
        if let serverID, !scope(serverID).allows(notice.kind) { return }
        guard NotificationRules.shouldDeliver(
            notice, settings: settings(), windowActive: windowActive(), selectedAgentID: selectedAgentID())
        else { return }
        var content = NotificationContent.make(notice)
        content.serverID = serverID
        content.key = key
        content.risky = risky
        sink.post(content)
    }

    /// A button on an approval notification was pressed. Clicks on the body answer nothing.
    /// On success the notification goes away. On failure the log gets the reason (never the command) and the
    /// user gets a notice that the answer did not go through.
    public func handleAction(_ identifier: String, agentID: String, approvalID: String) async {
        guard let decision = NotificationContent.decision(forAction: identifier) else { return }
        guard !approvalID.isEmpty else { return }
        do {
            try await resolve(agentID, approvalID, decision)
            sink.removeDelivered(approvalID: approvalID)
        } catch {
            Self.logger.error("approval answer failed: \(Self.reason(of: error), privacy: .public)")
            sink.post(NotificationContent.make(.resolveFailed(agentID: agentID)))
        }
    }

    /// The text the person typed into a question's notification. Empty text sends nothing.
    public func handleReply(_ text: String, agentID: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await reply(agentID, trimmed)
        } catch {
            Self.logger.error("question reply failed: \(Self.reason(of: error), privacy: .public)")
            sink.post(NotificationContent.make(.resolveFailed(agentID: agentID)))
        }
    }

    /// The approval was answered in the app or on another device: its notification is no longer needed.
    public func approvalSettled(_ approvalID: String) {
        guard !approvalID.isEmpty else { return }
        sink.removeDelivered(approvalID: approvalID)
    }

    /// What went wrong, without any text the daemon sent: an RPC code, or the error's type.
    static func reason(of error: Error) -> String {
        if let rpc = error as? RPCError { return "rpc code \(rpc.code)" }
        return String(describing: type(of: error))
    }
}

extension AgentNotice {
    /// The notice an agent event makes, if any: an approval waiting, a finished turn, or an error. A quiet turn
    /// (`turn.quiet`) finishes without a notice. Shared by the Mac and the iPhone.
    @MainActor
    public static func notice(for event: Event, in server: ServerModel) -> AgentNotice? {
        let name = server.agents.first { $0.id == event.agentId }?.name ?? ""
        switch event.body {
        case .approvalRequested(let approvalID, _, let tool, let title, let command, _, _, _):
            return .approval(
                agentID: event.agentId, agentName: name, approvalID: approvalID, title: title, command: command,
                reviewOnly: tool == AgentCreateSummary.tool)
        case .turnCompleted(_, .ok, _, _):
            if server.thread(for: event.agentId).quietTurn { return nil }
            return .finished(agentID: event.agentId, agentName: name)
        case .error(let message):
            return .failed(agentID: event.agentId, agentName: name, message: message)
        default:
            return nil
        }
    }
}
