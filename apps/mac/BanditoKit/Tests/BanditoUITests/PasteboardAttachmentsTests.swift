import AppKit
import Foundation
import Testing

@testable import BanditoUI

/// ⌘V reads the clipboard through `PasteboardAttachments.read`. Each test writes to a pasteboard of its own, so the
/// person's clipboard is not touched. Files are written to a temporary folder the test makes and removes.
@MainActor
@Suite struct PasteboardAttachmentsTests {
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("test-\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    /// A 2×2 picture as PNG and as TIFF bytes.
    private func pictures() throws -> (png: Data, tiff: Data) {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let tiff = try #require(bitmap.representation(using: .tiff, properties: [:]))
        return (png, tiff)
    }

    /// A temporary folder of this test, removed when the test ends.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "bandito-paste-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func pngIsKeptAsItIs() throws {
        let board = pasteboard()
        let (png, _) = try pictures()
        board.setData(png, forType: .png)
        #expect(PasteboardAttachments.read(board) == .picture(png))
    }

    @Test func tiffIsConvertedToPNG() throws {
        let board = pasteboard()
        let (_, tiff) = try pictures()
        board.setData(tiff, forType: .tiff)
        guard case .picture(let converted) = PasteboardAttachments.read(board) else {
            Issue.record("a TIFF picture should be read as a picture")
            return
        }
        // PNG signature, and the same picture again.
        #expect(converted.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(NSBitmapImageRep(data: converted)?.pixelsWide == 2)
    }

    @Test func textKeepsThePaste() throws {
        let board = pasteboard()
        let (png, _) = try pictures()
        board.setString("some text", forType: .string)
        board.setData(png, forType: .png)
        #expect(PasteboardAttachments.read(board) == .none)
    }

    @Test func emptyTextDoesNotBlockAPicture() throws {
        let board = pasteboard()
        let (png, _) = try pictures()
        board.setString("", forType: .string)
        board.setData(png, forType: .png)
        #expect(PasteboardAttachments.read(board) == .picture(png))
    }

    @Test func imageFilesAreAllAttached() throws {
        let board = pasteboard()
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appending(path: "one.png")
        let second = dir.appending(path: "two.jpg")
        try Data([1, 2, 3]).write(to: first)
        try Data([4, 5, 6]).write(to: second)
        board.writeObjects([first as NSURL, second as NSURL])
        let read = PasteboardAttachments.read(board)
        guard case .files(let urls) = read else {
            Issue.record("image files should be read as files, got \(read)")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["one.png", "two.jpg"])
    }

    @Test func aFileThatIsNotAPictureIsAFile() throws {
        let board = pasteboard()
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let note = dir.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: note)
        board.writeObjects([note as NSURL])
        let read = PasteboardAttachments.read(board)
        guard case .files(let urls) = read else {
            Issue.record("a file should be read as a file, got \(read)")
            return
        }
        #expect(urls.map(\.lastPathComponent) == ["notes.txt"])
    }

    @Test func webAddressIsNotAFile() {
        let board = pasteboard()
        board.writeObjects([URL(string: "https://bandito.dev")! as NSURL])
        #expect(PasteboardAttachments.fileURLs(board).isEmpty)
        #expect(PasteboardAttachments.read(board) == .none)
    }

    @Test func emptyPasteboardHasNothingToAttach() {
        #expect(PasteboardAttachments.read(pasteboard()) == .none)
    }
}
