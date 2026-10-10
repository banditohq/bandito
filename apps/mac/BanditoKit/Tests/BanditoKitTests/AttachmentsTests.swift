import Foundation
import Testing

@testable import BanditoKit

@Suite struct AttachmentRulesTests {
    @Test func aPlainFileIsAllowed() {
        #expect(AttachmentRules.problem(name: "report.pdf", size: 1_024) == nil)
    }

    @Test func sizeLimitIsTwentyMegabytesInclusive() {
        let limit = AttachmentRules.maxBytes
        #expect(limit == 20 * 1024 * 1024)
        #expect(AttachmentRules.problem(name: "a.bin", size: limit) == nil)
        #expect(AttachmentRules.problem(name: "a.bin", size: limit + 1) == .tooLarge)
    }

    @Test func emptyFileIsNotRefused() {
        #expect(AttachmentRules.problem(name: "empty.txt", size: 0) == nil)
    }

    @Test func namesWithFoldersParentLinksOrControlsAreBad() {
        for name in ["a/b.txt", "a\\b.txt", "..x.txt", "x..", "tab\tname.txt", "new\nline.txt", "  ", ""] {
            #expect(AttachmentRules.problem(name: name, size: 1) == .badName, "\(name.debugDescription)")
        }
    }

    @Test func dotNamesAreHidden() {
        #expect(AttachmentRules.problem(name: ".env", size: 1) == .hiddenName)
    }

    @Test func nameLimitCountsUTF8Bytes() {
        let fits = String(repeating: "a", count: 196) + ".txt"
        #expect(fits.utf8.count == 200)
        #expect(AttachmentRules.problem(name: fits, size: 1) == nil)
        // Cyrillic is two bytes a letter: 100 letters = 200 bytes, one more is too long.
        let cyrillic = String(repeating: "я", count: 100)
        #expect(cyrillic.utf8.count == 200)
        #expect(AttachmentRules.problem(name: cyrillic, size: 1) == nil)
        #expect(AttachmentRules.problem(name: cyrillic + "я", size: 1) == .nameTooLong)
    }

    @Test func pictureTypesAreRecognisedByExtension() {
        #expect(AttachmentRules.isImage(name: "shot.PNG"))
        #expect(AttachmentRules.isImage(name: "photo.jpeg"))
        #expect(AttachmentRules.isImage(name: "clip.heic"))
        #expect(!AttachmentRules.isImage(name: "report.pdf"))
        #expect(!AttachmentRules.isImage(name: "logo.svg"), "SVG is shown as a file, not a miniature")
        #expect(!AttachmentRules.isImage(name: "noextension"))
    }
}

@Suite struct AttachmentWireTests {
    func decode(_ json: String) throws -> Event {
        try RPCClient.decoder.decode(Event.self, from: Data(json.utf8))
    }

    @Test func messageUserCarriesItsFiles() throws {
        let e = try decode(
            #"{"seq":3,"agent_id":"a1","ts":1,"kind":"message.user","payload":{"text":"look","source":"user","attachments":[{"path":"/w/.bandito/attachments/2026-10-10/a.png","name":"a.png","size":12,"mime":"image/png"}]}}"#
        )
        guard case .messageUser(let text, _, _, _, let files, _) = e.body else {
            Issue.record("wrong body \(e.body)")
            return
        }
        #expect(text == "look")
        #expect(files == [AgentAttachment(path: "/w/.bandito/attachments/2026-10-10/a.png", name: "a.png", size: 12, mime: "image/png")])
    }

    @Test func messageUserWithoutFilesStillDecodes() throws {
        let e = try decode(#"{"seq":4,"agent_id":"a1","ts":1,"kind":"message.user","payload":{"text":"hi","source":"user"}}"#)
        guard case .messageUser(_, _, _, _, let files, _) = e.body else {
            Issue.record("wrong body \(e.body)")
            return
        }
        #expect(files.isEmpty)
    }

    @Test func threadKeepsTheFilesOfTheMessage() throws {
        var thread = AgentThread()
        let file = AgentAttachment(path: "/w/a.txt", name: "a.txt", size: 1, mime: "text/plain")
        thread.apply(Event(seq: 1, agentId: "a1", ts: 5, body: .messageUser(text: "x", source: .user, fromAgent: nil, attachments: [file])))
        guard case .user(_, _, _, _, _, let files) = thread.items.last else {
            Issue.record("no user item")
            return
        }
        #expect(files == [file])
    }

    @Test func sendOmitsAttachmentsWhenThereAreNone() throws {
        let plain = try RPCClient.encoder.encode(AgentSendRequest(agentId: "a1", text: "hi", attachments: nil))
        let object = try JSONSerialization.jsonObject(with: plain) as? [String: Any]
        #expect(object?["agent_id"] as? String == "a1")
        #expect(object?["text"] as? String == "hi")
        #expect(object?["attachments"] == nil)
    }

    @Test func sendListsTheUploadedPaths() throws {
        let data = try RPCClient.encoder.encode(AgentSendRequest(agentId: "a1", text: "see", attachments: ["/w/a.txt"]))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["attachments"] as? [String] == ["/w/a.txt"])
    }

    @Test func uploadedFileDecodesFromItsReply() throws {
        let reply = Data(#"{"path":"/w/a.txt","name":"a.txt","size":3,"mime":"text/plain"}"#.utf8)
        let file = try RPCClient.decoder.decode(AgentAttachment.self, from: reply)
        #expect(file.path == "/w/a.txt")
        #expect(file.size == 3)
    }
}
