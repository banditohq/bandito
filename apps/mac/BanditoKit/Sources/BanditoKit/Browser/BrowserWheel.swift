import Foundation

// Scrolling the page: the wheel and trackpad events of the Mac become `Input.dispatchMouseEvent` wheel commands.
// Pure rules, so they are easy to read and test. The view reads `NSEvent`; the model sends the commands.

/// The size of a wheel event in page pixels.
public enum WheelUnits {
    /// A mouse wheel reports lines; DevTools wants pixels.
    public static let pixelsPerLine = 40.0

    /// The delta DevTools reads for a Mac scroll event. `scrollingDeltaX/Y` follow the fingers (natural scrolling) while
    /// DevTools counts down and right as positive, so the sign flips. A trackpad reports points (`precise`); a mouse
    /// wheel reports lines, which become pixels.
    public static func pixels(scrollingDeltaX: Double, scrollingDeltaY: Double, precise: Bool) -> (x: Double, y: Double) {
        let factor = precise ? 1.0 : pixelsPerLine
        return (-scrollingDeltaX * factor, -scrollingDeltaY * factor)
    }
}

/// The wheel events waiting to be sent. They are merged, and the model sends one command every 16 ms at most
/// (60 a second), however many events came in.
public struct WheelBatch: Sendable, Equatable {
    public struct Pending: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var deltaX: Double
        public var deltaY: Double
        public var modifiers: KeyModifiers
    }

    /// One command never carries more than this much, so a page that answered late is not thrown far at once.
    public static let maxDelta = 4_000.0
    /// How long events are merged before a command goes out.
    public static let interval: Duration = .milliseconds(16)

    private var pending: Pending?

    public init() {}

    public var isEmpty: Bool { pending == nil }

    /// Adds one event. The position and the modifiers are the latest ones. A zero event is ignored.
    public mutating func add(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: KeyModifiers) {
        guard deltaX.isFinite, deltaY.isFinite, x.isFinite, y.isFinite, deltaX != 0 || deltaY != 0 else { return }
        var next = pending ?? Pending(x: x, y: y, deltaX: 0, deltaY: 0, modifiers: modifiers)
        next.x = x
        next.y = y
        next.modifiers = modifiers
        next.deltaX += deltaX
        next.deltaY += deltaY
        pending = next
    }

    /// The command to send now. What is above `maxDelta` stays for the next one.
    public mutating func take() -> Pending? {
        guard var all = pending else { return nil }
        var out = all
        out.deltaX = min(max(all.deltaX, -Self.maxDelta), Self.maxDelta)
        out.deltaY = min(max(all.deltaY, -Self.maxDelta), Self.maxDelta)
        all.deltaX -= out.deltaX
        all.deltaY -= out.deltaY
        pending = (all.deltaX != 0 || all.deltaY != 0) ? all : nil
        return out
    }

    public mutating func clear() {
        pending = nil
    }
}

/// Tells a sideways swipe (back and forward in the page's history) from a scroll, from the first points of a gesture.
/// A swipe is not sent to the page; a scroll is, with its momentum.
public struct WheelGesture: Sendable, Equatable {
    public enum Phase: Sendable {
        /// A mouse wheel, or a device with no phases.
        case none
        case began
        case changed
        case ended
        /// The coasting after the fingers left.
        case momentum
    }

    enum Claim {
        case undecided, scroll, swipe
    }

    /// How far a gesture must go before it is called a swipe or a scroll, in points.
    static let decisionDistance = 8.0

    private var claim: Claim = .undecided
    private var sumX = 0.0
    private var sumY = 0.0
    private var heldX = 0.0
    private var heldY = 0.0
    private var heldFingerX = 0.0
    private var fingerX = 0.0

    public init() {}

    /// Whether the gesture so far is a sideways swipe.
    public var isSwipe: Bool { claim == .swipe }

