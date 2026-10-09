import BanditoDesign
import BanditoL10n
import SwiftUI

/// The first-run flow, shown in the main window's place until the person has a server with an agent or skips.
/// This is the shell: the step counter, Skip and the order of steps (`OnboardingModel`). Step screens that are
/// not built yet are placeholders; Welcome, Account and approval are built.
public struct OnboardingFlow: View {
    @Environment(OnboardingModel.self) private var onboarding

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            stepBody
        }
        .padding(32)
        .frame(minWidth: 900, minHeight: 600)
        .background(Color.Bandito.bg)
    }

    private var header: some View {
        HStack {
            Text(L10n.Onboarding.stepOf(step: "\(onboarding.step.position)", total: "5"))
                .font(BanditoFont.font(size: 12, weight: 500, mono: true))
                .foregroundStyle(Color.Bandito.text3)
            Spacer()
            // Welcome has nothing to skip to: the first step is the introduction itself.
            if onboarding.step != .welcome {
                Button(L10n.Onboarding.skip) { onboarding.skip() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch onboarding.step {
        case .welcome:
            WelcomeView { onboarding.advance() }
        case .account:
            AccountSignInView(onFinished: { route in
                // A first device or a ready device goes on; anything else needs the approval step.
                onboarding.signedIn(deviceApproved: route == .firstDevice || route == .ready)
            }, onSkipAccount: {
                onboarding.advance()
            })
        case .approval:
            DeviceApprovalStep(onFinished: {
                onboarding.advance()
            }, onNoAccess: {
                onboarding.returnToSignIn()
            })
        case .server:
            FirstServerStep(onFinished: {
                onboarding.advance()
            })
        case .agent:
            AgentStep {
                onboarding.finishWithTour()
            }
        case .done:
            EmptyView()
        }
    }
}

/// A step screen that is not built yet: its title and one button that moves the flow on.
private struct PlaceholderStep<Label: View>: View {
    var title: String
    var next: () -> Void
    @ViewBuilder var action: () -> Label

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(BanditoFont.font(size: 28, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Button(action: next) { action() }
                .buttonStyle(SignalButtonStyle())
        }
        .frame(maxWidth: .infinity)
    }
}
