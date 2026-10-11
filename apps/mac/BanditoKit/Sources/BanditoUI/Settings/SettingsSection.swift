import BanditoL10n
import SwiftUI

/// The sections of the Settings window, in the order of the left navigation. The interface language lives in General.
public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, account, servers, approvals, usage, terminalFiles, browserScreen
    case keysGestures, notifications, telegram, sounds, appearance, updates

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: L10n.Settings.Nav.general
        case .account: L10n.Settings.Nav.account
        case .servers: L10n.Settings.Nav.servers
        case .approvals: L10n.Settings.Nav.approvals
        case .usage: L10n.Settings.Nav.usage
        case .terminalFiles: L10n.Settings.Nav.terminalFiles
        case .browserScreen: L10n.Settings.Nav.browserScreen
        case .keysGestures: L10n.Settings.Nav.keysGestures
        case .notifications: L10n.Settings.Nav.notifications
        case .telegram: L10n.Settings.Nav.telegram
        case .sounds: L10n.Settings.Nav.sounds
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
        case .terminalFiles: "terminal"
        case .browserScreen: "globe"
        case .keysGestures: "keyboard"
        case .notifications: "bell.badge"
        case .telegram: "paperplane.fill"
        case .sounds: "speaker.wave.2"
        case .appearance: "paintbrush"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }

    /// Fill of the navigation badge: one color per section, all different, as in System Settings.
    var tint: Color {
        switch self {
        case .general: BanditoPalette.badgeGray
        case .account: BanditoPalette.badgeBlue
        case .servers: BanditoPalette.badgeGreen
        case .approvals: BanditoPalette.badgeOrange
        case .usage: BanditoPalette.badgePurple
        case .terminalFiles: BanditoPalette.badgeDarkGray
        case .browserScreen: BanditoPalette.badgeLightBlue
        case .keysGestures: BanditoPalette.badgePink
        case .notifications: BanditoPalette.badgeRed
        case .telegram: BanditoPalette.badgeTeal
        case .sounds: BanditoPalette.badgeBrown
        case .appearance: BanditoPalette.badgeIndigo
        case .updates: BanditoPalette.badgeSlate
        }
    }
}
