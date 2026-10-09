import AppKit
import BanditoUI
import SwiftUI

@main
struct BanditoApp: App {
    @State private var model: AppModel
    @State private var router = Router()
    @State private var keymap = Keymap()
    @State private var gestures = GestureSettings()
    @State private var demo = DemoStore()
    @State private var onboarding: OnboardingModel

    init() {
        // Saved servers are read synchronously by AppModel, so the first frame already knows the launch state.
        let app = AppModel()
        _model = State(initialValue: app)
        _onboarding = State(initialValue: OnboardingModel(hasSavedServers: !app.servers.isEmpty))
    }

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
                    // Actions aimed at the server that was in front are dropped when another one is chosen.
                    model.onServerChanged = { [router] in router.dropPendingServerActions() }
                    model.startNotifications(
                        selectedAgentID: { [router] in
                            router.mode == .team ? router.selectedAgentID : nil
                        },
                        windowActive: { NSApp.isActive })
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
