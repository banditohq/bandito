import Foundation

/// When the app asks to show notifications: not up front, but at the first moment the person has a reason, the first
/// time an agent waits for an approval or finishes a turn ("Want to know when Forge needs you?"). The question is asked
/// once; the system's own question follows only after a "Yes".
public enum NotificationAsk {
    /// Set once the question was answered, or the system had been asked before.
    public static let askedKey = "notify.asked"

    /// Whether `notice` is a reason to ask: an approval, a form or a question that waits for the person, or a finished
    /// turn. A failure or a failed answer is not (it says nothing about what the person wants to hear).
    public static func isReason(_ notice: AgentNotice) -> Bool {
        switch notice {
        case .approval, .form, .question, .finished: true
        case .failed, .resolveFailed: false
        }
    }

    /// The agent the question is about, by name.
    public static func agentName(_ notice: AgentNotice) -> String? {
        switch notice {
        case .approval(_, let name, _, _, _, _), .finished(_, let name, _): name
        case .form(_, let name, _), .question(_, let name, _): name
        case .failed, .resolveFailed: nil
        }
    }

    /// The question is asked when nothing asked it before, the system has not been asked either, and the notice is a reason.
    public static func shouldAsk(notice: AgentNotice, asked: Bool, systemUndetermined: Bool) -> Bool {
        !asked && systemUndetermined && isReason(notice)
    }
}
