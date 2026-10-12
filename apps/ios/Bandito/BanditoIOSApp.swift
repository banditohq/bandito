import BanditoDesign
import SwiftUI

@main
struct BanditoIOSApp: App {
    init() {
        // The brand fonts are registered once, before the first view asks for them.
        BanditoFont.registerBundledFonts()
        BrandAppearance.apply()
        // The background check and the notification categories are registered before the first screen (Apple's rule).
        BackgroundRefresh.register()
        IOSNotifications.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
