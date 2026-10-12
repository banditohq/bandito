#if os(macOS)
import Testing

/// The tests that draw thread rows or the main window: they run one after the other. `PerfCounters` are global, and a
/// screen drawn by another test at the same time would count in a budget (`WorkBudgetTests`).
@Suite(.serialized) struct ScreenWorkSuites {}
#endif

#if os(macOS) && DEBUG
import AppKit
import BanditoDesign
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// The main window on the demo world (`PerfDemoWorld`), in a window nobody sees: borderless, off every screen,
/// see-through, deaf to the pointer, never ordered in. Steps are driven by hand (the run loop for a moment, then a
/// layout and a display), so a count depends on what the app builds, not on time.
@MainActor
final class WorkBudgetHarness {
    let world = PerfDemoWorld()
    let window: NSWindow
    let host: NSView

    init(width: CGFloat = 1240, height: CGFloat = 800) {
        window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let world = world
        let root = MainWindow()
            .windowRoot(minWidth: 900, minHeight: 600)
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
            .preferredColorScheme(.dark)
        host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = host
    }

    var router: Router { world.router }

    func start() async {
        _ = BanditoFont.registerBundledFonts()
        await world.start()
        await settle(rounds: 40)
    }

    func stop() async {
        window.contentView = nil
        await world.tearDown()
    }

    /// Lets the app take in a change: async work runs, the views update, lay out and draw. `rounds` steps.
    func settle(rounds: Int = 12) async {
        for _ in 0..<rounds {
            await Task.yield()
            step()
        }
    }

    /// One turn of the run loop, then a layout and a display.
    private func step() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    /// Waits until the window is at rest: `calm` steps in a row in which nothing was counted (no body, no cell), up to
    /// `limit` steps. A slow machine (a CI runner) finishes the last step's work later (a scroll's deferred report, the
    /// demo world's replies): without this, that work was counted in the next step.
    func quiet(calm: Int = 25, limit: Int = 600) async {
        let wasCounting = PerfCounters.counting
        PerfCounters.counting = true
        defer { PerfCounters.counting = wasCounting }
        let before = PerfCounters.snapshot()
        await rest(calm: calm, limit: limit)
        // What came while waiting was not part of a step: put the counts back as they were.
        PerfCounters.reset()
        for (name, value) in before { for _ in 0..<value { PerfCounters.hit(name) } }
    }

    /// Steps until `calm` steps in a row count nothing, twice, with a wait between: work the app schedules after a
    /// delay (a 0.3 s debounce) comes inside it. The counts grow meanwhile.
    private func rest(calm: Int, limit: Int) async {
        for pass in 0..<2 {
            if pass == 1 { try? await Task.sleep(for: .milliseconds(400)) }
            var still = 0
            for _ in 0..<limit {
                let total = PerfCounters.snapshot().values.reduce(0, +)
                await settle(rounds: 1)
                if PerfCounters.snapshot().values.reduce(0, +) == total {
                    still += 1
                    if still >= calm { break }
                } else {
                    still = 0
                }
            }
        }
    }

    /// The counters during `body` (and the settling after it), by name.
    func count(_ body: () async throws -> Void) async rethrows -> [String: Int] {
        await quiet()
        PerfCounters.reset()
        PerfCounters.counting = true
        defer { PerfCounters.counting = false }
        try await body()
        // The step's own late work (a debounce, a reply) counts in it, not in the next one.
        await rest(calm: 25, limit: 600)
        return PerfCounters.snapshot()
    }

    /// The thread's scroll view (the biggest one in the window).
    var threadScroll: NSScrollView? { PerfScroller.main(under: host) }
}

/// A budget of work for one step of a screen: the counter, its limit, and where to look when it grows.
struct WorkBudget {
    let counter: String
    let limit: Int
    let lookAt: String

    /// A message for each counter over its budget (empty: all within).
    static func excesses(_ counts: [String: Int], _ budgets: [WorkBudget], scenario: String) -> [String] {
        budgets.compactMap { budget in
            let value = counts[budget.counter, default: 0]
            guard value > budget.limit else { return nil }
            return "\(scenario): \(budget.counter) = \(value), budget \(budget.limit). Something now does more work here: "
                + "\(budget.lookAt). Counts: \(counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))"
        }
    }
}
#endif
