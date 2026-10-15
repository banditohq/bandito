import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The share rules, and the importer driven with a fake server: the order, what waits, what goes, and that a task is
/// removed only after its message is in the outbox.
@MainActor @Suite struct ShareImporterTests {
    private let server = UUID()
    private let online = ShareServerFacts(connected: true, agentsKnown: true, hasAgent: true)

    private func task(_ text: String, images: [String] = [], at seconds: TimeInterval, agent: String = "forge", serverID: UUID? = nil)
        -> SharedTask
    {
        SharedTask(
            id: UUID(), serverID: (serverID ?? server).uuidString, agentID: agent, text: text, images: images,
            createdAt: Date(timeIntervalSince1970: seconds))
    }

    private final class Log {
        var queued: [String] = []
        var uploads: [String] = []
        var inboxCountAtEnqueue: [Int] = []
        var failUploads = false
    }

    private func makeImporter(facts: ShareServerFacts?, loaded: Bool = true, log: Log) throws -> (ShareImporter, ShareInbox, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("share-importer-\(UUID().uuidString)")
        let inbox = ShareInbox(root: base.appendingPathComponent("Share", isDirectory: true))
        try FileManager.default.createDirectory(at: inbox.root, withIntermediateDirectories: true)
        let environment = ShareImporterEnvironment(
            serversLoaded: { loaded },
            facts: { _, _ in facts },
            upload: { _, _, _, name in
                if log.failUploads { throw CancellationError() }
                log.uploads.append(name)
                return AgentAttachment(path: "/a/\(name)", name: name, size: 1, mime: "image/jpeg")
            },
            enqueue: { _, _, text, attachments in
                log.queued.append("\(text)|\(attachments.count)")
                log.inboxCountAtEnqueue.append(inbox.pending().count)
            })
        return (ShareImporter(inbox: inbox, environment: environment), inbox, base)
    }

    // MARK: the rule

    @Test func ruleDecidesFromTheTaskAndTheServer() {
        let withText = task("hi", at: 1)
        let onlyPicture = task("", images: ["0.jpg"], at: 1)
        let nothing = task("  \n", at: 1)
        #expect(ShareImportRule.decide(withText, facts: online) == .send)
        #expect(ShareImportRule.decide(nothing, facts: online) == .drop)
        #expect(ShareImportRule.decide(withText, facts: nil) == .drop)
        #expect(ShareImportRule.decide(withText, facts: .init(connected: true, agentsKnown: true, hasAgent: false)) == .drop)
        // Not connected: the agent list may be stale or empty, so the task is not judged by it.
        #expect(ShareImportRule.decide(withText, facts: .init(connected: false, agentsKnown: false, hasAgent: false)) == .send)
        #expect(ShareImportRule.decide(withText, facts: .init(connected: true, agentsKnown: false, hasAgent: false)) == .send)
        #expect(ShareImportRule.decide(onlyPicture, facts: .init(connected: false, agentsKnown: true, hasAgent: true)) == .wait)
        #expect(ShareImportRule.decide(onlyPicture, facts: online) == .send)
    }

    // MARK: the importer

    @Test func tasksGoInOrderAndAreRemovedAfterTheyAreQueued() async throws {
        let log = Log()
        let (importer, inbox, base) = try makeImporter(facts: online, log: log)
        defer { try? FileManager.default.removeItem(at: base) }
        try inbox.save(task("second", at: 20), images: [])
        try inbox.save(task("first", at: 10), images: [])
        await importer.drain()
        #expect(log.queued == ["first|0", "second|0"])
        // When the first was queued both were still in the inbox, when the second was, one was.
        #expect(log.inboxCountAtEnqueue == [2, 1])
        #expect(inbox.pending().isEmpty)
        await importer.drain()
        #expect(log.queued.count == 2, "a task already sent is not sent again")
    }

    @Test func picturesAreUploadedThenQueuedWithTheirAttachments() async throws {
        let log = Log()
        let (importer, inbox, base) = try makeImporter(facts: online, log: log)
        defer { try? FileManager.default.removeItem(at: base) }
        try inbox.save(task("see", at: 10), images: [Data([1]), Data([2])])
        await importer.drain()
        #expect(log.uploads.count == 2)
        #expect(log.queued == ["see|2"])
        #expect(inbox.pending().isEmpty)
    }

    @Test func aTaskWithPicturesWaitsForTheConnection() async throws {
        let log = Log()
        let offline = ShareServerFacts(connected: false, agentsKnown: true, hasAgent: true)
        let (importer, inbox, base) = try makeImporter(facts: offline, log: log)
        defer { try? FileManager.default.removeItem(at: base) }
        try inbox.save(task("pic", at: 10), images: [Data([1])])
        try inbox.save(task("text only", at: 20), images: [])
        await importer.drain()
        #expect(log.queued == ["text only|0"], "a text goes into the outbox, which waits for the server itself")
        #expect(inbox.pending().map(\.text) == ["pic"])
    }

