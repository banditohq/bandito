import Foundation

/// The Dock icon's badge: the unread replies of the connected servers, or nothing. Pure, so tested alone.
enum DockBadgeRules {
    /// The switch in Settings → Notifications (`NotificationsSection`). On by default.
    static let defaultsKey = "notify.dockBadge"

    static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// The sum of the servers' counts; a count below zero counts as nothing.
    static func total(_ counts: [Int]) -> Int {
        counts.reduce(0) { $0 + max(0, $1) }
    }

    /// The badge's text: nil when the switch is off or nothing is unread, else the count ("99+" above 99, as the rows).
    static func label(total: Int, enabled: Bool) -> String? {
        enabled ? UnreadRules.badge(total) : nil
    }
}
