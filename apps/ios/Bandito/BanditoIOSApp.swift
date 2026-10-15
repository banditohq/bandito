import BanditoDesign
import SwiftUI

@main
struct BanditoIOSApp: App {
    /// The icon's quick actions (New task, Inbox) reach the app through this delegate (`NewTask/QuickActions.swift`).
    @UIApplicationDelegateAdaptor(QuickActionAppDelegate.self) private var quickActionDelegate

    init() {
        // The brand fonts are registered once, before the first view asks for them.
        BanditoFont.registerBundledFonts()
        BrandAppearance.apply()
        // The background check and the notification categories are registered before the first screen (Apple's rule).
        BackgroundRefresh.register()
        IOSNotifications.shared.start()
        // Siri, Shortcuts and Spotlight can wake the app without its screens: the paired servers are loaded on first use.
        AppIntentHub.shared.liveServers = {
            ServerSession.shared.loadIfNeeded()
            return ServerSession.shared.current
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
