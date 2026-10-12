import BanditoDesign
import BanditoL10n
import SwiftUI

/// The first run of the iPhone app: welcome (the raccoon of lights), what you get (three live cards), where your crew
/// lives (three ways to connect). It covers the app while no server is paired. The step bar, Back and the saved
/// progress are common to all steps; the copy and the order match the Mac's onboarding (docs/IOS_APP.md).
///
/// Always dark: the onboarding is the brand's first picture (warm dark ground, cream and signal lights), and it reads the
/// same whatever the person picked for the rest of the app.
struct OnboardingView: View {
    let store: OnboardingStore
    /// The app's motion setting: Bandito's own "always reduce" wins over the system's Reduce Motion.
    let motion: MotionPreference
    /// The connect step hands over to the pairing flow; the mode says which way the person picked.
    let onConnect: (OnboardingConnectMode) -> Void

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        motion.reducesMotion(systemSetting: systemReduceMotion)
    }

    var body: some View {
        let position = store.position
        let previous = OnboardingRules.back(from: position)
        VStack(spacing: 0) {
            OnboardingHeader(
                step: position.step,
                onBack: previous.map { target in { go(target) } })
            Group {
                switch position.step {
                case .welcome:
                    WelcomeStep(
                        reduceMotion: reduceMotion,
                        onStart: { go(OnboardingRules.forward(from: position)) },
                        onHaveServer: { go(OnboardingRules.skipToConnect()) })
                case .features:
                    FeaturesStep(
                        card: Binding(
                            get: { store.position.card },
                            set: { store.show(OnboardingPosition(step: .features, card: $0)) }),
                        reduceMotion: reduceMotion,
                        onNext: { go(OnboardingRules.forward(from: position)) },
                        onSkip: { go(OnboardingRules.skipToConnect()) })
                case .connect:
                    ConnectStep(onConnect: onConnect)
                }
            }
            .id(position.step)
            .transition(.opacity)
        }
        .background(Color.Bandito.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// Moves to `target` (nil: nowhere) on the brand's fast curve; under Reduce Motion the step changes at once.
    private func go(_ target: OnboardingPosition?) {
        guard let target else { return }
        withAnimation(reduceMotion ? nil : BanditoMotion.ease) {
            store.show(target)
        }
    }
}

// MARK: - Frame

/// The top line: Back on the left (when there is a step to go back to), the progress dots centred.
private struct OnboardingHeader: View {
    let step: OnboardingStep
    let onBack: (() -> Void)?

    var body: some View {
        ZStack {
            HStack {
                if let onBack {
                    Button(action: onBack) {
                        Label(L10n.Common.back, systemImage: "chevron.left")
                    }
                    .buttonStyle(OnboardingLinkStyle())
                }
                Spacer(minLength: 0)
            }
            StepBar(current: step.index, total: OnboardingStep.count)
        }
        .font(BanditoFont.text(size: 15, weight: 500))
        .padding(.horizontal, BanditoSpace.s5)
        .frame(minHeight: 52)
    }
}

/// The progress line: one dot per step, the current one in signal.
private struct StepBar: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: BanditoSpace.s2) {
            ForEach(0..<total, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.Bandito.signal : Color.Bandito.lineStrong)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Ios.Onboarding.progress(current: String(current + 1), total: String(total)))
    }
}

/// A step's body: scrolls when the text grows (Dynamic Type), and centres itself when it does not.
private struct OnboardingPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.horizontal, BanditoSpace.s6)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: - Step 1: Welcome

/// The raccoon assembles from points of light; the title, one line and the two ways on.
struct WelcomeStep: View {
    let reduceMotion: Bool
    let onStart: () -> Void
    let onHaveServer: () -> Void

