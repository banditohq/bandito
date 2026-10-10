import BanditoKit
import Foundation
import Testing

@testable import BanditoUI

@MainActor
@Suite struct DraftPictureTests {
    private let agent = "agent-1"

    /// An upload that does not finish: the file stays uploading, so the test decides what happens to it.
    private let idle: AttachmentTrays.Uploader = { _, _, _ in
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }

    @Test func aPastedPictureIsWrittenToATemporaryFile() throws {
        let trays = AttachmentTrays()
        trays.addPicture(Data([1, 2, 3]), name: "Clipboard-1.png", agentID: agent, upload: idle)
        let file = try #require(trays.files(for: agent).first)
        let url = try #require(file.temporary)
        #expect(url.pathExtension == "png")
        #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
        guard case .file(let original) = file.original else {
            Issue.record("the viewer should read the temporary copy")
            return
        }
        #expect(original == url)
    }

    @Test func removingTheDraftFileDeletesItsTemporaryCopy() throws {
        let trays = AttachmentTrays()
        trays.addPicture(Data([1, 2, 3]), name: "Screenshot-2.png", agentID: agent, upload: idle)
        let file = try #require(trays.files(for: agent).first)
        let url = try #require(file.temporary)
        trays.remove(file.id, agentID: agent)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(trays.files(for: agent).isEmpty)
    }

    @Test func aFailedPictureHasNoCopy() {
        let trays = AttachmentTrays()
        trays.addPicture(Data(count: 21 * 1024 * 1024), name: "Big-3.png", agentID: agent, upload: idle)
        let file = trays.files(for: agent).first
        #expect(file?.temporary == nil)
        #expect(file?.original == nil)
    }
}
