import BanditoKit
import Foundation

/// What the person's answer to an Inbox item sends, and whether it may be sent. The Face ID rule is here, not in the
/// view, so it can be tested with a fake authenticator.
@MainActor
enum InboxAnswer {
    /// How an answer ended, as the view shows it.
    enum Outcome: Equatable {
        case sent
        /// Face ID (or the passcode) was not confirmed: nothing was sent.
        case notConfirmed
        /// The owner cannot be checked at all (no Face ID, no passcode): a risky request is not allowed.
        case cannotConfirm
        /// The server refused the answer, or the connection failed: the answer did not reach the agent.
        case failed
    }

    /// Whether allowing the item asks for Face ID first: a risky approval, while the setting `riskyNeedsFaceID` is on.
    static func needsFaceID(_ item: InboxItem, riskyNeedsFaceID: Bool) -> Bool {
        riskyNeedsFaceID && item.isRisky
    }

    /// Allows an approval. A risky one is allowed only after the owner confirms with `authenticator`; when the owner
    /// cannot be checked, it is not allowed (it fails closed, unlike the app lock, which opens for a device without any
    /// passcode).
    static func allow(
        _ item: InboxItem, server: ServerModel, remember: Bool, riskyNeedsFaceID: Bool,
        authenticator: any BiometricAuthenticating, reason: String
    ) async throws -> Outcome {
        guard case .approval(let row) = item.kind else { return .sent }
        if needsFaceID(item, riskyNeedsFaceID: riskyNeedsFaceID) {
            guard authenticator.isAvailable else { return .cannotConfirm }
            guard await authenticator.authenticate(reason: reason) else { return .notConfirmed }
        }
        try await server.resolve(row.approvalId, .allow, remember: remember)
        return .sent
    }

    /// Refuses an approval. Needs no Face ID: refusing is never the risky side.
    static func deny(_ item: InboxItem, server: ServerModel) async throws {
        guard case .approval(let row) = item.kind else { return }
        try await server.resolve(row.approvalId, .deny)
    }

    /// Sends the answers of a form (`forms.answer`, action submit). The values are the checked ones of `FormAnswer`.
    static func submit(_ item: InboxItem, server: ServerModel, values: [String: JSONValue]) async throws {
        guard case .form(let row) = item.kind else { return }
        try await server.answerForm(row.formId, in: item.agentID, action: .submit, values: values)
    }

    /// Rejects a form without an answer (`forms.answer`, action reject).
    static func rejectForm(_ item: InboxItem, server: ServerModel) async throws {
        guard case .form(let row) = item.kind else { return }
        try await server.answerForm(row.formId, in: item.agentID, action: .reject)
    }

    /// The person does not want the service the agent asked for.
    static func declineConnect(_ item: InboxItem, server: ServerModel) async throws {
        guard case .connect(let row) = item.kind else { return }
        try await server.declineConnect(row.requestId)
    }

    /// Sends the text of a quick-reply button as the person's message, as the Mac does.
    static func reply(_ text: String, to item: InboxItem, server: ServerModel) async throws {
        try await server.send(text, to: item.agentID, viaButton: true)
    }
}
