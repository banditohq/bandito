import BanditoKit
import BanditoL10n
import Foundation
import Testing
import UIKit

@testable import Bandito

typealias ChatHost = ChatComposerLayoutTests.Host


/// What the chat shows while the history is read, when it cannot be read, and from the copy on disk.
@MainActor
@Suite(.serialized) struct ChatSavedHistoryTests {
    func offlineServer(agent id: String = "forge") -> ServerModel {
        let server = ServerModel(config: ServerConfig(name: "Mac", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:9/chat-test")!)))
        server.seedCachedAgents([Agent(id: id, name: "Forge", runtime: .claude, cwd: "/work")])
        return server
    }

    func tempCache() -> ChatHistoryCache {
        ChatHistoryCache(directory: FileManager.default.temporaryDirectory.appending(path: "chat-saved-\(UUID().uuidString)", directoryHint: .isDirectory))
    }

    func snapshot(_ texts: [String]) -> ChatHistorySnapshot {
        var thread = AgentThread()
        thread.items = texts.enumerated().map { index, text in
            index % 2 == 0
                ? .user(id: "s\(index + 1)", text: text, source: .user, from: nil, ts: Int64(1_000 + index))
                : .assistant(id: "s\(index + 1)", text: text, ts: Int64(1_000 + index))
        }
        return ChatHistorySnapshot(thread: thread, now: 1)
    }

    func texts(_ model: ChatModel) -> [String] {
        model.rows.compactMap { row -> String? in
            if case .message(let message) = row.content { return message.text }
            return nil
        }
    }

    @Test func aChatOpensWithItsSavedHistoryWithNoConnection() async {
        let server = offlineServer()
        let cache = tempCache()
        defer { cache.remove(serverID: server.id) }
        cache.save(snapshot(["Cached question", "Cached answer"]), serverID: server.id, agentID: "forge")
        let host = ChatHost(server: server, agentID: "forge", size: ChatComposerLayoutTests.portrait, history: cache)
        await host.settle()
        try? await Task.sleep(for: .milliseconds(100))
        await host.settle()
        #expect(texts(host.model) == ["Cached question", "Cached answer"])
        #expect(host.model.showsSavedHistory)
        // The history is there: neither "could not load" nor the empty chat's invitation takes its place.
        #expect(host.controller.overlayMode == .none)
        #expect(!host.controller.showsEmptyState)
        #expect(host.controller.collectionView.numberOfItems(inSection: 0) >= 2)
        saveShot(host.window, "offline-with-saved-history")
    }

    @Test func theRealHistoryReplacesTheCopyAndIsNotMergedWithIt() async {
        let server = offlineServer()
        let cache = tempCache()
        defer { cache.remove(serverID: server.id) }
        cache.save(snapshot(["Cached question", "Cached answer"]), serverID: server.id, agentID: "forge")
        let host = ChatHost(server: server, agentID: "forge", size: ChatComposerLayoutTests.portrait, history: cache)
        await host.settle()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(texts(host.model).contains("Cached answer"))
        // The server's thread arrives (events make a loaded thread).
        server.apply(Event(seq: 1, agentId: "forge", ts: 5_000, body: .messageUser(text: "Fresh question", source: .user, fromAgent: nil)))
        server.apply(Event(seq: 2, agentId: "forge", ts: 5_001, body: .messageAssistant(text: "Fresh answer")))
        let replaced = await eventually { texts(host.model) == ["Fresh question", "Fresh answer"] }
        #expect(replaced, "the rows are \(texts(host.model))")
        #expect(!host.model.showsSavedHistory)
    }

    @Test func aChatWithNoCopyAndNoConnectionSaysSoAndOffersTryAgain() async {
        let server = offlineServer()
        let cache = tempCache()
        let host = ChatHost(server: server, agentID: "forge", size: ChatComposerLayoutTests.portrait, history: cache)
        await host.settle()
        try? await Task.sleep(for: .milliseconds(150))
        await host.settle()
        #expect(host.model.loadFailed)
        #expect(host.controller.overlayMode == .failed(name: "Forge"))
        #expect(!host.controller.showsEmptyState)
        saveShot(host.window, "load-failed")
        // The box is still at the bottom and the list has its room.
        let view = host.controller.view!
        #expect(abs(host.controller.composer.frame.maxY - (view.bounds.maxY - view.safeAreaInsets.bottom)) < 1)
        // "Try again" asks again; the connection is still not there, so the message stays (and nothing crashes).
        host.model.retryLoad()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(host.controller.overlayMode == .failed(name: "Forge"))
    }

    @Test func theFailureGivesWayWhenTheThreadComes() async {
        let server = offlineServer()
        let host = ChatHost(server: server, agentID: "forge", size: ChatComposerLayoutTests.portrait, history: nil)
        await host.settle()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(host.controller.overlayMode == .failed(name: "Forge"))
        server.apply(Event(seq: 1, agentId: "forge", ts: 5_000, body: .messageAssistant(text: "Back again")))
        let shown = await eventually { texts(host.model) == ["Back again"] && host.controller.overlayMode == .none }
        #expect(shown, "rows \(texts(host.model)), overlay \(host.controller.overlayMode)")
    }

    @Test func aChatIsSavedWhenItsScreenGoes() async throws {
        let server = offlineServer()
        let cache = tempCache()
        defer { cache.remove(serverID: server.id) }
        server.apply(Event(seq: 1, agentId: "forge", ts: 5_000, body: .messageUser(text: "Keep me", source: .user, fromAgent: nil)))
        server.apply(Event(seq: 2, agentId: "forge", ts: 5_001, body: .messageAssistant(text: "Kept")))
        let model = ChatModel(server: server, agentID: "forge", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: cache)
        model.start()
        await model.settle()
        model.stop()
        let saved = try #require(cache.load(serverID: server.id, agentID: "forge"))
        #expect(saved.items.map(\.text) == ["Keep me", "Kept"])
    }

    @Test func aSyntheticAgentIsNeverSaved() async {
        let (server, _) = await IOSDemo.startWithTransport()
        let cache = tempCache()
        defer { cache.remove(serverID: server.id) }
        let model = ChatModel(server: server, agentID: "ios-demo-1", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: cache)
        model.start()
        await model.settle()
        model.saveNow()
        model.stop()
        #expect(cache.savedAgentFiles(serverID: server.id).isEmpty)
    }

    @Test func aNewAgentsChatIsEmptyWithItsInvitationAndTheBoxAtTheBottom() async {
        // A server of its own (the demo daemon answers every agent with a changes card).
        let server = offlineServer(agent: "other")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(id: "fresh", name: "Fresh", role: "r", runtime: .claude, cwd: "/work", createdAt: now, updatedAt: now, status: .idle),
            items: [])
        let host = ChatHost(server: server, agentID: "fresh", size: ChatComposerLayoutTests.portrait)
        await host.settle()
        try? await Task.sleep(for: .milliseconds(100))
        await host.settle()
        let invited = await eventually { host.controller.showsEmptyState }
        saveShot(host.window, "empty-chat")
        #expect(invited, "loading \(host.model.isLoading) busy \(host.model.isBusy) failed \(host.model.loadFailed) rows \(host.model.rows.map { String(String(describing: $0.content).prefix(120)) })")
        #expect(host.controller.overlayMode == .none)
        let view = host.controller.view!
        #expect(abs(host.controller.composer.frame.maxY - (view.bounds.maxY - view.safeAreaInsets.bottom)) < 1)
    }

    @Test func forgettingAServerRemovesItsSavedChats() throws {
        let cache = tempCache()
        let store = ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: UserDefaults(suiteName: "ios-chat-cache-\(UUID().uuidString)")!)
        let session = ServerSession(store: store, secrets: MemorySecrets(), connect: { _ in }, cache: AgentListCache(directory: FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString)")), chatHistory: cache)
        session.forgetCursor = { _ in }
        try session.add(ServerConfig(name: "Mac", endpoint: .direct(hosts: ["10.0.0.2:7879"], fingerprint: ConnectTests.fp), token: "tok"))
        let id = try #require(session.servers.first?.id)
        cache.save(snapshot(["One"]), serverID: id, agentID: "forge")
        cache.save(snapshot(["Two"]), serverID: id, agentID: "scout")
        session.remove(id)
        #expect(cache.savedAgentFiles(serverID: id).isEmpty)
        #expect(cache.load(serverID: id, agentID: "forge") == nil)
    }
}

/// The chat is read when its end is seen: a short list, the app coming back, rows that come in, an Activity entry.
@MainActor
@Suite(.serialized) struct ChatReadOnOpenTests {
    func install(_ server: ServerModel, id: String, messages: Int) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(id: id, name: "Reader", role: "r", runtime: .claude, cwd: DemoDaemonFiles.projects, createdAt: now, updatedAt: now, status: .idle),
            items: (0..<messages).map { index -> ThreadItem in
                let ts = now - Int64(messages - index) * 60_000
                return index % 2 == 0
                    ? .user(id: "s\(index + 1)", text: "Question \(index): how does it work?", source: .user, from: nil, ts: ts)
                    : .assistant(id: "s\(index + 1)", text: "An answer \(index), a few words of it.", ts: ts)
            })
        // Read to the end now; replies that come later are the unread ones.
        server.threadSummary(for: id).markRead()
    }

    func arrive(_ text: String, on server: ServerModel, agent id: String) {
        let seq = server.thread(for: id).lastSeq + 1
        server.apply(Event(seq: seq, agentId: id, ts: Int64(Date().timeIntervalSince1970 * 1000), body: .messageAssistant(text: text)))
    }

    func unread(_ server: ServerModel, _ id: String) -> Int { server.threadSummary(for: id).unreadCount }

    func open(_ server: ServerModel, _ id: String, active: Bool = true, focus: String? = nil) async -> ChatHost {
        let host = ChatHost(server: server, agentID: id, size: ChatComposerLayoutTests.portrait, deferred: true)
        host.controller.isAppActive = { active }
        host.controller.focusRowID = focus
        host.show()
        await host.settle()
        return host
    }

    @Test func aShortChatWithAnUnreadReplyIsReadWhenOpened() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-short", messages: 3)
        arrive("A new reply", on: server, agent: "read-short")
        #expect(unread(server, "read-short") == 1)
        let host = await open(server, "read-short")
        #expect(host.controller.collectionView.contentSize.height < host.controller.collectionView.bounds.height, "the whole chat fits")
        let read = await eventually { unread(server, "read-short") == 0 }
        #expect(read, "a chat that fits is read when it opens")
    }

    @Test func aChatOpenedWhileTheAppIsInTheBackgroundIsReadWhenTheAppComesBack() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-active", messages: 3)
        arrive("A new reply", on: server, agent: "read-active")
        var active = false
        let host = ChatHost(server: server, agentID: "read-active", size: ChatComposerLayoutTests.portrait, deferred: true)
        host.controller.isAppActive = { active }
        host.show()
        await host.settle()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(unread(server, "read-active") == 1)
        active = true
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let read = await eventually { unread(server, "read-active") == 0 }
        #expect(read)
    }

    @Test func aReplyThatComesWhileTheChatIsOpenIsRead() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-live", messages: 6)
        let host = await open(server, "read-live")
        arrive("Right now", on: server, agent: "read-live")
        let read = await eventually { unread(server, "read-live") == 0 }
        #expect(read)
    }

    @Test func aLongChatReadFromTheMiddleIsNotReadUntilItsEndIsSeen() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-long", messages: 80)
        let host = await open(server, "read-long")
        host.controller.collectionView.setContentOffset(.zero, animated: false)
        host.window.layoutIfNeeded()
        arrive("While reading above", on: server, agent: "read-long")
        try? await Task.sleep(for: .milliseconds(300))
        await host.settle()
        #expect(unread(server, "read-long") == 1, "the person is far from the end")
        host.controller.scrollToBottom(animated: false)
        host.window.layoutIfNeeded()
        let read = await eventually { unread(server, "read-long") == 0 }
        #expect(read)
    }

    @Test func aChatOnAnInactiveAppIsNotRead() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-inactive", messages: 3)
        arrive("Unseen", on: server, agent: "read-inactive")
        _ = await open(server, "read-inactive", active: false)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(unread(server, "read-inactive") == 1)
    }

    @Test func anActivityEntryOpensTheChatAtItsRowAndReadsIt() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-entry", messages: 80)
        arrive("The entry", on: server, agent: "read-entry")
        #expect(unread(server, "read-entry") == 1)
        let host = await open(server, "read-entry", focus: "s10")
        #expect(!host.controller.atBottom, "the chat is at the entry's row, not at the end")
        #expect(host.controller.position(of: "s10").map { abs($0) < 60 } == true)
        let read = await eventually { unread(server, "read-entry") == 0 }
        #expect(read)
    }

    @Test func anEntryThatIsNotInTheHistoryStillOpensTheChatAtTheEnd() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "read-gone", messages: 40)
        arrive("Latest", on: server, agent: "read-gone")
        let host = await open(server, "read-gone", focus: "s9999")
        #expect(host.controller.atBottom)
        let read = await eventually { unread(server, "read-gone") == 0 }
        #expect(read)
    }
}

