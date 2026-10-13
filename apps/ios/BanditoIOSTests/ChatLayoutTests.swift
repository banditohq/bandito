import BanditoKit
import Foundation
import Testing
import UIKit

@testable import Bandito

/// The measured rows: Markdown becomes blocks of the right kind, a row is measured once per width, and a longer text
/// is a taller row.
@MainActor
@Suite struct ChatLayoutTests {
    let metrics = ChatMetrics(width: 390, category: .large)

    func row(_ id: String, _ text: String, sender: ChatMessage.Sender = .agent, streaming: Bool = false) -> ChatRow {
        let message = ChatMessage(
            sender: sender, text: text, streaming: streaming, ts: 1_792_000_000_000, showsTime: true, files: [], caption: nil,
            tail: true, seq: nil)
        return ChatRow(id: id, content: .message(message), spacing: 8)
    }

    func message(_ layout: ChatRowLayout) -> ChatMessageLayout? {
        if case .message(let value) = layout.payload { return value }
        return nil
    }

    @Test func aShortMessageHugsItsText() throws {
        let engine = ChatLayoutEngine()
        let layout = try #require(message(engine.layout(row("a", "Hi"), metrics)))
        let bubble = try #require(layout.bubble)
        #expect(bubble.width < 120)
        // The agent's bubble is on the left, the person's on the right.
        #expect(bubble.minX == metrics.side)
        let mine = try #require(message(engine.layout(row("b", "Hi", sender: .me), metrics)))
        #expect(try #require(mine.bubble).maxX == metrics.width - metrics.side)
    }

    @Test func aLongerTextIsATallerRow() {
        let engine = ChatLayoutEngine()
        let short = engine.layout(row("a", "Short"), metrics).height
        let long = engine.layout(row("b", String(repeating: "A longer line of the reply that wraps. ", count: 30)), metrics).height
        #expect(long > short * 4)
    }

    @Test func aCodeBlockIsItsOwnBlockThatScrollsWhenALineIsWide() throws {
        let engine = ChatLayoutEngine()
        let wide = String(repeating: "let value = compute(argument)  ", count: 8)
        let text = "Run:\n```swift\nlet a = 1\n\(wide)\n```\nDone."
        let layout = try #require(message(engine.layout(row("a", text), metrics)))
        let codes = layout.blocks.compactMap { block -> ChatCodeItem? in
            if case .code(let item) = block { return item }
            return nil
        }
        #expect(codes.count == 1)
        #expect(codes[0].scrolls)
        #expect(codes[0].language == "swift")
        #expect(codes[0].code.contains("let a = 1"))
        // The bubble is as wide as it can be around a code block.
        #expect(try #require(layout.bubble).width > 300)
        // Text, code, text: three blocks in order.
        #expect(layout.blocks.count == 3)
    }

    @Test func aShortCodeBlockDoesNotScroll() throws {
        let engine = ChatLayoutEngine()
        let layout = try #require(message(engine.layout(row("a", "```\nls -la\n```"), metrics)))
        let code = layout.blocks.compactMap { block -> ChatCodeItem? in
            if case .code(let item) = block { return item }
            return nil
        }.first
        #expect(code?.scrolls == false)
    }

    @Test func listsAndHeadingsStayInOneTextBlock() throws {
        let engine = ChatLayoutEngine()
        let layout = try #require(message(engine.layout(row("a", "## Plan\n- one\n- two\n- three"), metrics)))
        #expect(layout.blocks.count == 1)
        guard case .text(let item)? = layout.blocks.first else {
            Issue.record("no text block")
            return
        }
        #expect(item.string.string.contains("•\tone"))
    }

    @Test func aWebLinkIsALinkAndAFilePathIsNot() throws {
        let engine = ChatLayoutEngine()
        let layout = try #require(message(engine.layout(row("a", "See https://bandito.dev/docs and Composer.swift"), metrics)))
        guard case .text(let item)? = layout.blocks.first else {
            Issue.record("no text block")
            return
        }
        var links: [URL] = []
        item.string.enumerateAttribute(.chatLink, in: NSRange(location: 0, length: item.string.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.map(\.host) == ["bandito.dev"])
    }

    @Test func aRowIsMeasuredOnceForAWidthAndAgainForAnother() {
        let engine = ChatLayoutEngine()
        let target = row("measure-once", "Some text")
        ChatCounters.shared.reset()
        _ = engine.layout(target, metrics)
        _ = engine.layout(target, metrics)
        _ = engine.layout(target, metrics)
        #expect(ChatCounters.shared.layoutsByRow["measure-once"] == 1)
        _ = engine.layout(target, ChatMetrics(width: 320, category: .large))
        #expect(ChatCounters.shared.layoutsByRow["measure-once"] == 2)
        // Another size category is another layout too (Dynamic Type changed).
        _ = engine.layout(target, ChatMetrics(width: 320, category: .accessibilityExtraLarge))
        #expect(ChatCounters.shared.layoutsByRow["measure-once"] == 3)
    }

    @Test func aChangedRowIsMeasuredAgain() {
        let engine = ChatLayoutEngine()
        ChatCounters.shared.reset()
        _ = engine.layout(row("stream-row", "He", streaming: true), metrics)
        _ = engine.layout(row("stream-row", "Hello", streaming: true), metrics)
        #expect(ChatCounters.shared.layoutsByRow["stream-row"] == 2)
    }

    @Test func prefetchMeasuresEachMissingRowOnce() async {
        let engine = ChatLayoutEngine()
        let rows = (0..<40).map { row("p\($0)", "Message number \($0) with a few words in it") }
        ChatCounters.shared.reset()
        await engine.prefetch(rows, metrics)
        await engine.prefetch(rows, metrics)
        #expect(ChatCounters.shared.textLayouts == 40)
        #expect(ChatCounters.shared.layoutsByRow.values.allSatisfy { $0 == 1 })
    }

    @Test func aBigAccessibilityTextMakesRowsTaller() {
        let engine = ChatLayoutEngine()
        let text = String(repeating: "Some words that wrap around. ", count: 12)
        let normal = engine.layout(row("n", text), metrics).height
        let large = engine.layout(row("n", text), ChatMetrics(width: 390, category: .accessibilityExtraExtraLarge)).height
        #expect(large > normal)
    }

    @Test func aFileOfAMessageGetsItsOwnTile() throws {
        let engine = ChatLayoutEngine()
        let files = [
            AgentAttachment(path: "/a/shot.png", name: "shot.png", size: 100, mime: "image/png"),
            AgentAttachment(path: "/a/notes.pdf", name: "notes.pdf", size: 2000, mime: "application/pdf"),
        ]
        let message = ChatMessage(
            sender: .me, text: "", streaming: false, ts: nil, showsTime: false, files: files, caption: nil, tail: true, seq: 1)
        let layout = try #require(
            self.message(engine.layout(ChatRow(id: "f", content: .message(message), spacing: 8), metrics)))
        #expect(layout.bubble == nil)
        #expect(layout.files.map(\.isPicture) == [true, false])
        #expect(layout.files[0].frame.width == metrics.pictureSide)
    }
}
