import BanditoDesign
import BanditoKit
import SwiftUI

/// The app's root: the main window, or the first-run flow in front of it while `OnboardingModel` says so.
/// The model is injected by the app (`BanditoApp`), which also owns the Help menu item that replays it.
public struct RootView: View {
    @Environment(OnboardingModel.self) private var onboarding

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
        // The system focus ring is off for the whole scene; Bandito draws its own (brandFocusRing).
        .focusEffectDisabled()
    }
}
