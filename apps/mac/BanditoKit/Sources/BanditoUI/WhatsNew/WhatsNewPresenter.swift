import BanditoKit
import SwiftUI

/// Opens the "What's new" sheet at the first launch of a new version (see `WhatsNewRules`). It reads the notes once,
/// off the main thread, and decides again only when something it depends on changes: no timer, no polling.
struct WhatsNewPresenter: ViewModifier {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(TelemetryCenter.self) private var telemetry
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    @State private var library: ReleaseNotesLibrary?

    /// Everything the decision reads, so that `onChange` fires only when one of them changes.
    private struct Trigger: Equatable {
        var loaded: Bool
        var introductionActive: Bool
        var dialogOpen: Bool
    }

    private var trigger: Trigger {
        Trigger(
            loaded: library != nil, introductionActive: onboarding.isActive,
            dialogOpen: telemetry.showsNotice || telemetry.showsCrashQuestion || app.notificationQuestion != nil
                || router.sheet != nil)
    }

    func body(content: Content) -> some View {
        content
            .task {
                guard library == nil else { return }
                library = await WhatsNewLibraryStore.shared.library()
            }
            .onChange(of: trigger, initial: true) { _, now in evaluate(now) }
    }

    private func evaluate(_ now: Trigger) {
        guard let library, let current = WhatsNewStore.currentVersion else { return }
        let decision = WhatsNewRules.decide(
            current: current, lastSeen: WhatsNewStore.lastSeen(), library: library,
            wasDoneAtLaunch: onboarding.wasDoneAtLaunch, introductionActive: now.introductionActive,
            otherDialogOpen: now.dialogOpen)
        switch decision {
        case .nothing, .wait:
            break
        case .remember:
            WhatsNewStore.remember(current)
        case .show(let skipped):
            // Remembered when it opens: a crash or a quit with the sheet open does not bring it back at every launch.
            WhatsNewStore.remember(current)
            router.sheet = .whatsNew(skipped: skipped)
        }
    }
}
