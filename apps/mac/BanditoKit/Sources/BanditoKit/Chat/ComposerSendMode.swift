import Foundation

/// What the round button of the message box does. While a turn runs, a message with text or files is sent: the daemon
/// queues it behind the turn, as on the iPhone. The button stops the turn only when the field is empty. When the agent
/// waits on a form and the person has typed a message without files, that message answers the form (`forms.answer`,
/// action `reply`) instead of joining the queue.
public enum ComposerSendMode: Equatable {
    case send
    case stop
    /// Answer the form with this id by the typed message.
    case replyToForm(String)

    /// - Parameters:
    ///   - running: a turn is running.
    ///   - hasText: the field holds a message (not blank, not a slash command).
    ///   - hasFiles: files wait in the tray; a reply carries text only, so they keep the usual queue.
    ///   - waitingFormId: the form to answer, `nil` when none waits or the daemon cannot take a reply.
    public static func resolve(running: Bool, hasText: Bool, hasFiles: Bool, waitingFormId: String?) -> ComposerSendMode {
        guard running else { return .send }
        if let waitingFormId, hasText, !hasFiles { return .replyToForm(waitingFormId) }
        if hasText || hasFiles { return .send }
        return .stop
    }

    /// The form a reply goes to: the last that still waits (the newest question the agent is blocked on). `nil` when
    /// the daemon does not list `form_reply`: the old behaviour stays.
    public static func formToAnswer(in pending: [FormRow], supportsReply: Bool) -> String? {
        supportsReply ? pending.last?.formId : nil
    }
}
