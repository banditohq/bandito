#if os(macOS)
import BanditoKit
import Foundation
import Testing
import os

@testable import BanditoUI

/// The smoothness check run as a program (`--perf-check`) makes only its demo world: no model of the saved servers,
/// no pairing with this Mac's daemon; its results go to Application Support under the app's own id.
@MainActor
@Suite(.serialized) struct PerfStandaloneTests {
    @Test func theSwitchIsRecognised() {
        #expect(PerfStandalone.isRequested(["Bandito", "--perf-check"]))
        #expect(!PerfStandalone.isRequested(["Bandito"]))
    }

    @Test func theCheckMakesNoSavedServersAndNoPairing() async {
        let heard = OSAllocatedUnfairLock(initialState: [String]())
        // The probe hears a model made here: the check is not blind to it.
        let suite = "perf-standalone-probe-\(UUID().uuidString)"
        LaunchProbe.$record.withValue({ name in heard.withLock { $0.append(name) } }) {
            _ = AppModel(defaults: UserDefaults(suiteName: suite)!)
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        #expect(heard.withLock { $0 } == ["savedServers"])
        heard.withLock { $0.removeAll() }
        let controller = await LaunchProbe.$record.withValue({ name in heard.withLock { $0.append(name) } }) {
            let controller = PerfCheckWindowController()
            // Its window is never shown here (no `showWindow`); off every screen in case anything orders it in.
            controller.window?.alphaValue = 0
            controller.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            await controller.world.start()
            return controller
        }
        #expect(heard.withLock { $0 }.isEmpty)
        // Every server of the world is a demo one: nothing is saved, nothing reaches a daemon.
        let ids = Set(controller.world.app.servers.map(\.id))
        #expect(ids == [PerfDemoWorld.primaryID, PerfDemoWorld.secondaryID])
        controller.window?.close()
        await controller.world.tearDown()
    }

    @Test func resultsGoToApplicationSupportUnderTheAppsID() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "perf-standalone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        let url = PerfStandalone.resultsURL(bundleID: "dev.bandito.mac.perf", date: date, support: support)
        #expect(url.deletingLastPathComponent().lastPathComponent == "dev.bandito.mac.perf")
        #expect(url.lastPathComponent.hasPrefix("perf-check-") && url.pathExtension == "json")
        let saved = try PerfStandalone.save([], fps: 120, to: url)
        let results = try JSONDecoder().decode(PerfStandalone.Results.self, from: Data(contentsOf: saved))
        #expect(results.screenFPS == 120 && results.reports.isEmpty)
    }
}
#endif
