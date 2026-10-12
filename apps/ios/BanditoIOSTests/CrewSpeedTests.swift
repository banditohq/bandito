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
    /// Waits until the window has laid out and the streams have landed.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
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
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: CrewScreen(servers: [server], onConnect: {}))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await settle()
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
        await settle()
        let made = CrewCounters.rowBodies - streamStart
        // The stream reached the row (its preview changed), and it did not rebuild it once per piece.
        #expect(made >= 1, "the streamed reply did not reach its row")
        #expect(made <= 2, "the rows were evaluated \(made) times for 100 pieces of one reply")

        window.isHidden = true
        await server.disconnect()
    }
}
