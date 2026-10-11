import SwiftUI

/// The first of a few candidates whose own width fits the width offered, as `ViewThatFits(in: .horizontal)` chooses,
/// and it takes all the width offered.
///
/// `ViewThatFits` measured all its candidates again at every layout of the window: a toolbar or a header with a field
/// and menus in each candidate cost 100–200 ms at every change of the page under it (the Marketplace's categories, the
/// Files toolbar). Here each candidate is measured once at its own width, out of sight, and again only when it changes;
/// the choice is made from those widths and the offered width (`FirstFitRule`).
///
/// The builder gets the candidate's index and whether it is built to be measured: a measured copy is never shown, so
/// fields, popovers and overlays that do not change its width can be left out of it (a field with the same width in a
/// placeholder), and actions in it never run.
struct FirstFit<Candidate: View>: View {
    let count: Int
    var alignment: Alignment = .leading
    @ViewBuilder let candidate: (_ index: Int, _ measuring: Bool) -> Candidate

    @State private var widths: [Int: CGFloat] = [:]
    @State private var available: CGFloat?

    var body: some View {
        candidate(FirstFitRule.index(available: available, widths: widths, count: count), false)
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                if available != width { available = width }
            }
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<count, id: \.self) { index in
                        candidate(index, true)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                if widths[index] != width { widths[index] = width }
                            }
                    }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

/// Which candidate of a `FirstFit` shows.
enum FirstFitRule {
    /// The first candidate whose width fits `available`; the last when none does. While the offered width is not known,
    /// the first; a candidate not measured yet is taken as fitting (it is measured in the same pass).
    static func index(available: CGFloat?, widths: [Int: CGFloat], count: Int) -> Int {
        guard count > 1, let available else { return 0 }
        for index in 0..<(count - 1) {
            guard let width = widths[index] else { return index }
            if width <= available + 0.5 { return index }
        }
        return count - 1
    }
}
