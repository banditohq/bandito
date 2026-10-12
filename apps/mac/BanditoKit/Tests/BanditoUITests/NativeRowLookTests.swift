#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import SwiftUI
import Testing

@testable import BanditoUI

/// The native rows of the thread (`NativeRow`) look as the SwiftUI rows they stand for: each sample is drawn both ways
/// in a dark window, and the two pictures must have the same height and differ in almost no pixel (a symbol may sit half
/// a pixel apart). Set `NATIVE_OUT` to a folder to get the pictures side by side.
@MainActor @Suite(.serialized) struct NativeRowLookTests {
    static let out = ProcessInfo.processInfo.environment["NATIVE_OUT"].map { URL(fileURLWithPath: $0) }

    static let samples: [ThreadRow] = {
        let ts: Int64 = 1_700_000_000_000
        let items: [ThreadItem] = [
            .assistant(id: "a1", text: "Short reply.", ts: ts),
            .assistant(
                id: "a2",
                text: "The plan:\n\n- **Read** the module `Thread.swift` and its tests\n- Change `windowSize` only where it is used\n- Run `swift test` and look at the result\n\nI read the module and the three call sites, and the change is small.",
                ts: ts),
            .assistant(
                id: "a3",
                text: "Here is the change:\n\n```swift\nfunc load() {\n    let rows = store.rows(limit: 50)\n}\n```\n\nThe failing test passes now.",
                ts: ts),
            .assistant(
                id: "a4",
                text: "## Result\n\n> The numbers are from one run.\n\n| step | before | after |\n| --- | --- | --- |\n| load | 412 ms | 96 ms |",
                ts: ts),
            .user(id: "u1", text: "ok", source: .user, from: nil, ts: ts),
            .user(
                id: "u2",
                text: "Please look at `ServerModel.swift` and tell me what you think.\n\nI read the module and the three call sites, and the change is small. I left the formatting alone and only touched the lines that had to change.",
                source: .user, from: nil, ts: ts),
            .note(id: "n1", text: "Handed over to Scout for review.", kind: .info, ts: ts),
            .assistant(
                id: "a5",
                text: "Run:\n\n```sh\nswift test --scratch-path /tmp/very/long/path/that/does/not/fit/in/the/bubble --filter ThreadListTests\n```",
                ts: ts),
            .streaming(text: "I am still writing this reply, the first paragraph is long enough to wrap onto a second line in the bubble."),
        ]
        return items.map { .item($0) } + [
            .toolGroup([
                ToolRow(callId: "c1", tool: "bash", title: "ls", ok: true, output: "a"),
                ToolRow(callId: "c2", tool: "bash", title: "pwd", ok: true, output: "b"),
            ]),
            .toolGroup([ToolRow(callId: "c3", tool: "bash", title: "false", ok: false, output: "")]),
            .day(Date()),
        ]
    }()

