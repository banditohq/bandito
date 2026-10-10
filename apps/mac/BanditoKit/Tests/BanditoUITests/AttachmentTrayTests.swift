import BanditoKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

@Suite struct AttachmentTrayTests {
    private let sample = AgentAttachment(path: "/w/.bandito/attachments/2026-10-10/a.png", name: "a.png", size: 9, mime: "image/png")

    private func file(_ state: DraftFile.State, name: String = "a.png") -> DraftFile {
        DraftFile(name: name, size: 9, preview: nil, state: state)
    }

    @Test func aMessageNeedsTextAndNoUploadInFlight() {
        #expect(AttachmentTray.canSend(text: "look", files: []))
        #expect(AttachmentTray.canSend(text: "look", files: [file(.ready(sample))]))
        #expect(!AttachmentTray.canSend(text: "look", files: [file(.uploading)]), "wait for the upload")
        #expect(AttachmentTray.canSend(text: "   ", files: [file(.ready(sample))]), "files alone are a message")
        #expect(!AttachmentTray.canSend(text: "", files: []), "nothing to send")
        #expect(!AttachmentTray.canSend(text: "", files: [file(.failed(.upload))]), "a failed file is not sent")
        #expect(!AttachmentTray.canSend(text: "", files: [file(.uploading)]), "wait for the upload")
    }

    @Test func aFailedFileDoesNotBlockTheSend() {
        #expect(AttachmentTray.canSend(text: "look", files: [file(.failed(.upload))]))
    }

    @Test func onlyReadyFilesGoWithTheMessageInOrder() {
        let second = AgentAttachment(path: "/w/b.txt", name: "b.txt", size: 1, mime: "text/plain")
        let files = [file(.ready(sample)), file(.uploading), file(.failed(.upload)), file(.ready(second))]
        #expect(AttachmentTray.readyFiles(files) == [sample, second])
    }

    @Test func aBreakingNameOrSizeFailsBeforeUpload() {
        #expect(AttachmentTray.failure(name: "ok.pdf", size: 1) == nil)
        #expect(AttachmentTray.failure(name: "big.bin", size: AttachmentRules.maxBytes + 1) == .problem(.tooLarge))
        #expect(AttachmentTray.failure(name: ".env", size: 1) == .problem(.hiddenName))
        #expect(AttachmentTray.failure(name: "a/b", size: 1) == .problem(.badName))
    }

    @Test func eachFailureHasItsWords() {
        #expect(AttachmentTray.message(for: .problem(.tooLarge)) == L10n.Composer.Attach.tooLarge)
        #expect(AttachmentTray.message(for: .upload) == L10n.Composer.Attach.failed)
    }

    @Test func theChipTextFollowsTheState() {
        #expect(file(.uploading).detailText == L10n.Composer.Attach.uploading)
        #expect(file(.failed(.problem(.tooLarge))).failureText == L10n.Composer.Attach.tooLarge)
        #expect(file(.ready(sample)).failureText == nil)
        #expect(file(.ready(sample)).detailText?.isEmpty == false)
    }

    @Test func pictureFilesAreTheMiniatures() {
        #expect(file(.uploading, name: "shot.png").isImage)
        #expect(!file(.uploading, name: "notes.pdf").isImage)
    }

    @Test func screenshotNamesHoldNoSeparators() {
        let name = Composer.pictureName("Screenshot")
        #expect(name.hasPrefix("Screenshot-"))
        #expect(name.hasSuffix(".png"))
        #expect(!name.contains("/") && !name.contains(":"))
    }
}
