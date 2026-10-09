import Foundation

/// The size of the shown page: its CSS size and the device pixels per CSS pixel. Pure, so the rules are easy to read and test.
public struct BrowserViewport: Equatable, Sendable {
    /// The largest side the app asks the page for, in CSS pixels.
    public static let maxSide = 10_000
    /// The largest scale the app asks the page for.
    public static let maxScale = 4.0

    /// Width of the page in CSS pixels (whole numbers).
    public var width: Int
    /// Height of the page in CSS pixels (whole numbers).
    public var height: Int
    /// Device pixels per CSS pixel: the scale of the screen the picture is shown on.
    public var scale: Double

    /// The largest screencast frame the app asks for, in device pixels.
    public static let maxScreencast = (width: 2560, height: 1600)
    /// The screencast frame when no picture area is known yet, in device pixels.
    public static let defaultScreencast = (width: 1280, height: 800)

    public init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    /// The frame size to ask the screencast for: the page in device pixels, capped at `maxScreencast`. The browser
    /// keeps the aspect ratio inside this box, so the frame matches the picture area.
    public var screencastBox: (width: Int, height: Int) {
        (
            min(Int((Double(width) * scale).rounded()), Self.maxScreencast.width),
            min(Int((Double(height) * scale).rounded()), Self.maxScreencast.height)
        )
    }

    /// The viewport for a picture area of `width` × `height` points on a screen of `scale` pixels per point.
    /// Nil while the area has no usable size (under one point, or not a finite number). Fractions are cut, so the page
    /// never gets more pixels than the area has. A bad scale counts as 1; a huge size or scale is capped.
    public static func fitting(width: Double, height: Double, scale: Double) -> BrowserViewport? {
        guard width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        let usableScale = scale.isFinite && scale > 0 ? min(scale, maxScale) : 1
        return BrowserViewport(
            width: Int(min(width.rounded(.down), Double(maxSide))),
            height: Int(min(height.rounded(.down), Double(maxSide))),
            scale: usableScale)
    }
}
