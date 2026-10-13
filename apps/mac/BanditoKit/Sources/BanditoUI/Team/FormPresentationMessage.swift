import BanditoKit
import BanditoL10n

extension FormPresentation {
    /// What to say when `forms.answer` fails. A form that is over has its own sentence; the rest go through the
    /// general mapper.
    public static func message(for error: Error) -> UserFacingMessage {
        if let rpc = error as? RPCError {
            switch rpc.message {
            case "already_answered": return UserFacingMessage(text: L10n.Form.alreadyAnswered)
            case "expired": return UserFacingMessage(text: L10n.Form.expiredError)
            default: break
            }
        }
        return UserFacingError.message(for: error)
    }
}
