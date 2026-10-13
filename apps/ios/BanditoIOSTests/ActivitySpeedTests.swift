import BanditoKit
import Foundation
import SwiftUI
import Testing
import UIKit

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// Work budgets of the Activity screen, counted rather than timed (like the Crew's `CrewSpeedTests`): a reply that streams
/// moves no row of the timeline until it is finished, so 100 pieces make at most two row evaluations, and finishing it
/// adds its one row.
@MainActor
@Suite struct ActivitySpeedTests {
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    @Test func aStreamedReplyMovesNoRowUntilItIsFinished() async {
        let server = await IOSDemo.start(withTeam: false)
        let agent = "ios-speed-activity"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(
                id: agent, name: "Speed", role: "Speed", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: now, updatedAt: now, status: .working),
            items: [.assistant(id: "s1", text: "An earlier reply", ts: now - 60_000)])

        let before = ActivityCounters.rowBodies
        // In the app's own scene, so that the list is laid out and its rows are built (a window outside a scene is not).
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: ActivityScreen(servers: [server]))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await settle()
        // The counter works: the earlier reply's row was evaluated when the screen was built.
        #expect(ActivityCounters.rowBodies - before >= 1, "the screen built \(ActivityCounters.rowBodies - before) rows")

        let streamStart = ActivityCounters.rowBodies
        for piece in 0..<100 {
            server.apply(Event(seq: 0, agentId: agent, ts: now, body: .messageDelta(text: "word\(piece) ")))
        }
        await settle()
        let streamed = ActivityCounters.rowBodies - streamStart
        #expect(streamed <= 2, "the rows were evaluated \(streamed) times for 100 pieces of a reply")

        // The reply is finished: it joins the timeline as one row.
        let finishStart = ActivityCounters.rowBodies
        let seq = server.thread(for: agent).lastSeq + 1
        server.apply(Event(seq: seq, agentId: agent, ts: now, body: .messageAssistant(text: "word0 word1")))
        await settle()
        let finished = ActivityCounters.rowBodies - finishStart
        #expect(finished >= 1, "the finished reply did not reach the timeline")
        #expect(finished <= 3, "the rows were evaluated \(finished) times for one finished reply")

        window.isHidden = true
        await server.disconnect()
    }
}
