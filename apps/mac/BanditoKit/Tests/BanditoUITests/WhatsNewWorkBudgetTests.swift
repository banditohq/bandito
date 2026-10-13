#if os(macOS) && DEBUG
import AppKit
import BanditoDesign
import BanditoKit
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

extension ScreenWorkSuites {
    /// The "What's new" sheet does a small, fixed amount of work: its body is built a few times, each card a few
    /// times (once, and once more when its cascade turn comes), the raccoon once, and after it is closed nothing is
    /// built any more (no timer, no task left running). Counts, not time (see `WorkBudgetTests`).
    @MainActor @Suite(.serialized) struct WhatsNewWorkBudgetTests {
        static let lookAt = "the sheet (WhatsNew/WhatsNewSheet.swift): state written per frame, a timer, or a card that redraws all of them"

        private func settle(_ seconds: Double) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        @Test func theSheetBuildsOnceAndStaysQuietAfterItIsClosed() throws {
            _ = BanditoFont.registerBundledFonts()
            let notes = try WhatsNewSnapshots.notes("0.1.15")
            let older = try WhatsNewSnapshots.notes("0.1.14")
            PerfCounters.reset()
            PerfCounters.counting = true
            defer { PerfCounters.counting = false }

            let size = CGSize(width: WhatsNewContent.width, height: WhatsNewContent.height)
            let host = NSHostingView(
                rootView: WhatsNewContent(notes: notes, version: "0.1.15", older: [older], preferredLanguages: ["en"]))
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            // The whole cascade (four cards, 140 ms + 90 ms each) and a margin.
            settle(1.2)
            let opened = PerfCounters.snapshot()
            if WorkBudgetTests.probe { print("WORKBUDGET whats new opens: \(opened.sorted { $0.key < $1.key })") }
            for message in WorkBudget.excesses(
                opened,
                [
                    WorkBudgetTests.budget("WhatsNew.body", 3, Self.lookAt),
                    WorkBudgetTests.budget("WhatsNew.card", 10, Self.lookAt),
                    WorkBudgetTests.budget("RaccoonLights.build", 1, WorkBudgetTests.raccoon),
                ], scenario: "the What's new sheet opens"
            ) {
                Issue.record(Comment(rawValue: message))
            }
            #expect((opened["WhatsNew.card"] ?? 0) >= 4, "every card was built: \(opened)")

            // Closed: nothing runs any more.
            window.contentView = nil
            PerfCounters.reset()
            settle(0.8)
            let after = PerfCounters.snapshot()
            #expect(after["WhatsNew.body"] == nil && after["WhatsNew.card"] == nil, "nothing is built after close: \(after)")
        }
    }
}
#endif
