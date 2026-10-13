import Foundation
import UIKit

/// Which chat the person is looking at. A notification for that agent is not shown (the reply is on the screen), and a
/// notice is not raised for a chat that is open.
@MainActor
final class ChatPresence {
    static let shared = ChatPresence()

    private(set) var open: Set<String> = []

    private static func key(_ serverID: UUID, _ agentID: String) -> String { "\(serverID.uuidString)/\(agentID)" }

    func enter(serverID: UUID, agentID: String) {
        open.insert(Self.key(serverID, agentID))
    }

    func leave(serverID: UUID, agentID: String) {
        open.remove(Self.key(serverID, agentID))
    }

    /// The chat is open and the app is in front: with the app in the background the person is not looking at it.
    func isViewing(serverID: UUID, agentID: String, appIsActive: Bool = UIApplication.shared.applicationState == .active) -> Bool {
        appIsActive && open.contains(Self.key(serverID, agentID))
    }
}
