import BanditoKit
import Foundation
import SwiftUI
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// A fake owner check for the Face ID rule: it counts the questions, and answers as it is told.
@MainActor
final class FakeAuthenticator: BiometricAuthenticating {
    var isAvailable: Bool
    var passes: Bool
    private(set) var asked = 0

    init(available: Bool = true, passes: Bool = true) {
        isAvailable = available
        self.passes = passes
    }

    func authenticate(reason: String) async -> Bool {
        asked += 1
        return passes
    }
}

/// The rules of the Inbox: what it collects, how it sorts and groups it, its badge, and the Face ID rule for risky
/// approvals. The demo team waits for: two approvals of Forge (one risky), a form of Quill, a question of Watch.
@MainActor
@Suite struct InboxRulesTests {
    private let now = Int64(Date().timeIntervalSince1970 * 1000)

    private func agentLook() -> CrewLook {
        CrewLook(color: .peach, face: .sleeping, customHex: nil)
    }

    private func item(_ id: String, server: UUID, name: String, ts: Int64, kind: InboxItem.Kind) -> InboxItem {
        InboxItem(
            id: id, serverID: server, serverName: name, agentID: "agent-\(id)", agentName: "Agent", look: agentLook(),
            mood: .idle, kind: kind, ts: ts)
    }

    private func approval(_ id: String, reason: String) -> ApprovalRow {
        ApprovalRow(
            approvalId: id, tool: "bash", title: "cmd \(id)", command: "cmd \(id)", diff: nil, reason: reason,
            state: .pending, ts: 1)
    }

    @Test func theDemoTeamWaitsForFourThings() async {
        let server = await IOSDemo.start()
        let items = InboxRules.items(in: [server])
        #expect(items.count == 4)
        #expect(InboxRules.badge(of: [server]) == 4)
        #expect(items.contains { $0.id == "approval-ios-demo-approval-1" })
        #expect(items.contains { $0.id == "approval-ios-demo-approval-2" })
        #expect(items.contains { if case .form = $0.kind { true } else { false } })
        #expect(items.contains { if case .question(_, let buttons) = $0.kind { buttons.count == 2 } else { false } })
        await server.disconnect()
    }

    @Test func onlyTheRiskyApprovalIsRisky() async {
        let server = await IOSDemo.start()
        let items = InboxRules.items(in: [server])
        #expect(items.filter(\.isRisky).map(\.id) == ["approval-ios-demo-approval-1"])
        await server.disconnect()
    }

    @Test func newestComesFirstAcrossServers() async {
        let server = await IOSDemo.start()
        let office = await IOSDemo.startOffice()
        // An older approval on the office server: it sorts after everything of the demo server.
        let agent = "office-agent"
        office.installSyntheticAgent(
            Agent(
                id: agent, name: "Office", role: "Ops", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: now, updatedAt: now, status: .needsYou),
            items: [])
        office.apply(
            Event(
                seq: 1, agentId: agent, ts: now - 3_600_000,
                body: .approvalRequested(
                    approvalId: "office-1", callId: "c", tool: "bash", title: "df -h", command: "df -h", diff: nil,
                    reason: "approval required for every action")))

        let items = InboxRules.items(in: [server, office])
        #expect(items.count == 5)
        #expect(items.last?.id == "approval-office-1")
        #expect(zip(items, items.dropFirst()).allSatisfy { $0.ts >= $1.ts })
        #expect(InboxRules.badge(of: [server, office]) == 5)

        // Disconnected servers list nothing: their answers could not be sent.
        await office.disconnect()
        #expect(InboxRules.items(in: [server, office]).count == 4)
        await server.disconnect()
    }

    @Test func groupsByServerOnlyWhenThereIsMoreThanOne() {
        let first = UUID()
        let second = UUID()
        let items = [
            item("a", server: second, name: "Office", ts: 30, kind: .question(text: nil, buttons: [])),
            item("b", server: first, name: "Demo", ts: 20, kind: .question(text: nil, buttons: [])),
            item("c", server: second, name: "Office", ts: 10, kind: .question(text: nil, buttons: [])),
        ]
        let grouped = InboxRules.sections(items, servers: [first, second], grouped: true)
        #expect(grouped.map(\.title) == ["Demo", "Office"])
        #expect(grouped.map { $0.items.map(\.id) } == [["b"], ["a", "c"]])

        let flat = InboxRules.sections(items, servers: [first, second], grouped: false)
        #expect(flat.count == 1)
        #expect(flat.first?.title == nil)
        #expect(flat.first?.items.map(\.id) == ["a", "b", "c"])
        #expect(InboxRules.sections([], servers: [first], grouped: false).isEmpty)
    }

