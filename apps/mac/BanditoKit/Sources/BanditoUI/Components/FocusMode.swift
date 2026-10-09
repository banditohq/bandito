import BanditoDesign
import SwiftUI

/// Whether the last input came from the keyboard or the pointer. The focus ring shows only in keyboard mode,
/// so a click does not leave a ring behind, and Tab shows where focus is.
@MainActor
@Observable
public final class FocusModeTracker {
    public enum Mode: Sendable, Equatable {
        case pointer, keyboard
    }

    /// What an input event means for the mode. Other keys (typing) change nothing.
    public enum Input: Sendable, Equatable {
        /// Tab or an arrow key: the user is moving focus with the keyboard.
        case navigationKey
        /// A press of the left mouse button.
        case pointerPress
        case other
    }

    /// Key codes that move focus: Tab (48) and the four arrows (123–126).
    static let navigationKeyCodes: Set<UInt16> = [48, 123, 124, 125, 126]

    public private(set) var mode: Mode = .pointer

    private let monitor = FocusInputMonitor()

    public init() {}

    /// Starts watching the app's key and click events. Safe to call again.
    public func start() {
        monitor.start { [weak self] input in self?.note(input) }
    }

    public func stop() {
        monitor.stop()
    }

    /// Feeds one input event into the tracker.
    public func note(_ input: Input) {
        mode = Self.mode(after: mode, input: input)
    }

    /// The mode after `input`. Navigation keys mean keyboard, a click means pointer, anything else keeps the mode.
    public static func mode(after current: Mode, input: Input) -> Mode {
        switch input {
        case .navigationKey: .keyboard
        case .pointerPress: .pointer
        case .other: current
        }
    }

    /// Classifies a key code from a key-down event.
    public static func input(forKeyCode code: UInt16) -> Input {
        navigationKeyCodes.contains(code) ? .navigationKey : .other
    }
}

@MainActor
private struct FocusModeKey: @preconcurrency EnvironmentKey {
    static let defaultValue = FocusModeTracker()
}

public extension EnvironmentValues {
    /// The app's focus-mode tracker. The app injects one; without it (previews, snapshots) the default stays in pointer mode.
    var focusMode: FocusModeTracker {
        get { self[FocusModeKey.self] }
        set { self[FocusModeKey.self] = newValue }
    }
}
