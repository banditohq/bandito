import BanditoDesign
import BanditoL10n
import SwiftUI

/// Step 1 of 5: what Bandito is, a live demo of an agent, and the way on.
/// Left: the promise, a carousel of four stories, two buttons. Right: the demo. Bottom: the five steps.
struct WelcomeView: View {
    /// Both buttons ("Start" and "I already have an account") go to the account step.
    var onContinue: () -> Void

    @State private var demoStart = Date()
    @State private var storyAnchorIndex = 0
    @State private var storyAnchorTime = Date()
    @State private var languageChanged = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            BlurOrbs()
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 56) {
                    intro
                        .frame(maxWidth: 560, alignment: .leading)
                    WelcomeDemoCard(start: demoStart) {
                        demoStart = Date()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                OnboardingStepBar(current: 0)
                    .padding(.top, 24)
                Text(L10n.Onboarding.Welcome.footer)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 14)
            }
            languageMenu
                .padding(.top, 4)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 22) {
            RaccoonMark()
            (Text(L10n.Onboarding.Welcome.headline)
                + Text("\n")
                + Text(L10n.Onboarding.Welcome.headlineAccent)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AvatarColor.peach.color, Color.Bandito.signal, Color.Bandito.signalFillEnd],
                            startPoint: .leading, endPoint: .trailing)))
                .font(BanditoFont.font(size: 62, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineSpacing(-4)
            Text(L10n.Onboarding.Welcome.subtitle)
                .font(BanditoFont.font(size: 17, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(3)
            StoryCard(anchorIndex: $storyAnchorIndex, anchorTime: $storyAnchorTime)
            HStack(spacing: 14) {
                Button(action: onContinue) {
                    HStack(spacing: 10) {
                        Text(L10n.Onboarding.Welcome.start)
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(SignalButtonStyle(size: .large))
                Button(L10n.Onboarding.Welcome.hasAccount, action: onContinue)
                    .buttonStyle(QuietButtonStyle(size: .large))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The language menu from the design: the same choice as Settings → Language, applied after a restart.
    private var languageMenu: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Menu {
                ForEach(L10n.languages, id: \.code) { entry in
                    Button(entry.native) {
                        GeneralSection.storeLanguage(entry.code)
                        languageChanged = true
                    }
                }
            } label: {
                Label(currentLanguageName, systemImage: "globe")
                    .font(BanditoFont.font(size: 12.5, weight: 400))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            if languageChanged {
                Text(L10n.Settings.languageRestart)
                    .font(BanditoFont.font(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .padding(.trailing, 24)
    }

    private var currentLanguageName: String {
        let code = GeneralSection.storedLanguage()
        return L10n.languages.first { $0.code == code }?.native ?? "English"
    }
}

/// The brand mark (72 pt raccoon tile) floating gently.
private struct RaccoonMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    var body: some View {
        let reduced = MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { context in
            // Five-second cycle, like the design's bnd-float keyframes: up 8 pt and tilt -2°.
            let k = reduced ? 0 : (1 - cos(2 * Double.pi * context.date.timeIntervalSinceReferenceDate / 5)) / 2
            RaccoonAvatar(name: "Bandito", color: .peach, size: 72)
                .offset(y: -8 * k)
                .rotationEffect(.degrees(-2 * k))
        }
    }
}

/// Four stories with progress bars. Each plays for six seconds, then the next one starts; a click on a bar jumps there.
private struct StoryCard: View {
    @Binding var anchorIndex: Int
    @Binding var anchorTime: Date

    private struct Slide {
        var title: String
        var text: String
        var icon: String
        var tint: Color
    }

    private var slides: [Slide] {
        [
            Slide(title: L10n.Onboarding.Welcome.sleepTitle, text: L10n.Onboarding.Welcome.sleepText,
                  icon: "moon.stars", tint: AvatarColor.sky.color),
            Slide(title: L10n.Onboarding.Welcome.askTitle, text: L10n.Onboarding.Welcome.askText,
                  icon: "checkmark.shield", tint: AvatarColor.peach.color),
            Slide(title: L10n.Onboarding.Welcome.serverTitle, text: L10n.Onboarding.Welcome.serverText,
                  icon: "terminal", tint: AvatarColor.lilac.color),
            Slide(title: L10n.Onboarding.Welcome.subsTitle, text: L10n.Onboarding.Welcome.subsText,
                  icon: "sparkles", tint: AvatarColor.sage.color),
        ]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let position = WelcomeTimeline.storyPosition(
                anchorIndex: anchorIndex, elapsed: context.date.timeIntervalSince(anchorTime))
            let slide = slides[position.index]
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(0..<WelcomeTimeline.storyCount, id: \.self) { k in
                        Button {
                            anchorIndex = k
                            anchorTime = Date()
                        } label: {
                            Capsule()
                                .fill(Color.Bandito.text.opacity(0.14))
                                .frame(height: 4)
                                .overlay(alignment: .leading) {
                                    GeometryReader { geometry in
                                        Capsule()
                                            .fill(Color.Bandito.signal)
                                            .frame(width: geometry.size.width * fill(k, position))
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(slides[k].title)
                    }
                }
                HStack(spacing: 16) {
                    Image(systemName: slide.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(slide.tint)
                        .frame(width: 52, height: 52)
                        .background(slide.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(slide.title)
                            .font(BanditoFont.font(size: 18, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                        Text(slide.text)
                            .font(BanditoFont.font(size: 14, weight: 400))
                            .foregroundStyle(Color.Bandito.text2)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 72, alignment: .leading)
                .id(position.index)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.Bandito.surface1.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.Bandito.text.opacity(0.09)))
        }
    }

    /// Fill of bar `k`: full before the current story, growing on it, empty after it.
    private func fill(_ k: Int, _ position: (index: Int, progress: Double)) -> Double {
        if k < position.index { return 1 }
        if k == position.index { return position.progress }
        return 0
    }
}
