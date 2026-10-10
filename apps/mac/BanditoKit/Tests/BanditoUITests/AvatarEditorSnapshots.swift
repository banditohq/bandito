import BanditoKit
import CoreGraphics
import SwiftUI
import Testing

@testable import BanditoUI

/// The avatar editor's tabs as PNG, for review. ScrollView, text fields and the color picker are AppKit-backed and may
/// show as plain placeholders offscreen; the layout around them is what these pictures are for.
@MainActor
@Suite struct AvatarEditorSnapshots {
    private func editor(tab: AvatarEditor.Tab, emoji: String? = nil, framing: CGImage? = nil, picture: CGImage? = nil)
        -> some View
    {
        let model = AvatarEditorModel()
        model.tab = tab
        model.framing = framing
        let look = AvatarLook(palette: .sky, customHex: nil, face: .happy, emoji: emoji)
        return AvatarEditor(
            name: "Forge", look: .constant(look), model: model, picture: picture, pictureSupported: true,
            onSetPicture: { _ in }, onRemovePicture: {}
        )
        .background(Color(red: 0.11, green: 0.1, blue: 0.09))
    }

    private func sample() -> CGImage? {
        let context = CGContext(
            data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: 0.9, green: 0.5, blue: 0.3, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        context?.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context?.fillEllipse(in: CGRect(x: 100, y: 50, width: 200, height: 200))
        return context?.makeImage()
    }

    @Test func faceTab() throws {
        let url = try SnapshotSupport.render(editor(tab: .face), "avatar-editor-face", size: CGSize(width: 360, height: 360))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func emojiTab() throws {
        let url = try SnapshotSupport.render(
            editor(tab: .emoji, emoji: "🦝"), "avatar-editor-emoji", size: CGSize(width: 360, height: 440))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pictureTabEmpty() throws {
        let url = try SnapshotSupport.render(
            editor(tab: .picture), "avatar-editor-picture-empty", size: CGSize(width: 360, height: 340))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func pictureTabWithPicture() throws {
        let url = try SnapshotSupport.render(
            editor(tab: .picture, picture: sample()), "avatar-editor-picture-set", size: CGSize(width: 360, height: 320))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func framing() throws {
        let url = try SnapshotSupport.render(
            editor(tab: .picture, framing: sample()), "avatar-editor-framing", size: CGSize(width: 360, height: 560))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func circularProfileFraming() throws {
        let view = PictureFraming(
            image: sample()!, encode: { AvatarPicture.jpeg(image: $0, crop: $1) }, maxBytes: 64 * 1024,
            tooLargeText: "", onSave: { _ in }, onCancel: {}, side: ProfileSheetLayout.cropSide, circular: true
        )
        .padding(16)
        .background(Color(red: 0.11, green: 0.1, blue: 0.09))
        let url = try SnapshotSupport.render(view, "profile-photo-framing", size: CGSize(width: 412, height: 420))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
