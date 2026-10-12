import BanditoDesign
import SwiftUI

@main
struct BanditoIOSApp: App {
    init() {
        // The brand fonts are registered once, before the first view asks for them.
        BanditoFont.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
