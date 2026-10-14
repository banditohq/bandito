import BanditoKit
import Foundation
import Testing
import UIKit

@testable import Bandito

/// The message box stays on the bottom edge of the chat in every state: an empty thread, a thread with messages, a box
/// that grew, a file in the tray, a turned screen. The list takes the rest of the screen above it. (The bug: an empty
/// thread showed the box at the top under the header, with the rest of the screen black.)
@MainActor
@Suite(.serialized) struct ChatComposerLayoutTests {
    /// A chat in a window of a fixed size, the way the app shows it.
    @MainActor final class Host {
        let model: ChatModel
        let controller: ChatViewController
        let window: UIWindow

        init(server: ServerModel, agentID: String, size: CGSize) {
            model = ChatModel(server: server, agentID: agentID, engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil))
            controller = ChatViewController(model: model, settings: IOSSettings())
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        /// Turns the screen (or sets its size) and lays it out.
        func resize(_ size: CGSize) {
            window.frame = CGRect(origin: .zero, size: size)
            window.setNeedsLayout()
            window.layoutIfNeeded()
        }

        /// Lets the model finish its work (the history, the first rows) and lays the screen out again.
        func settle() async {
            for _ in 0..<5 {
                await model.settle()
                window.layoutIfNeeded()
            }
        }
    }

    static let portrait = CGSize(width: 390, height: 844)
    static let landscape = CGSize(width: 844, height: 390)

    func install(_ server: ServerModel, id: String, messages: Int) -> String {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(
                id: id, name: "Layout", role: "Layout", runtime: .claude, cwd: DemoDaemonFiles.projects, createdAt: now,
                updatedAt: now, status: .idle),
            items: (0..<messages).map { index -> ThreadItem in
                let ts = now - Int64(messages - index) * 60_000
                if index % 2 == 0 {
                    return .user(id: "l\(index + 1)", text: "Question \(index): how does it work?", source: .user, from: nil, ts: ts)
                }
                return .assistant(id: "l\(index + 1)", text: "An answer \(index), a few words of it.", ts: ts)
            })
        return id
    }

    /// The box is at the bottom (above the safe area: no keyboard here), the list is above it and fills the rest.
    func expectBoxAtBottom(_ host: Host, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let view = host.controller.view!
        let box = host.controller.composer
        let list = host.controller.collectionView
        let bottom = view.bounds.maxY - view.safeAreaInsets.bottom
        #expect(abs(box.frame.maxY - bottom) < 1, "\(note): the box ends at \(box.frame.maxY), the screen's bottom is \(bottom)", sourceLocation: sourceLocation)
        #expect(abs(list.frame.maxY - box.frame.minY) < 1, "\(note): the list ends where the box begins", sourceLocation: sourceLocation)
        #expect(list.frame.minY < box.frame.minY, "\(note): the list is above the box", sourceLocation: sourceLocation)
        #expect(box.frame.height < 200, "\(note): the box is its own height, not the screen's (\(box.frame.height))", sourceLocation: sourceLocation)
        #expect(list.frame.height > 300, "\(note): the list has the screen's room (\(list.frame.height))", sourceLocation: sourceLocation)
    }

    @Test func anEmptyThreadKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-empty", messages: 0)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        expectBoxAtBottom(host, "empty thread, portrait")
    }

    @Test func aThreadWithMessagesKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-messages", messages: 20)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        expectBoxAtBottom(host, "thread with messages, portrait")
    }

    @Test func aBoxThatGrewStaysAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-grow", messages: 0)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.controller.composer.text = String(repeating: "A long line that wraps in the box again and again. ", count: 12)
        host.window.layoutIfNeeded()
        await host.settle()
        expectBoxAtBottom(host, "a box with six lines of text")
    }

    @Test func aFileInTheTrayKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-tray", messages: 0)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.controller.composer.addFile(name: "notes.txt", thumbnail: nil)
        host.window.layoutIfNeeded()
        await host.settle()
        expectBoxAtBottom(host, "a file waiting in the tray")
    }

    @Test func aTurnedScreenKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-turn", messages: 12)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.resize(Self.landscape)
        await host.settle()
        expectBoxAtBottom(host, "landscape, thread with messages")
        host.resize(Self.portrait)
        await host.settle()
        expectBoxAtBottom(host, "back to portrait")
    }
}