/// A long press on a message: reactions go to the daemon and show at once, a reply goes out with its quote.
@MainActor
@Suite(.serialized) struct ChatReactAndReplyTests {
    func install(_ server: ServerModel, id: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(id: id, name: "Talker", role: "r", runtime: .claude, cwd: DemoDaemonFiles.projects, createdAt: now, updatedAt: now, status: .idle),
            items: [
                .user(id: "s1", text: "Question", source: .user, from: nil, ts: now - 3_000),
                .assistant(id: "s2", text: "An answer worth a reaction.", ts: now - 2_000),
            ])
    }

    func message(_ model: ChatModel, seq: Int64) -> ChatMessage? {
        for row in model.rows {
            if case .message(let message) = row.content, message.seq == seq { return message }
        }
        return nil
    }

    @Test func aReactionIsSentAndShownBeforeTheDaemonAnswers() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "react-1")
        #expect(server.supports("reactions"))
        let model = ChatModel(server: server, agentID: "react-1", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: nil)
        model.setMetrics(ChatMetrics(width: 390, category: .large))
        model.start()
        await model.settle()
        #expect(message(model, seq: 2)?.canReact == true)
        let sent = await model.react("🔥", seq: 2)
        #expect(sent)
        await model.settle()
        #expect(message(model, seq: 2)?.reactions == [ChatReactionChip(emoji: "🔥", byUser: true, byAgent: false)])
        // Taking it off.
        let off = await model.react(nil, seq: 2)
        #expect(off)
        await model.settle()
        #expect(message(model, seq: 2)?.reactions.isEmpty == true)
        model.stop()
    }

    @Test func aServerWithoutReactionsTakesNone() async {
        let server = ServerModel(config: ServerConfig(name: "Old", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:9/old")!)))
        let model = ChatModel(server: server, agentID: "x", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: nil)
        let sent = await model.react("👍", seq: 1)
        #expect(!sent)
    }

    @Test func aReplyGoesOutWithTheSeqOfTheMessageItAnswers() async throws {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "reply-1")
        let host = ChatHost(server: server, agentID: "reply-1", size: ChatComposerLayoutTests.portrait)
        await host.settle()
        host.controller.reply(to: ReplyTarget(seq: 2, fromUser: false, text: "An answer worth a reaction."))
        #expect(host.controller.composer.hasReply)
        #expect(host.controller.currentReplyTarget?.seq == 2)
        host.controller.composer.text = "Yes, do it"
        host.controller.composer.send()
        await host.settle()
        let queued = host.model.outbox.items(serverID: server.id, agentID: "reply-1")
        let item = try #require(queued.first { $0.text == "Yes, do it" })
        #expect(item.replyTo == 2)
        // The quote is gone from the box after the send; the next message is a plain one.
        #expect(!host.controller.composer.hasReply)
        #expect(host.controller.currentReplyTarget == nil)
        host.controller.composer.text = "And another"
        host.controller.composer.send()
        await host.settle()
        let second = try #require(host.model.outbox.items(serverID: server.id, agentID: "reply-1").first { $0.text == "And another" })
        #expect(second.replyTo == nil)
    }

    @Test func theQuoteCanBeCancelled() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "reply-2")
        let host = ChatHost(server: server, agentID: "reply-2", size: ChatComposerLayoutTests.portrait)
        await host.settle()
        host.controller.reply(to: ReplyTarget(seq: 1, fromUser: true, text: "Question"))
        host.controller.composer.onCancelReply?()
        #expect(!host.controller.composer.hasReply)
        #expect(host.controller.currentReplyTarget == nil)
    }

    @Test func aMessageThatIsAReplyShowsItsQuote() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "reply-3")
        server.apply(
            Event(
                seq: 3, agentId: "reply-3", ts: Int64(Date().timeIntervalSince1970 * 1000),
                body: .messageUser(text: "About that", source: .user, fromAgent: nil, replyTo: 2)))
        let model = ChatModel(server: server, agentID: "reply-3", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: nil)
        model.setMetrics(ChatMetrics(width: 390, category: .large))
        model.start()
        await model.settle()
        let reply = message(model, seq: 3)
        #expect(reply?.reply?.seq == 2)
        #expect(reply?.reply?.excerpt?.hasPrefix("An answer") == true)
        model.stop()
    }

    @Test func reactionsAndAQuoteAreDrawnInTheList() async {
        let (server, _) = await IOSDemo.startWithTransport()
        install(server, id: "draw-1")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.apply(Event(seq: 3, agentId: "draw-1", ts: now, body: .messageUser(text: "About that answer: ship it", source: .user, fromAgent: nil, replyTo: 2)))
        server.apply(Event(seq: 4, agentId: "draw-1", ts: now + 1, body: .reaction(seq: 2, emoji: "🔥", by: .user)))
        server.apply(Event(seq: 5, agentId: "draw-1", ts: now + 2, body: .reaction(seq: 2, emoji: "👍", by: .agent)))
        server.apply(Event(seq: 6, agentId: "draw-1", ts: now + 3, body: .messageAssistant(text: "Shipped. Anything else?")))
        server.apply(Event(seq: 7, agentId: "draw-1", ts: now + 4, body: .reaction(seq: 3, emoji: "👍", by: .agent)))
        let host = ChatHost(server: server, agentID: "draw-1", size: ChatComposerLayoutTests.portrait)
        let drawn = await eventually {
            self.message(host.model, seq: 3)?.reply != nil && self.message(host.model, seq: 2)?.reactions.count == 2
        }
        #expect(drawn)
        await host.settle()
        host.controller.collectionView.layoutIfNeeded()
        let cells = host.controller.collectionView.visibleCells.compactMap { $0.accessibilityLabel }
        #expect(cells.contains { $0.contains("🔥") && $0.contains("👍") }, "the reactions are in the message's spoken text: \(cells)")
        #expect(cells.contains { $0.contains("\(L10n.Thread.reply) Talker") }, "the quote is spoken: \(cells)")
        saveShot(host.window, "reactions-and-quote")
    }
}

