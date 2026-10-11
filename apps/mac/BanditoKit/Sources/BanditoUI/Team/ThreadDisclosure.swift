import SwiftUI

/// Which folded parts of the thread's rows are open (a tool group, an answered form), kept outside the rows: the list
/// reuses a row's cell when the row scrolls away, and state kept in the row would be lost with it.
@MainActor
@Observable
final class ThreadDisclosure {
    static let shared = ThreadDisclosure()

    init() {}

    private(set) var open: Set<String> = []

    func isOpen(_ key: String) -> Bool { open.contains(key) }

    func toggle(_ key: String) {
        if open.contains(key) { open.remove(key) } else { open.insert(key) }
    }
}
