import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The folder the share extension fills and the app empties: save, list in order, remove, skip the broken, clean the old.
@Suite struct ShareInboxTests {
    private func makeInbox() throws -> (ShareInbox, URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("share-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (ShareInbox(root: base.appendingPathComponent("Share", isDirectory: true)), base)
    }

    private func task(_ text: String, at seconds: TimeInterval = 1_700_000_000, id: UUID = UUID()) -> SharedTask {
        SharedTask(
            id: id, serverID: "S1", agentID: "forge", text: text, images: [],
            createdAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func savedTaskIsPendingWithItsPicturesAndGoesWhenRemoved() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let pictures = [Data([1, 2, 3]), Data([4, 5])]
        let stored = try inbox.save(task("look at this"), images: pictures)
        #expect(stored.images == ["0.jpg", "1.jpg"])

        let pending = inbox.pending()
        #expect(pending == [stored])
        #expect(inbox.imageData(task: stored, name: "0.jpg") == pictures[0])
        #expect(inbox.imageData(task: stored, name: "1.jpg") == pictures[1])
        #expect(inbox.imageData(task: stored, name: "2.jpg") == nil)

        inbox.remove(id: stored.id)
        #expect(inbox.pending().isEmpty)
        inbox.remove(id: stored.id)
    }

    @Test func aPictureNameIsNeverAPath() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let stored = try inbox.save(task("x"), images: [Data([9])])
        let outside = SharedTask(
            id: stored.id, serverID: "S1", agentID: "forge", text: "x", images: ["../Share/\(stored.id)/0.jpg"],
            createdAt: stored.createdAt)
        #expect(inbox.imageData(task: outside, name: outside.images[0]) == nil)
    }

    @Test func tasksComeOldestFirst() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        try inbox.save(task("second", at: 200), images: [])
        try inbox.save(task("third", at: 300), images: [])
        try inbox.save(task("first", at: 100), images: [])
        #expect(inbox.pending().map(\.text) == ["first", "second", "third"])
    }

    @Test func anEmptyOrMissingFolderHasNothingPending() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(inbox.pending().isEmpty)
        #expect(inbox.task(id: UUID()) == nil)
    }

    @Test func aBrokenTaskIsSkippedAndTheOthersStay() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let good = try inbox.save(task("good"), images: [])
        let broken = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: broken.appendingPathComponent(ShareInbox.taskFileName))
        let half = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        try Data([1]).write(to: half.appendingPathComponent("0.jpg"))
        let stranger = inbox.root.appendingPathComponent("not-a-task", isDirectory: true)
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)

        #expect(inbox.pending() == [good])
    }

    @Test func aTaskFolderWhoseFileNamesAnotherIdIsSkipped() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let stored = try inbox.save(task("a"), images: [])
        let copy = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: inbox.root.appendingPathComponent(stored.id.uuidString), to: copy)
        #expect(inbox.pending() == [stored])
    }

    @Test func oldTasksAreCleanedAndNewOnesStay() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 24 * 60 * 60
        try inbox.save(task("old", at: now.timeIntervalSince1970 - 8 * day), images: [Data([1])])
        let fresh = try inbox.save(task("fresh", at: now.timeIntervalSince1970 - 6 * day), images: [])
        inbox.removeOlder(now: now)
        #expect(inbox.pending() == [fresh])
    }

    @Test func aFolderWithoutAFileIsCleanedOnceItIsOld() throws {
        let (inbox, base) = try makeInbox()
        defer { try? FileManager.default.removeItem(at: base) }
        let half = inbox.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: half, withIntermediateDirectories: true)
        inbox.removeOlder(now: Date())
        #expect(FileManager.default.fileExists(atPath: half.path), "a new folder may still be written")
        inbox.removeOlder(now: Date().addingTimeInterval(ShareInbox.maxAge + 60))
        #expect(!FileManager.default.fileExists(atPath: half.path))
    }
}
