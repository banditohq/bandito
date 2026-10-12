import AppIntents

/// The phrases Siri and Spotlight know. Each phrase has `\(.applicationName)`; the other languages are in
/// `Resources/<code>.lproj/AppShortcuts.strings`, keyed by these English phrases.
struct BanditoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatNeedsMeIntent(),
            phrases: ["What needs me in \(.applicationName)"],
            shortTitle: "What needs me",
            systemImageName: "tray")
        AppShortcut(
            intent: AskAgentIntent(),
            phrases: ["Ask \(\.$agent) in \(.applicationName)"],
            shortTitle: "Ask an agent",
            systemImageName: "bubble.left.and.bubble.right")
        AppShortcut(
            intent: OpenAgentIntent(),
            phrases: ["Open \(\.$agent) in \(.applicationName)"],
            shortTitle: "Open an agent",
            systemImageName: "person.crop.circle")
    }

    /// The brand's signal orange on the shortcut tiles.
    static var shortcutTileColor: ShortcutTileColor { .orange }
}
