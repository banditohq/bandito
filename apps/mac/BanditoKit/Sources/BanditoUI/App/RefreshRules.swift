import Foundation

/// What ⌘R re-reads, by the mode on show. The thread and the folder reload in their own views, when the router counts
/// a refresh; the terminals and the browser page are asked by the app. Pure, so tested alone.
enum RefreshRules {
    enum Reload: Equatable, Sendable {
        case thread
        case folder
        case terminals
        case browserPage
    }

    static func reloads(for mode: AppMode) -> [Reload] {
        switch mode {
        case .team: [.thread]
        case .files: [.folder]
        case .terminals: [.terminals]
        case .browser: [.browserPage]
        case .screen, .market, .server: []
        }
    }
}
