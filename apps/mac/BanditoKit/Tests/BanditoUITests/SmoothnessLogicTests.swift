import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

/// The pure parts of the performance work: what a stream re-parses, which rows a stream replaces, the sparkline's
/// curve, the composer's facts, the sidebar's facts.
@Suite struct SmoothnessLogicTests {
    private func paragraph(_ index: Int) -> String {
        "Paragraph \(index) says what the agent found in the module and why it matters for the change. "
            + "It links to https://example.com/\(index) and names `File\(index).swift`."
    }

    @Test func aStreamSplitsAtTheLastBlankLineOutsideCode() {
        let text = (0..<6).map(paragraph).joined(separator: "\n\n") + "\n\nThe last line is still being wri"
        let end = try! #require(StreamingSplit.stableEnd(of: text))
        #expect(text[end...] == "The last line is still being wri")
        // A blank line inside an open code block is not a place to split.
        let code = (0..<4).map(paragraph).joined(separator: "\n\n") + "\n\n```swift\nlet a = 1\n\nlet b = 2"
        let codeEnd = try! #require(StreamingSplit.stableEnd(of: code))
        #expect(code[codeEnd...].hasPrefix("```swift"))
        // A short text is parsed whole.
        #expect(StreamingSplit.stableEnd(of: "short\n\ntext") == nil)
    }

    @Test func aStreamRendersAsTheWholeTextWould() {
        let text = (0..<6).map(paragraph).joined(separator: "\n\n") + "\n\nThe last **bold** words and `code"
        let cache = MessageRenderCache()
        let streamed = cache.streamingMessage(for: text, markdown: true)
        let whole = MessageRenderCache.rendered(text, markdown: true)
        // Two texts (the finished paragraphs, the one being written) that read as the whole one.
        #expect(streamed.blocks.count == 2)
        #expect(streamed.blocks.plainText.replacingOccurrences(of: "|", with: "\n\n") == whole.blocks.plainText)
        #expect(streamed.firstWebLink == whole.firstWebLink)
    }

    @Test func aStreamReplacesOnlyItsOwnRow() {
        let items: [ThreadItem] = [
            .user(id: ThreadItem.messageID(seq: 1), text: "hi", source: .user, from: nil, ts: 1_700_000_000_000),
            .streaming(text: "Hel"),
        ]
        var next = items
        next[1] = .streaming(text: "Hello")
        let rows = ThreadRows.build(items)
        let replaced = try! #require(ThreadRows.replacingLast(rows, from: items, to: next))
        #expect(replaced == ThreadRows.build(next))
        // Another change than the stream's text builds the rows again.
        var other = next
        other[0] = .user(id: ThreadItem.messageID(seq: 1), text: "hey", source: .user, from: nil, ts: 1_700_000_000_000)
        #expect(ThreadRows.replacingLast(rows, from: items, to: other) == nil)
        #expect(ThreadRows.replacingLast(rows, from: items, to: items + [.streaming(text: "x")]) == nil)
    }

