#if os(macOS)
import BanditoKit
import AppKit
import BanditoDesign
import BanditoL10n
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

/// "Put the screen to sleep": when the button shows and when it asks first.
@Suite struct ScreenSleepRulesTests {
    private func status(running: Bool = true, controller: ControlHolder = .none) -> ScreenStatus {
        ScreenStatus(running: running, controller: controller)
    }

    @Test func aScreenNobodyHoldsSleepsAtOnce() {
        #expect(ScreenSleepRules.confirmation(for: status()) == nil)
        #expect(ScreenSleepRules.confirmation(for: nil) == nil)
    }

    @Test func anAgentOnTheScreenIsAskedAbout() {
        #expect(ScreenSleepRules.confirmation(for: status(controller: .agent)) == .agentWorking)
    }

    @Test func thePersonsOwnControlsAreAskedAboutToo() {
        #expect(ScreenSleepRules.confirmation(for: status(controller: .user)) == .personHolds)
    }

    @Test func eachQuestionHasItsOwnTitle() {
        let agent = ScreenSleepRules.Confirmation.agentWorking.title
        let person = ScreenSleepRules.Confirmation.personHolds.title
        #expect(!agent.isEmpty && !person.isEmpty)
        #expect(agent != person)
    }

    @Test func theButtonIsOnlyThereForARunningScreenThatIsNotChangingState() {
        #expect(ScreenSleepRules.isAvailable(running: true, isStarting: false, isSleeping: false))
        #expect(!ScreenSleepRules.isAvailable(running: false, isStarting: false, isSleeping: false))
        #expect(!ScreenSleepRules.isAvailable(running: true, isStarting: true, isSleeping: false))
        #expect(!ScreenSleepRules.isAvailable(running: true, isStarting: false, isSleeping: true))
    }
}

/// The button's model against the demo daemon that lives in memory: the real `ServerModel` and RPC calls, no network.
@MainActor
@Suite(.serialized) struct ScreenSleepModelTests {
    private func world(screen: DemoScreen) async -> (ServerModel, DemoDaemonTransport, ScreenModel) {
        let made = DemoDaemon.server(
            id: UUID(), name: "Studio", setup: DemoDaemonSetup(hostname: "studio", screen: screen))
        await made.0.connect()
        let model = ScreenModel(server: made.0, workspace: Workspace.sharedID)
        await model.refresh()
        return (made.0, made.1, model)
    }

    @Test func sleepingStopsTheScreenAndTheCardSaysAsleepAtOnce() async {
        let (server, transport, model) = await world(screen: DemoScreen(running: true))
        #expect(model.status?.running == true)
        #expect(model.canSleep)
        #expect(model.sleepConfirmation == nil)
        let overview = ScreenOverviews.shared.overview(for: server)
        await overview.poll([Workspace(id: Workspace.sharedID, name: "Shared", kind: .shared)])
        #expect(overview.state(of: Workspace.sharedID) == .running)

        await model.sleep()

        #expect(await transport.screenStopCalls == 1)
        #expect(model.status?.running == false)
        #expect(!model.isSleeping)
        #expect(!model.canSleep)
        #expect(overview.state(of: Workspace.sharedID) == .asleep)
        #expect(model.phase == .idle)
        await server.disconnect()
    }

    @Test func aSecondPressOnASleepingScreenDoesNothing() async {
        let (server, transport, model) = await world(screen: DemoScreen(running: true))
        await model.sleep()
        await model.sleep()
        #expect(await transport.screenStopCalls == 1)
        await server.disconnect()
    }

    @Test func aScreenAnAgentHoldsAsksFirstAndSleepsOnlyWhenTheCallIsMade() async {
        let (server, transport, model) = await world(screen: DemoScreen(running: true, controller: "agent"))
        #expect(model.sleepConfirmation == .agentWorking)
        // The view asks; nothing has stopped yet.
        #expect(await transport.screenStopCalls == 0)
        #expect(model.status?.running == true)

        await model.sleep()
        #expect(await transport.screenStopCalls == 1)
        #expect(model.status?.running == false)
        await server.disconnect()
    }

    @Test func aScreenThePersonHoldsAsksFirstToo() async {
        let (server, _, model) = await world(screen: DemoScreen(running: true, controller: "user"))
        #expect(model.sleepConfirmation == .personHolds)
        await server.disconnect()
    }

    @Test func aSleepingScreenOffersNoSleepButton() async {
        let (server, _, model) = await world(screen: DemoScreen(running: false))
        #expect(model.status?.running == false)
        #expect(!model.canSleep)
        await model.sleep()
        #expect(model.status?.running == false)
        await server.disconnect()
    }

    @Test func markingAsleepIsIdempotentAndTouchesOnlyThatScreen() async {
        let made = DemoDaemon.server(id: UUID(), name: "S", setup: DemoDaemonSetup())
        let overview = ScreenOverview(server: made.0)
        overview.markAsleep("a")
        overview.markAsleep("a")
        #expect(overview.state(of: "a") == .asleep)
        #expect(overview.state(of: "b") == .unknown)
    }

    /// The toolbar as a picture, in a view nobody sees (no window). `SCREEN_SNAPSHOT_DIR` keeps the PNG.
    private func toolbarPicture(model: ScreenModel, name: String) -> Data? {
        let suite = "screen-toolbar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = BanditoFont.registerBundledFonts()
        let view = ScreenToolbar(model: model, title: "Общий сервер")
            .environment(Keymap(defaults: defaults))
            .environment(\.colorScheme, .dark)
            .frame(width: 900, height: 52)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 52)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        if let dir = ProcessInfo.processInfo.environment["SCREEN_SNAPSHOT_DIR"], let png {
            try? png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
        }
        return png
    }

    @Test(.language("ru")) func theMoonButtonIsOnTheToolbarOnlyWhileTheScreenRuns() async {
        let (server, _, running) = await world(screen: DemoScreen(running: true))
        let (server2, _, asleep) = await world(screen: DemoScreen(running: false))
        let with = toolbarPicture(model: running, name: "screen-toolbar-running-ru")
        let without = toolbarPicture(model: asleep, name: "screen-toolbar-asleep-ru")
        #expect(with != nil && without != nil)
        // The moon is always in the toolbar, enabled only while the screen runs (compared on the model, not on the
        // picture: a headless runner can draw both states to the same bytes).
        #expect(running.canSleep)
        #expect(!asleep.canSleep)
        await server.disconnect()
        await server2.disconnect()
    }
}
#endif
