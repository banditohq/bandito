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

    /// The candidate shown: written only when the choice changes, so a window being resized does not rebuild it.
    @State private var chosen: Int?
    @State private var sizes = FirstFitSizes()
    @Environment(\.locale) private var locale

    var body: some View {
        candidate(chosen ?? max(count - 1, 0), false)
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                sizes.available = width
                choose()
            }
            .background(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<count, id: \.self) { index in
                        candidate(index, true)
                            .fixedSize()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                sizes.widths[index] = width
                                choose()
                            }
                    }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            // Another language: the widths are measured again, and the compact candidate stands until they are.
            .onChange(of: locale) { _, _ in
                sizes.widths.removeAll()
                choose()
            }
    }

    private func choose() {
        let index = FirstFitRule.index(available: sizes.available, widths: sizes.widths, count: count)
        if chosen != index { chosen = index }
    }
}

/// The widths a `FirstFit` measured, kept out of the observed state: a new width redraws nothing by itself.
@MainActor
final class FirstFitSizes {
    var available: CGFloat?
    var widths: [Int: CGFloat] = [:]
}

/// Which candidate of a `FirstFit` shows.
enum FirstFitRule {
    /// The first candidate whose width fits `available`; the last when none does. Until the offered width and the
    /// candidates are measured (the first layout), the last: the most compact never runs over the edge.
    static func index(available: CGFloat?, widths: [Int: CGFloat], count: Int) -> Int {
        guard count > 1 else { return 0 }
        guard let available, widths.count >= count else { return count - 1 }
        for index in 0..<(count - 1) where (widths[index] ?? .infinity) <= available + 0.5 {
            return index
        }
        return count - 1
    }
}
