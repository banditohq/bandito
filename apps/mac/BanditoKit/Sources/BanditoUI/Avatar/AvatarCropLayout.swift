import BanditoKit
import CoreGraphics
import Foundation
import ImageIO

/// Where a picture sits in a square frame so that the crop fills the frame, and how a drag moves the crop. Pure
/// geometry; the drawing and the gesture are in `AvatarEditor`.
enum AvatarCropLayout {
    /// The picture drawn at `scale` points per pixel, with its top-left corner at `offset` inside the frame.
    struct Placement: Equatable {
        var scale: CGFloat
        var offset: CGPoint
    }

    static func placement(crop: AvatarCrop, imageSize: CGSize, frame: CGFloat) -> Placement? {
        guard let rect = crop.rect(in: imageSize), rect.width > 0 else { return nil }
        let scale = frame / rect.width
        return Placement(scale: scale, offset: CGPoint(x: -rect.minX * scale, y: -rect.minY * scale))
    }

    /// The change of the crop centre (in image fractions) for a drag of `translation` points inside the frame. A drag
    /// to the right moves the picture right, so the centre moves left.
    static func centerDelta(translation: CGSize, crop: AvatarCrop, imageSize: CGSize, frame: CGFloat) -> CGPoint {
        guard let placement = placement(crop: crop, imageSize: imageSize, frame: frame), placement.scale > 0,
            imageSize.width > 0, imageSize.height > 0
        else { return .zero }
        return CGPoint(
            x: -translation.width / placement.scale / imageSize.width,
            y: -translation.height / placement.scale / imageSize.height)
    }
}

/// Reads a picture the owner picked: the file's own orientation applied, and limited in size so that a large photo
/// does not stay in memory.
enum AvatarImageFile {
    static let maxPixels = 1600

    static func load(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
