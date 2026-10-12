#if os(macOS)
import AppKit
import BanditoDesign
import SwiftUI

/// The texts of the native thread rows (`NativeMessageView`): the same parsed bodies the SwiftUI bubbles draw
/// (`MessageRenderCache`), turned into AppKit attributed strings with the bubbles' fonts, colours and spacing, and
/// measured the way a text view lays them out.
enum NativeRowText {
    /// Running text: Onest 14.5. The agent's lines are 4 pt apart, the person's 3 pt (as the bubbles' `lineSpacing`).
    static let size: CGFloat = 14.5
    static let codeSize: CGFloat = 12.5

    static func lineSpacing(markdown: Bool) -> CGFloat { markdown ? 4 : 3 }

    /// The running text of a block, with inline Markdown as the SwiftUI `Text` shows it: strong in a heavier weight,
    /// inline code in mono and peach, struck text, links.
    static func running(_ value: AttributedString, markdown: Bool, color: NSColor, peach: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing(markdown: markdown)
        let regular = BanditoFont.appKitText(size: size)
        let result = NSMutableAttributedString()
        for run in value.runs {
            let piece = String(value[run.range].characters)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: regular, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    attributes[.font] = BanditoFont.appKitMono(size: codeSize)
                    attributes[.foregroundColor] = peach
                }
                // Strong and emphasised text keep the regular face: the SwiftUI `Text` of the bubbles draws them so
                // (the variable Onest has no bold trait it can take).
                if intent.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
            }
            if let link = run.link {
                attributes[.link] = link
                // A link takes the accent, unless it is inline code (peach), as in the SwiftUI `Text`.
                if run.inlinePresentationIntent?.contains(.code) != true {
                    attributes[.foregroundColor] = NSColor.controlAccentColor
                }
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    /// The code of a fenced block: JetBrains Mono 12.5, lines 2 pt apart.
    static func code(_ code: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: code.isEmpty ? " " : code,
            attributes: [
                .font: BanditoFont.appKitMono(size: codeSize), .foregroundColor: color, .paragraphStyle: paragraph,
            ])
    }

    /// The size a text takes laid out in `width` (wrapped), as an AppKit text view lays it out: the widest line and the
    /// height of all lines. Safe off the main thread.
    static func size(of text: NSAttributedString, width: CGFloat) -> CGSize {
        let box = text.boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        // The width as it is (a bubble is as wide as its text, to the fraction); the height up to whole points.
        return CGSize(width: box.width, height: ceil(box.height))
    }
}

/// The design colours resolved for an appearance, for layers and AppKit text.
enum NativeColors {
    static func ns(_ color: Color) -> NSColor { NSColor(color) }

    /// The colour as it shows in `appearance` (a layer takes a fixed `CGColor`). Resolved once per colour and
    /// appearance: every row that came into view used to resolve its colours again.
    @MainActor
    static func cg(_ color: Color, in appearance: NSAppearance) -> CGColor {
        let key = Key(color: color, appearance: appearance.name)
        if let known = resolved[key] { return known }
        var value = CGColor(gray: 0, alpha: 0)
        appearance.performAsCurrentDrawingAppearance { value = NSColor(color).cgColor }
        resolved[key] = value
        return value
    }

    private struct Key: Hashable {
        var color: Color
        var appearance: NSAppearance.Name
    }

    @MainActor private static var resolved: [Key: CGColor] = [:]
}
#endif