    @Test func aFailedUploadKeepsTheTaskForNextTime() async throws {
        let log = Log()
        log.failUploads = true
        let (importer, inbox, base) = try makeImporter(facts: online, log: log)
        defer { try? FileManager.default.removeItem(at: base) }
        try inbox.save(task("pic", at: 10), images: [Data([1])])
        await importer.drain()
        #expect(log.queued.isEmpty)
        #expect(inbox.pending().count == 1)
        log.failUploads = false
        await importer.drain()
        #expect(log.queued == ["pic|1"])
        #expect(inbox.pending().isEmpty)
    }

    @Test func aGoneServerOrAgentDropsTheTaskAndAnUnloadedListDoesNot() async throws {
        let log = Log()
        let (gone, goneInbox, goneBase) = try makeImporter(facts: nil, log: log)
        defer { try? FileManager.default.removeItem(at: goneBase) }
        try goneInbox.save(task("x", at: 10), images: [])
        await gone.drain()
        #expect(goneInbox.pending().isEmpty)

        let (early, earlyInbox, earlyBase) = try makeImporter(facts: nil, loaded: false, log: log)
        defer { try? FileManager.default.removeItem(at: earlyBase) }
        try earlyInbox.save(task("x", at: 10), images: [])
        await early.drain()
        #expect(earlyInbox.pending().count == 1, "servers not read yet: nothing is judged")
        #expect(log.queued.isEmpty)
    }

    @Test func theLinkOpensTheChatOnceAndOnlyForARealTask() async throws {
        let log = Log()
        let (importer, inbox, base) = try makeImporter(facts: online, log: log)
        defer { try? FileManager.default.removeItem(at: base) }
        let stored = try inbox.save(task("hi", at: 10, agent: "scout"), images: [])
        let before = try #require(importer.target(of: stored.id))
        #expect(before.agent == "scout" && before.server == server)
        await importer.drain()
        #expect(importer.target(of: stored.id) != nil, "the task was queued before the link was read")
        #expect(importer.target(of: stored.id) == nil, "a link used twice does nothing")
        #expect(importer.target(of: UUID()) == nil)
    }

    @Test func twoDrainsAtOnceSendEachTaskOnce() async throws {
        let log = Log()
        let (importer, inbox, base) = try makeImporter(facts: online, log: log)
        defer { try? FileManager.default.removeItem(at: base) }
        try inbox.save(task("a", at: 10), images: [])
        try inbox.save(task("b", at: 20), images: [])
        async let first: Void = importer.drain()
        async let second: Void = importer.drain()
        _ = await (first, second)
        #expect(log.queued == ["a|0", "b|0"])
    }
}

@Suite struct ShareRulesTests {
    @Test func linkGoesOnANewLineAfterTheText() {
        #expect(ShareRules.compose(texts: ["Title"], urls: ["https://a.dev"]) == "Title\nhttps://a.dev")
        #expect(ShareRules.compose(texts: [], urls: ["https://a.dev"]) == "https://a.dev")
        #expect(ShareRules.compose(texts: ["  hi  \n"], urls: []) == "hi")
        #expect(ShareRules.compose(texts: [" ", ""], urls: []) == "")
    }

    @Test func repeatedTextAndLinksAreNotWrittenTwice() {
        #expect(ShareRules.compose(texts: ["x", "x"], urls: []) == "x")
        #expect(ShareRules.compose(texts: ["https://a.dev"], urls: ["https://a.dev"]) == "https://a.dev")
        #expect(ShareRules.compose(texts: ["see https://a.dev now"], urls: ["https://a.dev"]) == "see https://a.dev now")
    }

    @Test func theLastAgentComesFirstIfStillListed() {
        let a = WidgetSnapshot.Listing(server: "S", id: "a", name: "A", role: "")
        let b = WidgetSnapshot.Listing(server: "S", id: "b", name: "B", role: "")
        let c = WidgetSnapshot.Listing(server: "T", id: "a", name: "A", role: "")
        #expect(ShareRules.order([a, b, c], last: "S/b") == [b, a, c])
        #expect(ShareRules.order([a, b, c], last: "T/a") == [c, a, b])
        #expect(ShareRules.order([a, b, c], last: "S/gone") == [a, b, c])
        #expect(ShareRules.order([a, b, c], last: nil) == [a, b, c])
        #expect(ShareRules.order([], last: "S/a").isEmpty)
    }

    @Test func sendNeedsAnAgentAndSomethingToSend() {
        #expect(ShareRules.canSend(text: "hi", imageCount: 0, agentChosen: true))
        #expect(ShareRules.canSend(text: " ", imageCount: 2, agentChosen: true))
        #expect(!ShareRules.canSend(text: " \n", imageCount: 0, agentChosen: true))
        #expect(!ShareRules.canSend(text: "hi", imageCount: 1, agentChosen: false))
    }
}
