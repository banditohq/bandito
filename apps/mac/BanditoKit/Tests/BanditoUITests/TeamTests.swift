@testable import BanditoKit
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

/// Logic behind the Team mode: avatar moods, thread rows, context share, effort levels, pins.
@Suite struct TeamLogicTests {
    // MARK: avatar mood

    @Test func pausedAgentSleepsWhateverItWasDoing() {
        #expect(AvatarMood.make(status: .working, paused: true) == .sleeping)
        #expect(AvatarMood.make(status: .needsYou, turnRunning: true, paused: true) == .sleeping)
        #expect(AvatarMood.make(status: .idle, paused: false) == .idle)
    }

    @Test func statusMapsToMood() {
        #expect(AvatarMood.make(status: .idle) == .idle)
        #expect(AvatarMood.make(status: .working) == .working)
        #expect(AvatarMood.make(status: .needsYou) == .needsYou)
        #expect(AvatarMood.make(status: .error) == .error)
        #expect(AvatarMood.make(status: .offline) == .sleeping)
    }

    @Test func runningTurnAndStreamingMeanThinking() {
        #expect(AvatarMood.make(status: .idle, turnRunning: true) == .thinking)
        #expect(AvatarMood.make(status: .idle, streaming: true) == .thinking)
        // Waiting for a person outranks everything else.
        #expect(AvatarMood.make(status: .needsYou, turnRunning: true, streaming: true) == .needsYou)
        #expect(AvatarMood.make(status: .error, streaming: true) == .error)
    }

    @Test func workingStaysWorkingWhileToolsRun() {
        #expect(AvatarMood.make(status: .working, turnRunning: true) == .working)
    }

    // MARK: avatar pose

    @Test func sleepingPoseIsFadedWithDashEyesAndZ() {
        let pose = AvatarPose.make(mood: .sleeping, time: 1, phase: 0)
        #expect(pose.opacity < 1)
        #expect(pose.showsDashEyes)
        #expect(pose.showsZ)
    }

    @Test func needsYouHopsUpAtItsPeak() {
        // 70% of the 2 s cycle is the peak of the hop.
        let peak = AvatarPose.make(mood: .needsYou, time: 1.4, phase: 0)
        let rest = AvatarPose.make(mood: .needsYou, time: 0.2, phase: 0)
        #expect(peak.bodyOffsetY < -4)
        #expect(rest.bodyOffsetY == 0)
    }

    @Test func thinkingSquintsAndShowsDots() {
        let pose = AvatarPose.make(mood: .thinking, time: 0.9, phase: 0)
        #expect(pose.eyeScaleY < 1)
        #expect(pose.showsDots)
    }

    @Test func idleBlinksOnlyNearTheEndOfItsCycle() {
        let open = AvatarPose.make(mood: .idle, time: 1, phase: 0)
        let blink = AvatarPose.make(mood: .idle, time: 4.8, phase: 0)
        #expect(open.eyeScaleY == 1)
        #expect(blink.eyeScaleY < 0.5)
    }

    @Test func agentsBlinkOutOfStepFromTheirNameHash() {
        // Two agents with different phases do not blink at the same moment.
        let forge = AvatarPose.phase(for: "Forge")
        let scout = AvatarPose.phase(for: "Scout")
        #expect(forge != scout)
        #expect(forge >= 0 && forge < 5)
        let differs = stride(from: 0.0, to: 5.0, by: 0.05).contains { time in
            AvatarPose.make(mood: .idle, time: time, phase: forge).eyeScaleY
                != AvatarPose.make(mood: .idle, time: time, phase: scout).eyeScaleY
        }
        #expect(differs)
        // The same name always gets the same rhythm.
        #expect(AvatarPose.phase(for: "Forge") == forge)
    }

    @Test func reduceMotionFreezesEveryMoodAtRest() {
        for mood in AvatarMood.allCases {
            let pose = AvatarPose.make(mood: mood, time: 4.8, phase: 0, reduceMotion: true)
            #expect(pose.bodyOffsetY == 0)
            #expect(pose.eyeOffsetX == 0)
            #expect(pose.shakeX == 0)
            #expect(pose.eyeScaleY == 1)
            #expect(!pose.showsZ)
        }
    }

    // MARK: thread rows

    private func message(_ id: String, _ text: String, ts: Int64) -> ThreadItem {
        .user(id: id, text: text, source: .user, from: nil, ts: ts)
    }

