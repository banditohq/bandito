import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The app's root: the main window, or the first-run flow in front of it while `OnboardingModel` says so.
/// The model is injected by the app (`BanditoApp`), which also owns the Help menu item that replays it.
public struct RootView: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(AppModel.self) private var app
    /// The Dock icon's unread count, kept for the window's life (see `DockBadge`).
    @State private var dockIcon: DockBadge?
    @Environment(Router.self) private var router
    @Environment(TelemetryCenter.self) private var telemetry

    public init() {}

    public var body: some View {
        Group {
            if onboarding.isActive {
                OnboardingFlow()
            } else {
                MainWindow()
                    .overlay(alignment: .top) {
                        if let banner = telemetry.banner {
                            AnnouncementBanner(
                                announcement: banner,
                                onOpen: { telemetry.openBannerLink() },
                                onClose: { telemetry.dismissBanner() })
                        }
                    }
            }
        }
        .background(Color.Bandito.bg)
        // The first-run notice and the crash question wait until the first-run flow is over; they answer with a button.
        .sheet(isPresented: .constant(telemetry.showsNotice && !onboarding.isActive)) {
            TelemetryNoticeSheet(telemetry: telemetry)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: .constant(telemetry.showsCrashQuestion && !onboarding.isActive)) {
            TelemetryConfirmSheet(
                title: L10n.Telemetry.Crash.title,
                message: L10n.Telemetry.Crash.body,
                confirmTitle: L10n.Telemetry.Crash.send,
                confirmIsDanger: false,
                cancelTitle: L10n.Telemetry.Notice.decline,
                onConfirm: { Task { await telemetry.answerCrashQuestion(send: true) } },
                onCancel: { Task { await telemetry.answerCrashQuestion(send: false) } })
                .interactiveDismissDisabled()
        }
        // Every mode switch (mode bar, ⌘1…⌘6, back and forward, swipes) makes the tab sound.
        .onChange(of: router.mode) { _, _ in SoundPlayer.play(.tab) }
        // The system focus ring is off for the whole scene; Bandito draws its own (brandFocusRing).
        .focusEffectDisabled()
        #if os(macOS)
        .modifier(SettingsOpenerBridge())
        #endif
        #if DEBUG && os(macOS)
        // QA copies (scripts/qa): launch arguments and the command channel. Not in release builds.
        .task { QAHooks.start(router: router, onboarding: onboarding, telemetry: telemetry) }
        #endif
        .task { await app.keepUsageFresh() }
        // The introduction is over: now the system may ask to show notifications (it asks only the first time).
        .onChange(of: onboarding.isActive) { _, active in
            if !active { app.askNotificationPermission() }
        }
        // The unread count on the Dock icon (see `DockBadge`), watched from the first appearance on.
        .task {
            guard dockIcon == nil else { return }
            let badge = DockBadge(app: app)
            dockIcon = badge
            badge.start()
        }
        #if os(macOS)
        // Help → (⌥) Smoothness check… (see `PerfCheck`).
        .task { PerfCheckMenu.install() }
        #endif
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
        .modifier(DeviceSignInPresenter())
    }
}
