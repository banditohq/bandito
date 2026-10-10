import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The square the owner frames out of a picture for an avatar: a zoom and a centre, clamped so the square stays inside
/// the image. Pure geometry, so the framing can be tested without drawing.
public struct AvatarCrop: Equatable, Sendable {
    /// Zoom from `minZoom` to `maxZoom`. 1 takes the whole short side; 2 takes half of it.
    public static let minZoom = 1.0
    public static let maxZoom = 4.0

    /// Zoom as set, always within `minZoom...maxZoom`.
    public private(set) var zoom: Double
    /// Centre of the square as fractions of the image: (0.5, 0.5) is the middle. `pan` keeps it where the square fits.
    public private(set) var center: CGPoint

    public init(zoom: Double = AvatarCrop.minZoom, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        self.center = center
    }

    /// Changes the zoom; the value is clamped.
    public mutating func setZoom(_ value: Double) {
        zoom = min(max(value, Self.minZoom), Self.maxZoom)
    }

    /// Moves the centre by a drag of `delta`, in fractions of the image (a tenth of the view is 0.1 of the image). The
    /// centre stops where the square reaches the edge, for the current zoom: a drag past the edge does not pile up, so
    /// the next drag back moves the picture at once.
    public mutating func pan(by delta: CGPoint, in imageSize: CGSize) {
        let raw = CGPoint(x: center.x + delta.x, y: center.y + delta.y)
        center = Self.clamped(raw, zoom: zoom, imageSize: imageSize)
    }

    /// The crop rect in pixels of an image of `imageSize`: a square with a whole-pixel side, inside the image. Nil for
    /// an empty image.
    public func rect(in imageSize: CGSize) -> CGRect? {
        let width = imageSize.width.rounded(.down)
        let height = imageSize.height.rounded(.down)
        guard width >= 1, height >= 1 else { return nil }
        let side = Self.side(zoom: zoom, imageSize: imageSize)
        let half = side / 2
        let x = min(max((width * center.x - half).rounded(), 0), width - side)
        let y = min(max((height * center.y - half).rounded(), 0), height - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// The whole-pixel side of the square: the short side over the zoom, rounded once and used for both edges.
    static func side(zoom: Double, imageSize: CGSize) -> CGFloat {
        let shortSide = min(imageSize.width.rounded(.down), imageSize.height.rounded(.down))
        return max(1, (shortSide / CGFloat(zoom)).rounded())
    }

    /// The centre kept so that the square of this zoom lies inside the image.
    static func clamped(_ center: CGPoint, zoom: Double, imageSize: CGSize) -> CGPoint {
        let width = imageSize.width.rounded(.down)
        let height = imageSize.height.rounded(.down)
        guard width >= 1, height >= 1 else {
            return CGPoint(x: min(max(center.x, 0), 1), y: min(max(center.y, 0), 1))
        }
        let side = Self.side(zoom: zoom, imageSize: imageSize)
        let halfX = side / 2 / width
        let halfY = side / 2 / height
        return CGPoint(
            x: min(max(center.x, halfX), 1 - halfX),
            y: min(max(center.y, halfY), 1 - halfY))
    }
}

/// Turns a framed picture into the bytes the daemon and the account store keep: a square PNG for an agent, a small
/// JPEG for the owner's profile.
public enum AvatarPicture {
    /// The agent picture edge in pixels.
    public static let agentSide = 512
    /// The profile picture edge in pixels, and its size limit in bytes.
    public static let profileSide = 256
    public static let profileMaxBytes = 64 * 1024

    /// The framed part of `image` scaled to `side` × `side` pixels, as PNG. Nil when the crop is empty or the
    /// encoder fails.
    public static func png(image: CGImage, crop: AvatarCrop, side: Int = agentSide) -> Data? {
        guard let square = squareImage(image, crop: crop, side: side) else { return nil }
        return encode(square, type: .png, quality: nil)
    }

    /// The framed part of `image` as JPEG no larger than `maxBytes`. Tries a few qualities from high to low and
    /// returns the first that fits, or nil when even the lowest does not.
    public static func jpeg(
        image: CGImage, crop: AvatarCrop, side: Int = profileSide, maxBytes: Int = profileMaxBytes
    ) -> Data? {
        guard let square = squareImage(image, crop: crop, side: side) else { return nil }
        for quality in [0.9, 0.8, 0.7, 0.6, 0.5] {
            guard let data = encode(square, type: .jpeg, quality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }

    /// The crop drawn into a `side` × `side` bitmap, so the output size is fixed whatever the source size.
    static func squareImage(_ image: CGImage, crop: AvatarCrop, side: Int) -> CGImage? {
        guard side > 0,
            let rect = crop.rect(in: CGSize(width: image.width, height: image.height)),
            let part = image.cropping(to: rect.integral),
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(part, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// What an avatar shows: its picture when it has one, else its emoji, else the raccoon face.
public enum AvatarPresentation: Equatable, Sendable {
    case picture
    case emoji(String)
    case face

    public static func choose(hasPicture: Bool, emoji: String?) -> AvatarPresentation {
        if hasPicture { return .picture }
        if let emoji {
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return .emoji(trimmed) }
        }
        return .face
    }
}

/// The picture of an agent's avatar as the daemon returns it (`agents.avatar_image_get`): the bytes and their type.
public struct AvatarImage: Decodable, Sendable, Equatable {
    public var data: Data
    /// `image/png` or `image/jpeg`.
    public var mime: String

    private enum CodingKeys: String, CodingKey {
        case dataBase64 = "data_base64"
        case mime
    }

    public init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode(String.self, forKey: .dataBase64)
        guard let bytes = Data(base64Encoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .dataBase64, in: container, debugDescription: "avatar picture is not base64")
        }
        data = bytes
        mime = try container.decode(String.self, forKey: .mime)
    }
}