    private func picture(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The share of pixels whose colour differs by more than a faint edge.
    private func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent)
                    + abs(p.blueComponent - q.blueComponent)
                if delta > 0.45 { differing += 1 }
            }
        }
        return Double(differing) / Double(max(1, width * height))
    }

    @Test(arguments: [900.0, 520.0])
    func nativeRowsDrawAsTheSwiftUIRows(_ width: Double) throws {
        _ = BanditoFont.registerBundledFonts()
        let server = ServerModel(config: ServerConfig(id: UUID(), name: "s", endpoint: .local(socketPath: "/tmp/x")))
        let width = CGFloat(width)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(Color.Bandito.bg).cgColor
        window.contentView = root
        for (index, row) in Self.samples.enumerated() {
            let key = ThreadRowKey(
                row: row, agentName: "Forge", primaryRuntime: "claude", agentID: "a", folder: nil, chat: ThreadChat())
            let line = ThreadListLine.row(key, live: false)
            let context = ThreadListContext(server: server, agentID: "a", chat: ThreadChat(), onError: { _ in })
            let native = try #require(NativeRow.of(line), "sample \(index) is a native row")
            let swiftCell = ThreadListCell()
            swiftCell.show(line, context: context)
            let nativeCell = NativeRowCell()
            nativeCell.show(native, context: context)
            let height = swiftCell.height(forWidth: width)
            #expect(nativeCell.height(forWidth: width) == height, "sample \(index) height at \(width)")
            var pictures: [NSBitmapImageRep] = []
            for cell in [swiftCell, nativeCell] as [NSView] {
                for sub in root.subviews { sub.removeFromSuperview() }
                root.setFrameSize(NSSize(width: width, height: height))
                cell.frame = NSRect(x: 0, y: 0, width: width, height: height)
                root.addSubview(cell)
                pictures.append(picture(root))
            }
            let share = difference(pictures[0], pictures[1])
            #expect(share < 0.003, "sample \(index) at \(width): \(share * 100)% of pixels differ")
            if let out = Self.out {
                for (side, rep) in zip(["swiftui", "native"], pictures) {
                    try rep.representation(using: .png, properties: [:])?
                        .write(to: out.appending(path: "row-\(Int(width))-\(index)-\(side).png"))
                }
            }
        }
    }

    @Test func rowsWithMoreThanABubbleStaySwiftUI() {
        let ts: Int64 = 1_700_000_000_000
        var chat = ThreadChat()
        chat.repliesOn = true
        chat.replies = [3: 1]
        chat.mentions = [5: [Mention(kind: .agent, id: "x", label: "Scout")]]
        let quoted = ThreadItem.user(id: ThreadItem.messageID(seq: 3), text: "Re", source: .user, from: nil, ts: ts)
        let mentioned = ThreadItem.user(id: ThreadItem.messageID(seq: 5), text: "Hi", source: .user, from: nil, ts: ts)
        let link = ThreadItem.assistant(id: "w", text: "See https://bandito.dev", ts: ts)
        let running = ThreadRow.toolGroup([ToolRow(callId: "r", tool: "bash", title: "ls")])
        for row in [ThreadRow.item(quoted), .item(mentioned), .item(link), running] {
            let key = ThreadRowKey(
                row: row, agentName: "F", primaryRuntime: "claude", agentID: "a", folder: nil,
                chat: { var c = chat; c.original = { _ in ReplyTarget(seq: 1, fromUser: true, text: "x") }; return c }())
            #expect(NativeRow.of(.row(key, live: false)) == nil)
        }
        // A row rising in as it arrives keeps the SwiftUI animation.
        let plain = ThreadRowKey(
            row: .item(.assistant(id: "p", text: "Plain", ts: ts)), agentName: "F", primaryRuntime: "claude",
            agentID: "a", folder: nil, chat: ThreadChat())
        #expect(NativeRow.of(.row(plain, live: true)) == nil)
        #expect(NativeRow.of(.row(plain, live: false)) != nil)
    }

    @Test func theGeometryKeepsTheSwiftUIRowsSpacing() {
        // 900 pt: a 740 pt line centred; an agent's bubble on its left edge, a person's on its right, each leaving 120.
        let agent = NativeMessageGeometry.make(
            cellWidth: 900, fromUser: false, streaming: false, markdown: true, sizes: [CGSize(width: 100, height: 20)],
            code: [false])
        #expect(agent.bubble == CGRect(x: 80, y: 0, width: 128, height: 40))
        #expect(agent.height == CGFloat(40 + 16 + 12))
        let user = NativeMessageGeometry.make(
            cellWidth: 900, fromUser: true, streaming: false, markdown: false, sizes: [CGSize(width: 100, height: 20)],
            code: [false])
        #expect(user.bubble.maxX == 820)
        // A stream keeps no room for actions; code blocks fill the widest text.
        let stream = NativeMessageGeometry.make(
            cellWidth: 900, fromUser: false, streaming: true, markdown: true,
            sizes: [CGSize(width: 50, height: 20), CGSize(width: 10, height: 40)], code: [false, true])
        #expect(stream.height == 20 + 10 + 40 + NativeMessageGeometry.codeChrome + 20 + 12)
        #expect(stream.blocks[1].width == NativeMessageGeometry.textWidth(cellWidth: 900))
        #expect(stream.bubble.width == CGFloat(740 - 120))
    }
}
#endif
