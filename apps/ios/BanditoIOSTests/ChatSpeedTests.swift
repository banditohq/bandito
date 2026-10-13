import BanditoKit
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Bandito

/// The chat holds the Mac's bar: work is counted, never timed (like `CrewSpeedTests` and the Mac's `WorkBudgetTests`).
/// A streamed reply sets up one cell and measures one row per update; typing in the box touches no row; scrolling a long
/// thread measures each row once.
@MainActor
@Suite(.serialized) struct ChatSpeedTests {
    /// A chat on screen: the model, the controller in a window of the app's scene, and a way to wait until it is at rest.
    @MainActor final class Harness {
        let server: ServerModel
        let agentID: String
        let model: ChatModel
        let controller: ChatViewController
        let window: UIWindow

        init(server: ServerModel, agentID: String) {
            self.server = server
            self.agentID = agentID
            // Its own engine and queue: no other test's rows or messages are counted here.
            model = ChatModel(server: server, agentID: agentID, engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil))
            controller = ChatViewController(model: model, settings: IOSSettings())
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        /// Steps until the chat has nothing left to do: its updates are done, and `calm` steps in a row counted no new
        /// cell, snapshot or measure. Twice, with a pause between, so late work lands inside it.
        func rest(calm: Int = 12, limit: Int = 800) async {
            for pass in 0..<2 {
                if pass == 1 { try? await Task.sleep(for: .milliseconds(300)) }
                var still = 0
                for _ in 0..<limit {
                    await model.settle()
                    let before = signature()
                    try? await Task.sleep(for: .milliseconds(10))
                    window.layoutIfNeeded()
                    if signature() == before {
                        still += 1
                        if still >= calm { break }
                    } else {
                        still = 0
                    }
                }
            }
        }

        private func signature() -> [Int] {
            let counters = ChatCounters.shared
            return [counters.cellConfigurations, counters.snapshots, counters.textLayouts, model.updates]
        }
    }

    func install(_ server: ServerModel, id: String, messages: Int) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Speed", role: "Speed", runtime: .claude, cwd: DemoDaemonFiles.projects, createdAt: now,
                updatedAt: now, status: .idle),
            items: (0..<messages).map { index -> ThreadItem in
                let ts = now - Int64(messages - index) * 60_000
                if index % 2 == 0 {
                    return .user(id: "s\(index + 1)", text: "Question number \(index): how does it work?", source: .user, from: nil, ts: ts)
                }
                return .assistant(id: "s\(index + 1)", text: Self.reply(index), ts: ts)
            })
        return id
    }

    /// Replies of different shapes: a line, a list, a code block, a long paragraph.
    static func reply(_ index: Int) -> String {
        switch index % 4 {
        case 0: return "A short answer for message \(index)."
        case 1: return "## Plan \(index)\n- first step\n- second step\n- third step with `code` in it"
        case 2: return "Here:\n```swift\nfunc work\(index)() {\n    run()\n}\n```\nAnd that is all."
        default: return String(repeating: "A longer paragraph of the answer that goes over several lines. ", count: 8)
        }
    }

    // (a) A stream of 100 pieces sets up one cell, and measures one row per update.
    @Test func aStreamedReplySetsUpOneCellAndMeasuresOneRow() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "chat-speed-stream", messages: 30)
        let harness = Harness(server: server, agentID: id)
        await harness.rest()
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        // The reply begins: the first piece makes the stream's row.
        server.apply(Event(seq: 0, agentId: id, ts: now, body: .messageDelta(text: "First ")))
        await harness.rest()
        ChatCounters.shared.reset()
        let updatesBefore = harness.model.updates

        for piece in 0..<100 {
            server.apply(Event(seq: 0, agentId: id, ts: now, body: .messageDelta(text: "word\(piece) ")))
            // A token does not wait for the screen: every few pieces the run loop turns (as it does between packets).
            if piece % 7 == 0 { await Task.yield() }
        }
        await harness.rest()
        let counters = ChatCounters.shared
        let updates = harness.model.updates - updatesBefore
        #expect(updates >= 1, "the stream did not reach the screen")
        // Only the stream's own cell was set up, and nothing but its row was measured.
        #expect(Set(counters.configuredRows.keys) == ["streaming"], "cells set up: \(counters.configuredRows.keys.sorted())")
        #expect(Set(counters.layoutsByRow.keys) == ["streaming"], "rows measured: \(counters.layoutsByRow.keys.sorted())")
        #expect(counters.textLayouts <= updates, "\(counters.textLayouts) layouts for \(updates) updates")
        #expect(counters.reconfigured <= updates)
        // The text arrived whole.
        let thread = server.thread(for: id)
        guard case .streaming(let text)? = thread.items.last else {
            Issue.record("no stream")
            return
        }
        #expect(text.hasSuffix("word99 "))
        harness.window.isHidden = true
    }

    // (b) Typing in the box does not touch the list.
    @Test func typingInTheBoxTouchesNoRow() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "chat-speed-typing", messages: 30)
        let harness = Harness(server: server, agentID: id)
        await harness.rest()
        ChatCounters.shared.reset()
        let updatesBefore = harness.model.updates

        let field = harness.controller.composer.textField
        for _ in 0..<20 {
            field.insertText("a")
        }
        #expect(field.text == String(repeating: "a", count: 20))
        await harness.rest()
        let counters = ChatCounters.shared
        #expect(counters.cellConfigurations == 0, "\(counters.cellConfigurations) cells set up for 20 letters")
        #expect(counters.textLayouts == 0, "\(counters.textLayouts) rows measured for 20 letters")
        #expect(counters.snapshots == 0)
        #expect(harness.model.updates == updatesBefore)
        harness.window.isHidden = true
    }

    // (c) Scrolling 500 messages measures each row once.
    @Test func scrollingFiveHundredMessagesMeasuresEachRowOnce() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "chat-speed-scroll", messages: 500)
        ChatCounters.shared.reset()
        let harness = Harness(server: server, agentID: id)
        await harness.rest(calm: 20, limit: 2000)
        let rows = harness.model.rows.count
        #expect(rows >= 500, "the chat has \(rows) rows")

        let list = harness.controller.collectionView
        var y = list.contentSize.height - list.bounds.height
        while y > 0 {
            list.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            list.layoutIfNeeded()
            y -= 260
        }
        list.setContentOffset(.zero, animated: false)
        list.layoutIfNeeded()
        var down: CGFloat = 0
        while down < list.contentSize.height {
            list.setContentOffset(CGPoint(x: 0, y: down), animated: false)
            list.layoutIfNeeded()
            down += 260
        }
        await harness.rest()
        let counters = ChatCounters.shared
        #expect(counters.layoutsByRow.values.max() ?? 0 <= 1, "a row was measured more than once")
        #expect(counters.textLayouts <= rows, "\(counters.textLayouts) layouts for \(rows) rows")
        #expect(counters.snapshots <= 3, "\(counters.snapshots) snapshots to open a thread")
        harness.window.isHidden = true
    }
}