    @MainActor @Test func theListRemakesOnlyTheStreamedLine() {
        let rows = ThreadRowsMemo()
        let lines = ThreadListMemo()
        let signature = ThreadListMemo.Signature(
            chat: ThreadChat(), agentName: "Forge", runtime: "claude", agentID: "a", folder: nil, baseline: nil)
        var items: [ThreadItem] = [
            .user(id: ThreadItem.messageID(seq: 1), text: "hi", source: .user, from: nil, ts: 1_700_000_000_000),
            .streaming(text: "Hel"),
        ]
        var made = 0
        func update(typing: ThreadListLine? = nil) -> Int {
            lines.update(rows: rows.rows(of: items), memo: rows, signature: signature, typing: typing) { row in
                made += 1
                return .row(
                    ThreadRowKey(
                        row: row, agentName: "Forge", primaryRuntime: "claude", agentID: "a", folder: nil,
                        chat: ThreadChat()),
                    live: false)
            }
        }
        let first = update()
        let all = made
        #expect(all >= 2 && lines.box.change == .all && lines.box.lines.count == all)
        // Nothing changed: the same version, nothing made.
        #expect(update() == first && made == all)
        // A token: only the streamed line is made, and the list is told so.
        items[1] = .streaming(text: "Hello")
        #expect(update() == first + 1 && made == all + 1 && lines.box.change == .last)
        // Rows read again by someone else in between do not hide the change.
        items[1] = .streaming(text: "Hello, wor")
        _ = rows.rows(of: items)
        _ = rows.rows(of: items)
        #expect(update() == first + 2 && made == all + 2 && lines.box.change == .last)
        // A new item makes the lines again; the typing line goes under them.
        items.append(.streaming(text: "x"))
        _ = update(typing: .typing(.thinking, since: nil))
        #expect(lines.box.change == .all && lines.box.lines.last?.id == ThreadListLine.typingID)
    }

