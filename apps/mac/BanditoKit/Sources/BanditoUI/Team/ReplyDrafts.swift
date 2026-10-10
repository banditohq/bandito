import BanditoKit
import Foundation
import Observation

/// The message each agent's composer is answering, if any. Kept apart from the thread view so that a reply that was
/// started stays with its agent when the person goes to another agent and back.
@MainActor
@Observable
final class ReplyDrafts {
    static let shared = ReplyDrafts()

    private(set) var targets: [String: ReplyTarget] = [:]

    init() {}

    func target(for agentID: String) -> ReplyTarget? { targets[agentID] }

    /// Answer `target` next (or nothing, with nil).
    func set(_ target: ReplyTarget?, for agentID: String) {
        targets[agentID] = target
    }

    /// The reply of an agent, for sending; it is cleared.
    func take(for agentID: String) -> ReplyTarget? {
        defer { targets[agentID] = nil }
        return targets[agentID]
    }

    /// Puts back a reply whose message could not be sent, unless the person has chosen another one meanwhile.
    func restore(_ target: ReplyTarget?, for agentID: String) {
        guard let target, targets[agentID] == nil else { return }
        targets[agentID] = target
    }
}
