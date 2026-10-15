import BanditoKit
import BanditoDesign
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Bandito

/// Writes a picture of the window as a PNG into the folder named by `BANDITO_SHOTS_DIR` (pass it to xcodebuild as
/// `TEST_RUNNER_BANDITO_SHOTS_DIR`); without it nothing is written. For looking at what the tests lay out.
@MainActor
func saveShot(_ window: UIWindow, _ name: String) {
    guard let folder = ProcessInfo.processInfo.environment["BANDITO_SHOTS_DIR"], !folder.isEmpty else { return }
    window.layoutIfNeeded()
    // A window with no scene draws nothing through `drawHierarchy`; the layers draw themselves.
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
        UIColor(red: 0.07, green: 0.06, blue: 0.05, alpha: 1).setFill()
        context.fill(window.bounds)
        window.layer.render(in: context.cgContext)
    }
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try? image.pngData()?.write(to: URL(fileURLWithPath: folder).appending(path: "\(name).png"))
}

/// Waits (up to `seconds`) until the condition holds: the model hears of a change a hop of the main actor later, so a
/// test that looked right after `settle()` could look before the screen was told.
@MainActor
func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

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

        /// `deferred`: the window is made later with `show()` (a test sets up the controller first).
        init(server: ServerModel, agentID: String, size: CGSize, history: ChatHistoryCache? = nil, deferred: Bool = false) {
            model = ChatModel(server: server, agentID: agentID, engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: history)
            controller = ChatViewController(model: model, settings: IOSSettings())
            window = Self.makeWindow(size)
            if !deferred { show() }
        }

        /// The window sits in the app's scene when there is one: only then do the screen's coordinates mean what they do on a phone.
        static func makeWindow(_ size: CGSize) -> UIWindow {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
            window.frame = CGRect(origin: .zero, size: size)
            return window
        }

        /// A host over a model the test made (it set things on it first).
        init(model: ChatModel, server: ServerModel, size: CGSize) {
            self.model = model
            controller = ChatViewController(model: model, settings: IOSSettings())
            window = Self.makeWindow(size)
            show()
        }

        func show() {
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
        // The list takes everything between the top of the screen and the box (the screen may be a turned, short one).
        let room = box.frame.minY - view.safeAreaInsets.top
        #expect(abs(list.frame.height - room) < 1, "\(note): the list has the room above the box (\(list.frame.height) of \(room))", sourceLocation: sourceLocation)
        #expect(list.frame.height > view.bounds.height * 0.5, "\(note): the list has most of the screen (\(list.frame.height))", sourceLocation: sourceLocation)
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
        saveShot(host.window, "layout-landscape")
        host.resize(Self.portrait)
        await host.settle()
        expectBoxAtBottom(host, "back to portrait")
    }

    // MARK: the states that once moved the box

    /// An empty thread that then fills up (the history coming in after "offline"): the box stays down, the list takes the rest.
    @Test func anEmptyThreadThatFillsUpKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-fill", messages: 0)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        expectBoxAtBottom(host, "empty")
        saveShot(host.window, "layout-empty-synthetic")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 1...150 {
            let body: EventBody =
                index % 2 == 0
                ? .messageAssistant(text: "Answer \(index) with a few words of text in it.")
                : .messageUser(text: "Question \(index)?", source: .user, fromAgent: nil)
            server.apply(Event(seq: Int64(index), agentId: id, ts: now + Int64(index), body: body))
        }
        let filled = await eventually {
            host.controller.collectionView.contentSize.height > host.controller.collectionView.bounds.height
        }
        #expect(filled, "the messages came into the list")
        await host.settle()
        expectBoxAtBottom(host, "after 150 messages came in")
        saveShot(host.window, "layout-filled")
        #expect(!host.controller.showsEmptyState)
    }

    /// The connection going away and coming back moves nothing (the banner is over the list, not in the layout).
    @Test func theConnectionComingAndGoingKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-link", messages: 8)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        await server.disconnect()
        await host.settle()
        expectBoxAtBottom(host, "offline")
        saveShot(host.window, "layout-offline")
        await server.connect()
        await host.settle()
        expectBoxAtBottom(host, "online again")
        saveShot(host.window, "layout-online")
    }

    /// A screenshot (the system re-lays its keyboard frames out for a moment) must not carry the box away.
    @Test func aScreenshotKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        for (name, messages) in [("empty", 0), ("short", 3), ("long", 60)] {
            let id = install(server, id: "composer-shot-\(name)", messages: messages)
            let host = Host(server: server, agentID: id, size: Self.portrait)
            await host.settle()
            NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
            host.window.layoutIfNeeded()
            expectBoxAtBottom(host, "\(name): right after the screenshot")
            try? await Task.sleep(for: .milliseconds(600))
            host.window.layoutIfNeeded()
            expectBoxAtBottom(host, "\(name): after the system settled")
        }
    }

    @Test func theAppComingBackKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-active", messages: 5)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        host.window.layoutIfNeeded()
        expectBoxAtBottom(host, "after becoming active")
    }

    @Test func aSendKeepsTheBoxAtTheBottomAndTheNewMessageInView() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-send", messages: 30)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.controller.composer.text = "A message that goes out"
        host.controller.composer.send()
        await host.settle()
        expectBoxAtBottom(host, "after a send")
        saveShot(host.window, "layout-after-send")
        #expect(host.controller.composer.text.isEmpty)
        let list = host.controller.collectionView
        // The list slides to the new message (an animation: wait for its end).
        let followed = await eventually { list.contentSize.height - (list.contentOffset.y + list.bounds.height) < 60 }
        #expect(followed, "the list follows the new message")
    }

    @Test func theKeyboardOpeningKeepsTheBoxInsideTheScreen() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-keys", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.controller.composer.textField.becomeFirstResponder()
        host.window.layoutIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        host.window.layoutIfNeeded()
        let view = host.controller.view!
        let box = host.controller.composer.frame
        let list = host.controller.collectionView.frame
        #expect(box.maxY <= view.bounds.maxY - view.safeAreaInsets.bottom + 1)
        #expect(box.minY > list.minY)
        #expect(abs(list.maxY - box.minY) < 1)
        #expect(list.height >= ChatFrameRules.listFloor - 1)
        host.controller.composer.textField.resignFirstResponder()
        try? await Task.sleep(for: .milliseconds(500))
        host.window.layoutIfNeeded()
        expectBoxAtBottom(host, "the keyboard is closed again")
    }

    @Test func aLargeTextSizeKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-type", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        host.window.layoutIfNeeded()
        await host.settle()
        let view = host.controller.view!
        let box = host.controller.composer.frame
        #expect(abs(box.maxY - (view.bounds.maxY - view.safeAreaInsets.bottom)) < 1)
        #expect(host.controller.collectionView.frame.height >= ChatFrameRules.listFloor - 1)
        #expect(abs(host.controller.collectionView.frame.maxY - box.minY) < 1)
    }

    @Test func aQuoteAboveTheBoxGrowsItUpwardOnly() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-quote", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        let before = host.controller.composer.frame.height
        host.controller.reply(to: ReplyTarget(seq: 3, fromUser: false, text: "The message being answered, with some words."))
        host.window.layoutIfNeeded()
        let after = host.controller.composer.frame.height
        #expect(after > before + 30)
        expectBoxAtBottom(host, "with a quote")
        saveShot(host.window, "layout-reply-bar")
        host.controller.setReplyTarget(nil)
        host.window.layoutIfNeeded()
        #expect(abs(host.controller.composer.frame.height - before) < 1)
        expectBoxAtBottom(host, "the quote is gone")
    }

    @Test func aChatInANavigationStackKeepsTheBoxAtTheBottom() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "composer-nav", messages: 0)
        let root = UIHostingController(
            rootView: AnyView(NavigationStack { ChatScreen(server: server, agentID: id, settings: IOSSettings()) }))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Self.portrait))
        window.frame = CGRect(origin: .zero, size: Self.portrait)
        window.rootViewController = root
        window.makeKeyAndVisible()
        func chat(_ controller: UIViewController) -> ChatViewController? {
            if let found = controller as? ChatViewController { return found }
            for child in controller.children { if let found = chat(child) { return found } }
            return nil
        }
        func settle() async {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(30))
                window.layoutIfNeeded()
            }
        }
        func check(_ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
            guard let controller = chat(root) else {
                Issue.record("\(note): no chat", sourceLocation: sourceLocation)
                return
            }
            let view = controller.view!
            #expect(abs(controller.composer.frame.maxY - (view.bounds.maxY - view.safeAreaInsets.bottom)) < 1, "\(note): box \(controller.composer.frame) in \(view.bounds)", sourceLocation: sourceLocation)
            #expect(controller.composer.frame.minY > view.bounds.height * 0.5, "\(note): the box is in the lower half", sourceLocation: sourceLocation)
            #expect(abs(controller.collectionView.frame.maxY - controller.composer.frame.minY) < 1, "\(note): the list ends at the box", sourceLocation: sourceLocation)
        }
        await settle()
        check("empty")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 1...80 {
            server.apply(
                Event(
                    seq: Int64(index), agentId: id, ts: now + Int64(index),
                    body: index % 2 == 0 ? .messageAssistant(text: "Answer \(index)") : .messageUser(text: "Question \(index)", source: .user, fromAgent: nil)))
        }
        await settle()
        check("filled")
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        await settle()
        check("after a screenshot")
        await server.disconnect()
        await settle()
        check("offline")
        await server.connect()
        await settle()
        check("online")
        window.isHidden = true
    }

    // MARK: the keyboard

    /// What the system posts when the keyboard comes up (`top` in screen coordinates; the frame reaches the screen's bottom).
    func postKeyboard(_ name: Notification.Name, top: CGFloat?) {
        let screen = UIScreen.main.bounds
        let frame = CGRect(x: 0, y: top ?? screen.height, width: screen.width, height: top.map { screen.height - $0 } ?? 300)
        NotificationCenter.default.post(
            name: name, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: frame),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.0,
            ])
    }

    func openKeyboard(_ host: Host, top: CGFloat = 500) async {
        host.controller.composer.textField.becomeFirstResponder()
        postKeyboard(UIResponder.keyboardWillShowNotification, top: top)
        host.window.layoutIfNeeded()
    }

    func expectBox(_ host: Host, on top: CGFloat, _ note: String, sourceLocation: SourceLocation = #_sourceLocation) {
        host.window.layoutIfNeeded()
        let box = host.controller.composer.frame
        #expect(abs(box.maxY - top) < 1, "\(note): the box ends at \(box.maxY), the keyboard's top is \(top)", sourceLocation: sourceLocation)
        #expect(abs(host.controller.collectionView.frame.maxY - box.minY) < 1, "\(note): the list ends at the box", sourceLocation: sourceLocation)
    }

    @Test func theBoxSitsOnTheKeyboardTheNotificationReports() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "keys-1", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        await openKeyboard(host)
        expectBox(host, on: 500, "keyboard open")
        postKeyboard(UIResponder.keyboardWillHideNotification, top: nil)
        host.window.layoutIfNeeded()
        host.controller.composer.textField.resignFirstResponder()
        expectBoxAtBottom(host, "keyboard hidden")
        postKeyboard(UIResponder.keyboardDidHideNotification, top: nil)
        expectBoxAtBottom(host, "keyboard did hide")
    }

    @Test func aKeyboardTheBoxDidNotAskForIsNotFollowed() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "keys-2", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        postKeyboard(UIResponder.keyboardWillShowNotification, top: 400)
        expectBoxAtBottom(host, "a keyboard for another field")
    }

    @Test func aWrongGuideWhileTheFieldHasTheKeyboardIsIgnored() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "keys-3", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        await openKeyboard(host)
        for wrong in [CGFloat(50), 0, -200, 700, 900] {
            host.controller.keyboardTracker.frame.origin.y = wrong
            host.controller.placeViews()
            expectBox(host, on: 500, "the guide says \(wrong)")
            #expect(host.controller.collectionView.frame.height >= ChatFrameRules.listFloor)
        }
    }

    @Test func aScreenshotWithTheKeyboardOpenKeepsTheBoxOnIt() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "keys-4", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        await openKeyboard(host)
        NotificationCenter.default.post(name: UIApplication.userDidTakeScreenshotNotification, object: nil)
        host.controller.keyboardTracker.frame.origin.y = 40
        expectBox(host, on: 500, "right after the screenshot")
        try? await Task.sleep(for: .milliseconds(600))
        host.controller.keyboardTracker.frame.origin.y = 40
        host.controller.placeViews()
        // (The simulator may show its own keyboard meanwhile: its notification is then the keyboard.)
        let top = host.controller.keyboardTop()
        #expect(top != nil && top! > 300)
        expectBox(host, on: top ?? 500, "after the system settled")
    }

    @Test func aTraitChangeWithTheKeyboardOpenKeepsTheBoxOnIt() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "keys-5", messages: 10)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        await openKeyboard(host)
        host.controller.overrideUserInterfaceStyle = .light
        host.controller.traitOverrides.preferredContentSizeCategory = .extraExtraLarge
        host.controller.keyboardTracker.frame.origin.y = 60
        host.window.layoutIfNeeded()
        await host.settle()
        host.controller.keyboardTracker.frame.origin.y = 60
        host.controller.placeViews()
        let top = host.controller.keyboardTop()
        #expect(top != nil && top! > 300)
        expectBox(host, on: top ?? 500, "after the traits changed")
    }

    // MARK: width and the banner

    @Test func aNewWidthCountsTheBoxsLinesAgain() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "width-1", messages: 4)
        let host = Host(server: server, agentID: id, size: Self.portrait)
        await host.settle()
        host.controller.composer.text = String(repeating: "word ", count: 40)
        host.window.layoutIfNeeded()
        let narrow = host.controller.composer.frame.height
        host.resize(Self.landscape)
        await host.settle()
        let wide = host.controller.composer.frame.height
        #expect(wide < narrow, "wide \(wide), narrow \(narrow), field \(host.controller.composer.textField.bounds.width), fits \(host.controller.composer.textField.sizeThatFits(CGSize(width: host.controller.composer.textField.bounds.width, height: .greatestFiniteMagnitude)).height), scroll \(host.controller.composer.textField.isScrollEnabled), last \(host.controller.composer.lastFieldWidth), text \(host.controller.composer.text.count)")
        host.resize(Self.portrait)
        await host.settle()
        #expect(abs(host.controller.composer.frame.height - narrow) < 1)
        expectBoxAtBottom(host, "back to portrait")
    }

    @Test func theOfflineBannerWrapsToTwoLinesWithMarginsAndRoundedCorners() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let id = install(server, id: "banner-1", messages: 4)
        let host = Host(server: server, agentID: id, size: CGSize(width: 320, height: 640))
        await server.disconnect()
        await host.settle()
        let banner = host.controller.banner
        host.window.layoutIfNeeded()
        let one = banner.font.lineHeight
        #expect(!banner.isHidden)
        #expect(banner.numberOfLines == 2)
        #expect(banner.frame.minX == BanditoSpace.s3 && abs(banner.frame.width - (320 - 2 * BanditoSpace.s3)) < 1)
        #expect(banner.layer.cornerRadius == BanditoRadius.md)
        #expect(banner.frame.height > one * 1.5 + 2 * BanditoSpace.s2 - 1, "the text wraps: \(banner.frame.height)")
        #expect(banner.frame.height < one * 2.5 + 2 * BanditoSpace.s2, "and no more than two lines")
        saveShot(host.window, "offline-banner")
    }
}