/// Older pages are read to find something to show; a page that fails is a failure the screen says, not a spinner for good.
@MainActor
@Suite(.serialized) struct ChatOlderPagesTests {
    struct Boom: Error {}

    final class Reads: @unchecked Sendable {
        var count = 0
        var fail = true
    }

    /// A connected demo server with no script: it has no changes card to put in an empty chat.
    func plainServer() async -> ServerModel {
        let (server, _) = DemoDaemon.server(id: UUID(), name: "Plain", setup: DemoDaemonSetup(agentIDs: []))
        await server.connect()
        return server
    }

    func emptyAgent(on server: ServerModel, id: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        server.installSyntheticAgent(
            Agent(id: id, name: "Older", role: "r", runtime: .claude, cwd: DemoDaemonFiles.projects, createdAt: now, updatedAt: now, status: .idle),
            items: [])
    }

    @Test func aFailedOlderPageIsAFailureWithTryAgainNotASpinner() async {
        let server = await plainServer()
        emptyAgent(on: server, id: "older-fail")
        let reads = Reads()
        let model = ChatModel(server: server, agentID: "older-fail", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: nil)
        model.olderSource = ChatModel.OlderSource(
            hasMore: { true },
            read: {
                reads.count += 1
                if reads.fail { throw Boom() }
            })
        let host = ChatHost(model: model, server: server, size: ChatComposerLayoutTests.portrait)
        let failed = await eventually { host.controller.overlayMode == .failed(name: "Older") }
        #expect(failed, "overlay \(host.controller.overlayMode), busy \(model.isBusy), older failed \(model.olderFailed)")
        #expect(model.olderFailed && !model.isBusy)
        #expect(!host.controller.showsEmptyState)
        // It does not go on asking by itself.
        let before = reads.count
        try? await Task.sleep(for: .milliseconds(300))
        #expect(reads.count == before)
        // "Try again" asks again; this time the page comes with a message.
        reads.fail = false
        model.olderSource.read = {
            reads.count += 1
            server.apply(Event(seq: 1, agentId: "older-fail", ts: Int64(Date().timeIntervalSince1970 * 1000), body: .messageAssistant(text: "Found it")))
        }
        model.retryLoad()
        let found = await eventually { host.controller.overlayMode == .none && !model.rows.isEmpty }
        #expect(found)
        #expect(!model.olderFailed)
    }

    @Test func onlyPagesThatCameEmptyCountTowardTheLimit() async {
        let server = await plainServer()
        emptyAgent(on: server, id: "older-empty")
        let reads = Reads()
        reads.fail = false
        let model = ChatModel(server: server, agentID: "older-empty", engine: ChatLayoutEngine(), outbox: ChatOutbox(file: nil), history: nil)
        model.olderSource = ChatModel.OlderSource(
            hasMore: { true },
            read: {
                reads.count += 1
                // The page came and shows nothing.
            })
        model.setMetrics(ChatMetrics(width: 390, category: .large))
        model.start()
        let stopped = await eventually(8) { reads.count >= ChatModel.emptyPageLimit && !model.isBusy }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(stopped)
        #expect(reads.count == ChatModel.emptyPageLimit, "pages read: \(reads.count)")
        #expect(!model.olderFailed)
        model.stop()
    }
}
