#if os(macOS)
import AppKit
import SwiftUI

/// Typing without a click: a printable key pressed while nothing takes text (after a click on the thread, a message, the
/// sidebar or the empty window) goes to the composer of the agent on screen. The rule is `ComposerFocus.shouldRedirectTyping`.
///
/// How: a local key monitor, not `onKeyPress`. `onKeyPress` only hears a view that has the focus, and a click on an AppKit
/// table (the thread) or the window's ground gives the focus to none of ours. The monitor sees the key first, asks the
/// composer for the keyboard, and gives the very same event again once the field has it (`NSApp.postEvent`), so the field
/// gets the real key press: a layout's character, ⇧, ⌥, and the first key of an input method (Japanese, Chinese) all arrive
/// as if the field had had the keyboard all along. Nothing is typed by hand, so nothing is lost or reordered.
/// The monitor's answer, carried out of the main-actor hop (`NSEvent` is not `Sendable`; it never leaves the main thread).
private struct HandledEvent: @unchecked Sendable {
    var event: NSEvent?
}

@MainActor
final class ComposerTypeAhead {
    /// The window of the chat, and the state the rule needs, read at the moment of each key.
    var window: () -> NSWindow? = { nil }
    var isEnabled: () -> Bool = { false }
    var chatShown: () -> Bool = { false }
    var modalOpen: () -> Bool = { false }
    /// Asks the composer of the agent on screen for the keyboard (`Router.requestComposerFocus`).
    var requestFocus: () -> Void = {}
    /// Gives a held press back to the app, in front of its queue (a test catches them instead).
    var post: (NSEvent) -> Void = { NSApp.postEvent($0, atStart: true) }

    /// Only a key window gets typing (always, in the app); a test with a window nobody sees turns it off.
    var requiresKeyWindow = true

    private var monitor: Any?
    private(set) var queue = TypeAheadQueue<NSEvent>()
    /// Presses given back to the window: they pass this monitor once.
    private var returned: [Stamp] = []
    private struct Stamp: Equatable {
        var time: TimeInterval
        var keyCode: UInt16
    }

    /// How long the field gets to take the keyboard: ten turns of 10 ms.
    private static let attempts = 10
    private static let step: DispatchTimeInterval = .milliseconds(10)

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { HandledEvent(event: self.handle(event)) }.event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        queue = TypeAheadQueue()
        returned = []
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        let stamp = Stamp(time: event.timestamp, keyCode: event.keyCode)
        if let index = returned.firstIndex(of: stamp) {
            returned.remove(at: index)
            return event
        }
        guard isEnabled(), let window = window(), event.window === window, window.isKeyWindow || !requiresKeyWindow else { return event }
        let flags = event.modifierFlags
        let key = ComposerFocus.TypedKey(
            characters: event.characters ?? "", command: flags.contains(.command), control: flags.contains(.control),
            option: flags.contains(.option))
        let redirect = ComposerFocus.shouldRedirectTyping(
            key: key, responder: Self.classify(window.firstResponder),
            modalOpen: modalOpen() || window.attachedSheet != nil || NSApp.modalWindow != nil, chatShown: chatShown())
        guard redirect else { return event }
        if queue.hold(event) {
            requestFocus()
            wait(window: window, attempt: 0)
        }
        return nil
    }

    /// Gives the held presses back once the field has the keyboard, or when it did not get it in time (they then reach
    /// whatever has it, as they would have without this).
    private func wait(window: NSWindow, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? .milliseconds(0) : Self.step)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.queue.isWaiting else { return }
                if Self.classify(window.firstResponder) == .textInput || attempt >= Self.attempts {
                    self.giveBack()
                } else {
                    self.wait(window: window, attempt: attempt + 1)
                }
            }
        }
    }

    private func giveBack() {
        // The field took the keyboard a moment ago: SwiftUI may have selected its text. The key is typed after it, not over it.
        if let editor = window()?.firstResponder as? NSTextView, editor.isEditable {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
        let events = queue.release()
        returned += events.map { Stamp(time: $0.timestamp, keyCode: $0.keyCode) }
        // At the front of the queue, last first: they come out in the order they were typed, before anything newer.
        for event in events.reversed() { post(event) }
    }

    /// What the keyboard is on: a field or an editable text takes text, a read-only text, a table, a scroll view or the
    /// window itself does not, any other view has keys of its own (the terminal, the browser).
    static func classify(_ responder: NSResponder?) -> ComposerFocus.Responder {
        guard let responder else { return .inert }
        if let text = responder as? NSTextView {
            return text.isEditable || text.isFieldEditor ? .textInput : .inert
        }
        if responder is NSTextField { return .textInput }
        if responder is NSWindow { return .inert }
        if let view = responder as? NSView {
            if view is NSTableView || view is NSTableRowView || view is NSScrollView || view is NSClipView {
                return .inert
            }
            // SwiftUI's own host (a click on a stretch of the window with no control).
            if String(describing: type(of: view)).contains("HostingView") { return .inert }
            return .other
        }
        return .other
    }
}

/// Puts the monitor under the chat: it lives while the chat is on screen, and reads the window and the router when a key comes.
struct ComposerTypeAheadAnchor: NSViewRepresentable {
    var agentID: String
    /// False while the chat is out of sight (kept under another mode).
    var active: Bool
    var router: Router

    func makeCoordinator() -> ComposerTypeAhead { ComposerTypeAhead() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let model = context.coordinator
        model.window = { [weak view] in view?.window }
        model.start()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let model = context.coordinator
        let agentID = agentID, active = active, router = router
        model.isEnabled = { active }
        model.chatShown = { active && router.shownAgentID == agentID }
        model.modalOpen = {
            router.sheet != nil || router.paletteOpen || router.imageViewer != nil || router.dictationRecording
        }
        model.requestFocus = { router.requestComposerFocus(agentID: agentID) }
    }

    static func dismantleNSView(_ view: NSView, coordinator: ComposerTypeAhead) {
        coordinator.stop()
    }
}
#endif

extension View {
    /// Typing with no field focused goes to this agent's composer (see `ComposerFocus.shouldRedirectTyping`).
    @ViewBuilder
    func typesIntoComposer(agentID: String, active: Bool, router: Router) -> some View {
        #if os(macOS)
        background(ComposerTypeAheadAnchor(agentID: agentID, active: active, router: router).frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}
