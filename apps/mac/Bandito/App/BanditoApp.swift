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
                .background(WindowChrome())
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
                .environment(accountHub)
                .focusEffectDisabled()
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
                .environment(demo)
                .environment(router)
                .focusEffectDisabled()
        } label: {
            MenuBarLabel(app: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Window chrome for the hidden title bar: the titlebar area is transparent and the window fill is the app's
/// background, so no grey system strip shows above or below the content (onboarding draws edge to edge).
private struct WindowChrome: NSViewRepresentable {
    final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // The dark value of Color.Bandito.bg (#12100E).
            window.backgroundColor = NSColor(srgbRed: 0.071, green: 0.063, blue: 0.055, alpha: 1)
        }
    }

    func makeNSView(context: Context) -> NSView {
        ChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
