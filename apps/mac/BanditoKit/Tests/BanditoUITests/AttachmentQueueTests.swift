import BanditoKit
import AppKit
import BanditoL10n
import Foundation
import Testing

@testable import BanditoUI

/// The upload queue of the composer: one upload at a time, and a removed file is not uploaded.
@MainActor
@Suite struct AttachmentQueueTests {
    /// Records how many uploads run at once and which names were uploaded.
    final class Recorder {
        var running = 0
        var peak = 0
        var uploaded: [String] = []
    }

    private func upload(_ recorder: Recorder, delay: Duration) -> AttachmentTrays.Uploader {
        { _, name, agentID in
            recorder.running += 1
            recorder.peak = max(recorder.peak, recorder.running)
            try await Task.sleep(for: delay)
            recorder.running -= 1
            recorder.uploaded.append(name)
            return AgentAttachment(path: "/w/.bandito/attachments/\(agentID)/\(name)", name: name, size: 1, mime: "image/png")
        }
    }

    /// Waits until `condition` holds, for at most two seconds.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func uploadsRunOneAtATime() async {
        let recorder = Recorder()
        let trays = AttachmentTrays()
        let up = upload(recorder, delay: .milliseconds(15))
        for name in ["a.png", "b.png", "c.png"] {
            trays.addPicture(Data([1, 2, 3]), name: name, agentID: "agent", upload: up)
        }
        await settle { trays.files(for: "agent").allSatisfy { if case .ready = $0.state { true } else { false } } }
        #expect(recorder.uploaded == ["a.png", "b.png", "c.png"], "in the order they were added")
        #expect(recorder.peak == 1, "never more than one upload at a time")
        #expect(trays.files(for: "agent").count == 3)
    }

    @Test func aRemovedFileWaitingInTheQueueIsNotUploaded() async {
        let recorder = Recorder()
        let trays = AttachmentTrays()
        let up = upload(recorder, delay: .milliseconds(40))
        trays.addPicture(Data([1]), name: "first.png", agentID: "agent", upload: up)
        trays.addPicture(Data([2]), name: "second.png", agentID: "agent", upload: up)
        let second = trays.files(for: "agent")[1].id
        trays.remove(second, agentID: "agent")
        await settle { recorder.uploaded.count == 1 }
        // Give a cancelled task the chance to (wrongly) upload before the check.
        try? await Task.sleep(for: .milliseconds(120))
        #expect(recorder.uploaded == ["first.png"])
        #expect(trays.files(for: "agent").map(\.name) == ["first.png"])
    }

    @Test func aRemovedFileIsGoneFromTheTrayAtOnce() {
        let trays = AttachmentTrays()
        trays.addPicture(Data([1]), name: "x.png", agentID: "agent", upload: upload(Recorder(), delay: .milliseconds(5)))
        let id = trays.files(for: "agent")[0].id
        trays.remove(id, agentID: "agent")
        #expect(trays.files(for: "agent").isEmpty)
    }

    @Test func aFailedUploadMarksTheFile() async {
        let trays = AttachmentTrays()
        trays.addPicture(Data([1]), name: "bad.png", agentID: "agent") { _, _, _ in
            throw CancellationError()
        }
        await settle { trays.files(for: "agent").first?.failureText != nil }
        #expect(trays.files(for: "agent").first?.failureText == L10n.Composer.Attach.failed)
    }

    /// A picture gets a miniature of at most 256 pixels, decoded off the main thread; a non-picture has none.
    @Test func aPictureGetsAMiniature() async {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let mini = Thumbnail.decode(png)
        #expect(mini != nil)
        #expect(max(mini?.width ?? 0, mini?.height ?? 0) == 256)

        let trays = AttachmentTrays()
        trays.addPicture(png, name: "big.png", agentID: "agent", upload: upload(Recorder(), delay: .milliseconds(1)))
        await settle { trays.files(for: "agent").first?.preview != nil }
        #expect(trays.files(for: "agent").first?.preview != nil)
        #expect(Thumbnail.decode(Data("not a picture".utf8)) == nil)
    }
}
