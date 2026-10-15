import BanditoKit
import Foundation
import SwiftUI
import Testing
import UIKit

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// Work budgets of the Crew screen, counted rather than timed (like the Mac's `WorkBudgetTests`): how many times a row
/// is evaluated while a reply streams. A streamed token changes no row's facts except the preview, and the preview is
/// written at most once per interval, so a reply of 100 pieces makes its row once or twice, never once per piece.
@MainActor
@Suite struct CrewSpeedTests {
    /// Steps the run loop until the rows stop being evaluated: `calm` steps in a row in which nothing was counted, in two
    /// passes with a pause between (as the Mac's `WorkBudgetHarness.quiet`). Work the app schedules after a delay lands
    /// inside it, and a slow debug build that is still laying out the screen does not leak its rows into the next count.
    /// The steps are counted, not timed: a fast machine and a slow one count the same.
    private func rest(calm: Int = 25, limit: Int = 600) async {
        for pass in 0..<2 {
            if pass == 1 { try? await Task.sleep(for: .milliseconds(400)) }
            var still = 0
            for _ in 0..<limit {
                let before = CrewCounters.rowBodies
                try? await Task.sleep(for: .milliseconds(10))
                if CrewCounters.rowBodies == before {
                    still += 1
                    if still >= calm { break }
                } else {
                    still = 0
                }
            }
        }
    }

    @Test func aStreamedReplyMakesItsRowAtMostTwice() async {
        let server = await IOSDemo.start()
        // An agent with no message yet: its first streamed piece is written at once, the rest wait for the interval.
        let streamer = "ios-speed-stream"
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(
                id: streamer, name: "Stream", role: "Speed", runtime: .claude, cwd: DemoDaemonFiles.projects,
                createdAt: now, updatedAt: now, status: .working),
            items: [])

        let before = CrewCounters.rowBodies
        // In the app's own scene, so that the list is laid out and its rows are built (a window outside a scene is not).
        // The list is lazy: a row below the fold is not built, so it would not count. The window is tall enough for the
        // whole team (the waiting cards and their line take room above it), so every row is on screen.
        let frame = CGRect(x: 0, y: 0, width: 390, height: 2400)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: frame)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: CrewScreen(servers: [server], settings: IOSSettings(), onConnect: {}, onShowInbox: {}))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        // The screen is built and at rest before the stream starts counting.
        await rest()
        // The counter works: the rows were evaluated when the screen was built.
        #expect(CrewCounters.rowBodies - before >= IOSDemo.team.count + 1, "the screen built \(CrewCounters.rowBodies - before) rows")

        // As the Mac's WorkBudgetTests: the streamed preview's interval is widened for the stream, so the count does not
        // depend on how fast a debug build applies 100 pieces.
        let interval = AgentThreadState.streamPreviewInterval
        AgentThreadState.streamPreviewInterval = .seconds(60)
        defer { AgentThreadState.streamPreviewInterval = interval }

        let streamStart = CrewCounters.rowBodies
        for piece in 0..<100 {
            server.apply(Event(seq: 0, agentId: streamer, ts: now, body: .messageDelta(text: "word\(piece) ")))
        }
        // The pieces reach the row as the run loop takes them in: wait for its first look at them (bounded), then rest.
        var waited = 0
        while CrewCounters.rowBodies == streamStart, waited < 300 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        await rest()
        let made = CrewCounters.rowBodies - streamStart
        // The stream reached the row (its preview changed), and it did not rebuild it once per piece.
        #expect(made >= 1, "the streamed reply did not reach its row")
        #expect(made <= 2, "the rows were evaluated \(made) times for 100 pieces of one reply")

        window.isHidden = true
        await server.disconnect()
    }
}
