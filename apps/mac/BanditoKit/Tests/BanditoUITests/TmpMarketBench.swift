#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import Testing

@testable import BanditoUI

/// Temporary: times the Marketplace's page changes on the host (deleted after use).
@MainActor @Suite(.serialized) struct TmpMarketBench {
    private func pump(_ hosting: NSView, _ seconds: Double = 0.02) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }

    private func timed(_ label: String, _ hosting: NSView, _ change: () -> Void) -> Double {
        pump(hosting, 0.05)
        let start = CACurrentMediaTime()
        change()
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let ms = (CACurrentMediaTime() - start) * 1000
        print("BENCH \(label) \(String(format: "%.1f", ms)) ms")
        return ms
    }

    @Test func marketPages() async throws {
        let world = PerfDemoWorld()
        await world.start()
        let root = MainWindow()
            .font(BanditoFont.text(size: 13))
            .environment(world.app)
            .environment(world.router)
            .environment(world.keymap)
            .environment(world.gestures)
            .environment(world.demoStore)
            .environment(world.onboarding)
            .environment(world.hub)
            .environment(world.telemetry)
            .environment(world.updates)
            .environment(\.focusMode, world.focusMode)
            .environment(\.scenarioRequests, world.requests)
            .environment(\.settingsNavigation, world.settingsNavigation)
            .windowRoot(minWidth: 900, minHeight: 600)
            .preferredColorScheme(.dark)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: root)
        window.contentView = hosting
        window.orderFrontRegardless()
        world.router.select(mode: .market)
        world.router.marketTab = .services
        for _ in 0..<300 where world.router.marketCategories.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
            pump(hosting, 0.001)
        }
        try await Task.sleep(for: .milliseconds(500))
        pump(hosting, 0.1)
        let categories = Array(world.router.marketCategories.prefix(3))
        print("BENCH categories \(categories)")
        for exp in [[], []] as [Set<Int>] {
        world.router.marketTab = .bots
        pump(hosting, 0.2)
        world.router.marketTab = .services
        pump(hosting, 0.3)
        var open = 0.0
        var back = 0.0
        for name in categories {
            open += timed("open \(name)", hosting) { world.router.marketFilter = .category(name) }
            back += timed("back", hosting) { world.router.marketFilter = .all }
        }
        print("BENCHX exp \(exp.sorted()) open \(Int(open / 3)) back \(Int(back / 3))")
        }
        if let field = PerfScroller.textField(in: window, placeholder: L10n.Market.search) {
            window.makeFirstResponder(field)
            pump(hosting, 0.1)
            if let editor = window.firstResponder as? NSTextView {
                var typed = 0.0
                for character in "linear" {
                    typed += timed("letter", hosting) {
                        editor.insertText(String(character), replacementRange: editor.selectedRange())
                    }
                }
                print("BENCHX letter \(Int(typed / 6))")
                _ = timed("clear", hosting) {
                    editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                }
            }
        }
        for round in 0..<3 {
            for mode in [AppMode.team, .screen, .files, .screen, .terminals, .browser, .screen, .market, .server, .screen] {
                _ = timed("mode \(mode) \(round)", hosting) { world.router.select(mode: mode) }
            }
        }
        world.router.select(mode: .team)
        pump(hosting, 0.3)
        if ProcessInfo.processInfo.environment["BENCH_LOOP"] != nil {
            let end = Date().addingTimeInterval(14)
            var i = 0
            while Date() < end {
                world.router.selectedAgentID = world.agentIDs[i % 40]
                hosting.layoutSubtreeIfNeeded()
                pump(hosting, 0.001)
                i += 1
            }
            print("BENCHX loop \(i) switches")
        }
        for exp in [[], []] as [Set<Int>] {
            ThreadExp.on = exp
            var total = 0.0
            for id in world.agentIDs.prefix(16) {
                total += timed("agent", hosting) { world.router.selectedAgentID = id }
            }
            print("BENCHX agents exp \(exp.sorted()) \(Int(total / 16))")
        }
        world.router.select(mode: .market)
        pump(hosting, 0.3)
        _ = timed("bots", hosting) { world.router.marketTab = .bots }
        _ = timed("skills", hosting) { world.router.marketTab = .skills }
        _ = timed("services", hosting) { world.router.marketTab = .services }
        _ = timed("team", hosting) { world.router.select(mode: .team) }
        _ = timed("market", hosting) { world.router.select(mode: .market) }
        window.orderOut(nil)
        await world.tearDown()
    }
}
#endif
