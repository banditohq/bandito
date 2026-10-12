import BanditoDesign
import SwiftUI
import UIKit

/// The tab bar in the brand's colors: it sits on the warm ground, cream for the selected item, the secondary tone for the
/// rest. The navigation bar is left to SwiftUI (transparent, `toolbarBackground(.hidden)` in the Crew screen): a UIKit
/// navigation appearance with a background color hid the large title.
@MainActor
enum BrandAppearance {
    /// The brand color as a UIKit color that follows the theme: resolved again for each trait collection, so light and
    /// dark never share one value.
    static func brand(_ color: Color) -> UIColor {
        let base = UIColor(color)
        return UIColor { traits in base.resolvedColor(with: traits) }
    }

    static func apply() {
        let ground = brand(Color.Bandito.bg)
        let cream = brand(Color.Bandito.text)
        let quiet = brand(Color.Bandito.text3)

        let item = UITabBarItemAppearance()
        item.selected.iconColor = cream
        item.selected.titleTextAttributes = [.foregroundColor: cream]
        item.normal.iconColor = quiet
        item.normal.titleTextAttributes = [.foregroundColor: quiet]

        let tabs = UITabBarAppearance()
        tabs.configureWithOpaqueBackground()
        tabs.backgroundColor = ground
        tabs.stackedLayoutAppearance = item
        tabs.inlineLayoutAppearance = item
        tabs.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs
    }
}
