import BanditoKit
import BanditoDesign
import BanditoL10n
import SwiftUI

/// Shared geometry of the first-run flow. Every step sits between the same two bars, so the step counter,
/// Skip, the step bar and the primary action keep their coordinates from step to step.
enum OnboardingLayout {
    /// Left and right inset of the content and both bars. Clears the window's rounded corners and the traffic lights.
    static let horizontal: CGFloat = 64
    /// Space above the top bar: the traffic lights sit in the top 28 pt of the window.
    static let top: CGFloat = 44
    /// Height of the top bar (step counter, Skip).
    static let topBarHeight: CGFloat = 28
    /// Space between the content and the bottom bar.
    static let bottomGap: CGFloat = 24
    /// Height of the bottom bar: the step bar, and the primary action at its right end.
    static let bottomBarHeight: CGFloat = 46
    /// Space under the bottom bar.
    static let bottom: CGFloat = 32
    /// Width of the slot for the primary action, so the step bar keeps the same width on every step.
    static let nextSlotWidth: CGFloat = 200
}

/// The primary action of a step, shown at the right end of the bottom bar. A step reports it with `onboardingNext`.
struct OnboardingNextAction: Equatable {
    var title: String
    var isEnabled: Bool
    var perform: () -> Void

    /// The closure is not compared: a changed title or enabled state is what the bar must redraw for.
    static func == (lhs: OnboardingNextAction, rhs: OnboardingNextAction) -> Bool {
        lhs.title == rhs.title && lhs.isEnabled == rhs.isEnabled
    }
}

private struct OnboardingNextKey: PreferenceKey {
    // Computed, not stored: a stored static of a non-Sendable value would not pass strict concurrency.
    static var defaultValue: OnboardingNextAction? { nil }

    static func reduce(value: inout OnboardingNextAction?, nextValue: () -> OnboardingNextAction?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// Reports this step's primary action to the flow's bottom bar. Pass nil when the step has none.
    func onboardingNext(_ action: OnboardingNextAction?) -> some View {
        preference(key: OnboardingNextKey.self, value: action)
    }
}

/// The first-run flow, shown in the main window's place until the person has a server with an agent or skips.
/// This is the shell for every step: the background over the whole window, the top bar (step counter, Skip),
/// the content, and the bottom bar (step bar, primary action). Steps draw only their content.
public struct OnboardingFlow: View {
    @Environment(OnboardingModel.self) private var onboarding
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router
    @State private var next: OnboardingNextAction?
    /// The models of the steps that need the server (see `OnboardingSession`), made when the first of them opens.
    @State private var session: OnboardingSession?

    public init() {}

