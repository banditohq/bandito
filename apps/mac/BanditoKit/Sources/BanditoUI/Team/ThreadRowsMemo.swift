import BanditoKit
import SwiftUI

/// The rows of one thread, made again only when its items changed. A stream changes only the last item, and its row is
/// that item: only that row is replaced, and the version says so (`lastOnlyFrom`), so the list remakes one line, not all.
@MainActor
final class ThreadRowsMemo {
    private var builtFrom: [ThreadItem] = []
    private var built: [ThreadRow] = []
    /// Counts the changes of the rows.
    private(set) var version = 0
    /// When the last change replaced only the last row: the version before it.
    private(set) var lastOnlyFrom: Int?

    func rows(of items: [ThreadItem]) -> [ThreadRow] {
        if items.count == builtFrom.count, items == builtFrom { return built }
        if let replaced = ThreadRows.replacingLast(built, from: builtFrom, to: items) {
            builtFrom = items
            built = replaced
            lastOnlyFrom = version
            version &+= 1
            return built
        }
        builtFrom = items
        built = ThreadRows.build(items)
        lastOnlyFrom = nil
        version &+= 1
        return built
    }
}

/// Reads the thread for the rows in a view of its own: a streamed token draws this again, not the chat around it.
struct ThreadRowsScope<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}
