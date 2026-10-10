import CoreText
import Foundation
import SwiftUI

/// The three brand typefaces and the one place that draws them.
///
/// - `display`: Unbounded, the brand voice (page titles, big numbers, agent names, section labels, primary buttons).
/// - `text`: Onest, everything a person reads.
/// - `mono`: JetBrains Mono, machine text (code, paths, commands, ids).
///
/// All three are variable fonts bundled in `Fonts/`; the weight is set on the `wght` axis, so any weight inside the
/// font's range is exact. They are registered for this process on first use (or explicitly with
/// `registerBundledFonts()`). Onest and Unbounded have no CJK glyphs: CoreText falls back to the system font there.
public enum BanditoFont {
    public static let displayFamily = "Unbounded"
    public static let textFamily = "Onest"
    public static let monoFamily = "JetBrains Mono"

    /// The `wght` variation axis identifier (the four characters "wght" as a number).
    public static let weightAxis = 2_003_265_652

    private struct Spec {
        let family: String
        let range: ClosedRange<Double>
    }

    private static let displaySpec = Spec(family: displayFamily, range: 200...900)
    private static let textSpec = Spec(family: textFamily, range: 100...900)
    private static let monoSpec = Spec(family: monoFamily, range: 100...800)

    /// Registers the bundled TTFs for this process. Safe to call any number of times; only the first call does work.
    /// Returns false when a font could not be registered.
    @discardableResult
    public static func registerBundledFonts() -> Bool {
        registered
    }

    private static let registered: Bool = {
        guard let root = Bundle.module.resourceURL?.appendingPathComponent("Fonts", isDirectory: true),
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return false }
        var urls: [URL] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "ttf" {
            urls.append(url)
        }
        guard !urls.isEmpty else { return false }
        var ok = true
        for url in urls {
            var error: Unmanaged<CFError>?
            // "Already registered" (the same font registered by another copy of this bundle) counts as success.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), !isAlreadyRegistered(error) {
                ok = false
            }
        }
        return ok
    }()

    private static func isAlreadyRegistered(_ error: Unmanaged<CFError>?) -> Bool {
        guard let error = error?.takeRetainedValue() else { return false }
        return CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
    }

    // MARK: Roles

    /// Unbounded: titles, big numbers, agent names, section labels, the primary button.
    public static func display(size: CGFloat, weight: Int = 600) -> Font {
        font(displaySpec, size: size, weight: weight)
    }

    /// Onest: all running text.
    public static func text(size: CGFloat, weight: Int = 400) -> Font {
        font(textSpec, size: size, weight: weight)
    }

    /// JetBrains Mono: code, paths, commands, ids, monospaced fields.
    public static func mono(size: CGFloat, weight: Int = 400) -> Font {
        font(monoSpec, size: size, weight: weight)
    }

    /// Text or mono font for an explicit size and numeric weight.
    public static func font(size: CGFloat, weight: Int, mono: Bool = false) -> Font {
        mono ? Self.mono(size: size, weight: weight) : text(size: size, weight: weight)
    }

    /// The CTFont behind a role (`displayFamily`, `textFamily`, `monoFamily`); tests use it to check family and axis.
    public static func ctFont(family: String, size: CGFloat, weight: Int) -> CTFont {
        let spec = [displaySpec, textSpec, monoSpec].first { $0.family == family } ?? textSpec
        return ctFont(spec, size: size, weight: weight)
    }

    // MARK: Building

    private final class Box: NSObject {
        let font: CTFont
        init(_ font: CTFont) { self.font = font }
    }

    // NSCache is thread safe; the compiler cannot know that.
    nonisolated(unsafe) private static let cache = NSCache<NSString, Box>()

    private static func ctFont(_ spec: Spec, size: CGFloat, weight: Int) -> CTFont {
        _ = registered
        let wght = min(max(Double(weight), spec.range.lowerBound), spec.range.upperBound)
        let key = "\(spec.family)|\(size)|\(wght)" as NSString
        if let hit = cache.object(forKey: key) { return hit.font }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: spec.family,
            kCTFontVariationAttribute: [weightAxis: wght],
        ] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        // A font asked for while the registration is still settling comes back as the system fallback: keep only the
        // real face, so the next call tries again instead of keeping the fallback for good.
        if CTFontCopyFamilyName(font) as String == spec.family {
            cache.setObject(Box(font), forKey: key)
        }
        return font
    }

    private static func font(_ spec: Spec, size: CGFloat, weight: Int) -> Font {
        Font(ctFont(spec, size: size, weight: weight))
    }
}

#if canImport(AppKit)
import AppKit

public extension BanditoFont {
    /// JetBrains Mono as an `NSFont`, for AppKit views (the code editor, the terminal).
    static func appKitMono(size: CGFloat, weight: Int = 400) -> NSFont {
        ctFont(family: monoFamily, size: size, weight: weight) as NSFont
    }

    /// JetBrains Mono Regular as the plain named font. A terminal derives its bold and italic faces with
    /// `NSFontManager`, which finds the Bold instance from this font but not from a font built on a variation.
    static func appKitTerminalMono(size: CGFloat) -> NSFont {
        _ = registerBundledFonts()
        return NSFont(name: "JetBrainsMono-Regular", size: size) ?? appKitMono(size: size)
    }

    /// Onest as an `NSFont`, for AppKit controls that cannot take a SwiftUI font.
    static func appKitText(size: CGFloat, weight: Int = 400) -> NSFont {
        ctFont(family: textFamily, size: size, weight: weight) as NSFont
    }
}
#endif
