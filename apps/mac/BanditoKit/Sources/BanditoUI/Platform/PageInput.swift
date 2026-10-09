#if os(macOS)
import AppKit
import BanditoKit
import SwiftUI

// Mouse and keyboard of the shared browser's page. The view covers the picture; NSEvent gives the key codes
// that DevTools needs (`BrowserKeys` turns them into CDP key events).

/// A pointer event on the page, in view points (top-left origin).
struct PagePointer {
    var type: CDPMouseType
    var point: CGPoint
    var button: CDPMouseButton
    var clickCount: Int
    var deltaX: Double
    var deltaY: Double
    var modifiers: KeyModifiers
}

/// A keyboard event on the page: a key with its CDP description, or text to insert.
enum PageKey {
    case key(CDPKeyType, CDPKeyDescriptor, KeyModifiers)
    case text(String)
}

struct PageInput: NSViewRepresentable {
    var onPointer: (PagePointer) -> Void
    var onKey: (PageKey) -> Void

    func makeNSView(context: Context) -> PageInputView {
        let view = PageInputView()
        view.onPointer = onPointer
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: PageInputView, context: Context) {
        view.onPointer = onPointer
        view.onKey = onKey
    }
}

final class PageInputView: NSView {
    var onPointer: ((PagePointer) -> Void)?
    var onKey: ((PageKey) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func pointer(_ event: NSEvent, _ type: CDPMouseType, _ button: CDPMouseButton) -> PagePointer {
        PagePointer(
            type: type, point: convert(event.locationInWindow, from: nil), button: button,
            clickCount: max(event.clickCount, 1), deltaX: 0, deltaY: 0, modifiers: Self.modifiers(event))
    }

    private func emit(_ event: NSEvent, _ type: CDPMouseType, _ button: CDPMouseButton) {
        onPointer?(pointer(event, type, button))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(event, .mousePressed, .left)
    }

    override func mouseUp(with event: NSEvent) { emit(event, .mouseReleased, .left) }
    override func mouseDragged(with event: NSEvent) { emit(event, .mouseMoved, .left) }
    override func mouseMoved(with event: NSEvent) { emit(event, .mouseMoved, .none) }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(event, .mousePressed, .right)
    }

    override func rightMouseUp(with event: NSEvent) { emit(event, .mouseReleased, .right) }
    override func rightMouseDragged(with event: NSEvent) { emit(event, .mouseMoved, .right) }

    override func otherMouseDown(with event: NSEvent) { emit(event, .mousePressed, .middle) }
    override func otherMouseUp(with event: NSEvent) { emit(event, .mouseReleased, .middle) }
    override func otherMouseDragged(with event: NSEvent) { emit(event, .mouseMoved, .middle) }

    override func scrollWheel(with event: NSEvent) {
        // Natural scrolling: the content moves with the fingers, which DevTools reads as the opposite delta.
        var p = pointer(event, .mouseWheel, .none)
        p.deltaX = -Double(event.scrollingDeltaX)
        p.deltaY = -Double(event.scrollingDeltaY)
        onPointer?(p)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = Self.modifiers(event)
        // Typed text goes in as text (IME-friendly). Named keys, control characters and shortcuts are key events.
        let shortcut = modifiers.contains(.control) || modifiers.contains(.meta)
        if !shortcut, let characters = event.characters, Self.isPlainText(characters) {
            onKey?(.text(characters))
            return
        }
        guard let descriptor = BrowserKeys.descriptor(keyCode: event.keyCode, characters: event.characters, modifiers: modifiers)
        else { return }
        onKey?(.key(event.isARepeat ? .rawKeyDown : .keyDown, descriptor, modifiers))
    }

    override func keyUp(with event: NSEvent) {
        let modifiers = Self.modifiers(event)
        guard let descriptor = BrowserKeys.descriptor(keyCode: event.keyCode, characters: event.characters, modifiers: modifiers)
        else { return }
        onKey?(.key(.keyUp, descriptor, modifiers))
    }

    /// Command shortcuts stay with the menus (⌘L, ⌘R, ⌘⇧C…), so the page does not get them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        false
    }

    /// Text that is typed as text: printable characters, not control characters or private-use keys.
    static func isPlainText(_ characters: String) -> Bool {
        characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) && $0.value != 0x7F }
    }

    static func modifiers(_ event: NSEvent) -> KeyModifiers {
        var result: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.option) { result.insert(.alt) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.command) { result.insert(.meta) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
#endif
