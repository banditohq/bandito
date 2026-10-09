import Foundation

/// A terminal command issued from the menu bar (⌘T, ⌘W, ⌥⌘ arrows…). `Router.terminalRequest` carries it to the
/// Terminals mode, which performs it and clears the request. Each request has its own `id`, so the same
/// command can be issued twice in a row.
public struct TerminalRequest: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case new, splitVertical, splitHorizontal, collapse, restoreLast, close, fullscreen, clear
        case fontBigger, fontSmaller, fontReset
        case move(TerminalDirection)
    }

    public let action: Action
    public let id = UUID()

    public init(_ action: Action) {
        self.action = action
    }
}
