import Foundation

/// Which place on screen shows the terminal views of one server. A terminal view (an NSView) can sit in one place
/// only, so a place draws the pane only while it is the owner; the others show a stub. Last claim wins; a release
/// clears the owner only when the releasing place is the owner. Pure, so it is tested alone.
struct TerminalDisplayOwner: Equatable, Sendable {
    /// The Terminals mode.
    static let terminals = "terminals"

    /// The place of a pane of an agent's workbench.
    static func workbench(agentID: String, pane: Int) -> String {
        "workbench:\(agentID):\(pane)"
    }

    private(set) var place: String?

    init(place: String? = nil) {
        self.place = place
    }

    func isOwner(_ place: String) -> Bool {
        self.place == place
    }

    mutating func claim(_ place: String) {
        self.place = place
    }

    mutating func release(_ place: String) {
        if self.place == place { self.place = nil }
    }
}