    var body: some View {
        OnboardingPage {
            VStack(spacing: BanditoSpace.s5) {
                Spacer(minLength: BanditoSpace.s4)
                RaccoonLightsAssembly(reduceMotion: reduceMotion)
                    .frame(width: 280, height: 280)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.Ios.Onboarding.Welcome.assembly)
                    .accessibilityAddTraits(.isImage)
                VStack(spacing: BanditoSpace.s3) {
                    Text(L10n.Ios.Onboarding.Welcome.title)
                        .font(BanditoFont.display(size: 35, weight: 700))
                        .foregroundStyle(Color.Bandito.text)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.Ios.Onboarding.Welcome.subtitle)
                        .font(BanditoFont.text(size: 15))
                        .foregroundStyle(Color.Bandito.text2)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BanditoSpace.s4)
                VStack(spacing: BanditoSpace.s3) {
                    Button(action: onStart) {
                        HStack(spacing: BanditoSpace.s2) {
                            Circle()
                                .fill(Color.Bandito.signalFill)
                                .frame(width: 7, height: 7)
                            Text(L10n.Ios.Onboarding.Welcome.start)
                        }
                    }
                    .buttonStyle(SignalButtonStyle())
                    .accessibilityIdentifier("onboarding.welcome.start")
                    Button(action: onHaveServer) {
                        Text(L10n.Ios.Onboarding.Welcome.haveServer)
                    }
                    .buttonStyle(OnboardingLinkStyle())
                    .accessibilityIdentifier("onboarding.welcome.haveServer")
                }
                .padding(.bottom, BanditoSpace.s6)
            }
        }
    }
}

// MARK: - Step 2: What you get

/// The three live cards, with "Next" and "Skip". Next on the last card goes to the connect step.
struct FeaturesStep: View {
    @Binding var card: Int
    let reduceMotion: Bool
    let onNext: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: BanditoSpace.s4) {
            FeatureCarousel(card: $card, reduceMotion: reduceMotion)
                .frame(maxHeight: .infinity)
            VStack(spacing: BanditoSpace.s3) {
                Button(action: onNext) {
                    Text(L10n.Common.next)
                }
                .buttonStyle(SignalButtonStyle())
                .accessibilityIdentifier("onboarding.features.next")
                Button(action: onSkip) {
                    Text(L10n.Ios.Onboarding.skip)
                }
                .buttonStyle(OnboardingLinkStyle())
                .accessibilityIdentifier("onboarding.features.skip")
            }
            .padding(.horizontal, BanditoSpace.s6)
            .padding(.bottom, BanditoSpace.s6)
        }
        .padding(.top, BanditoSpace.s2)
    }
}

// MARK: - Step 3: Where your crew lives

/// Three big ways to connect. Each calls `onConnect` with its mode; the pairing flow itself is not here.
struct ConnectStep: View {
    let onConnect: (OnboardingConnectMode) -> Void

    var body: some View {
        OnboardingPage {
            VStack(alignment: .leading, spacing: BanditoSpace.s4) {
                Spacer(minLength: BanditoSpace.s4)
                Text(L10n.Ios.Onboarding.Connect.title)
                    .font(BanditoFont.display(size: 35, weight: 700))
                    .foregroundStyle(Color.Bandito.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, BanditoSpace.s2)
                VStack(spacing: BanditoSpace.s3) {
                    ConnectOption(
                        symbol: "qrcode.viewfinder", title: L10n.Ios.Onboarding.Connect.scan,
                        identifier: "onboarding.connect.scan"
                    ) { onConnect(.scanCode) }
                    ConnectOption(
                        symbol: "link", title: L10n.Ios.Onboarding.Connect.paste,
                        identifier: "onboarding.connect.paste"
                    ) { onConnect(.pasteLink) }
                    ConnectOption(
                        symbol: "keyboard", title: L10n.Ios.Onboarding.Connect.type,
                        identifier: "onboarding.connect.type"
                    ) { onConnect(.typeAddress) }
                }
                Text(L10n.Ios.Onboarding.Connect.hint)
                    .font(BanditoFont.text(size: 13))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, BanditoSpace.s2)
                Spacer(minLength: BanditoSpace.s6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, BanditoSpace.s6)
        }
    }
}

/// One connect option: a tile with its symbol, the title, a chevron. A surface row with a hairline, pressed a little.
private struct ConnectOption: View {
    let symbol: String
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BanditoSpace.s4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Color.Bandito.text)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.Bandito.surface2))
                Text(title)
                    .font(BanditoFont.display(size: 16, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text3)
                    .accessibilityHidden(true)
            }
            .padding(BanditoSpace.s4)
            .frame(maxWidth: .infinity, minHeight: 76)
        }
        .buttonStyle(ConnectOptionStyle())
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Styles

/// A row option: the surface with a hairline, a slight press. Its own style, as the brand's buttons live in BanditoUI.
private struct ConnectOptionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.Bandito.surface1))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// A quiet text button: the secondary tone, underlined on press.
struct OnboardingLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BanditoFont.text(size: 15, weight: 500))
            .foregroundStyle(configuration.isPressed ? Color.Bandito.text : Color.Bandito.text2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}
