import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The Dock icon follows the unread counts of the connected servers: written when the label changes, not on a token.
@MainActor
@Suite(.serialized) struct DockBadgeObservationTests {
    private final class Written {
        var labels: [String?] = []
    }

    /// The total the rule takes: the connected servers' agents' counts.
    private func total(_ world: PerfDemoWorld) -> Int {
        DockBadgeRules.total(
            world.app.servers.filter { $0.state == .connected }.flatMap { server in
                server.agents.map { server.threadSummary(for: $0.id).unreadCount }
            })
    }

    /// Waits until the icon was given `label` last (the watch reads on the next main-actor turn).
    private func settle(_ written: Written, on label: String?) async throws {
        for _ in 0..<300 where written.labels.last != label {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(written.labels.last == label)
    }

    @Test func theIconFollowsTheCountAndIsWrittenOnlyWhenTheLabelChanges() async throws {
        let world = PerfDemoWorld()
        await world.start()
        let agent = world.agentIDs[0]
        let written = Written()
        let badge = DockBadge(app: world.app, defaults: world.defaults, write: { written.labels.append($0) })
        badge.start()

        // A reply that comes in: the icon takes the new total.
        let base = total(world)
        let next = { (world.primary.thread(for: agent).lastSeq) + 1 }
        world.primary.apply(Event(seq: next(), agentId: agent, ts: 1_791_530_000_000, body: .messageAssistant(text: "one")))
        try await settle(written, on: DockBadgeRules.label(total: base + 1, enabled: true))
        let countAfterReply = written.labels.count

        // A streamed token changes no count: nothing is written.
        world.primary.apply(Event(seq: 0, agentId: agent, ts: 1_791_530_000_001, body: .messageDelta(text: "tw")))
        try await Task.sleep(for: .milliseconds(150))
        #expect(written.labels.count == countAfterReply)

        // Another reply, then the chat is looked at: the icon follows each change.
        world.primary.apply(Event(seq: next(), agentId: agent, ts: 1_791_530_000_002, body: .messageAssistant(text: "two")))
        try await settle(written, on: DockBadgeRules.label(total: base + 2, enabled: true))
        world.primary.threadSummary(for: agent).markRead()
        // The agent's whole count is read now (what was unread before the replies too).
        try await settle(written, on: DockBadgeRules.label(total: total(world), enabled: true))
        #expect(total(world) < base + 2)
    }
}
