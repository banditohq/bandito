#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Calls `onBack` or `onForward` for one two-finger horizontal swipe over this view.
    ///
    /// Fingers moving right is "back" (as in Safari). A swipe counts once it moves far enough
    /// horizontally and more than twice as far as vertically, so scrolling is not mistaken for it.
    /// `sensitivity` is 0 (firm) to 1 (light). Events are only observed, never consumed, so scroll views keep working.
    func onTwoFingerSwipe(
        isEnabled: Bool = true,
        sensitivity: Double = 0.5,
        onBack: @escaping () -> Void,
        onForward: @escaping () -> Void
    ) -> some View {
        background(
            TwoFingerSwipeSensor(
                isEnabled: isEnabled, sensitivity: sensitivity, onBack: onBack, onForward: onForward)
        )
    }
}

/// An invisible view that watches the app's scroll events for swipes that land on it.
private struct TwoFingerSwipeSensor: NSViewRepresentable {
    var isEnabled: Bool
    var sensitivity: Double
    var onBack: () -> Void
    var onForward: () -> Void

    func makeNSView(context: Context) -> SwipeSensorView {
        SwipeSensorView()
    }

    func updateNSView(_ view: SwipeSensorView, context: Context) {
        view.isEnabled = isEnabled
        view.sensitivity = sensitivity
        view.onBack = onBack
        view.onForward = onForward
    }

    static func dismantleNSView(_ view: SwipeSensorView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
private final class SwipeSensorView: NSView {
    var isEnabled = true
    var sensitivity = 0.5
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    /// One swipe fires once; the gesture must end before another can fire.
    private var fired = false

    /// Clicks go to the views underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObserving()
        } else if monitor == nil {
            startObserving()
        }
    }

    private func startObserving() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors run on the main thread, which is the main actor's thread.
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event
        }
    }

    func stopObserving() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled, let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // Mouse wheels have no phase and momentum is the tail of a finished swipe: neither counts.
        guard event.momentumPhase.isEmpty else { return }

        switch event.phase {
        case .began:
            reset()
            accumulate(event)
        case .changed:
            accumulate(event)
        case .ended, .cancelled:
            reset()
        default:
            break
        }
    }

    private func accumulate(_ event: NSEvent) {
        // With natural scrolling the deltas follow the fingers; without it they run the other way.
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        accumulatedX += fingerX
        accumulatedY += event.scrollingDeltaY
        guard !fired else { return }

        // 0 → 160 pt to commit, 1 → 40 pt.
        let threshold = CGFloat(160 - 120 * min(max(sensitivity, 0), 1))
        guard abs(accumulatedX) >= threshold, abs(accumulatedX) > 2 * abs(accumulatedY) else { return }
        fired = true
        if accumulatedX > 0 {
            onBack?()
        } else {
            onForward?()
        }
    }

    private func reset() {
        accumulatedX = 0
        accumulatedY = 0
        fired = false
    }
}
#endif
