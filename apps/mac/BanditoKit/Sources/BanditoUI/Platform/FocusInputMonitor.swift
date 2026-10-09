#if os(macOS)
import AppKit

/// Feeds key and click events to `FocusModeTracker`. It only observes: every event goes on to its target.
@MainActor
final class FocusInputMonitor {
    private var monitor: Any?

    func start(_ onInput: @escaping @MainActor (FocusModeTracker.Input) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            let input: FocusModeTracker.Input = event.type == .leftMouseDown
                ? .pointerPress
                : FocusModeTracker.input(forKeyCode: event.keyCode)
            MainActor.assumeIsolated { onInput(input) }
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}
#else
/// No keyboard focus ring outside macOS: the tracker stays in pointer mode.
@MainActor
final class FocusInputMonitor {
    func start(_ onInput: @escaping @MainActor (FocusModeTracker.Input) -> Void) {}
    func stop() {}
}
#endif
