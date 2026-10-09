import BanditoL10n

/// The sections of the Settings window, in the order of the left navigation.
public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, account, servers, approvals, usage, workplaces, terminalFiles, browserScreen
    case keysGestures, notifications, appearance, language

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: L10n.Settings.Nav.general
        case .account: L10n.Settings.Nav.account
        case .servers: L10n.Settings.Nav.servers
        case .approvals: L10n.Settings.Nav.approvals
        case .usage: L10n.Settings.Nav.usage
        case .workplaces: L10n.Settings.Nav.workplaces
        case .terminalFiles: L10n.Settings.Nav.terminalFiles
        case .browserScreen: L10n.Settings.Nav.browserScreen
        case .keysGestures: L10n.Settings.Nav.keysGestures
        case .notifications: L10n.Settings.Nav.notifications
        case .appearance: L10n.Settings.Nav.appearance
        case .language: L10n.Settings.Nav.language
        }
    }

    /// Glyph in the navigation badge, as in the design.
    public var glyph: String {
        switch self {
        case .general: "◐"
        case .account: "☁"
        case .servers: "⌁"
        case .approvals: "✓"
        case .usage: "▮"
        case .workplaces: "▣"
        case .terminalFiles: "›_"
        case .browserScreen: "◎"
        case .keysGestures: "⌘"
        case .notifications: "◔"
        case .appearance: "✦"
        case .language: "Aa"
        }
    }
}
