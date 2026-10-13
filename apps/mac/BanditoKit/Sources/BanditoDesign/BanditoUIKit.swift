#if os(iOS)
import CoreText
import UIKit

// The brand's colors and fonts for UIKit views (the iPhone chat's list and composer). The same tokens as `Color.Bandito`
// and `BanditoFont`: the colors come from the same asset catalog, so they follow dark and light; the fonts are the
// bundled faces, scaled with Dynamic Type as the SwiftUI ones are.

public extension UIColor {
    enum Bandito {
        public static let bg = named("bg")
        public static let surface1 = named("surface-1")
        public static let surface2 = named("surface-2")
        public static let surface3 = named("surface-3")
        public static let line = named("line")
        public static let lineStrong = named("line-strong")
        public static let text = named("text")
        public static let text2 = named("text-2")
        public static let text3 = named("text-3")
        public static let signal = named("signal")
        public static let onSignal = named("on-signal")
        public static let ok = named("ok")
        public static let info = named("info")
        public static let danger = named("danger")

        private static func named(_ name: String) -> UIColor {
            UIColor(named: name, in: .module, compatibleWith: nil) ?? .magenta
        }
    }
}

public extension BanditoFont {
    /// Onest as a `UIFont`, scaled with Dynamic Type from `size`.
    static func uiText(size: CGFloat, weight: Int = 400) -> UIFont {
        scaled(ctFont(family: textFamily, size: size, weight: weight))
    }

    /// Unbounded as a `UIFont`, scaled with Dynamic Type.
    static func uiDisplay(size: CGFloat, weight: Int = 600) -> UIFont {
        scaled(ctFont(family: displayFamily, size: size, weight: weight))
    }

    /// JetBrains Mono as a `UIFont`, scaled with Dynamic Type.
    static func uiMono(size: CGFloat, weight: Int = 400) -> UIFont {
        scaled(ctFont(family: monoFamily, size: size, weight: weight))
    }

    /// The same face at a size given by the person's Dynamic Type setting, for the measured text of a list: a size
    /// category the list was laid out for is part of its cache key.
    private static func scaled(_ font: CTFont) -> UIFont {
        scaledForDynamicType(font) as UIFont
    }
}
#endif
