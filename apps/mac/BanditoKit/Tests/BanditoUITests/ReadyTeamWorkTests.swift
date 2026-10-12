#if os(macOS) && DEBUG
import AppKit
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

extension ScreenWorkSuites {
    /// The new sheets and the ready teams' cards build once and do no more work than they need. The counts are of
    /// bodies built (never time), in a view nobody sees: no window on any screen.
    @MainActor @Suite(.serialized) struct ReadyTeamWorkTests {
        private func build<V: View>(_ view: V, width: CGFloat, height: CGFloat, passes: Int = 4) -> [String: Int] {
            PerfCounters.reset()
            PerfCounters.counting = true
            defer { PerfCounters.counting = false }
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.appearance = NSAppearance(named: .darkAqua)
            for _ in 0..<passes {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            return PerfCounters.snapshot()
        }

        private func check(_ counts: [String: Int], _ budgets: [WorkBudget], _ scenario: String) {
            for message in WorkBudget.excesses(counts, budgets, scenario: scenario) {
                Issue.record(Comment(rawValue: message))
            }
        }

        @Test func theReadyTeamsRowBuildsEachCardOnce() {
            let env = AuditEnvironment()
            defer { env.cleanUp() }
            let catalog = LayoutAuditSnapshots.readyTeamCatalog
            let counts = build(
                env.wrap(
                    ReadyTeamsSection(bundles: catalog.bundles, templates: catalog.templates, languageCode: "en")
                        .frame(width: 700)),
                width: 700, height: 600)
            check(
                counts,
                [
                    WorkBudget(counter: "ReadyTeamsSection", limit: 2, lookAt: "ReadyTeamsSection (Team/ReadyTeamsSection.swift)"),
                    // Four cards, built once each; a second pass of layout must not build them again.
                    WorkBudget(counter: "ReadyTeamCard", limit: 8, lookAt: "ReadyTeamCard is Equatable: what it reads must not change"),
                ], "ready teams row")
            #expect(counts["ReadyTeamCard", default: 0] >= 4, "the four cards are on screen")
        }

        @Test func theReadyTeamSheetBuildsOnce() {
            let env = AuditEnvironment()
            defer { env.cleanUp() }
            let counts = build(
                env.wrap(
                    ReadyTeamSheet(bundleID: "web-project", server: env.server, preview: LayoutAuditSnapshots.readyTeamCatalog)),
                width: 600, height: 620)
            check(
                counts,
                [WorkBudget(counter: "ReadyTeamSheet", limit: 3, lookAt: "ReadyTeamSheet (Team/ReadyTeamSheet.swift): state written while it builds")],
                "ready team sheet")
            #expect(counts["ReadyTeamSheet", default: 0] >= 1)
        }

        @Test func theReportSheetBuildsOnce() {
            let env = AuditEnvironment()
            defer { env.cleanUp() }
            let counts = build(env.wrap(ReportProblemSheet()), width: 640, height: 640)
            check(
                counts,
                [WorkBudget(counter: "ReportProblemSheet", limit: 3, lookAt: "ReportProblemSheet (Report/ReportProblemSheet.swift): state written while it builds")],
                "report sheet")
            #expect(counts["ReportProblemSheet", default: 0] >= 1)
        }
    }
}
#endif