    /// A flow whose server steps already have their session: a picture or a test that has no server to wait for.
    init(session: OnboardingSession?) {
        _session = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: OnboardingLayout.topBarHeight)
            // A step leaves and the next one comes by a short fade (none under Reduce Motion).
            ZStack {
                content
                    .id(onboarding.step)
                    .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 24)
            .banditoAnimation(BanditoMotion.ease, value: onboarding.step)
            bottomBar
                .frame(height: OnboardingLayout.bottomBarHeight)
                .padding(.top, OnboardingLayout.bottomGap)
        }
        .padding(.horizontal, OnboardingLayout.horizontal)
        .padding(.top, OnboardingLayout.top)
        .padding(.bottom, OnboardingLayout.bottom)
        .windowRoot(minWidth: 900, minHeight: 640)
        .background {
            OnboardingBackground(showsOrbs: onboarding.step == .welcome)
                .ignoresSafeArea()
        }
        .onPreferenceChange(OnboardingNextKey.self) { next = $0 }
        // Onboarding is mouse-first: no system focus ring on any button of the flow (the brand ring comes from the styles).
        .focusEffectDisabled()
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            // Back always works, except on the first step.
            if onboarding.canGoBack {
                Button { onboarding.back() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.Common.back)
                    }
                    .fixedSize()
                }
                .banditoButton(.quiet())
            }
            Text(L10n.Onboarding.stepOf(step: "\(onboarding.step.position)", total: "\(OnboardingStep.barCount)"))
                .font(BanditoFont.text(size: 12, weight: 500))
                .monospacedDigit()
                .foregroundStyle(Color.Bandito.text3)
            Spacer()
            // The language menu sits where Skip sits on the other steps. Welcome has nothing to skip to.
            if onboarding.step == .welcome {
                OnboardingLanguageMenu()
            } else {
                Button(L10n.Onboarding.skip) { onboarding.skip() }
                    .banditoButton(.quiet())
                    .help(L10n.Onboarding.skipHint)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 24) {
            OnboardingStepBar(current: onboarding.step.position - 1)
                .frame(maxWidth: .infinity)
            ZStack(alignment: .trailing) {
                if let next {
                    Button(next.title, action: next.perform)
                        .banditoButton(.signal(size: .large))
                        .disabled(!next.isEnabled)
                }
            }
            // At least the usual slot, so the button keeps its place from step to step; a longer label widens the
            // slot and the step bar gives way (it drops the other steps' labels), instead of the two overlapping.
            .frame(minWidth: OnboardingLayout.nextSlotWidth, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// The step's content, clipped to its own area so nothing paints over the bottom bar.
    /// Welcome and Account pick their own compact layout (no scroll view: a scroll view would accept any height
    /// and hide the fit check). The other steps scroll when the window is shorter than the step.
    @ViewBuilder
    private var content: some View {
        if onboarding.step == .welcome {
            stepBody
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else if onboarding.step == .account {
            stepBody
                .clipped()
        } else {
            GeometryReader { geometry in
                ScrollView {
                    // The top inset keeps the mascot's float (8 pt up) inside the scroll view, not clipped by it.
                    // Short content is centered vertically in the area between the bars.
                    stepBody
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                        .padding(.top, 12)
                }
                // Visible when the step is taller than the window, so it is clear there is more below.
                .scrollIndicators(.automatic)
                // The last 22 pt fade out, so a step that goes on below the bottom bar is not cut like a blade.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 22)
                    }
                }
            }
            .clipped()
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch onboarding.step {
        case .welcome:
            WelcomeView(onContinue: { onboarding.advance() }, onHaveServer: { onboarding.haveServer() })
        case .features:
            FeaturesStep()
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
            }, placesNextInFooter: true)
        case .runtimes:
            OnboardingSessionHost(session: $session) { session in
                RuntimesPane(model: session.subscriptions) { onboarding.advance() }
            }
        case .team:
            OnboardingSessionHost(session: $session) { session in
                CrewStep(
                    model: session.crew, rememberedAgentID: onboarding.firstAgentID,
                    onMade: { agent, team in onboarding.rememberFirstAgent(agent.id, team: team) },
                    onContinue: { onboarding.advance() })
            }
        case .task:
            OnboardingSessionHost(session: $session) { session in
                taskStep(session)
            }
        case .done:
            EmptyView()
        }
    }

    /// The first task goes to the agent the crew step made (also after a relaunch: the flow remembers it).
    @ViewBuilder
    private func taskStep(_ session: OnboardingSession) -> some View {
        let agentID = onboarding.firstAgentID ?? session.crew.firstAgent?.id ?? ""
        let model = session.taskModel(agentID: agentID, teamID: onboarding.firstTeamID)
        FirstTaskStep(
            model: model, onSent: { openChat(agentID, on: session.server) },
            onLater: { openChat(agentID, on: session.server) }, onChooseCrew: { onboarding.back() })
    }

    /// The flow ends inside the agent's chat: the agent is chosen, the Team mode is in front, and the reply is already
    /// coming in (the task was sent before this).
    private func openChat(_ agentID: String, on server: ServerModel) {
        // Without an agent there is no chat to open: the flow does not end in silence (the step offers the way back).
        guard !agentID.isEmpty else { return }
        router.selectAgent(agentID, on: server)
        router.select(mode: .team)
        onboarding.finish()
    }
}

/// The background of every step: the window's dark fill. Welcome has the drifting blobs; the others have a soft
/// glow at the top edge, as in the design boards.
private struct OnboardingBackground: View {
    var showsOrbs: Bool

    var body: some View {
        if showsOrbs {
            BlurOrbs()
        } else {
            ZStack {
                Color.Bandito.bg
                RadialGradient(
                    colors: [Color.Bandito.signal.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 520)
            }
        }
    }
}
