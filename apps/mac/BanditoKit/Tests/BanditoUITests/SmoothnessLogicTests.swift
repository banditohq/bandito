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
        #expect(String(streamed.blocks.plainText) == String(whole.blocks.plainText))
        #expect(streamed.blocks.count == whole.blocks.count)
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
