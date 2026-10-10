#if os(macOS)
import AppKit
import BanditoKit
import OSLog
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
    /// A sideways two-finger swipe over the page is back and forward in its history (the window's swipe handles it),
    /// so it is not scrolled into the page.
    var swipeNavigates = false
    /// Whether the page has an earlier (`true`) or later (`false`) page to swipe to. A sideways gesture with none is a
    /// scroll of the page.
    var canSwipe: (Bool) -> Bool = { _ in true }

    func makeNSView(context: Context) -> PageInputView {
        let view = PageInputView()
        view.onPointer = onPointer
        view.onKey = onKey
        view.swipeNavigates = swipeNavigates
        view.canSwipe = canSwipe
        return view
    }

    func updateNSView(_ view: PageInputView, context: Context) {
        view.onPointer = onPointer
        view.onKey = onKey
        view.swipeNavigates = swipeNavigates
        view.canSwipe = canSwipe
    }
}

final class PageInputView: NSView {
    var onPointer: ((PagePointer) -> Void)?
    var onKey: ((PageKey) -> Void)?
    var swipeNavigates = false
    var canSwipe: (Bool) -> Bool = { _ in true }
    private static let log = Logger(subsystem: "dev.bandito.app", category: "browser")
    private var wheelGesture = WheelGesture()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func pointer(_ event: NSEvent, _ type: CDPMouseType, _ button: CDPMouseButton) -> PagePointer {
        // `clickCount` exists only on mouse button events: AppKit raises on a scroll or move event, and swallows the
        // exception, so the wheel was lost without a trace.
        let clicks = Self.hasClickCount(event.type) ? max(event.clickCount, 1) : 0
        return PagePointer(
            type: type, point: convert(event.locationInWindow, from: nil), button: button,
            clickCount: clicks, deltaX: 0, deltaY: 0, modifiers: Self.modifiers(event))
    }

    /// The event types that carry a click count.
    static func hasClickCount(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp: true
        default: false
        }
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
        // DevTools counts down and right as positive; a mouse wheel's lines become pixels (see `WheelUnits`).
        // A wheel event made by software in lines may carry only `deltaX/Y`: they are lines too, so they stand in.
        let scrollX = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.deltaX
        let scrollY = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        let precise = event.hasPreciseScrollingDeltas && (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0)
        let delta = WheelUnits.pixels(scrollingDeltaX: Double(scrollX), scrollingDeltaY: Double(scrollY), precise: precise)
        // The fingers' sideways move, as the window's swipe reads it (see `SwipeSensorView`).
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        let send = wheelGesture.feed(
            deltaX: delta.x, deltaY: delta.y, phase: Self.wheelPhase(event), swipeEnabled: swipeNavigates,
            fingerX: Double(fingerX), canSwipe: canSwipe)
        Self.log.debug("scroll event delta \(delta.x),\(delta.y) phase \(String(describing: Self.wheelPhase(event))) -> send \(send.x),\(send.y)")
        guard send.x != 0 || send.y != 0 else { return }
        var p = pointer(event, .mouseWheel, .none)
        p.deltaX = send.x
        p.deltaY = send.y
        onPointer?(p)
    }

    /// The phase of a scroll event: the fingers' own, or the coasting after them.
    static func wheelPhase(_ event: NSEvent) -> WheelGesture.Phase {
        if !event.momentumPhase.isEmpty { return .momentum }
        switch event.phase {
        case .began, .mayBegin: return .began
        case .changed, .stationary: return .changed
        case .ended, .cancelled: return .ended
        default: return .none
        }
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