    /// Takes one event (deltas as DevTools reads them) and returns what to send to the page now: everything for a scroll,
    /// nothing for a swipe, and nothing for the first few points while the gesture is not clear yet.
    ///
    /// `fingerX` is the sideways move of the fingers (right is positive, which is "back"), and `canSwipe(back)` says whether
    /// that direction has a page to go to. Without one the gesture is a scroll: the page gets it, like a page that scrolls
    /// sideways.
    public mutating func feed(
        deltaX: Double, deltaY: Double, phase: Phase, swipeEnabled: Bool, fingerX: Double = 0,
        canSwipe: (_ back: Bool) -> Bool = { _ in true }
    ) -> (x: Double, y: Double) {
        self.fingerX = fingerX
        guard swipeEnabled, phase != .none else {
            if phase == .none { reset() }
            return (deltaX, deltaY)
        }
        switch phase {
        case .none:
            return (deltaX, deltaY)
        case .momentum:
            if claim == .swipe { return (0, 0) }
            let held = takeHeld()
            return (deltaX + held.x, deltaY + held.y)
        case .began:
            reset()
            return decide(deltaX, deltaY, canSwipe)
        case .changed:
            return decide(deltaX, deltaY, canSwipe)
        case .ended:
            let out = decide(deltaX, deltaY, canSwipe)
            // A short touch that never became clear is a scroll after all. A decided gesture stays so for its momentum.
            if claim == .undecided {
                claim = .scroll
                let held = takeHeld()
                return (out.x + held.x, out.y + held.y)
            }
            return out
        }
    }

    private mutating func decide(
        _ deltaX: Double, _ deltaY: Double, _ canSwipe: (Bool) -> Bool
    ) -> (x: Double, y: Double) {
        switch claim {
        case .scroll:
            return (deltaX, deltaY)
        case .swipe:
            return (0, 0)
        case .undecided:
            sumX += abs(deltaX)
            sumY += abs(deltaY)
            heldX += deltaX
            heldY += deltaY
            heldFingerX += fingerX
            guard max(sumX, sumY) >= Self.decisionDistance else { return (0, 0) }
            if sumX > 2 * sumY, canSwipe(heldFingerX > 0) {
                claim = .swipe
                heldX = 0
                heldY = 0
                return (0, 0)
            }
            claim = .scroll
            return takeHeld()
        }
    }

    private mutating func takeHeld() -> (x: Double, y: Double) {
        defer {
            heldX = 0
            heldY = 0
        }
        return (heldX, heldY)
    }

    private mutating func reset() {
        claim = .undecided
        sumX = 0
        sumY = 0
        heldX = 0
        heldY = 0
        heldFingerX = 0
    }
}

/// Sends merged wheel events: events are added at any rate, and `send` is called with one merged batch every 16 ms at
/// most, one call at a time (the next batch waits for the answer to the last one, and keeps merging meanwhile).
@MainActor
public final class WheelSender {
    private var batch = WheelBatch()
    private var task: Task<Void, Never>?
    private let interval: Duration
    private let send: @MainActor (WheelBatch.Pending) async -> Void

    public init(interval: Duration = WheelBatch.interval, send: @escaping @MainActor (WheelBatch.Pending) async -> Void) {
        self.interval = interval
        self.send = send
    }

    public var isIdle: Bool { task == nil && batch.isEmpty }

    public func add(x: Double, y: Double, deltaX: Double, deltaY: Double, modifiers: KeyModifiers) {
        batch.add(x: x, y: y, deltaX: deltaX, deltaY: deltaY, modifiers: modifiers)
        guard task == nil, !batch.isEmpty else { return }
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.interval)
                guard !Task.isCancelled, let next = self.batch.take() else { break }
                await self.send(next)
            }
            // A cancelled loop leaves the slot to the task that replaced it.
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// Drops what waits and stops the loop.
    public func stop() {
        task?.cancel()
        task = nil
        batch.clear()
    }
}
