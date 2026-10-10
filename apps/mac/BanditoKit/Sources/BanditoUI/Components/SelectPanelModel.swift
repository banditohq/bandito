import AppKit
import SwiftUI

/// The state of an open select panel that the keyboard acts on. The panel holds it while it is open. Keys come from a
/// local monitor that is set only while the panel is on screen, so they reach the panel wherever focus is: in the
/// search field or not.
@MainActor
@Observable
final class SelectPanelModel<Value: Hashable> {
    /// The id of the marker at the top of the list. Row ids are their indices, so this one is never a row.
    static var topMarker: Int { -1 }

    /// The search text.
    var query = ""
    /// The row the keyboard or the pointer is on, as an index into the rows shown.
    var highlight: Int?
    /// Counts the keyboard moves, so the list scrolls the highlighted row into view. The pointer never scrolls.
    var keyboardMoves = 0
    /// The last pointer position that moved a highlight. A row takes the highlight only when the pointer really moved,
    /// so scrolling with the keys under a still pointer does not change the highlight.
    @ObservationIgnored var pointer: NSPoint?

    /// The rows shown. The panel writes them on each render; the keys act on them.
    @ObservationIgnored var rows: [SelectOption<Value>] = []
    @ObservationIgnored var choose: (Value) -> Void = { _ in }
    @ObservationIgnored var close: () -> Void = {}
    /// The window the panel is in. Only its key events are the panel's.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var monitor: Any?

    var enabled: [Bool] {
        rows.map(\.isEnabled)
    }

    /// Starts handling the keys of the panel. Balanced by `stop`.
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Local monitors are called on the main thread, which is the main actor's thread.
            nonisolated(unsafe) let received = event
            let consumed = MainActor.assumeIsolated { self.handle(received) }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// Handles a key press and tells whether the panel took it. Only while the panel's window is the key window.
    func handle(_ event: NSEvent) -> Bool {
        // Only while the panel's window is the key window. `event.window` is not compared: key presses reach the
        // monitor through the search field's editor, whose event does not always name the panel's window.
        guard let window, window.isKeyWindow else { return false }
        switch event.keyCode {
        case 126:  // ↑
            move(-1)
            return true
        case 125:  // ↓
            move(1)
            return true
        case 36, 76:  // Return, keypad Enter
            return chooseHighlighted()
        case 53:  // Escape
            close()
            return true
        default:
            return false
        }
    }

    func move(_ step: Int) {
        let next = step > 0
            ? SelectHighlight.next(from: highlight, enabled: enabled)
            : SelectHighlight.previous(from: highlight, enabled: enabled)
        guard let next else { return }
        highlight = next
        keyboardMoves += 1
    }

    /// Chooses the highlighted row when it can be chosen. Returns whether it did.
    private func chooseHighlighted() -> Bool {
        guard let highlight, rows.indices.contains(highlight), rows[highlight].isEnabled else { return false }
        choose(rows[highlight].value)
        return true
    }
}

/// Reports the window a view sits in, so the panel knows which key presses are its own.
struct PanelWindowProbe: NSViewRepresentable {
    let report: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(report: report)
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        private let report: (NSWindow?) -> Void

        init(report: @escaping (NSWindow?) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report(window)
        }
    }
}
