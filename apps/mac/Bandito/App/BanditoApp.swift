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
    @State private var focusMode = FocusModeTracker()
    @State private var onboarding: OnboardingModel
    @State private var accountHub = AccountHub()
    // Starts Sparkle at launch: the first scheduled check runs a few seconds after it.
    private let updater = AppUpdater()

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
                .environment(accountHub)
                .environment(\.focusMode, focusMode)
                .task {
                    // Tab and arrow keys show the focus ring; a click hides it.
                    focusMode.start()
                }
                .task {
                    // Actions aimed at the server that was in front are dropped when another one is chosen.
                    model.onServerChanged = { [router] in router.dropPendingServerActions() }
                    model.startNotifications(
                        selectedAgentID: { [router] in
                            router.mode == .team ? router.selectedAgentID : nil
                        },
                        windowActive: { NSApp.isActive })
                    await model.connectAll()
                }
                .task {
                    // The daemons' update checks are re-read hourly, and the Server screen re-reads on open.
                    await model.refreshDaemonInfoHourly()
                }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1240, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            BanditoCommands(keymap: keymap, router: router, app: model, onboarding: onboarding)
            AppUpdateCommands { [updater] in updater.checkForUpdates() }
        }

        Settings {
            SettingsWindow()
                .environment(model)
                .environment(router)
                .environment(keymap)
                .environment(gestures)
                .environment(demo)
                .focusEffectDisabled()
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(demo)
                .focusEffectDisabled()
        } label: {
            MenuBarLabel(app: model)
        }
        .menuBarExtraStyle(.window)
    }
}
