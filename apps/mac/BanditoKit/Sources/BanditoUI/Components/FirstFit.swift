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
///
/// Until the widths are known (the first layout, or a picture made in one pass) it is a `ViewThatFits`, so the first
/// frame is already the right candidate.
///
/// With a `memory` key, the widths outlive the view (`FirstFitMemory`): the same toolbar made again (a return to
/// Files) shows the candidate chosen last time at once, measures nothing, and only checks the choice against the
/// width it gets. The key must name everything the candidates' widths depend on. With `persists`, they are kept in the
/// defaults too (for this build), so the first visit after a launch is quick as well.
struct FirstFit<Candidate: View>: View {
    let count: Int
    var alignment: Alignment = .leading
    var memory: String? = nil
    var persists = false
    @ViewBuilder let candidate: (_ index: Int, _ measuring: Bool) -> Candidate

    /// The candidate shown: written only when the choice changes, so a window being resized does not rebuild it.
    @State private var chosen: Int?
    @State private var sizes = FirstFitSizes()
    @Environment(\.locale) private var locale

    var body: some View {
        let remembered = rememberedWidths
        Group {
            if let shown = chosen ?? remembered.map({ FirstFitRule.index(available: $0.available, widths: $0.widths, count: count) }) {
                candidate(shown, false)
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach(0..<count, id: \.self) { index in candidate(index, false) }
                }
            }
        }
            .frame(maxWidth: .infinity, alignment: alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                sizes.available = width
                choose()
            }
            .background(alignment: .topLeading) {
                if remembered == nil {
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
                    // A measured copy never acts: its buttons' keyboard shortcuts stay with the shown candidate.
                    .disabled(true)
                    .accessibilityHidden(true)
                }
            }
            // Another language: the widths are measured again, and the compact candidate stands until they are.
            .onChange(of: locale) { _, _ in
                sizes.widths.removeAll()
                choose()
            }
    }

    /// The widths kept under `memory` for this language, with the width offered last time.
    private var rememberedWidths: FirstFitMemory.Entry? {
        guard let memory, let entry = FirstFitMemory.entry(memory, locale: locale.identifier, persists: persists),
            entry.widths.count >= count
        else { return nil }
        return entry
    }

    private func choose() {
        // Until everything is measured (or remembered) the `ViewThatFits` stands.
        var widths = sizes.widths
        if widths.count < count, let remembered = rememberedWidths { widths = remembered.widths }
        guard let available = sizes.available, widths.count >= count else { return }
        if let memory, sizes.widths.count >= count || rememberedWidths != nil {
            FirstFitMemory.keep(
                memory, locale: locale.identifier, widths: widths, available: available, persists: persists)
        }
        let index = FirstFitRule.index(available: available, widths: widths, count: count)
        if chosen != index { chosen = index }
    }
}

/// The widths of `FirstFit` candidates by key and language, kept for the life of the app: a view made again chooses
/// from them at once. Small: a few toolbars and the trails of the folders visited.
@MainActor
enum FirstFitMemory {
    struct Entry {
        var widths: [Int: CGFloat]
        var available: CGFloat
    }

    private static var entries: [String: Entry] = [:]
    static let limit = 300

    static func entry(_ key: String, locale: String, persists: Bool = false) -> Entry? {
        let id = key + "|" + locale
        if let known = entries[id] { return known }
        guard persists, let stored = UserDefaults.standard.array(forKey: defaultsKey(id)) as? [Double], stored.count >= 2
        else { return nil }
        var widths: [Int: CGFloat] = [:]
        for (index, width) in stored.dropLast().enumerated() { widths[index] = CGFloat(width) }
        let entry = Entry(widths: widths, available: CGFloat(stored[stored.count - 1]))
        entries[id] = entry
        return entry
    }

    /// Kept for the app's life; in the defaults too with `persists`, written only when the widths change.
    static func keep(_ key: String, locale: String, widths: [Int: CGFloat], available: CGFloat, persists: Bool = false) {
        let id = key + "|" + locale
        if entries.count >= limit { entries.removeAll() }
        let old = entries[id]
        entries[id] = Entry(widths: widths, available: available)
        if persists, old?.widths != widths {
            let values = widths.keys.sorted().map { Double(widths[$0] ?? 0) } + [Double(available)]
            UserDefaults.standard.set(values, forKey: defaultsKey(id))
        }
    }

    /// Per build: another build may draw the candidates at other widths.
    private static func defaultsKey(_ id: String) -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "firstFit.\(build).\(id)"
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
