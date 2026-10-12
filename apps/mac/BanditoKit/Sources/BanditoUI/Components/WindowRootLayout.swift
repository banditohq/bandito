import SwiftUI

/// The root of a window's content: it tells the window its size without measuring what is inside.
///
/// A SwiftUI window asks its content for its smallest and largest size whenever anything in it is laid out again (the
/// hosting view's size constraints). With a `.frame(minWidth:minHeight:)` at the root that question went down the whole
/// tree, every row of every list, built or not: on the Services page it was 30 % of the main thread while scrolling,
/// and every page paid it on every change. This layout answers from its limits alone and gives its content the
/// window's size, as the frame did.
struct WindowRootLayout: Layout {
    var minWidth: CGFloat
    var minHeight: CGFloat
    /// The size asked for when the window opens (no size proposed).
    var idealWidth: CGFloat?
    var idealHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(
            width: max(minWidth, proposal.width ?? idealWidth ?? minWidth),
            height: max(minHeight, proposal.height ?? idealHeight ?? minHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }
}

extension View {
    /// Makes this view the root of a window that is at least `minWidth` × `minHeight` (see `WindowRootLayout`).
    func windowRoot(
        minWidth: CGFloat, minHeight: CGFloat, idealWidth: CGFloat? = nil, idealHeight: CGFloat? = nil
    ) -> some View {
        WindowRootLayout(minWidth: minWidth, minHeight: minHeight, idealWidth: idealWidth, idealHeight: idealHeight) {
            self
        }
    }
}
