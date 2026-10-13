import BanditoKit
import BanditoL10n
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The Activity timeline: what it lists (quiet runs left out), the filters, the badge, the days, the memory limit.
@MainActor
@Suite struct ActivityTests {
    private let now = Int64(Date().timeIntervalSince1970 * 1000)

    /// A connected server with no agent and one agent (Forge) whose thread holds `items`, all of it read.
    private func makeServer(items: [ThreadItem]) async -> (ServerModel, String) {
        let server = await IOSDemo.start(withTeam: false)
        let id = "activity-test"
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Forge", role: "Builder", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: now, updatedAt: now, status: .idle),
            items: items)
        server.threadSummary(for: id).markRead()
        return (server, id)
    }

    /// A finished reply that arrives after the server was read: an unread reply.
    private func arrive(_ text: String, on server: ServerModel, agent id: String) {
        let seq = server.thread(for: id).lastSeq + 1
        server.apply(Event(seq: seq, agentId: id, ts: now, body: .messageAssistant(text: text)))
    }

    @Test func aQuietRunIsNotListed() async {
        let (server, _) = await makeServer(items: [
            .scheduleRun(id: "s1", run: ScheduleRun(id: "r1", name: "Nightly", firedAt: now), prompt: "Check", ts: now),
            .quietTurn(id: "s2", reason: "nothing_to_report", steps: [], ts: now),
        ])
        #expect(ActivityFacts.days(servers: [server], filter: .all).isEmpty)
        await server.disconnect()
    }

    @Test func aScheduledRunThatSpokeNamesItsSchedule() async {
        let (server, _) = await makeServer(items: [
            .scheduleRun(id: "s1", run: ScheduleRun(id: "r1", name: "Nightly disk check", firedAt: now), prompt: "Check", ts: now - 1000),
            .assistant(id: "s2", text: "The disk is 81% full.", ts: now),
        ])
        let rows = ActivityFacts.days(servers: [server], filter: .all).flatMap(\.rows)
        #expect(rows.count == 1)
        #expect(rows.first?.title == L10n.Ios.Activity.scheduled(name: "Forge", schedule: "Nightly disk check"))
        #expect(rows.first?.line == "The disk is 81% full.")
        await server.disconnect()
    }

    @Test func errorsAreListedOnlyUnderTheErrorsFilter() async {
        let (server, _) = await makeServer(items: [
            .note(id: "s1", text: "The build failed.", kind: .error, ts: now - 1000),
            .assistant(id: "s2", text: "Fine now.", ts: now),
        ])
        #expect(ActivityFacts.days(servers: [server], filter: .all).flatMap(\.rows).count == 2)
        let errors = ActivityFacts.days(servers: [server], filter: .errors).flatMap(\.rows)
        #expect(errors.map(\.line) == ["The build failed."])
        #expect(errors.first?.title == L10n.Ios.Activity.failed(name: "Forge"))
        #expect(errors.first?.mood == .error)
        await server.disconnect()
    }

    @Test func aCreationIsListedAndAHandOffIsNot() async {
        let (server, _) = await makeServer(items: [
            .note(id: "s1", text: "Forge created Scout", kind: .crew, ts: now - 1000),
            .note(id: "s2-n", text: "Message from Forge", kind: .crew, ts: now - 500),
            .user(id: "s2", text: "Hand-off text", source: .crew, from: "Forge", ts: now),
        ])
        let rows = ActivityFacts.days(servers: [server], filter: .all).flatMap(\.rows)
        #expect(rows.map(\.title) == ["Forge created Scout"])
        #expect(rows.first?.line == nil)
        await server.disconnect()
    }

    @Test func theBadgeAndTheUnreadFilterCountTheRepliesNotRead() async {
        let (server, id) = await makeServer(items: [.assistant(id: "s1", text: "Read already", ts: now - 2000)])
        #expect(ActivityFacts.unreadCount(servers: [server]) == 0)

        arrive("New reply", on: server, agent: id)
        #expect(ActivityFacts.unreadCount(servers: [server]) == 1)
        let unread = ActivityFacts.days(servers: [server], filter: .unread).flatMap(\.rows)
        #expect(unread.map(\.line) == ["New reply"])

        // Opening the chat reads it: the badge and the filter let it go.
        server.threadSummary(for: id).markRead()
        #expect(ActivityFacts.unreadCount(servers: [server]) == 0)
        #expect(ActivityFacts.days(servers: [server], filter: .unread).isEmpty)
        await server.disconnect()
    }

    @Test func theTimelineIsGroupedByDayNewestFirst() async {
        let calendar = Calendar.current
        let day = { (back: Int) -> Int64 in
            let date = calendar.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        let (server, _) = await makeServer(items: [
            .assistant(id: "s1", text: "Long ago", ts: day(40)),
            .assistant(id: "s2", text: "Yesterday", ts: day(1)),
            .assistant(id: "s3", text: "Today", ts: now),
        ])
        let days = ActivityFacts.days(servers: [server], filter: .all)
        #expect(days.count == 3)
        #expect(days.map { $0.rows.first?.line } == ["Today", "Yesterday", "Long ago"])
        #expect(ActivityGrouping.title(of: days[0].day) == L10n.Thread.today)
        #expect(ActivityGrouping.title(of: days[1].day) == L10n.Thread.yesterday)
        await server.disconnect()
    }

    @Test func theMemoryHoldsTheNewest500Entries() async {
        let items: [ThreadItem] = (1...600).map { index in
            .assistant(id: "s\(index)", text: "Reply \(index)", ts: now - Int64(600 - index) * 1000)
        }
        let (server, _) = await makeServer(items: items)
        let rows = ActivityFacts.days(servers: [server], filter: .all).flatMap(\.rows)
        #expect(rows.count == ActivityFacts.memoryLimit)
        #expect(rows.first?.line == "Reply 600")
        await server.disconnect()
    }

    @Test func aRowRoutesToItsAgentAndEvent() async {
        let (server, _) = await makeServer(items: [.assistant(id: "s1", text: "Mine", ts: now)])
        let row = ActivityFacts.days(servers: [server], filter: .all).flatMap(\.rows).first
        #expect(row?.route.agentID == "activity-test")
        #expect(row?.route.eventID == "s1")
        #expect(row?.route.serverID == server.id)
        await server.disconnect()
    }
}
