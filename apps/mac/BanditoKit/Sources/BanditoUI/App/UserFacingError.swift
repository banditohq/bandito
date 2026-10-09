import BanditoKit
import BanditoL10n

/// A failure as the interface shows it: one sentence, the technical text for "Подробнее" (only when the
/// sentence does not say everything), and whether a retry makes sense (only for a server that does not answer).
public struct UserFacingMessage: Equatable, Sendable {
    public var text: String
    public var technical: String?
    public var canRetry: Bool

    public init(text: String, technical: String? = nil, canRetry: Bool = false) {
        self.text = text
        self.technical = technical
        self.canRetry = canRetry
    }

    /// The same message inside a longer sentence ("Upload of a.txt failed: …"). The technical text and the retry stay.
    public func wrapped(_ sentence: (String) -> String) -> UserFacingMessage {
        UserFacingMessage(text: sentence(text), technical: technical, canRetry: canRetry)
    }
}

/// The one mapper from a failure to words. Views never show `localizedDescription` or a raw error:
/// they take a `UserFacingMessage` from here and render it with `UserFacingErrorView`.
public enum UserFacingError {
    public static func message(for error: Error) -> UserFacingMessage {
        message(for: FailureKind.classify(error))
    }

    public static func message(for kind: FailureKind) -> UserFacingMessage {
        switch kind {
        case .noAnswer:
            UserFacingMessage(text: L10n.Failure.noAnswer, canRetry: true)
        case .deviceRevoked:
            UserFacingMessage(text: L10n.Failure.deviceRevoked)
        case .reason(let reason):
            if let text = reasonText(reason) {
                UserFacingMessage(text: text)
            } else {
                UserFacingMessage(text: L10n.Failure.generic, technical: "reason: \(reason)")
            }
        case .other(let technical):
            UserFacingMessage(text: L10n.Failure.generic, technical: technical)
        }
    }

    /// Short sentences for the daemon's reasons (`data.reason`, or the word before the colon in a message).
    /// A reason not listed here is shown as the generic failure, with the reason under "Подробнее".
    static func reasonText(_ reason: String) -> String? {
        switch reason {
        case "not_found": L10n.Failure.Reason.notFound
        case "forbidden": L10n.Failure.Reason.forbidden
        case "conflict": L10n.Failure.Reason.conflict
        case "exists": L10n.Failure.Reason.exists
        case "not_empty": L10n.Failure.Reason.notEmpty
        case "too_large": L10n.Failure.Reason.tooLarge
        case "binary": L10n.Failure.Reason.binary
        case "io": L10n.Failure.Reason.io
        case "unsupported": L10n.Failure.Reason.unsupported
        case "clone_failed": L10n.Failure.Reason.cloneFailed
        case "decode_failed": L10n.Failure.Reason.decodeFailed
        default: nil
        }
    }
}