    @Test func aRiskyApprovalNeedsFaceIDOnlyWhenTheSettingAsksForIt() {
        let risky = item(
            "r", server: UUID(), name: "Demo", ts: 1,
            kind: .approval(approval("r", reason: "risky: git push")))
        let ordinary = item(
            "o", server: UUID(), name: "Demo", ts: 1,
            kind: .approval(approval("o", reason: "approval required for every action")))
        #expect(InboxAnswer.needsFaceID(risky, riskyNeedsFaceID: true))
        #expect(!InboxAnswer.needsFaceID(risky, riskyNeedsFaceID: false))
        #expect(!InboxAnswer.needsFaceID(ordinary, riskyNeedsFaceID: true))
        #expect(risky.canAllow, "a risky approval is allowed from its sheet")
    }

    @Test func aRiskyAllowIsNotSentWithoutTheOwnersCheck() async {
        let server = await IOSDemo.start()
        let forge = server.sortedAgents.first { $0.name == "Forge" }!.id
        let risky = InboxRules.items(in: [server]).first { $0.id == "approval-ios-demo-approval-1" }!
        let failing = FakeAuthenticator(passes: false)
        let outcome = try? await InboxAnswer.allow(
            risky, server: server, remember: false, riskyNeedsFaceID: true, authenticator: failing, reason: "x")
        #expect(outcome == .notConfirmed)
        #expect(failing.asked == 1)
        #expect(server.threadSummary(for: forge).pendingApprovalRows.contains { $0.approvalId == "ios-demo-approval-1" })

        let absent = FakeAuthenticator(available: false, passes: true)
        let cannot = try? await InboxAnswer.allow(
            risky, server: server, remember: false, riskyNeedsFaceID: true, authenticator: absent, reason: "x")
        #expect(cannot == .cannotConfirm)
        #expect(absent.asked == 0)
        #expect(server.threadSummary(for: forge).pendingApprovalRows.contains { $0.approvalId == "ios-demo-approval-1" })
        await server.disconnect()
    }

    @Test func aConfirmedRiskyAllowReachesTheDaemonAndLeavesTheList() async {
        let server = await IOSDemo.start()
        let forge = server.sortedAgents.first { $0.name == "Forge" }!.id
        let risky = InboxRules.items(in: [server]).first { $0.id == "approval-ios-demo-approval-1" }!
        let passing = FakeAuthenticator(passes: true)
        let outcome = try? await InboxAnswer.allow(
            risky, server: server, remember: false, riskyNeedsFaceID: true, authenticator: passing, reason: "x")
        #expect(outcome == .sent)
        #expect(passing.asked == 1)
        // The demo daemon answers the approval and its event comes back: the thread no longer waits for it.
        await waitUntil { !server.threadSummary(for: forge).pendingApprovalRows.contains { $0.approvalId == "ios-demo-approval-1" } }
        #expect(!server.threadSummary(for: forge).pendingApprovalRows.contains { $0.approvalId == "ios-demo-approval-1" })
        await server.disconnect()
    }

    @Test func anOrdinaryAllowNeedsNoCheck() async {
        let server = await IOSDemo.start()
        let ordinary = InboxRules.items(in: [server]).first { $0.id == "approval-ios-demo-approval-2" }!
        let check = FakeAuthenticator(passes: false)
        let outcome = try? await InboxAnswer.allow(
            ordinary, server: server, remember: true, riskyNeedsFaceID: true, authenticator: check, reason: "x")
        #expect(outcome == .sent)
        #expect(check.asked == 0)
        await server.disconnect()
    }

    /// Waits (a few seconds at most) until the condition holds: the demo daemon answers on its own queue.
    /// A notice pressed on a cold start names an item the list does not have yet: the focus waits for it.
    @Test func aFocusWaitsForItsItemToBeListed() {
        let server = UUID()
        let listed = item("approval-ap1", server: server, name: "Mac", ts: 1, kind: .approval(approval("ap1", reason: "")))
        #expect(InboxRules.focusedItem("approval-ap1", in: []) == nil)
        #expect(InboxRules.focusedItem("approval-ap1", in: [listed]) == listed)
        #expect(InboxRules.focusedItem("approval-other", in: [listed]) == nil)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<60 where !condition() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
