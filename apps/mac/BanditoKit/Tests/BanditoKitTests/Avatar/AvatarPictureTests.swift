import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import BanditoKit

@Suite struct AvatarCropTests {
    private let wide = CGSize(width: 400, height: 300)

    @Test func fullZoomCentredTakesTheShortSide() {
        #expect(AvatarCrop().rect(in: wide) == CGRect(x: 50, y: 0, width: 300, height: 300))
    }

    @Test func zoomTwoTakesHalfTheShortSideAtTheCentre() {
        #expect(AvatarCrop(zoom: 2).rect(in: wide) == CGRect(x: 125, y: 75, width: 150, height: 150))
    }

    @Test func centreAtACornerStaysInsideTheImage() {
        let topLeft = AvatarCrop(zoom: 2, center: CGPoint(x: 0, y: 0))
        #expect(topLeft.rect(in: wide) == CGRect(x: 0, y: 0, width: 150, height: 150))
        let bottomRight = AvatarCrop(zoom: 2, center: CGPoint(x: 1, y: 1))
        #expect(bottomRight.rect(in: wide) == CGRect(x: 250, y: 150, width: 150, height: 150))
    }

    @Test func zoomIsClampedToItsRange() {
        #expect(AvatarCrop(zoom: 0.2).zoom == 1)
        #expect(AvatarCrop(zoom: 9).zoom == 4)
        var crop = AvatarCrop()
        crop.setZoom(3)
        #expect(crop.zoom == 3)
        crop.setZoom(0)
        #expect(crop.zoom == 1)
    }

    @Test func panStopsAtTheEdgeOfWhatTheZoomAllows() {
        // At zoom 1 the square is the short side (300 of 400 × 300): the centre may only move 0.375…0.625 across.
        var crop = AvatarCrop()
        crop.pan(by: CGPoint(x: 2, y: -2), in: wide)
        #expect(crop.center == CGPoint(x: 0.625, y: 0.5))
    }

    @Test func noDeadZoneAfterDraggingPastTheEdge() {
        // At zoom 2 the centre may move from 0.1875 to 0.8125 across and from 0.25 to 0.75 down.
        var crop = AvatarCrop(zoom: 2)
        crop.pan(by: CGPoint(x: -1, y: -1), in: wide)
        #expect(crop.center == CGPoint(x: 0.1875, y: 0.25))
        // A small drag back moves the picture at once: nothing was piled up beyond the edge.
        crop.pan(by: CGPoint(x: 0.05, y: 0), in: wide)
        #expect(abs(crop.center.x - 0.2375) < 1e-9)
        #expect(crop.rect(in: wide)?.minX == 20)
    }

    @Test func rectIsAWholePixelSquareInsideTheImage() {
        let sizes = [CGSize(width: 401, height: 299), CGSize(width: 640, height: 480), CGSize(width: 1000, height: 333)]
        for size in sizes {
            for zoom in [1.0, 1.3, 2.7, 4.0] {
                for x in [0.0, 0.3, 0.5, 1.0] {
                    for y in [0.0, 0.7, 1.0] {
                        var crop = AvatarCrop(zoom: zoom)
                        crop.pan(by: CGPoint(x: x - 0.5, y: y - 0.5), in: size)
                        guard let rect = crop.rect(in: size) else {
                            Issue.record("no rect for \(size) zoom \(zoom)")
                            continue
                        }
                        #expect(rect.width == rect.height)
                        #expect(rect.width == rect.width.rounded())
                        #expect(rect.minX == rect.minX.rounded() && rect.minY == rect.minY.rounded())
                        #expect(rect.minX >= 0 && rect.maxX <= size.width)
                        #expect(rect.minY >= 0 && rect.maxY <= size.height)
                    }
                }
            }
        }
    }

    @Test func emptyImageHasNoRect() {
        #expect(AvatarCrop().rect(in: .zero) == nil)
    }
}

@Suite struct AvatarPictureTests {
    /// A solid 600 × 400 test picture.
    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        return context.makeImage()!
    }

    /// The decoded picture and its container type, to check what was written.
    private func decode(_ data: Data) -> (image: CGImage, type: String?)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return (image, CGImageSourceGetType(source) as String?)
    }

    @Test func agentPictureIsAPNGSquareAtTheRequestedSize() throws {
        let data = try #require(AvatarPicture.png(image: makeImage(), crop: AvatarCrop()))
        let decoded = try #require(decode(data))
        #expect(decoded.type == "public.png")
        #expect(decoded.image.width == 512)
        #expect(decoded.image.height == 512)
    }

    @Test func profilePictureIsAJPEGWithinTheLimit() throws {
        let data = try #require(
            AvatarPicture.jpeg(image: makeImage(), crop: AvatarCrop(zoom: 2), side: 256, maxBytes: 64 * 1024))
        #expect(data.count <= 64 * 1024)
        let decoded = try #require(decode(data))
        #expect(decoded.type == "public.jpeg")
        #expect(decoded.image.width == 256)
        #expect(decoded.image.height == 256)
    }

    @Test func jpegGivesUpWhenNothingFitsTheLimit() {
        #expect(AvatarPicture.jpeg(image: makeImage(), crop: AvatarCrop(), side: 256, maxBytes: 10) == nil)
    }

    @Test func pictureWinsOverEmojiAndTheFace() {
        #expect(AvatarPresentation.choose(hasPicture: true, emoji: "🦝") == .picture)
        #expect(AvatarPresentation.choose(hasPicture: true, emoji: nil) == .picture)
    }

    @Test func emojiShowsWhenThereIsNoPicture() {
        #expect(AvatarPresentation.choose(hasPicture: false, emoji: "🦝") == .emoji("🦝"))
        #expect(AvatarPresentation.choose(hasPicture: false, emoji: " 🚀 ") == .emoji("🚀"))
    }

    @Test func faceShowsWhenThereIsNeitherPictureNorEmoji() {
        #expect(AvatarPresentation.choose(hasPicture: false, emoji: nil) == .face)
        #expect(AvatarPresentation.choose(hasPicture: false, emoji: "   ") == .face)
    }
}

@Suite struct AvatarWireTests {
    @Test func avatarDecodesPictureFields() throws {
        let json = #"{"color":"sky","face":"wink","emoji":"🦝","image":true,"image_rev":1700000000123}"#
        let spec = try JSONDecoder().decode(AvatarSpec.self, from: Data(json.utf8))
        #expect(spec.emoji == "🦝")
        #expect(spec.image == true)
        #expect(spec.imageRev == 1_700_000_000_123)
    }

    @Test func avatarLeavesUnsetPictureFieldsOutOfTheWire() throws {
        let data = try JSONEncoder().encode(AvatarSpec(color: "sky", face: "wink"))
        let keys = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        #expect(Set(keys) == ["color", "face"])
    }

    @Test func pictureReplyDecodesBase64() throws {
        let json = #"{"data_base64":"AAEC","mime":"image/png"}"#
        let image = try JSONDecoder().decode(AvatarImage.self, from: Data(json.utf8))
        #expect(image == AvatarImage(data: Data([0, 1, 2]), mime: "image/png"))
    }

    @Test func pictureReplyRejectsBrokenBase64() {
        let json = #"{"data_base64":"not base64!","mime":"image/png"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AvatarImage.self, from: Data(json.utf8))
        }
    }
}
