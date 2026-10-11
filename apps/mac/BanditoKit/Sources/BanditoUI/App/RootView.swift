import BanditoDesign
import BanditoKit
import SwiftUI

/// The app's root: the main window, or the first-run flow in front of it while `OnboardingModel` says so.
/// The model is injected by the app (`BanditoApp`), which also owns the Help menu item that replays it.
public struct RootView: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    public init() {}

    public var body: some View {
        Group {
            if onboarding.isActive {
                OnboardingFlow()
            } else {
                MainWindow()
            }
        }
        .background(Color.Bandito.bg)
        // Every mode switch (mode bar, ⌘1…⌘6, back and forward, swipes) makes the tab sound.
        .onChange(of: router.mode) { _, _ in SoundPlayer.play(.tab) }
        // The system focus ring is off for the whole scene; Bandito draws its own (brandFocusRing).
        .focusEffectDisabled()
        #if os(macOS)
        .modifier(SettingsOpenerBridge())
        #endif
        #if DEBUG && os(macOS)
        // QA copies (scripts/qa): launch arguments and the command channel. Not in release builds.
        .task { QAHooks.start(router: router, onboarding: onboarding) }
        #endif
        .task { await app.keepUsageFresh() }
        // The browser sends the owner back with `bandito://oauth/callback` after a service's sign-in.
        .onOpenURL { url in
            // `bandito://install?share=<id>`: a shared bot or skill, opened from its page. Any other id is ignored.
            if let shareID = ShareLogic.installID(fromURL: url) {
                router.select(mode: .market)
                router.sheet = .installShared(shareID: shareID)
                return
            }
            Task {
                if await app.handleOpen(url) { router.select(mode: .market) }
            }
        }
        .modifier(OAuthSignInPresenter())
    }
}
