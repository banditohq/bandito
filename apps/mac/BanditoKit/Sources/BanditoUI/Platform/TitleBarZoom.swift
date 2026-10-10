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

/// Zooms (or minimizes) the window the way the system's double-click setting says.
enum TitleBarZoom {
    #if os(macOS)
    @MainActor
    static func perform(on window: NSWindow?) {
        guard let window else { return }
        switch TitleBarDoubleClick.action(for: TitleBarDoubleClick.systemValue) {
        case .zoom: window.zoom(nil)
        case .minimize: window.miniaturize(nil)
        case .none: break
        }
    }
    #endif
}

#if os(macOS)
extension View {
    /// Double-click on the empty part of a title strip zooms the window. The strip's controls keep their clicks: a
    /// button or a field takes the gesture first, so only the empty space around them reacts.
    func titleBarZoomOnDoubleClick() -> some View {
        background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    TitleBarZoom.perform(on: NSApp.keyWindow ?? NSApp.mainWindow)
                }
        }
    }
}

/// An empty strip of the title area that zooms the window on a double-click, as Safari does, and moves the window on
/// a drag, as the title bar does. Put it only where no control sits: it takes the mouse there.
struct TitleBarZoomArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        TitleBarZoomView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class TitleBarZoomView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        guard event.clickCount == 2 else {
            window.performDrag(with: event)
            return
        }
        TitleBarZoom.perform(on: window)
    }
}
#else
struct TitleBarZoomArea: View {
    var body: some View { Color.clear }
}

extension View {
    func titleBarZoomOnDoubleClick() -> some View { self }
}
#endif
