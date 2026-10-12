import BanditoKit
import Foundation
import SwiftUI
import Testing
import UIKit

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// Work budget of the Inbox, counted rather than timed (like `CrewSpeedTests`): a streamed reply in the chat of an agent
/// that waits for the person rebuilds its own row at most twice, and no other row is built again.
@MainActor
@Suite struct InboxSpeedTests {
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
    }

    @Test func aStreamedReplyRebuildsItsOwnRowAtMostTwice() async {
        let server = await IOSDemo.start()
        let watch = server.sortedAgents.first { $0.name == "Watch" }!.id
        let settings = IOSSettings(defaults: UserDefaults(suiteName: "inbox-speed-tests")!)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: InboxScreen(servers: [server], settings: settings))
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        await settle()
        #expect(InboxCounters.rowBodies >= InboxRules.items(in: [server]).count, "the list built its rows")

        // The interval of the streamed preview is widened for the stream: the count does not depend on the device's speed.
        let interval = AgentThreadState.streamPreviewInterval
        AgentThreadState.streamPreviewInterval = .seconds(60)
        defer { AgentThreadState.streamPreviewInterval = interval }

        let before = InboxCounters.rowBodies
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for piece in 0..<100 {
            server.apply(Event(seq: 0, agentId: watch, ts: now, body: .messageDelta(text: "word\(piece) ")))
        }
        await settle()
        let built = InboxCounters.rowBodies - before
        #expect(built <= 2, "the rows were built \(built) times for 100 pieces of one reply")

        window.isHidden = true
        await server.disconnect()
    }
}
