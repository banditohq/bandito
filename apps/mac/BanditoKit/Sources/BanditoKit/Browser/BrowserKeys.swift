import CoreGraphics
import Foundation

// Input for the shared browser: macOS keys and modifiers as DevTools key events, and view points as page points.

/// Modifier keys in the bit order that `Input.dispatchMouseEvent` / `dispatchKeyEvent` use.
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let alt = KeyModifiers(rawValue: 1)
    public static let control = KeyModifiers(rawValue: 2)
    /// Command on macOS.
    public static let meta = KeyModifiers(rawValue: 4)
    public static let shift = KeyModifiers(rawValue: 8)
}

/// What one key press is, for `Input.dispatchKeyEvent`.
public struct CDPKeyDescriptor: Sendable, Equatable {
    /// The DOM `key` value: `a`, `Enter`, `ArrowLeft`…
    public var key: String
    /// The DOM `code` value: `KeyA`, `Digit1`, `Enter`…
    public var code: String
    public var windowsVirtualKeyCode: Int
    /// The text the key types, when it types any (nil for shortcuts and named keys).
    public var text: String?

    public init(key: String, code: String, windowsVirtualKeyCode: Int, text: String?) {
        self.key = key
        self.code = code
        self.windowsVirtualKeyCode = windowsVirtualKeyCode
        self.text = text
    }
}

public enum BrowserKeys {
    /// One macOS key code (`kVK_*`) and what it is in DOM terms.
    private struct Entry {
        var code: String
        var virtualKey: Int
        /// The DOM key of a named key. Nil for printable keys, whose key is the typed character.
        var name: String?
        var fallback: String
    }

    private static let table: [UInt16: Entry] = {
        var t: [UInt16: Entry] = [:]
        let letters: [(UInt16, String)] = [
            (0, "a"), (11, "b"), (8, "c"), (2, "d"), (14, "e"), (3, "f"), (5, "g"), (4, "h"), (34, "i"),
            (38, "j"), (40, "k"), (37, "l"), (46, "m"), (45, "n"), (31, "o"), (35, "p"), (12, "q"),
            (15, "r"), (1, "s"), (17, "t"), (32, "u"), (9, "v"), (13, "w"), (7, "x"), (16, "y"), (6, "z"),
        ]
        for (code, letter) in letters {
            let upper = letter.uppercased()
            t[code] = Entry(code: "Key\(upper)", virtualKey: Int(upper.unicodeScalars.first!.value), name: nil, fallback: letter)
        }
        let digits: [(UInt16, Character)] = [
            (29, "0"), (18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"), (22, "6"), (26, "7"), (28, "8"), (25, "9"),
        ]
        for (code, digit) in digits {
            t[code] = Entry(code: "Digit\(digit)", virtualKey: Int(String(digit))! + 48, name: nil, fallback: String(digit))
        }
        let punctuation: [(UInt16, String, Int, String)] = [
            (24, "Equal", 187, "="), (27, "Minus", 189, "-"), (30, "BracketRight", 221, "]"),
            (33, "BracketLeft", 219, "["), (39, "Quote", 222, "'"), (41, "Semicolon", 186, ";"),
            (42, "Backslash", 220, "\\"), (43, "Comma", 188, ","), (44, "Slash", 191, "/"),
            (47, "Period", 190, "."), (50, "Backquote", 192, "`"),
        ]
        for (code, name, vk, character) in punctuation {
            t[code] = Entry(code: name, virtualKey: vk, name: nil, fallback: character)
        }
        let named: [(UInt16, String, Int, String)] = [
            (36, "Enter", 13, "Enter"), (76, "Enter", 13, "Enter"), (48, "Tab", 9, "Tab"),
            (49, "Space", 32, " "), (51, "Backspace", 8, "Backspace"), (53, "Escape", 27, "Escape"),
            (117, "Delete", 46, "Delete"), (115, "Home", 36, "Home"), (119, "End", 35, "End"),
            (116, "PageUp", 33, "PageUp"), (121, "PageDown", 34, "PageDown"),
            (123, "ArrowLeft", 37, "ArrowLeft"), (124, "ArrowRight", 39, "ArrowRight"),
            (125, "ArrowDown", 40, "ArrowDown"), (126, "ArrowUp", 38, "ArrowUp"),
        ]
        for (code, name, vk, key) in named {
            t[code] = Entry(code: name, virtualKey: vk, name: key, fallback: key)
        }
        return t
    }()

    /// The CDP description of a key press. `characters` is what macOS typed (`NSEvent.characters`), if any.
    /// Returns nil for key codes the table does not know.
    ///
    /// Text is typed only without Control or Command, so ⌘A selects instead of typing "a".
    public static func descriptor(
        keyCode: UInt16, characters: String?, modifiers: KeyModifiers = []
    ) -> CDPKeyDescriptor? {
        guard let entry = table[keyCode] else { return nil }
        let shortcut = modifiers.contains(.control) || modifiers.contains(.meta)
        let key: String
        var text: String?
        if let name = entry.name {
            key = name
            if !shortcut {
                switch name {
                case "Enter": text = "\r"
                case " ": text = " "
                default: text = nil
                }
            }
        } else {
            if let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) {
                key = characters
            } else {
                key = entry.fallback
            }
            if !shortcut { text = key }
        }
        return CDPKeyDescriptor(key: key, code: entry.code, windowsVirtualKeyCode: entry.virtualKey, text: text)
    }

    /// The `modifiers` bitmask of CDP: alt 1, control 2, meta 4, shift 8.
    public static func bitmask(_ modifiers: KeyModifiers) -> Int {
        modifiers.rawValue
    }

    /// The `buttons` bitmask of CDP for a pressed mouse button: left 1, right 2, middle 4.
    public static func buttonMask(_ button: CDPMouseButton) -> Int {
        switch button {
        case .none: 0
        case .left: 1
        case .right: 2
        case .middle: 4
        }
    }
}

/// Where a picture of the page is shown, and where a click on it lands in the page.
public enum PageGeometry {
    /// The picture of a `pageWidth` × `pageHeight` page, fitted into the view and centred. Empty when a size is not positive.
    public static func displayRect(
        viewWidth: CGFloat, viewHeight: CGFloat, pageWidth: CGFloat, pageHeight: CGFloat
    ) -> CGRect {
        guard viewWidth > 0, viewHeight > 0, pageWidth > 0, pageHeight > 0 else { return .zero }
        let scale = min(viewWidth / pageWidth, viewHeight / pageHeight)
        let width = pageWidth * scale
        let height = pageHeight * scale
        return CGRect(x: (viewWidth - width) / 2, y: (viewHeight - height) / 2, width: width, height: height)
    }

    /// The page point under a view point, or nil when the point is outside the picture.
    public static func pagePoint(
        x: CGFloat, y: CGFloat, viewWidth: CGFloat, viewHeight: CGFloat, pageWidth: CGFloat, pageHeight: CGFloat
    ) -> CGPoint? {
        let rect = displayRect(viewWidth: viewWidth, viewHeight: viewHeight, pageWidth: pageWidth, pageHeight: pageHeight)
        guard !rect.isEmpty, rect.contains(CGPoint(x: x, y: y)) else { return nil }
        let scale = rect.width / pageWidth
        return CGPoint(x: (x - rect.minX) / scale, y: (y - rect.minY) / scale)
    }
}