/// What the person reads stays where it is when older messages come in above.
@MainActor
@Suite(.serialized) struct ChatPrependTests {
    @Test func olderMessagesAboveDoNotMoveWhatIsRead() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        let speed = ChatSpeedTests()
        let id = speed.install(server, id: "chat-prepend", messages: 120)
        let harness = ChatSpeedTests.Harness(server: server, agentID: id)
        await harness.rest()
        let list = harness.controller.collectionView
        // Read in the middle of the thread.
        list.setContentOffset(CGPoint(x: 0, y: list.contentSize.height / 2), animated: false)
        list.layoutIfNeeded()
        await harness.rest()
        let before = harness.controller.topVisibleRow()
        let anchor = try #require(before)

        // Sixty older messages come in above (what `loadOlder` does).
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let older: [ThreadItem] = (0..<60).map { index in
            .assistant(id: "o\(index)", text: "An older message \(index) with a few words in it.", ts: now - 10_000_000 - Int64(index) * 1000)
        }
        let current = server.thread(for: id).items
        let agent = try #require(server.agents.first { $0.id == id })
        server.installSyntheticAgent(agent, items: older + current)
        await harness.rest()
        let after = try #require(harness.controller.position(of: anchor.id))
        #expect(abs(after - anchor.distance) < 1.5, "the row moved by \(after - anchor.distance) points")
        harness.window.isHidden = true
    }

    @Test func updatesThatWaitForAnApplyAreMergedNotReplaced() {
        let rows = [ChatRow(id: "a", content: .day("x"), spacing: 0)]
        let first = ChatUpdate(rows: rows, heights: ["a": 10], changed: ["stream"], prepended: 2, initial: true)
        let second = ChatUpdate(rows: rows, heights: ["a": 12], changed: ["stream", "other"], prepended: 3, initial: false)
        let merged = ChatUpdate.merge(first, second)
        #expect(merged.changed == ["stream", "other"])
        #expect(merged.prepended == 5)
        #expect(merged.initial)
        #expect(merged.heights["a"] == 12)
    }

    @Test func aStreamUpdateIsNotLostWhenAHeightUpdateFollowsWhileOneIsApplied() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        let speed = ChatSpeedTests()
        let id = speed.install(server, id: "chat-merge", messages: 20)
        let harness = ChatSpeedTests.Harness(server: server, agentID: id)
        await harness.rest()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.apply(Event(seq: 0, agentId: id, ts: now, body: .messageDelta(text: "He")))
        await harness.rest()
        let rows = harness.model.rows
        let metrics = try #require(harness.model.metrics)
        guard let last = rows.last, case .message(var message) = last.content, last.id == "streaming" else {
            Issue.record("no stream row")
            return
        }
        message.text = "Hello there, this grew"
        let grown = ChatRow(id: last.id, content: .message(message), spacing: last.spacing)
        let grownRows = Array(rows.dropLast()) + [grown]
        var heights = harness.model.heights
        heights[grown.id] = harness.model.engine.layout(grown, metrics).height
        ChatCounters.shared.reset()
        let controller = harness.controller
        // An update is being applied; a stream's update and a height update arrive meanwhile, in that order.
        controller.receive(ChatUpdate(rows: rows, heights: harness.model.heights, changed: [], prepended: 0, initial: false))
        controller.receive(ChatUpdate(rows: grownRows, heights: heights, changed: [grown.id], prepended: 0, initial: false))
        controller.receive(ChatUpdate(rows: grownRows, heights: heights, changed: [], prepended: 0, initial: false))
        await harness.rest()
        #expect(ChatCounters.shared.configuredRows[grown.id, default: 0] >= 1, "the stream's cell was not set up again")
        harness.window.isHidden = true
    }
}
