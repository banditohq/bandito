import BanditoL10n
import SwiftUI

/// The sections of the Settings window, in the order of the left navigation. The interface language lives in General.
public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, account, servers, approvals, usage, workplaces, terminalFiles, browserScreen
    case keysGestures, notifications, appearance, updates

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
        case .updates: L10n.Settings.Nav.updates
        }
    }

    /// SF Symbol in the navigation badge, as in System Settings.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .account: "person.crop.circle"
        case .servers: "server.rack"
        case .approvals: "checkmark.shield"
        case .usage: "gauge.medium"
        case .workplaces: "square.stack.3d.up"
        case .terminalFiles: "terminal"
        case .browserScreen: "globe"
        case .keysGestures: "keyboard"
        case .notifications: "bell.badge"
        case .appearance: "paintbrush"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }

    /// Fill of the navigation badge: one color per section, as in System Settings.
    var tint: Color {
        switch self {
        case .general, .keysGestures, .updates: BanditoPalette.badgeGray
        case .account: BanditoPalette.badgeBlue
        case .servers: BanditoPalette.badgeGreen
        case .approvals: BanditoPalette.badgeOrange
        case .usage: BanditoPalette.badgePurple
        case .workplaces: BanditoPalette.badgeTeal
        case .terminalFiles: BanditoPalette.badgeDarkGray
        case .browserScreen: BanditoPalette.badgeLightBlue
        case .notifications: BanditoPalette.badgeRed
        case .appearance: BanditoPalette.badgeIndigo
        }
    }
}
