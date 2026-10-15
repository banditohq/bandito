import BanditoKit
import BanditoL10n
import Foundation

// What a notification says, built in one place for both ways it can come: made by the app from a live event, or by the
// notification extension from a push. This folder is compiled into both targets.

/// The pure part of the phone's notifications: an event becomes a notice, a notice becomes the fields of a system
/// notification (title, text, category, what a press carries).
enum PhoneNotice {
    /// The notice an event makes on the phone, and whether it is a risky approval. The shared notices (approval,
    /// finished, error) come from `AgentNotice.notice(for:agentName:quietTurn:turnText:)`; a form and a question are
    /// phone-only. `turnText` is a finished turn's reply (plain, from the push); `agentWaitsAlone` says whether nothing
    /// else of the agent waits (a question is the agent's own wait, as the Inbox lists it); `questionText` is its last
    /// message.
    static func notice(
        for event: Event, agentName name: String, quietTurn: () -> Bool, turnText: () -> String?,
        agentWaitsAlone: () -> Bool, questionText: () -> String?
    ) -> (notice: AgentNotice, risky: Bool)? {
        if case .approvalRequested(_, _, _, _, _, _, let reason, _) = event.body {
            guard
                let notice = AgentNotice.notice(for: event, agentName: name, quietTurn: quietTurn, turnText: turnText)
            else { return nil }
            return (notice, ApprovalReason.isRisky(reason))
        }
        if let notice = AgentNotice.notice(for: event, agentName: name, quietTurn: quietTurn, turnText: turnText) {
            return (notice, false)
        }
        switch event.body {
        case .formRequested(let formID, _):
            return (.form(agentID: event.agentId, agentName: name, formID: formID), false)
        case .agentStatus(let status, _) where status == .needsYou:
            guard agentWaitsAlone() else { return nil }
            return (.question(agentID: event.agentId, agentName: name, text: questionText()), false)
        default:
            return nil
        }
    }

    /// The category of a risky approval while `riskyNeedsFaceID` is on: its Allow opens the app (the sheet asks Face ID).
    static let riskyCategory = "bandito.approval.risky"

    /// The category a notice is posted with: a risky approval whose Allow asks for the app's sheet, else the shared one.
    static func categoryID(for content: NotificationContent, riskyNeedsFaceID: Bool) -> String? {
        if content.categoryID == NotificationContent.approvalCategory, content.risky, riskyNeedsFaceID {
            return riskyCategory
        }
        return content.categoryID
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

    /// What the system notification of a notice carries.
    struct Fields {
        var title: String
        var body: String
        /// Empty when the notice has no category (the answer-failed notice).
        var categoryID: String
        var threadID: String
        /// `agentID`, `approvalID`, `formID`, `risky`, and `server` (the server's id) when it is known: a press reads them.
        var userInfo: [String: Any]
    }

    static func fields(for content: NotificationContent, serverRef: String?, riskyNeedsFaceID: Bool) -> Fields {
        var info: [String: Any] = [
            "agentID": content.agentID,
            "approvalID": content.approvalID ?? "",
            "formID": content.formID ?? "",
            "risky": content.risky,
        ]
        if let server = serverRef ?? content.serverID?.uuidString { info["server"] = server }
        return Fields(
            title: title(for: content), body: body(for: content),
            categoryID: categoryID(for: content, riskyNeedsFaceID: riskyNeedsFaceID) ?? "",
            threadID: content.agentID, userInfo: info)
    }
}

/// A push, opened and turned into a notification.
enum PushNoticeBuilder {
    /// What the extension shows for a push it could open.
    struct Plan {
        var fields: PhoneNotice.Fields
        var serverRef: String
        var seq: Int64
        /// The key a local notice of the same event has (`<server>:<seq>`): the extension takes that one down.
        var noticeKey: String { "\(serverRef):\(seq)" }
    }

    /// The plan for an open text, or nil when it is not a push this version reads (then the cloud's own text stays).
    static func plan(plain: Data, serverRef: String, riskyNeedsFaceID: Bool) -> Plan? {
        guard let root = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any],
            (root["v"] as? Int) == 1,
            let agent = root["agent"] as? String, !agent.isEmpty,
            let name = root["name"] as? String, !name.isEmpty,
            let eventBody = root["event"] as? [String: Any], let kind = eventBody["kind"] as? String
        else { return nil }
        let seq = (root["seq"] as? NSNumber)?.int64Value ?? 0
        let ts = (root["ts"] as? NSNumber)?.int64Value ?? 0

        var made: (notice: AgentNotice, risky: Bool)?
        // The reply of a done, as the daemon wrote it (plain); an older daemon sends none.
        let text = (root["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // The event as `events.since` sends it: decoded by the same code as the app's live events.
        var wire = eventBody
        wire["seq"] = seq
        wire["agent_id"] = agent
        wire["ts"] = ts
        var decoded = false
        if let data = try? JSONSerialization.data(withJSONObject: wire),
            let event = try? RPCClient.decoder.decode(Event.self, from: data)
        {
            decoded = true
            // The daemon has already looked at the agent's other waits and at quiet turns; nothing is left to check here.
            made = PhoneNotice.notice(
                for: event, agentName: name, quietTurn: { false }, turnText: { text }, agentWaitsAlone: { true },
                questionText: { nil })
        }
        if !decoded {
            made = shortened(
                kind: kind, payload: eventBody["payload"] as? [String: Any], agent: agent, name: name, text: text)
        }
        guard let made else { return nil }
        var content = NotificationContent.make(made.notice)
        content.risky = made.risky
        content.agentName = name
        // An approval that cannot be answered (its id was cut) has nothing to press: no buttons.
        if case .approval(_, _, let approvalID, _, _, _) = made.notice, approvalID.isEmpty {
            content.categoryID = NotificationContent.finishedCategory
            content.approvalID = nil
        }
        return Plan(
            fields: PhoneNotice.fields(for: content, serverRef: serverRef, riskyNeedsFaceID: riskyNeedsFaceID),
            serverRef: serverRef, seq: seq)
    }

    /// An event the daemon had to cut down (`payload` only has an id, or is gone): a text for its kind, and the buttons
    /// that still make sense. The app reads the rest from the server when it connects.
    static func shortened(
        kind: String, payload: [String: Any]?, agent: String, name: String, text: String?
    ) -> (notice: AgentNotice, risky: Bool)? {
        switch kind {
        case "approval.requested":
            // No command is left: the notification asks to open the app, and only Deny is offered (when the id is there).
            let id = payload?["approval_id"] as? String ?? ""
            return (.approval(agentID: agent, agentName: name, approvalID: id, title: "", command: nil, reviewOnly: true), false)
        case "form_requested":
            return (.form(agentID: agent, agentName: name, formID: payload?["form_id"] as? String ?? ""), false)
        case "agent.status":
            return (.question(agentID: agent, agentName: name, text: nil), false)
        case "turn.completed":
            return (.finished(agentID: agent, agentName: name, text: text), false)
        case "error":
            return (.failed(agentID: agent, agentName: name, message: payload?["message"] as? String), false)
        default:
            return nil
        }
    }

    /// The category of a push that could not be opened: the generic one, with no buttons.
    static let unopenedCategory = NotificationContent.finishedCategory
}
