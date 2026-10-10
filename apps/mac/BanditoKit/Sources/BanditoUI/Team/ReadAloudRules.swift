import BanditoKit
import Foundation

/// Which reply a turn that just ended reads aloud. Pure.
enum ReadAloudRules {
    /// The last agent reply after the last message of the person. Nil when the turn ended without a reply (its last
    /// reply is older than the person's message), so an old answer is never read again.
    static func lastReply(in items: [ThreadItem]) -> (id: String, text: String)? {
        for item in items.reversed() {
            switch item {
            case .assistant(let id, let text, _):
                return (id, text)
            case .user:
                return nil
            default:
                continue
            }
        }
        return nil
    }
}
