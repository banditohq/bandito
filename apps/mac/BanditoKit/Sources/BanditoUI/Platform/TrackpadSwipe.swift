#if os(macOS)
import AppKit
import SwiftUI

/// How far a swipe has gone: 0 to 1, where 1 is the distance that commits it.
struct SwipeProgress: Equatable {
    var direction: SwipeDirection
    var fraction: Double
    /// The swipe began over a page of the shared browser.
    var overBrowserPage: Bool
}

extension View {
    /// Watches two-finger horizontal swipes over this view.
    ///
    /// Fingers moving right is "back" (as in Safari). A swipe counts once it moves far enough horizontally and more than
    /// twice as far as vertically, so scrolling is not mistaken for it. `sensitivity` is 0 (firm) to 1 (light).
    /// `canSwipe` says whether the direction does anything where the swipe is (the second value is true over a page of the
    /// shared browser); only then is there progress to show and a commit. Events are only observed, never consumed, so
    /// scroll views keep working.
    func onTwoFingerSwipe(
        isEnabled: Bool = true,
        sensitivity: Double = 0.5,
        canSwipe: @escaping (SwipeDirection, Bool) -> Bool,
        onProgress: @escaping (SwipeProgress?) -> Void,
        onCommit: @escaping (SwipeDirection, Bool) -> Void
    ) -> some View {
        background(
            TwoFingerSwipeSensor(
                isEnabled: isEnabled, sensitivity: sensitivity, canSwipe: canSwipe, onProgress: onProgress,
                onCommit: onCommit)
        )
    }
}

/// An invisible view that watches the app's scroll events for swipes that land on it.
private struct TwoFingerSwipeSensor: NSViewRepresentable {
    var isEnabled: Bool
    var sensitivity: Double
    var canSwipe: (SwipeDirection, Bool) -> Bool
    var onProgress: (SwipeProgress?) -> Void
    var onCommit: (SwipeDirection, Bool) -> Void

    func makeNSView(context: Context) -> SwipeSensorView {
        SwipeSensorView()
    }

    func updateNSView(_ view: SwipeSensorView, context: Context) {
        view.isEnabled = isEnabled
        view.sensitivity = sensitivity
        view.canSwipe = canSwipe
        view.onProgress = onProgress
        view.onCommit = onCommit
        if !isEnabled { view.cancelGesture() }
    }

    static func dismantleNSView(_ view: SwipeSensorView, coordinator: ()) {
        view.stopObserving()
    }
}

@MainActor
private final class SwipeSensorView: NSView {
    var isEnabled = true
    var sensitivity = 0.5
    var canSwipe: ((SwipeDirection, Bool) -> Bool)?
    var onProgress: ((SwipeProgress?) -> Void)?
    var onCommit: ((SwipeDirection, Bool) -> Void)?

    private var monitor: Any?
    private var accumulatedX: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    /// One swipe fires once; the gesture must end before another can fire.
    private var fired = false
    /// Whether the gesture began over a page of the shared browser. Decided once, when the fingers land.
    private var overBrowserPage = false
    /// The last progress given out, in steps of 5%, so the window is told only when something changes.
    private var shown: SwipeProgress?

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

    /// Drops a gesture in progress (the gesture was switched off in the middle of it).
    func cancelGesture() {
        // Called while the view updates, where the window's state must not be written.
        Task { @MainActor [weak self] in self?.reset() }
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
            overBrowserPage = isOverBrowserPage(event)
            accumulate(event)
        case .changed:
            accumulate(event)
        case .ended, .cancelled:
            reset()
        default:
            break
        }
    }

    /// Whether the pointer is over a page of the shared browser (the view that takes its input).
    private func isOverBrowserPage(_ event: NSEvent) -> Bool {
        guard let content = window?.contentView, let frame = content.superview else { return false }
        var view = content.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let current = view {
            if current is PageInputView { return true }
            view = current.superview
        }
        return false
    }

    private func accumulate(_ event: NSEvent) {
        // With natural scrolling the deltas follow the fingers; without it they run the other way.
        let fingerX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        accumulatedX += fingerX
        accumulatedY += event.scrollingDeltaY
        guard !fired else { return }

        // 0 → 160 pt to commit, 1 → 40 pt.
        let threshold = CGFloat(160 - 120 * min(max(sensitivity, 0), 1))
        let direction: SwipeDirection = accumulatedX > 0 ? .back : .forward
        guard abs(accumulatedX) > 2 * abs(accumulatedY), canSwipe?(direction, overBrowserPage) == true else {
            publish(nil)
            return
        }
        let fraction = min(Double(abs(accumulatedX) / threshold), 1)
        if fraction >= 1 {
            fired = true
            publish(SwipeProgress(direction: direction, fraction: 1, overBrowserPage: overBrowserPage))
            onCommit?(direction, overBrowserPage)
        } else {
            publish(SwipeProgress(
                direction: direction, fraction: (fraction * 20).rounded(.down) / 20, overBrowserPage: overBrowserPage))
        }
    }

    private func publish(_ progress: SwipeProgress?) {
        // Nothing to show for the first few points: a scroll that starts sideways does not flash an arrow.
        let visible = progress.flatMap { $0.fraction >= 0.1 ? $0 : nil }
        guard visible != shown else { return }
        shown = visible
        onProgress?(visible)
    }

    private func reset() {
        accumulatedX = 0
        accumulatedY = 0
        fired = false
        overBrowserPage = false
        publish(nil)
    }
}
#endif
