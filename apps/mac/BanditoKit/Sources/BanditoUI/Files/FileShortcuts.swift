import SwiftUI

extension KeyBinding {
    /// Whether a key press is this binding. For keys without modifiers (Return, Space) inside a focused list,
    /// where `keyboardShortcut` is not used.
    func matches(_ press: KeyPress) -> Bool {
        guard let key = keyEquivalent else { return false }
        return press.key == key && press.modifiers == eventModifiers
    }
}

extension View {
    /// Runs `action` on the shortcut the keymap gives `commandID`. A hidden button carries the shortcut, so
    /// rebinding in Settings applies here too.
    func keymapShortcut(_ commandID: String, keymap: Keymap, action: @escaping () -> Void) -> some View {
        background {
            if let shortcut = keymap.binding(for: commandID)?.keyboardShortcut {
                ShortcutButton(shortcut: shortcut, action: action)
            }
        }
    }

    /// A hidden button for a fixed shortcut that has no command in the keymap (for example ⌘⇧. for hidden files).
    func fixedShortcut(_ key: KeyEquivalent, _ modifiers: EventModifiers, action: @escaping () -> Void) -> some View {
        background {
            ShortcutButton(shortcut: KeyboardShortcut(key, modifiers: modifiers), action: action)
        }
    }
}

/// Invisible and out of the layout; it exists only to receive its keyboard shortcut.
private struct ShortcutButton: View {
    let shortcut: KeyboardShortcut
    let action: () -> Void

    var body: some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(shortcut)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}
