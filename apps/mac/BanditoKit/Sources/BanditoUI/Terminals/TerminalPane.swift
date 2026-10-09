#if os(macOS)
import AppKit
@preconcurrency import SwiftTerm
import SwiftUI

/// Brand colors of the terminal (docs/APP_SPEC.md, Terminals board): background, text, caret, and the 16 ANSI colors.
enum TerminalTheme {
    static let background = NSColor(hex: 0x0B0A09)
    static let foreground = NSColor(hex: 0xD9CFBF)
    static let caret = NSColor(hex: 0xFF8A1F)

    /// ANSI 0–7 (black, red, green, yellow, blue, magenta, cyan, white), then the bright 8–15.
    static let ansiHex: [UInt32] = [
        0x2C2722, 0xF2A093, 0xA9C7A2, 0xFFB067, 0xA3BDEB, 0xC8B6E8, 0x8FCFC4, 0xF3EBDD,
        0x6E655A, 0xF7BBAE, 0xC2DAB9, 0xFFCB8F, 0xBFD2F2, 0xDACDF2, 0xADE0D7, 0xFFFFFF,
    ]

    static var ansi: [SwiftTerm.Color] {
        ansiHex.map { hex in
            SwiftTerm.Color(
                red8: UInt16((hex >> 16) & 0xFF), green8: UInt16((hex >> 8) & 0xFF), blue8: UInt16(hex & 0xFF))
        }
    }

    static func font(size: Double) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

/// The emulator view of one terminal. It is owned by its `TerminalSession`, so it keeps the screen
/// while the pane is collapsed and is only put on screen by `TerminalPane`.
final class BanditoTerminalView: TerminalView {
    /// Called when the view becomes first responder (a click or a keyboard focus).
    var onFocus: (() -> Void)?
    /// Called with the trackpad magnification of a pinch over the text (0.1 means 10 % larger).
    var onPinch: ((Double) -> Void)?
    /// Set when the pane should take keyboard focus as soon as it is in a window.
    var wantsFocus = false

    /// A click on the text makes this pane the focused one. (SwiftTerm's `becomeFirstResponder` is not open,
    /// so the click is the hook; keyboard focus moved by the workspace goes through `makeFirstResponder`.)
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, let window {
            wantsFocus = false
            window.makeFirstResponder(self)
        }
    }

    override func magnify(with event: NSEvent) {
        onPinch?(Double(event.magnification))
    }
}

/// SwiftTerm reports on the main thread. The bridge forwards to the main-actor session without
/// capturing the view, so the session can be used from its own isolation.
/// `@unchecked Sendable`: the closures are set once by the session on the main actor, and only read there.
final class TerminalViewBridge: TerminalViewDelegate, @unchecked Sendable {
    var onInput: (@MainActor (Data) -> Void)?
    var onSize: (@MainActor (Int, Int) -> Void)?

    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Data(data)
        MainActor.assumeIsolated { onInput?(bytes) }
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { onSize?(newCols, newRows) }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func bell(source: TerminalView) {
        NSSound.beep()
    }

    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        // The program asked to copy to the Mac clipboard (OSC 52). Only an explicit paste or copy by the user
        // should change the clipboard, so this is ignored.
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// The terminal text of one pane: an `NSView` supplied by its session.
struct TerminalPane: NSViewRepresentable {
    let view: BanditoTerminalView
    let fontSize: Double

    func makeNSView(context: Context) -> BanditoTerminalView {
        view
    }

    func updateNSView(_ view: BanditoTerminalView, context: Context) {
        if abs(view.font.pointSize - CGFloat(fontSize)) > 0.01 {
            view.font = TerminalTheme.font(size: fontSize)
        }
    }
}
#endif
