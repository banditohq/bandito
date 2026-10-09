/// What a key press means while a shortcut is being recorded.
enum KeyCapture: Equatable {
    case binding(KeyBinding)
    /// ⌫ with no modifiers: remove the shortcut.
    case clear
    /// Esc: keep the shortcut as it was.
    case cancel
}

#if os(macOS)
import AppKit

/// Records one shortcut for the keys settings. While recording, key presses go to the recorder
/// and not to the rest of the app. Esc cancels; ⌫ with no modifiers clears the shortcut.
@MainActor
final class KeyRecorder {
    private var monitor: Any?

    var isRecording: Bool { monitor != nil }

    /// Starts recording. `onCapture` runs once, with the first press that means something, and recording stops.
    func start(_ onCapture: @escaping (KeyCapture) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let capture = Self.capture(for: event) else {
                return nil
            }
            MainActor.assumeIsolated {
                self?.stop()
                onCapture(capture)
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// What a key press means while recording. `nil` for keys that cannot be a shortcut (e.g. F-keys, forward delete).
    static func capture(for event: NSEvent) -> KeyCapture? {
        if event.keyCode == 53 {
            return .cancel
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 51, flags.isEmpty {
            return .clear
        }
        guard let key = keyName(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers) else {
            return nil
        }
        return .binding(KeyBinding(key: key, modifiers: modifiers(flags)))
    }

    static func keyName(keyCode: UInt16, characters: String?) -> String? {
        switch keyCode {
        case 36, 76: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 51: return "delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            guard let text = characters?.lowercased(), text.count == 1, let scalar = text.unicodeScalars.first,
                scalar.value >= 0x21, scalar.value != 0x7F
            else { return nil }
            return text
        }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Set<KeyModifier> {
        var result: Set<KeyModifier> = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }
}
#endif
