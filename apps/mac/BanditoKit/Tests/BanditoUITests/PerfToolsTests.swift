import Foundation
import Testing
import BanditoL10n

@testable import BanditoKit
@testable import BanditoUI

#if os(macOS)
@Suite struct HangTrackerTests {
    private let ms: UInt64 = 1_000_000

    @Test func shortStretchIsNoHang() {
        var tracker = HangTracker()
        tracker.wake(at: 1_000 * ms)
        let r1 = tracker.sleep(at: 1_100 * ms)
        #expect(r1 == nil)
    }

    @Test func longStretchReportsItsLength() {
        var tracker = HangTracker()
        tracker.wake(at: 1_000 * ms)
        let r2 = tracker.sleep(at: 1_400 * ms)
        #expect(r2 == 400 * ms)
        // The next stretch starts clean.
        #expect(tracker.busySince == nil)
        let r3 = tracker.sleep(at: 2_000 * ms)
        #expect(r3 == nil)
    }

    @Test func exactlyTheThresholdCounts() {
        var tracker = HangTracker()
        tracker.wake(at: 0)
        let r4 = tracker.sleep(at: HangTracker.threshold)
        #expect(r4 == HangTracker.threshold)
    }

    @Test func aWakeInsideAStretchDoesNotRestartIt() {
        var tracker = HangTracker()
        tracker.wake(at: 1_000 * ms)
        tracker.wake(at: 1_200 * ms)
        let r5 = tracker.sleep(at: 1_300 * ms)
        #expect(r5 == 300 * ms)
    }

    @Test func theWatcherAnnouncesOncePerStretch() {
        var tracker = HangTracker()
        let r6 = tracker.shouldAnnounce(at: 5_000 * ms)
        #expect(!r6)
        tracker.wake(at: 1_000 * ms)
        let r7 = tracker.shouldAnnounce(at: 1_200 * ms)
        #expect(!r7)
        let r8 = tracker.shouldAnnounce(at: 1_300 * ms)
        #expect(r8)
        let r9 = tracker.shouldAnnounce(at: 1_400 * ms)
        #expect(!r9)
        _ = tracker.sleep(at: 1_500 * ms)
        tracker.wake(at: 2_000 * ms)
        let r10 = tracker.shouldAnnounce(at: 2_300 * ms)
        #expect(r10)
    }

    @Test func aClockThatWentBackwardsIsNoHang() {
        var tracker = HangTracker()
        tracker.wake(at: 2_000 * ms)
        let r11 = tracker.sleep(at: 1_000 * ms)
        #expect(r11 == nil)
    }
}

@Suite struct HangMonitorLiveTests {
    /// The monitor runs for two seconds while the main thread freezes for 300 ms: it must not crash on its background
    /// timer, and it must see the hang when the main thread returns to its run loop.
    @MainActor @Test func seesAFreezeOfTheMainThread() async throws {
        let tally = HangTally()
        HangMonitor.start()
        HangMonitor.observeHangs { tally.add($0) }
        defer { HangMonitor.observeHangs(nil) }
        HangMonitor.note(action: "test.freeze")
        try await Task.sleep(for: .milliseconds(300))
        usleep(300_000)
        // Waits for the monitor's background timer to report it; a starved CI runner can be late by seconds.
        for _ in 0..<2000 where tally.count < 1 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tally.count >= 1)
        #expect(tally.longest >= HangTracker.threshold)
    }
}

@Suite struct HangEventTests {
    @Test func everyScreenHasAnAllowedName() {
        for screen in TelemetryEvent.HangScreen.allCases {
            let name = TelemetryEvent.hang(screen).name
            #expect(name == "perf.hang.\(screen.rawValue)")
            #expect(TelemetryEvent.isAllowedName(name))
        }
    }

    @Test func everyModeMapsToAScreen() {
        for mode in AppMode.allCases {
            #expect(TelemetryEvent.HangScreen(rawValue: mode.rawValue) != nil)
        }
    }
}
#endif

