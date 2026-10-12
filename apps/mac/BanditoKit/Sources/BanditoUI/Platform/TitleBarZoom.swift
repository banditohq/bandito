import SwiftUI

#if os(macOS)
import AppKit
#endif

/// What a double-click on the window's empty title strip does. It follows the system setting "Double-click a window's
/// title bar to", which macOS stores as `AppleActionOnDoubleClick` in the global domain.
public enum TitleBarDoubleClick {
    public enum Action: Equatable, Sendable {
        /// Zoom: the window takes the whole screen without making a Space; the next double-click restores it.
        case zoom
        case minimize
        case none
    }

    /// The action for the stored system value. "Maximize" and "Fill" zoom, "Minimize" minimizes, "None" does nothing.
    /// Anything else, or no value, zooms: that is the system default.
    public static func action(for systemValue: String?) -> Action {
        switch systemValue {
        case "Minimize": .minimize
        case "None": .none
        default: .zoom
        }
    }

    /// The setting as the system stores it. Standard defaults read the global domain when the app has no value of its own.
    static var systemValue: String? {
        UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
    }
}

/// Zooms (or minimizes) the window the way the system's double-click setting says, and moves it on a drag.
enum TitleBarZoom {
    #if os(macOS)
    /// `performZoom` is the system's zoom: the window takes the screen's visible size and goes back on the next
    /// double-click. It does not make a full-screen Space, as the green button does.
    @MainActor
    static func perform(on window: NSWindow?) {
        guard let window else { return }
        switch TitleBarDoubleClick.action(for: TitleBarDoubleClick.systemValue) {
        case .zoom: window.performZoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }

    /// The double-click of a title strip: zooms the key window (or the main one). The QA hook `zoom` calls the same.
    @MainActor
    static func doubleClick() {
        perform(on: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// Moves the window with the mouse held down. `event` is the mouse event that started the drag.
    @MainActor
    static func drag(on window: NSWindow?, event: NSEvent?) {
        guard let window, let event else { return }
        window.performDrag(with: event)
    }
    #endif
}

#if os(macOS)
/// The title strip of a window with a hidden title bar. The content starts below the title bar's safe area
/// (`inset`, where the traffic lights sit); the strip is the area above the content plus the first 52 pt of it
/// (the sidebar's top row, the main area's header row).
enum TitleBarBand {
    static let height: CGFloat = 52
    static let inset: CGFloat = 28
}

extension View {
    /// The title strip of the view's top edge, drawn behind the content: a double-click on its empty part zooms the
    /// window and a drag moves it. It runs up under the title bar's safe area, so the strip above the content (where
    /// the traffic lights are) reacts too. Buttons and fields keep their own clicks, because the content is in front
    /// of this layer; only the empty space reacts. Apply it before any opaque background of the view.
    func titleBarBand() -> some View {
        background(alignment: .top) {
            TitleBarBandSurface()
                .frame(height: TitleBarBand.height + TitleBarBand.inset)
                .ignoresSafeArea(.container, edges: .top)
        }
        // The strip above the content takes its clicks directly (no control is there).
        .overlay(alignment: .top) {
            TitleBarZoomStrip()
                .frame(height: TitleBarBand.inset)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    /// Double-click on the empty part of a title strip zooms the window. The strip's controls keep their clicks: a
    /// button or a field takes the gesture first, so only the empty space around them reacts.
    func titleBarZoomOnDoubleClick() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    TitleBarZoom.doubleClick()
                }
        }
    }
}

/// The empty space of the title band: a double-click zooms, a drag moves the window.
private struct TitleBarBandSurface: View {
    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                TitleBarZoom.doubleClick()
            }
            .modifier(TitleBarDragModifier())
    }
}

/// Moves the window with a drag from the band. macOS 15 has `WindowDragGesture`, which SwiftUI uses for this; on
/// macOS 14 (the deployment target) the drag hands the window to AppKit's `performDrag(with:)`, once per gesture.
private struct TitleBarDragModifier: ViewModifier {
    @State private var dragging = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.gesture(WindowDragGesture())
        } else {
            content.gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { _ in
                        guard !dragging else { return }
                        dragging = true
                        TitleBarZoom.drag(on: NSApp.keyWindow ?? NSApp.mainWindow, event: NSApp.currentEvent)
                    }
                    .onEnded { _ in dragging = false })
        }
    }
}

/// The strip above the content of a window with a hidden title bar (where the traffic lights are). Nothing in it is a
/// control, so this view takes the clicks there: a double-click zooms the window, a drag moves it.
struct TitleBarZoomStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleBarStripView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleBarStripView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            window?.performDrag(with: event)
            return
        }
        TitleBarZoom.perform(on: window)
    }
}
#else
struct TitleBarZoomStrip: View {
    var body: some View { Color.clear }
}

extension View {
    func titleBarZoomOnDoubleClick() -> some View { self }

    func titleBarBand() -> some View { self }
}
#endif
