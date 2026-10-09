import BanditoUI
import SwiftUI

@main
struct BanditoApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.connectAll() }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unifiedCompact)
    }
}