#if os(macOS)
@Suite struct FrameStatsTests {
    @Test func steadyFramesMissNothing() {
        let stats = FrameStats.compute(intervals: Array(repeating: 1.0 / 60, count: 120), frameDuration: 1.0 / 60)
        #expect(stats.frames == 120)
        #expect(stats.missed == 0)
        #expect(stats.droppedEstimate == 0)
        #expect(stats.shareOver16Ms == 0)
        #expect(abs(stats.p95Ms - 16.67) < 0.1)
    }

    @Test func aLongGapIsOneMissedFrameAndSeveralDropped() {
        var intervals = Array(repeating: 1.0 / 60, count: 99)
        intervals.append(0.1)
        let stats = FrameStats.compute(intervals: intervals, frameDuration: 1.0 / 60)
        #expect(stats.missed == 1)
        #expect(stats.droppedEstimate == 5)
        #expect(stats.shareOver16Ms == 0.01)
        #expect(abs(stats.worstFrameMs - 100) < 0.001)
    }

    @Test func aFrameBelowOneAndAHalfDurationsIsNotMissed() {
        let stats = FrameStats.compute(intervals: [0.024, 0.026], frameDuration: 1.0 / 60)
        #expect(stats.missed == 1)
    }

    @Test func percentilesUseTheSortedGaps() {
        let intervals = (1...100).map { Double($0) / 1000 }
        let stats = FrameStats.compute(intervals: intervals, frameDuration: 1.0 / 60)
        #expect(abs(stats.p50Ms - 50) < 0.001)
        #expect(abs(stats.p95Ms - 95) < 0.001)
        #expect(abs(stats.worstFrameMs - 100) < 0.001)
    }

    @Test func workTimeIsJudgedAgainstTheBudgetOfAFrame() {
        let intervals = Array(repeating: 1.0 / 60, count: 10)
        let work = [0.002, 0.004, 0.006, 0.009, 0.012, 0.017, 0.003, 0.003, 0.003, 0.003]
        let stats = FrameStats.compute(intervals: intervals, work: work, frameDuration: 1.0 / 60)
        #expect(stats.shareOver8Ms == 0.3)
        #expect(stats.shareOver16Ms == 0.1)
        #expect(abs(stats.workWorstMs - 17) < 0.001)
        #expect(abs(stats.workP50Ms - 3) < 0.001)
    }

    @Test func processorTimeAndLongStretchesAreReported() {
        let stats = FrameStats.compute(
            intervals: [0.008, 0.008, 0.2], work: [0.001, 0.002, 0.19], cpu: [0.001, 0.002, 0.003], longStretches: 1,
            frameDuration: 1.0 / 120)
        #expect(stats.stretchesOver100Ms == 1)
        #expect(abs(stats.cpuP95Ms - 3) < 0.001)
    }

    @Test func noFramesGiveZeros() {
        let stats = FrameStats.compute(intervals: [], frameDuration: 0)
        #expect(stats.frames == 0)
        #expect(stats.worstFrameMs == 0)
        #expect(abs(stats.frameDurationMs - 16.67) < 0.1)
        #expect(!stats.meetsTarget(displayFrameMs: 16.67))
    }

    @Test func theTargetIsMetOnlyWithinEveryLimit() {
        let frame = 1.0 / 120
        let smooth = FrameStats.compute(
            intervals: Array(repeating: frame, count: 200), work: Array(repeating: 0.004, count: 200),
            frameDuration: frame)
        #expect(smooth.meetsTarget(displayFrameMs: frame * 1000))
        // On a 60 Hz screen the gaps are 16.7 ms; the work still has to fit a 120 Hz frame.
        let sixty = FrameStats.compute(
            intervals: Array(repeating: 1.0 / 60, count: 200), work: Array(repeating: 0.004, count: 200),
            frameDuration: 1.0 / 60)
        #expect(sixty.meetsTarget(displayFrameMs: 1000.0 / 60))
        let heavy = FrameStats.compute(
            intervals: Array(repeating: frame, count: 200), work: Array(repeating: 0.009, count: 200),
            frameDuration: frame)
        #expect(!heavy.meetsTarget(displayFrameMs: frame * 1000))
        var late = Array(repeating: frame, count: 200)
        late[10] = 0.03
        late[20] = 0.03
        let dropped = FrameStats.compute(
            intervals: late, work: Array(repeating: 0.002, count: 200), frameDuration: frame)
        #expect(!dropped.meetsTarget(displayFrameMs: frame * 1000))
        let frozen = FrameStats.compute(
            intervals: Array(repeating: frame, count: 200), work: Array(repeating: 0.002, count: 200), longStretches: 1,
            frameDuration: frame)
        #expect(!frozen.meetsTarget(displayFrameMs: frame * 1000))
    }
}