    private func tool(_ id: String) -> ThreadItem {
        .tool(ToolRow(callId: id, tool: "Bash", title: "cmd \(id)", ok: true, output: nil))
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func consecutiveToolRowsGroupIntoOneCard() {
        let items: [ThreadItem] = [
            message("m1", "hi", ts: 1_000),
            tool("a"), tool("b"),
            .assistant(id: "r1", text: "done", ts: 2_000),
            tool("c"),
        ]
        // Day dividers are not part of the grouping under test.
        let rows = ThreadRows.build(items, calendar: utc).filter { row in
            if case .day = row { false } else { true }
        }
        #expect(rows.count == 4)
        guard case .toolGroup(let first) = rows[1], case .toolGroup(let last) = rows[3] else {
            Issue.record("expected two tool groups, got \(rows)")
            return
        }
        #expect(first.map(\.callId) == ["a", "b"])
        #expect(last.map(\.callId) == ["c"])
    }

    @Test func dayDividerAppearsOnlyWhenTheDayChanges() {
        let day1: Int64 = 1_791_000_000_000  // 2026-10-01 UTC
        let day2 = day1 + 26 * 3_600_000
        let items: [ThreadItem] = [
            message("m1", "a", ts: day1),
            message("m2", "b", ts: day1 + 60_000),
            message("m3", "c", ts: day2),
        ]
        let rows = ThreadRows.build(items, calendar: utc)
        let days = rows.filter { if case .day = $0 { true } else { false } }
        #expect(days.count == 2)
    }

    @Test func savedChapterBecomesChapterDivider() {
        let items: [ThreadItem] = [
            .chapter(id: "c1", number: 4, saved: true, ts: 1_000),
            .note(id: "n2", text: "Stopped", kind: .info, ts: 2_000),
        ]
        let rows = ThreadRows.build(items, calendar: utc)
        guard case .chapter(4, true) = rows[1] else {
            Issue.record("expected chapter divider in \(rows)")
            return
        }
        guard case .item = rows[2] else {
            Issue.record("expected plain note, got \(rows[2])")
            return
        }
    }

    /// The divider comes from the event's chapter number, so the language of a note's text does not matter.
    @Test func chapterNumberDoesNotDependOnLanguage() {
        for text in ["Chapter 4 · memory saved", "Глава 4 · память сохранена"] {
            let rows = ThreadRows.build([.note(id: "n", text: text, kind: .info, ts: 1_000)], calendar: utc)
            guard case .item = rows[1] else {
                Issue.record("a note must stay a note, got \(rows) for \(text)")
                return
            }
        }
        let rows = ThreadRows.build([.chapter(id: "c", number: 4, saved: true, ts: 1_000)], calendar: utc)
        guard case .chapter(4, true) = rows[1] else {
            Issue.record("expected divider for chapter 4, got \(rows)")
            return
        }
    }

    /// An unsaved chapter keeps its boundary: the divider is there and flags the missing memory.
    @Test func unsavedChapterKeepsADividerInOrder() {
        let items: [ThreadItem] = [
            .chapter(id: "c4", number: 4, saved: false, ts: 1_000),
            .note(id: "n", text: "Stopped", kind: .info, ts: 2_000),
            .chapter(id: "c5", number: 5, saved: true, ts: 3_000),
        ]
        let rows = ThreadRows.build(items, calendar: utc)
        // rows: day, unsaved chapter 4, note, saved chapter 5
        #expect(rows.count == 4)
        guard case .chapter(4, false) = rows[1] else {
            Issue.record("expected unsaved divider for chapter 4 at row 1, got \(rows)")
            return
        }
        guard case .item = rows[2] else {
            Issue.record("expected the note at row 2, got \(rows[2])")
            return
        }
        guard case .chapter(5, true) = rows[3] else {
            Issue.record("expected saved divider for chapter 5 at row 3, got \(rows[3])")
            return
        }
    }

    // MARK: context share

    @Test func contextShareIsTokensOverBudget() {
        #expect(abs(ContextUsage.fraction(tokens: 38_400, budget: 120_000) - 0.32) < 0.0001)
        #expect(ContextUsage.fraction(tokens: 0, budget: 120_000) == 0)
        #expect(ContextUsage.fraction(tokens: 500, budget: 0) == 0)
        #expect(ContextUsage.fraction(tokens: 300_000, budget: 120_000) == 1)
        #expect(ContextUsage.fraction(tokens: 10, budget: nil) == 10.0 / Double(ContextUsage.defaultBudget))
    }

    // MARK: effort levels

    @Test func effortLevelsDependOnRuntime() {
        #expect(EffortLevels.levels(for: .claude) == [.low, .medium, .high, .xhigh, .max])
        #expect(EffortLevels.levels(for: .codex) == [.low, .medium, .high, .xhigh])
        #expect(EffortLevels.levels(for: .grok) == [.low, .medium, .high])
    }

    // MARK: pins

    @Test func pinsPersistAcrossStores() throws {
        let suite = "team-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var pins = PinnedAgents(defaults: defaults)
        #expect(pins.ids.isEmpty)
        pins.toggle("forge")
        pins.toggle("scout")
        #expect(pins.isPinned("forge"))

        let reloaded = PinnedAgents(defaults: defaults)
        #expect(reloaded.ids == ["forge", "scout"])

        var again = reloaded
        again.toggle("forge")
        #expect(!PinnedAgents(defaults: defaults).isPinned("forge"))
        #expect(defaults.stringArray(forKey: "pinned.agents") == ["scout"])
    }
}

/// Visual snapshots for review: PNG files go to `BANDITO_SNAPSHOTS`.
@MainActor
@Suite struct TeamSnapshots {
    @Test func approvalCard() throws {
        let row = ApprovalRow(
            approvalId: "ap1", tool: "Bash", title: "git push origin feat/billing-webhook-tests",
            command: "git push origin feat/billing-webhook-tests", diff: nil,
            reason: "risky: git push*", state: .pending)
        let view = ApprovalCard(row: row, agentName: "Forge", onDecide: { _, _ in })
            .padding(24)
            .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        let url = try SnapshotSupport.render(view, "team-approval-card", size: CGSize(width: 680, height: 260))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func toolGroup() throws {
        let tools = [
            ToolRow(callId: "1", tool: "Bash", title: "cargo test billing::", ok: true, output: "14 passed"),
            ToolRow(callId: "2", tool: "Bash", title: "git checkout -b feat/billing-webhook-tests", ok: true, output: nil),
            ToolRow(callId: "3", tool: "Bash", title: "git commit -m \"test: billing webhook\"", ok: true, output: nil),
        ]
        let view = ToolGroupCard(tools: tools, duration: 4.8)
            .padding(24)
            .background(Color(red: 0.07, green: 0.063, blue: 0.055))
        let url = try SnapshotSupport.render(view, "team-tool-group", size: CGSize(width: 680, height: 200))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
