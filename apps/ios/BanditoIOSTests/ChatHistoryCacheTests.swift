import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import Bandito

/// The chat copy on disk: what is kept, where, for how long, and that it goes with its agent or server.
@Suite(.serialized) struct ChatHistoryCacheTests {
    let serverA = UUID()
    let serverB = UUID()

    func makeCache() -> ChatHistoryCache {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chat-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ChatHistoryCache(directory: directory)
    }

    func thread(messages: Int, extra: [ThreadItem] = []) -> AgentThread {
        var thread = AgentThread()
        thread.items = (1...max(1, messages)).map { index -> ThreadItem in
            index % 2 == 0
                ? .assistant(id: "s\(index)", text: "Answer \(index)", ts: Int64(1_000 + index))
                : .user(id: "s\(index)", text: "Question \(index)", source: .user, from: nil, ts: Int64(1_000 + index))
        } + extra
        return thread
    }

    @Test func aSavedChatComesBackAsItWas() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        var source = thread(messages: 4)
        source.items.append(.note(id: "s5", text: "A note", kind: .info, ts: 1_005))
        source.items.append(.chapter(id: "s6", number: 2, saved: true, ts: 1_006))
        cache.save(ChatHistorySnapshot(thread: source, now: 99), serverID: serverA, agentID: "forge")
        let loaded = try #require(cache.load(serverID: serverA, agentID: "forge"))
        #expect(loaded.savedAt == 99)
        #expect(loaded.thread.items == source.items)
    }

    @Test func aChatNeverSavedIsNotThere() {
        let cache = makeCache()
        #expect(cache.load(serverID: serverA, agentID: "nobody") == nil)
    }

    @Test func onlyTheLast200ItemsAreKept() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        let source = thread(messages: 450)
        cache.save(ChatHistorySnapshot(thread: source, now: 1), serverID: serverA, agentID: "forge")
        let loaded = try #require(cache.load(serverID: serverA, agentID: "forge"))
        #expect(loaded.items.count == ChatHistoryCache.itemLimit)
        #expect(loaded.items.first?.id == "s251")
        #expect(loaded.items.last?.id == "s450")
    }

    @Test func attachmentsAndWhatWaitsForAnAnswerAreNotKept() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        let file = AgentAttachment(path: "/tmp/secret.png", name: "secret.png", size: 10, mime: "image/png")
        var source = AgentThread()
        source.items = [
            .user(id: "s1", text: "Look at this", source: .user, from: nil, ts: 1, attachments: [file]),
            .tool(ToolRow(callId: "c1", tool: "bash", title: "ls", ok: true)),
            .streaming(text: "half a sentence"),
            .assistant(id: "s2", text: "Done", ts: 2),
        ]
        cache.save(ChatHistorySnapshot(thread: source, now: 1), serverID: serverA, agentID: "forge")
        let loaded = try #require(cache.load(serverID: serverA, agentID: "forge"))
        #expect(loaded.items.map(\.id) == ["s1", "s2"])
        let text = String(data: try JSONEncoder().encode(loaded), encoding: .utf8) ?? ""
        #expect(!text.contains("secret.png"))
        #expect(!text.contains("half a sentence"))
        for item in loaded.thread.items {
            if case .user(_, _, _, _, _, let files) = item { #expect(files.isEmpty) }
        }
    }

    @Test func aMessageThatWasOnlyAFileIsKeptAsALineSayingSo() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        let file = AgentAttachment(path: "/tmp/photo.jpg", name: "photo.jpg", size: 10, mime: "image/jpeg")
        var source = AgentThread()
        source.items = [
            .user(id: "s1", text: "", source: .user, from: nil, ts: 1, attachments: [file]),
            .user(id: "s2", text: "With words", source: .user, from: nil, ts: 2, attachments: [file]),
            .user(id: "s3", text: "", source: .user, from: nil, ts: 3),
        ]
        cache.save(ChatHistorySnapshot(thread: source, now: 1), serverID: serverA, agentID: "forge")
        let loaded = try #require(cache.load(serverID: serverA, agentID: "forge"))
        var texts: [String] = []
        for item in loaded.thread.items {
            if case .user(_, let text, _, _, _, _) = item { texts.append(text) }
        }
        // The file-only message says there was a file; the one with words keeps its words; the empty one stays empty.
        #expect(texts == [L10n.Ios.Chat.attachmentPlaceholder, "With words", ""])
        #expect(!L10n.Ios.Chat.attachmentPlaceholder.isEmpty)
        let json = String(data: try JSONEncoder().encode(loaded), encoding: .utf8) ?? ""
        #expect(!json.contains("photo.jpg"))
    }

    @Test func aVeryLongMessageIsCutInTheCopy() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        var source = AgentThread()
        source.items = [.assistant(id: "s1", text: String(repeating: "a", count: 50_000), ts: 1)]
        cache.save(ChatHistorySnapshot(thread: source, now: 1), serverID: serverA, agentID: "forge")
        let loaded = try #require(cache.load(serverID: serverA, agentID: "forge"))
        #expect(loaded.items[0].text.count == CachedChatItem.textLimit + 1)
    }

    /// A thread built by the daemon's events: message n has seq n; every 3rd of the user's messages answers the one before.
    func eventThread(messages: Int) -> AgentThread {
        var thread = AgentThread()
        for seq in 1...messages {
            let body: EventBody =
                seq % 2 == 0
                ? .messageAssistant(text: "Answer \(seq)")
                : .messageUser(text: "Question \(seq)", source: .user, fromAgent: nil, replyTo: seq > 2 ? Int64(seq - 1) : nil)
            thread.apply(Event(seq: Int64(seq), agentId: "forge", ts: Int64(1_000 + seq), body: body))
        }
        return thread
    }

    @Test func repliesAndReactionsOfKeptMessagesComeBack() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        var source = eventThread(messages: 260)
        source.apply(Event(seq: 261, agentId: "forge", ts: 5_000, body: .reaction(seq: 260, emoji: "🔥", by: .user)))
        source.apply(Event(seq: 262, agentId: "forge", ts: 5_001, body: .reaction(seq: 3, emoji: "👍", by: .agent)))
        let snapshot = ChatHistorySnapshot(thread: source, now: 1)
        // Only the newest 200 are kept, and with them only their own replies and reactions.
        #expect(snapshot.items.count == 200)
        #expect(snapshot.replies.allSatisfy { $0.seq > 60 })
        #expect(snapshot.reactions.map(\.seq) == [260])
        cache.save(snapshot, serverID: serverA, agentID: "forge")
        let loaded = try #require(cache.load(serverID: serverA, agentID: "forge"))
        #expect(loaded.replyMap == snapshot.replyMap)
        #expect(loaded.replyMap[259] == 258)
        #expect(loaded.reactionMap[260] == [ChatReactionChip(emoji: "🔥", byUser: true, byAgent: false)])
    }

    @Test func eachServerAndEachAgentHasItsOwnCopy() throws {
        let cache = makeCache()
        defer {
            cache.remove(serverID: serverA)
            cache.remove(serverID: serverB)
        }
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "forge")
        cache.save(ChatHistorySnapshot(thread: thread(messages: 4), now: 2), serverID: serverA, agentID: "scout")
        cache.save(ChatHistorySnapshot(thread: thread(messages: 6), now: 3), serverID: serverB, agentID: "forge")
        #expect(try #require(cache.load(serverID: serverA, agentID: "forge")).items.count == 2)
        #expect(try #require(cache.load(serverID: serverA, agentID: "scout")).items.count == 4)
        #expect(try #require(cache.load(serverID: serverB, agentID: "forge")).items.count == 6)
    }

    @Test func aDeletedAgentTakesItsCopyOnly() {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "forge")
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "scout")
        cache.remove(serverID: serverA, agentID: "forge")
        #expect(cache.load(serverID: serverA, agentID: "forge") == nil)
        #expect(cache.load(serverID: serverA, agentID: "scout") != nil)
    }

    @Test func aForgottenServerTakesAllItsCopies() {
        let cache = makeCache()
        defer { cache.remove(serverID: serverB) }
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "forge")
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "scout")
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverB, agentID: "forge")
        cache.remove(serverID: serverA)
        #expect(cache.savedAgentFiles(serverID: serverA).isEmpty)
        #expect(cache.load(serverID: serverB, agentID: "forge") != nil)
    }

    @Test func pruningKeepsTheAgentsTheServerStillHas() {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        for agent in ["forge", "scout", "gone"] {
            cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: agent)
        }
        cache.prune(serverID: serverA, keeping: ["forge", "scout"])
        #expect(cache.load(serverID: serverA, agentID: "gone") == nil)
        #expect(cache.load(serverID: serverA, agentID: "forge") != nil)
        #expect(cache.load(serverID: serverA, agentID: "scout") != nil)
        // A server with no copies, and an empty list of agents, do no harm.
        cache.prune(serverID: serverB, keeping: [])
        cache.prune(serverID: serverA, keeping: [])
        #expect(cache.savedAgentFiles(serverID: serverA).isEmpty)
    }

    @Test func aFileThatDoesNotReadIsRemovedAndNothingIsShown() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "forge")
        let name = try #require(cache.savedAgentFiles(serverID: serverA).first)
        let url = cache.directory.appending(path: serverA.uuidString).appending(path: name)
        try Data("{ not json".utf8).write(to: url)
        #expect(cache.load(serverID: serverA, agentID: "forge") == nil)
        #expect(cache.savedAgentFiles(serverID: serverA).isEmpty)
    }

    @Test func aCopyOfANewerFormatIsNotShown() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        var snapshot = ChatHistorySnapshot(thread: thread(messages: 2), now: 1)
        snapshot.version = ChatHistorySnapshot.currentVersion + 1
        cache.save(snapshot, serverID: serverA, agentID: "forge")
        #expect(cache.load(serverID: serverA, agentID: "forge") == nil)
    }

    @Test func anAgentIdNeverBecomesAPath() {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        for hostile in ["../../escape", "a/b", "..", "", "ünï cødé", "x.json"] {
            cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: hostile)
            #expect(cache.load(serverID: serverA, agentID: hostile) != nil, "\(hostile)")
        }
        let names = cache.savedAgentFiles(serverID: serverA)
        #expect(names.count == 6)
        #expect(names.allSatisfy { !$0.contains("/") && $0.hasSuffix(".json") })
        // Nothing was written outside the cache folder.
        let parent = cache.directory.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: parent.appending(path: "escape.json").path))
    }

    @Test func theFilesAreProtectedUntilFirstUnlockAndOutOfTheBackup() throws {
        let cache = makeCache()
        defer { cache.remove(serverID: serverA) }
        cache.save(ChatHistorySnapshot(thread: thread(messages: 2), now: 1), serverID: serverA, agentID: "forge")
        let folder = cache.directory.appending(path: serverA.uuidString)
        let file = folder.appending(path: ChatHistoryCache.fileName("forge"))
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try cache.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // The Simulator may not report a protection class; a device must report this one.
        for url in [file, folder, cache.directory] {
            let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
            if let protection {
                #expect(protection == .completeUntilFirstUserAuthentication, "\(url.lastPathComponent)")
            }
        }
    }

    @Test func theDefaultFolderIsInApplicationSupport() {
        let path = ChatHistoryCache.defaultDirectory.path
        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("ChatCache"))
    }
}
