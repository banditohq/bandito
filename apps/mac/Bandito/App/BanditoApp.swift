import BanditoUI
import SwiftUI

@main
struct BanditoApp: App {
    @State private var model = AppModel()
    @State private var router = Router()
    @State private var keymap = Keymap()
    @State private var gestures = GestureSettings()
    @State private var demo = DemoStore()
    @State private var onboarding = OnboardingModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .environment(keymap)
                .environment(gestures)
                .environment(demo)
                .environment(onboarding)
                .task {
                    await model.connectAll()
                    // Servers are connected by now, so their agents are known.
                    onboarding.evaluate(hasServerWithAgents: model.servers.contains { !$0.agents.isEmpty })
                }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            BanditoCommands(keymap: keymap, router: router, app: model, onboarding: onboarding)
        }

        Settings {
            SettingsWindow()
                .environment(model)
                .environment(router)
                .environment(keymap)
                .environment(gestures)
                .environment(demo)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(demo)
        } label: {
            MenuBarLabel(app: model)
        }
        .menuBarExtraStyle(.window)
    }
}
