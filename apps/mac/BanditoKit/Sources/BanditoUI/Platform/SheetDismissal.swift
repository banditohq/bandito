import SwiftUI

public extension View {
    /// A sheet that also closes on a click outside it (on the window behind) and on Esc, like a popover.
    /// Use it instead of `.sheet(isPresented:)` everywhere in the app.
    /// - Parameter dismissOnOutsideClick: false keeps the sheet open on outside clicks (Esc still closes it), for a
    ///   sheet in the middle of work that must not be lost by a stray click.
    func banditoSheet<Content: View>(
        isPresented: Binding<Bool>,
        dismissOnOutsideClick: Bool = true,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(SheetDismissal(outsideClick: dismissOnOutsideClick))
        }
    }

    /// As `banditoSheet(isPresented:)`, for a sheet driven by an optional item.
    func banditoSheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        dismissOnOutsideClick: Bool = true,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss) { value in
            content(value).modifier(SheetDismissal(outsideClick: dismissOnOutsideClick))
        }
    }
}

/// Closes the sheet it is applied to on Esc and, when `outsideClick` is on, on a mouse click in the window the
/// sheet is attached to. The click that closes the sheet is not passed on to the window behind.
struct SheetDismissal: ViewModifier {
    let outsideClick: Bool
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .background {
                // Esc: a zero-size button with the cancel shortcut. A sheet's own Cancel button may have the same
                // shortcut; either way the sheet closes.
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                #if os(macOS)
                if outsideClick {
                    SheetWindowReader { window in
                        OutsideClickMonitor.shared.register(sheet: window) { dismiss() }
                    } onDetach: { window in
                        OutsideClickMonitor.shared.unregister(sheet: window)
                    }
                    .frame(width: 0, height: 0)
                }
                #endif
            }
    }
}

#if os(macOS)
import AppKit

/// One app-wide monitor of mouse-down events. A click in a window whose attached sheet asked for it closes that
/// sheet (the topmost one, when sheets are stacked) and is swallowed.
@MainActor
final class OutsideClickMonitor {
    static let shared = OutsideClickMonitor()

    private struct Entry {
        weak var sheet: NSWindow?
        let dismiss: () -> Void
    }

    private var handlers: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?

    func register(sheet: NSWindow, dismiss: @escaping () -> Void) {
        // Sheets that are gone drop out here, so an identifier reused by a new window never finds an old closure.
        handlers = handlers.filter { $0.value.sheet != nil }
        handlers[ObjectIdentifier(sheet)] = Entry(sheet: sheet, dismiss: dismiss)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Local monitors run on the main thread. Only the window's number crosses into the main actor.
            let number = event.windowNumber
            let closed = MainActor.assumeIsolated { OutsideClickMonitor.shared.handleClick(inWindowNumber: number) }
            return closed ? nil : event
        }
    }

    func unregister(sheet: NSWindow) {
        handlers[ObjectIdentifier(sheet)] = nil
    }

    /// True when the event closed a sheet and must not reach its window.
    private func handleClick(inWindowNumber number: Int) -> Bool {
        guard let window = NSApp.window(withWindowNumber: number), let sheet = window.attachedSheet,
            let entry = handlers[ObjectIdentifier(sheet)], entry.sheet === sheet
        else { return false }
        entry.dismiss()
        return true
    }
}

/// Reports the window its view is in (the sheet's window) once it is attached, and again when it goes away.
private struct SheetWindowReader: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void
    let onDetach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void, onDetach: @escaping (NSWindow) -> Void) {
        self.onAttach = onAttach
        self.onDetach = onDetach
    }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onAttach = onAttach
        view.onDetach = onDetach
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onAttach = onAttach
        view.onDetach = onDetach
    }

    final class ReaderView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        var onDetach: ((NSWindow) -> Void)?
        private weak var current: NSWindow?

        deinit {
            // The sheet's content can go away without moving out of its window first.
            if let current { MainActor.assumeIsolated { onDetach?(current) } }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let old = current, old !== window { onDetach?(old) }
            current = window
            if let window { onAttach?(window) }
        }
    }
}

#endif