    @Test func theListKeepsWhatStaysWhenTheThreadChanges() {
        #expect(ThreadListDiff.of(old: ["a", "b"], new: ["a", "b"]) == .same)
        // A new message, the typing line coming and going, a stream that got its final id: the end changes.
        #expect(ThreadListDiff.of(old: ["a", "b"], new: ["a", "b", "c"]) == .tail(removed: 0, inserted: 1))
        #expect(ThreadListDiff.of(old: ["a", "b", "typing"], new: ["a", "b"]) == .tail(removed: 1, inserted: 0))
        #expect(ThreadListDiff.of(old: ["a", "streaming"], new: ["a", "m5"]) == .tail(removed: 1, inserted: 1))
        // Older history above, on another day and on the same day (its day line comes again above it).
        #expect(
            ThreadListDiff.of(old: ["day-1", "m3", "m4"], new: ["day-0", "m1", "day-1", "m3", "m4"])
                == .head(removed: 0, inserted: 2))
        #expect(
            ThreadListDiff.of(old: ["day-1", "m3", "m4"], new: ["day-1", "m1", "m2", "m3", "m4"])
                == .head(removed: 1, inserted: 3))
        // Nothing in common: made again.
        #expect(ThreadListDiff.of(old: ["a"], new: ["b"]) == .reload)
        #expect(ThreadListDiff.of(old: [], new: ["b"]) == .reload)
    }

    @MainActor @Test func aFoldedPartStaysOpenOutsideItsRow() {
        let disclosure = ThreadDisclosure()
        #expect(!disclosure.isOpen("tools-a"))
        disclosure.toggle("tools-a")
        #expect(disclosure.isOpen("tools-a") && !disclosure.isOpen("form-a"))
        disclosure.toggle("tools-a")
        #expect(!disclosure.isOpen("tools-a"))
    }

    @Test func teamModeIsKeptForTheLastTwoServers() {
        var kept: [String] = []
        kept = TeamKeeping.kept(kept, adding: "a", limit: 2)
        kept = TeamKeeping.kept(kept, adding: "b", limit: 2)
        #expect(kept == ["a", "b"])
        // Back to the first: it moves to the end, nothing is dropped.
        kept = TeamKeeping.kept(kept, adding: "a", limit: 2)
        #expect(kept == ["b", "a"])
        // A third: the oldest goes.
        kept = TeamKeeping.kept(kept, adding: "c", limit: 2)
        #expect(kept == ["a", "c"])
        // In the window: the kept ones, and the one in front while Team mode shows (before it joins them).
        #expect(TeamKeeping.built(kept: ["a"], front: "b", teamShown: true) == ["a", "b"])
        #expect(TeamKeeping.built(kept: ["a"], front: "b", teamShown: false) == ["a"])
        #expect(TeamKeeping.built(kept: ["a", "b"], front: "b", teamShown: true) == ["a", "b"])
        // No server: Team mode's empty state.
        #expect(TeamKeeping.built(kept: [], front: nil, teamShown: true) == [nil])
    }

    @MainActor @Test func firstFitWidthsOutliveTheView() {
        let key = "test.\(UUID().uuidString)"
        #expect(FirstFitMemory.entry(key, locale: "en") == nil)
        FirstFitMemory.keep(key, locale: "en", widths: [0: 300, 1: 120], available: 500)
        let entry = FirstFitMemory.entry(key, locale: "en")
        #expect(entry?.widths == [0: 300, 1: 120] && entry?.available == 500)
        // Per language: another language measures again.
        #expect(FirstFitMemory.entry(key, locale: "de") == nil)
        // Chosen from the kept widths.
        #expect(FirstFitRule.index(available: 250, widths: entry?.widths ?? [:], count: 2) == 1)
    }

    @Test func shelvesBelowTheFirstScreenComeAFrameApart() {
        #expect(MarketShelfReveal.atOnce(0) && MarketShelfReveal.atOnce(MarketShelfReveal.atOnceCount - 1))
        #expect(!MarketShelfReveal.atOnce(MarketShelfReveal.atOnceCount))
        let first = MarketShelfReveal.delay(MarketShelfReveal.atOnceCount)
        let next = MarketShelfReveal.delay(MarketShelfReveal.atOnceCount + 1)
        #expect(first > .zero && next > first && next < .milliseconds(100))
    }

    @Test func longFramesSayWhereAHitchCameFrom() {
        let stats = FrameStats.compute(
            intervals: [0.0167, 0.12, 0.0167, 0.38], work: [0.002, 0.11, 0.06, 0.04], cpu: [0.002, 0.1, 0.05, 0.04],
            frameDuration: 1.0 / 60, slides: [false, false, false, true])
        let long = stats.longFrames ?? []
        // Worst first; a short frame with long work is one too; a slide is marked.
        #expect(long.map(\.index) == [3, 1, 2])
        #expect(long[0].slide && !long[1].slide)
        #expect(abs(long[1].workMs - 110) < 0.01 && abs(long[1].cpuMs - 100) < 0.01)
        #expect(FrameStats.compute(intervals: [0.0167], work: [0.002], frameDuration: 1.0 / 60).longFrames == nil)
    }

    @Test func aNewWidthRemeasuresOnlyTheMeasuredRows() {
        let ids = ["a", "b", "c", "d"]
        // b was measured and is measured again at the same height; c was measured and is not any more (back to its
        // guess); d is measured now. a was never measured: it stands at its guess.
        let changed = ThreadListWidthChange.rows(ids, old: ["b": 40, "c": 60], new: ["b": 40, "d": 30])
        #expect(changed == IndexSet([2, 3]))
        #expect(ThreadListWidthChange.rows(ids, old: [:], new: [:]).isEmpty)
    }

    @Test func aSheetSlideIsNotAFreeze() {
        let ms: UInt64 = 1_000_000
        // 380 ms in AppKit's loop while a sheet moved, 40 ms of it on the processor: 40 ms of work.
        #expect(SheetSlideRule.busy(start: 0, end: 380 * ms, cpu: 40 * ms, sheetMovedAt: 10 * ms) == 40 * ms)
        // The sheet's building is work all the same.
        #expect(SheetSlideRule.busy(start: 0, end: 380 * ms, cpu: 200 * ms, sheetMovedAt: 10 * ms) == 200 * ms)
        // No sheet moving in it: the whole stretch, waiting or not (a wait on a lock is a freeze).
        #expect(SheetSlideRule.busy(start: 0, end: 380 * ms, cpu: 40 * ms, sheetMovedAt: nil) == 380 * ms)
        #expect(SheetSlideRule.busy(start: 100 * ms, end: 380 * ms, cpu: 40 * ms, sheetMovedAt: 50 * ms) == 280 * ms)
        // A frame that comes right after a slide, before its stretch ends, counts only the processor time in it.
        #expect(SheetSlideRule.part(from: 0, to: 380 * ms, cpu: 60 * ms, sheetMoved: true) == 60 * ms)
        #expect(SheetSlideRule.part(from: 0, to: 380 * ms, cpu: 60 * ms, sheetMoved: false) == 380 * ms)
        #expect(SheetSlideRule.part(from: 10 * ms, to: 5 * ms, cpu: 60 * ms, sheetMoved: false) == 0)
        // Its frame is counted apart, not as a late frame.
        let stats = FrameStats.compute(
            intervals: [0.0167, 0.38, 0.0167], work: [0.002, 0.04, 0.002], frameDuration: 1.0 / 60,
            slides: [false, true, false])
        #expect(stats.frames == 2 && stats.sheetSlides == 1 && stats.worstFrameMs < 20)
        // The work in it still counts: 40 ms is over a 60 Hz frame.
        #expect(stats.workWorstMs == 40 && stats.shareOver16Ms > 0.3)
        #expect(abs(stats.sheetSlideWorstMs - 380) < 0.01)
    }

    @Test func firstFitTakesTheFirstCandidateThatFits() {
        let widths: [Int: CGFloat] = [0: 500, 1: 300, 2: 40]
        #expect(FirstFitRule.index(available: nil, widths: widths, count: 3) == 2)
        #expect(FirstFitRule.index(available: 500, widths: widths, count: 3) == 0)
        #expect(FirstFitRule.index(available: 499, widths: widths, count: 3) == 1)
        #expect(FirstFitRule.index(available: 100, widths: widths, count: 3) == 2)
        // The last is shown when nothing fits, and until all are measured.
        #expect(FirstFitRule.index(available: 10, widths: widths, count: 3) == 2)
        #expect(FirstFitRule.index(available: 900, widths: [0: 500], count: 3) == 2)
        #expect(FirstFitRule.index(available: 10, widths: [:], count: 1) == 0)
    }

    @Test func theSparklineSpansItsRectAndNeverOvershoots() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let points = SparklineGeometry.points(values: [0, 10, 10, 5], top: 10, in: rect)
        #expect(points.first == CGPoint(x: 0, y: 50))
        #expect(points.last?.x == 100)
        #expect(points[1].y == 0)
        let slopes = SparklineGeometry.tangents(points)
        // A flat run between two equal samples stays flat at both ends.
        #expect(slopes[1] == 0 && slopes[2] == 0)
        #expect(SparklineGeometry.points(values: [1], top: 1, in: rect).isEmpty)
    }

    @MainActor @Test func theComposerFactsChangeOnlyWithWhatTheyShow() {
        let facts = DraftFacts()
        facts.update("hello")
        #expect(facts.hasText && !facts.isCommand && facts.slashQuery == nil && facts.mentionMatch == nil)
        facts.update("/rev")
        #expect(facts.slashQuery == "rev")
        facts.update("ask @Sco")
        #expect(facts.mentionMatch?.query == "Sco")
        facts.update("   ")
        #expect(!facts.hasText)
    }

    @Test func theSidebarFactsKeepOnlyTheStartOfAStream() {
        let agent = Agent(id: "a", name: "Forge", runtime: .claude, cwd: "/tmp")
        var thread = AgentThread()
        thread.items = [.streaming(text: String(repeating: "word ", count: 200))]
        let long = SidebarThreadFacts(thread: thread, agent: agent)
        thread.items = [.streaming(text: String(repeating: "word ", count: 201))]
        #expect(SidebarThreadFacts(thread: thread, agent: agent).preview?.hasPrefix("word word") == true)
        #expect(long.preview != nil)
    }
}

private extension Array where Element == RenderedBlock {
    /// The characters of the running texts and the code, in order.
    var plainText: String {
        map { block in
            switch block {
            case .text(let value): String(value.characters)
            case .code(_, let code): code
            }
        }.joined(separator: "|")
    }
}
