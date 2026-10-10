import BanditoKit
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

/// What keeps a long thread smooth while it is scrolled: nothing is written to state by a scroll that crosses no
/// threshold, rows with the same data are equal (so they are not built again), and a message is parsed once.
@MainActor
@Suite struct ThreadScrollPerformanceTests {
    private func metrics(offset: Int, content: Int = 40_000, height: Int = 800) -> ThreadScrollMetrics {
        ThreadScrollMetrics(offset: Double(offset), contentHeight: Double(content), height: Double(height))
    }

    // MARK: Scroll state

    @Test func scrollingAwayFromTheBottomByOnePointChangesNoFlag() {
        var previous: ThreadScrollMetrics? = metrics(offset: 10_000)
        let first = ThreadScroll.flags(was: false, old: nil, new: previous!)
        var lastFlags = first
        var writes = 0
        // 2000 steps of one point, up and down, far from the bottom and far from the "down" button threshold.
        for step in 1...2000 {
            let offset = 10_000 + (step % 2 == 0 ? -step / 2 : step / 2)
            let new = metrics(offset: offset)
            let flags = ThreadScroll.flags(was: lastFlags.atBottom, old: previous, new: new)
            if flags.atBottom != lastFlags.atBottom || flags.jump != lastFlags.jump { writes += 1 }
            lastFlags = flags
            previous = new
        }
        #expect(writes == 0)
        #expect(lastFlags.atBottom == false)
        #expect(lastFlags.jump == true)
    }

    @Test func followingTheBottomIsNotAskedByAPlainScroll() {
        let old = metrics(offset: 39_100)
        let new = metrics(offset: 39_101)
        #expect(!ThreadScroll.shouldFollow(atBottom: false, old: old, new: new))
        #expect(!ThreadScroll.shouldFollow(atBottom: true, old: old, new: new))
    }

    @Test func hoverIsHeldBackOnlyWhileTheThreadMoves() {
        ThreadScrollActivity.noteMove(at: 100)
        #expect(ThreadScrollActivity.isScrolling(at: 100.05))
        #expect(!ThreadScrollActivity.isScrolling(at: 100 + ThreadScrollActivity.settle + 0.01))
    }

    // MARK: Equatable rows

    private func key(
        _ row: ThreadRow, chat: ThreadChat = ThreadChat(), name: String = "Forge"
    ) -> ThreadRowKey {
        ThreadRowKey(row: row, agentName: name, primaryRuntime: "claude", agentID: "a1", folder: nil, chat: chat)
    }

    @Test func rowsWithTheSameDataAreEqual() {
        let item = ThreadItem.assistant(id: "s7", text: "Hello **world**", ts: 1)
        var a = ThreadChat()
        var b = ThreadChat()
        // Closures differ, data does not.
        a.onJump = { _ in }
        b.onReact = { _, _ in }
        #expect(key(.item(item), chat: a) == key(.item(item), chat: b))
    }

    @Test func rowsWithOtherDataAreNotEqual() {
        let one = ThreadItem.assistant(id: "s7", text: "Hello", ts: 1)
        let two = ThreadItem.assistant(id: "s7", text: "Hello!", ts: 1)
        #expect(key(.item(one)) != key(.item(two)))
        #expect(key(.item(one)) != key(.item(one), name: "Other"))
    }

    @Test func aFlashOrAReplyTouchesOnlyItsOwnRow() {
        let mine = ThreadItem.assistant(id: "s7", text: "A", ts: 1)
        let other = ThreadItem.assistant(id: "s9", text: "B", ts: 1)
        var chat = ThreadChat(repliesOn: true)
        let before = (key(.item(mine), chat: chat), key(.item(other), chat: chat))
        chat.highlightedID = "s9"
        chat.replies[9] = 7
        chat.original = { _ in ReplyTarget(seq: 7, fromUser: false, text: "A") }
        let after = (key(.item(mine), chat: chat), key(.item(other), chat: chat))
        #expect(before.0 == after.0)
        #expect(before.1 != after.1)
    }

    @Test func theLastAgentMessageChangesWhenANewOneComes() {
        let item = ThreadItem.assistant(id: "s7", text: "A", ts: 1)
        var chat = ThreadChat()
        chat.lastAgentID = "s7"
        let last = key(.item(item), chat: chat)
        chat.lastAgentID = "s9"
        #expect(last != key(.item(item), chat: chat))
    }

    // MARK: Parsing once

    private func messages(_ count: Int) -> [String] {
        (0..<count).map { i in
            """
            Message \(i) with **bold**, `code` and a link https://example.com/\(i) and /Users/me/project/file\(i).swift.

            ```swift
            let value\(i) = \(i)
            print(value\(i))
            ```

            Closing words for message \(i), long enough to wrap over a couple of lines in a bubble of a chat.
            """
        }
    }

    @Test func aMessageIsParsedOnceHoweverOftenItIsDrawn() {
        let cache = MessageRenderCache()
        let texts = messages(300)
        for _ in 0..<5 {
            for text in texts { _ = cache.blocks(for: text, markdown: true) }
        }
        #expect(cache.parses == 300)
        _ = cache.blocks(for: texts[0], markdown: false)
        #expect(cache.parses == 301)
    }

    @Test func renderedBlocksSplitTextAndCode() {
        let blocks = MessageRenderCache.build(messages(1)[0], markdown: true)
        #expect(blocks.count == 3)
        if case .code(let language, let code) = blocks[1] {
            #expect(language == "swift")
            #expect(code.contains("let value0"))
        } else {
            Issue.record("the middle block is code")
        }
        let plain = MessageRenderCache.build("just text", markdown: true)
        #expect(plain.count == 1)
    }

    @Test func aStreamingTextIsNotKept() {
        let cache = MessageRenderCache(limit: 1 << 20)
        _ = cache.blocks(for: "partial", markdown: true, cached: false)
        _ = cache.blocks(for: "partial", markdown: true, cached: false)
        #expect(cache.parses == 2)
        _ = cache.blocks(for: "partial", markdown: true)
        _ = cache.blocks(for: "partial", markdown: true)
        #expect(cache.parses == 3)
    }
}
