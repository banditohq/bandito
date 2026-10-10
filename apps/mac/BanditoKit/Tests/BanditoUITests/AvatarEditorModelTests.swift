import BanditoKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import BanditoUI

@MainActor
@Suite struct AvatarEditorModelTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small valid PNG file.
    private func pictureFile(in folder: URL, name: String = "photo.png") throws -> URL {
        let context = try #require(
            CGContext(
                data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let image = try #require(context.makeImage())
        let data = try #require(AvatarPicture.png(image: image, crop: AvatarCrop(), side: 64))
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aPickedFileIsReadAndOpensThePictureTab() async throws {
        let model = AvatarEditorModel()
        #expect(model.tab == .face)
        model.load(try pictureFile(in: try folder()))
        await waitUntil { model.framing != nil }
        #expect(model.framing != nil)
        #expect(model.tab == .picture)
        #expect(model.loadedCount == 1)
        #expect(model.error == nil)
    }

    @Test func aFileThatIsNotAPictureGivesAnErrorAndNothingToFrame() async throws {
        let directory = try folder()
        let text = directory.appendingPathComponent("notes.png")
        try Data("not a picture".utf8).write(to: text)
        let model = AvatarEditorModel()
        model.load(text)
        await waitUntil { model.error != nil }
        #expect(model.error != nil)
        #expect(model.framing == nil)
        #expect(model.loadedCount == 0)
        #expect(model.tab == .face)
    }

    @Test func aMissingFileGivesAnError() async {
        let model = AvatarEditorModel()
        model.load(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).png"))
        await waitUntil { model.error != nil }
        #expect(model.error != nil)
        #expect(model.framing == nil)
    }

    @Test func aNewerPickReplacesAnOlderOneStillReading() async throws {
        let directory = try folder()
        let broken = directory.appendingPathComponent("broken.png")
        try Data("x".utf8).write(to: broken)
        let model = AvatarEditorModel()
        model.load(broken)
        model.load(try pictureFile(in: directory))
        await waitUntil { model.framing != nil }
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.framing != nil)
        // The older, broken read ended after the newer pick and must not show its error over the picture.
        #expect(model.error == nil)
        #expect(model.loadedCount == 1)
    }

    @Test func resetForgetsThePictureAndStopsAReadInFlight() async throws {
        let directory = try folder()
        let model = AvatarEditorModel()
        model.load(try pictureFile(in: directory))
        model.reset()
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.framing == nil)
        #expect(model.loadedCount == 0)
    }

    @Test func theModelOutlivesTheEditorView() async throws {
        // The cause of "the picture never loads": the picture used to be a @State of the popover view, which is gone
        // once the file panel took the focus. Here the owner holds the model; the result lands in it with no view.
        let model = AvatarEditorModel()
        weak var weakModel = model
        model.load(try pictureFile(in: try folder()))
        await waitUntil { model.framing != nil }
        #expect(weakModel?.framing != nil)
    }
}

@Suite struct AvatarEditorLayoutTests {
    @Test func theEditorContentIsThe360PopoverWithItsInsets() {
        #expect(AvatarEditorLayout.width == 360)
        #expect(AvatarEditorLayout.contentWidth == 328)
    }

    @Test func emojiGridHeightGrowsWithRowsUpToFive() {
        #expect(AvatarEditorLayout.gridHeight(count: 0) == 0)
        #expect(AvatarEditorLayout.gridHeight(count: 1) == 36)
        #expect(AvatarEditorLayout.gridHeight(count: 8) == 36)
        #expect(AvatarEditorLayout.gridHeight(count: 9) == 76)
        #expect(AvatarEditorLayout.gridHeight(count: 40) == 196)
        // 48 emoji are six rows; the grid shows five and scrolls.
        #expect(AvatarEditorLayout.gridHeight(count: 48) == 196)
    }

    @Test func tabsFitTheEditorContentWidth() {
        let emojiRow = CGFloat(AvatarEditorLayout.emojiColumns) * AvatarEditorLayout.emojiCell
        #expect(emojiRow <= AvatarEditorLayout.contentWidth)
        #expect(5 * 52 <= AvatarEditorLayout.contentWidth)
        // Six palette circles and the custom one, 32 pt each with 8 between.
        #expect(7 * 32 + 6 * 8 <= AvatarEditorLayout.contentWidth)
    }

    @Test func theProfilePhotoFrameFitsTheSheetWithItsCardPadding() {
        #expect(ProfileSheetLayout.contentWidth == 412)
        #expect(ProfileSheetLayout.fits(ProfileSheetLayout.cropSide))
        // The frame sits in a card with 16 pt on each side.
        #expect(ProfileSheetLayout.fits(ProfileSheetLayout.cropSide + 32))
        #expect(ProfileSheetLayout.fits(ProfileSheetLayout.avatarSize))
        #expect(ProfileSheetLayout.fits(500) == false)
    }
}