@Suite struct PerfCheckRowTests {
    @Test func aRowNamesThePageAndItsVerdict() {
        var report = PerfReport(
            scenario: "files", startedAt: "", durationSec: 1,
            frames: FrameStats.compute(
                intervals: Array(repeating: 1.0 / 120, count: 50), work: Array(repeating: 0.003, count: 50),
                frameDuration: 1.0 / 120),
            hangs: 0, longestHangMs: 0, memoryStartMB: 0, memoryPeakMB: 0, memoryEndMB: 0, segments: [], silentFrames: 0,
            bodies: [:], note: "")
        report.meetsTarget = true
        let row = PerfCheckRow(report)
        #expect(row.page == PerfScenario.files.title)
        #expect(row.meets && !row.failed)
        #expect(row.verdict == L10n.PerfCheck.met)
        report.error = "no scroll view"
        report.meetsTarget = false
        #expect(PerfCheckRow(report).verdict == L10n.PerfCheck.failed)
        #expect(PerfCheckRow.summary([report]) == L10n.PerfCheck.Summary.some(count: 1))
    }
}
#endif

#if DEBUG && os(macOS)
@Suite struct PerfCommandTests {
    @Test func perfNamesAScenarioAndAnOptionalPath() {
        #expect(QACommand.parse("perf thread") == .perf(.thread, path: nil))
        #expect(QACommand.parse("perf switch /tmp/a b.json") == .perf(.switch, path: "/tmp/a b.json"))
        #expect(QACommand.parse("perf typing") == .perf(.typing, path: nil))
        #expect(QACommand.parse("perf files") == .perf(.files, path: nil))
        #expect(QACommand.parse("perf check") == .perfCheck(path: nil))
        #expect(QACommand.parse("perf check /tmp/all.json") == .perfCheck(path: "/tmp/all.json"))
        #expect(QACommand.parse("perf bogus") == nil)
        #expect(QACommand.parse("perf") == nil)
        #expect(QACommand.parse("dismiss-consent") == .dismissConsent)
    }

    @Test func theResultGoesToTheGivenPathOrTheCacheFolder() {
        #expect(PerfReport.destination(scenario: "market", path: "/tmp/x.json").path == "/tmp/x.json")
        #expect(PerfReport.destination(scenario: "market", path: nil).path.hasSuffix("/.cache/bandito-qa/perf-market.json"))
    }
}
#endif

@Suite struct PerfFixtureTests {
    @Test func theThreadFixtureIsDeterministicAndMixed() {
        let first = PerfFixtures.thread(count: 1_500)
        let second = PerfFixtures.thread(count: 1_500)
        #expect(first.count == 1_500)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(Set(first.map(\.id)).count == first.count)
        let hasCode = first.contains { item in
            if case .assistant(_, let text, _) = item { return text.contains("```") }
            return false
        }
        let hasFiles = first.contains { item in
            if case .user(_, _, _, _, _, let files) = item { return !files.isEmpty }
            return false
        }
        let hasTools = first.contains { if case .tool = $0 { return true } else { return false } }
        #expect(hasCode && hasFiles && hasTools)
    }

    @Test func everyDemoAgentHasAName() {
        #expect(PerfFixtures.names.count >= 40)
        #expect(Set(PerfFixtures.names).count == PerfFixtures.names.count)
    }
}
