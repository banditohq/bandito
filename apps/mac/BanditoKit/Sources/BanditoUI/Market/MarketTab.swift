import BanditoKit
import BanditoL10n
import Foundation

/// The three pages of the Marketplace. Bots and Skills show only when the server has the feature.
public enum MarketTab: String, CaseIterable, Identifiable, Sendable {
    case services, bots, skills

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .services: L10n.Market.Tab.services
        case .bots: L10n.Market.Tab.bots
        case .skills: L10n.Market.Tab.skills
        }
    }

    /// The daemon feature the page needs.
    public var feature: String {
        switch self {
        case .services: "integrations"
        case .bots: "agent_templates"
        case .skills: "skills"
        }
    }

    /// The pages this server offers, in display order. Services is always there: without the feature it explains that
    /// the server is too old.
    public static func available(supports: (String) -> Bool) -> [MarketTab] {
        allCases.filter { $0 == .services || supports($0.feature) }
    }

    /// The page to show: the one the person chose, or Services when the server does not offer it.
    public static func effective(_ chosen: MarketTab, available: [MarketTab]) -> MarketTab {
        available.contains(chosen) ? chosen : .services
    }

    /// The sidebar rows of the page: All, then what the page filters by (Bots: My bots), then its categories.
    public func filterRows(categories: [String]) -> [MarketFilter] {
        switch self {
        case .services: [.all, .connected] + categories.map { .category($0) }
        case .bots: [.all, .myBots] + categories.map { .category($0) }
        case .skills: [.all, .installed] + categories.map { .category($0) }
        }
    }
}

/// The page the person left the Marketplace on, kept per viewer in the app's own defaults.
public enum MarketTabStore {
    static let key = "market.tab.v1"

    public static func load(defaults: UserDefaults = .standard) -> MarketTab {
        defaults.string(forKey: key).flatMap(MarketTab.init(rawValue:)) ?? .services
    }

    public static func save(_ tab: MarketTab, defaults: UserDefaults = .standard) {
        defaults.set(tab.rawValue, forKey: key)
    }
}
