import BanditoDesign
import BanditoL10n
import SwiftUI

/// Step 1 of 5: the raccoon of points of light, what Bandito is, and the way on.
/// Left: the raccoon, the title and one line, a carousel of four stories, one button and a link. Right: the demo.
struct WelcomeView: View {
    /// "Let's go" goes to the account step.
    var onContinue: () -> Void
    /// "I already have a server" goes to the server step.
    var onHaveServer: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    @State private var demoStart = Date()
    @State private var storyAnchorIndex = 0
    @State private var storyAnchorTime = Date()

    var body: some View {
        // The background, the top bar (with the language control) and the step bar belong to the flow.
        // One layout, picked from the space there is: wide or narrow (the demo leaves below 1040 pt), full or compact
        // (short window). Not ViewThatFits: it keeps every candidate alive, four demos and four story cards animating
        // at once, and measured them all on every frame.
        GeometryReader { geometry in
            layout(
                wide: geometry.size.width >= Self.wideWidth, compact: geometry.size.height < Self.fullHeight,
                raccoon: Self.raccoonSide(height: geometry.size.height))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// The raccoon's side for a content height: as large as the window leaves room for (the hero, 240 pt, from about
    /// 600 pt of content), and 0 (no raccoon) when even the smallest side (`raccoonMinimumSide`) does not fit beside the
    /// title, the story card and the buttons.
    static let raccoonMaximumSide: CGFloat = 240
    static let raccoonMinimumSide: CGFloat = 96
    static func raccoonSide(height: CGFloat) -> CGFloat {
        let side = min(raccoonMaximumSide, height - 360)
        return side >= raccoonMinimumSide ? side : 0
    }

    /// Narrowest content width that still has room for the demo beside the intro (540 + 40 + 460).
    static let wideWidth: CGFloat = 1040
    /// Shortest content height for the full layout (mascot, big headline, story card, footer).
    static let fullHeight: CGFloat = 640

    private func layout(wide: Bool, compact: Bool, raccoon: CGFloat) -> some View {
        VStack(spacing: 0) {
            if wide {
                wideLayout(compact: compact, raccoon: raccoon)
            } else {
                narrowLayout(compact: compact, raccoon: raccoon)
            }
        }
    }

    private func wideLayout(compact: Bool, raccoon: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 40) {
            intro(compact: compact, raccoon: raccoon)
                .frame(width: 540, alignment: .leading)
            WelcomeDemoCard(start: demoStart) {
                demoStart = Date()
            }
        }
    }

    private func narrowLayout(compact: Bool, raccoon: CGFloat) -> some View {
        // Without the demo the column keeps a readable measure instead of running across the window.
        intro(compact: compact, raccoon: raccoon)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func intro(compact: Bool, raccoon: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
            // The raccoon of points of light: the hero of the screen, assembled on appear (static under Reduce Motion).
            // Its size follows the window's height (`raccoonSide`); it is left out when even the smallest does not fit.
            if raccoon > 0 {
                RaccoonLightsHost(
                    reduceMotion: MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion),
                    dark: colorScheme == .dark)
                    .frame(width: raccoon, height: raccoon)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L10n.Ios.Onboarding.Welcome.assembly)
                    .accessibilityAddTraits(.isImage)
            }
            // The title is never cut: the first size whose line fits the column is used.
            let titleSizes: [CGFloat] = compact ? [44, 40, 36] : [62, 52, 44, 36]
            FirstFit(count: titleSizes.count) { index, _ in
                title(size: titleSizes[index])
            }
            Text(L10n.Onboarding.Welcome.subtitle)
                .font(BanditoFont.text(size: 17, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(3)
            StoryCard(anchorIndex: $storyAnchorIndex, anchorTime: $storyAnchorTime, compact: compact)
            // The button, and under it the link, in the same column.
            VStack(alignment: .leading, spacing: 12) {
                startButton
                hasAccountButton
            }
            // Under the buttons, in the same column, so it lines up with them on every width.
            if !compact {
                Text(L10n.Onboarding.Welcome.footer)
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.top, -8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(size: CGFloat) -> some View {
        Text(L10n.Ios.Onboarding.Welcome.title)
            .font(BanditoFont.text(size: size, weight: 600))
            .foregroundStyle(Color.Bandito.text)
            .lineLimit(1)
            .fixedSize()
    }

    private var startButton: some View {
        Button(action: onContinue) {
            HStack(spacing: 10) {
                Text(L10n.Ios.Onboarding.Welcome.start)
                Image(systemName: "arrow.right")
            }
            .fixedSize()
        }
        .banditoButton(.signal(size: .large))
        .fixedSize()
    }

    private var hasAccountButton: some View {
        Button(L10n.Ios.Onboarding.Welcome.haveServer, action: onHaveServer)
            .banditoButton(.link)
            .fixedSize()
    }
}

/// Four stories with progress bars. Each plays for six seconds, then the next one starts; a click on a bar jumps there.
private struct StoryCard: View {
    @Binding var anchorIndex: Int
    @Binding var anchorTime: Date
    /// On a short window the card is shorter: smaller icon and padding.
    var compact = false

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

    /// The story on screen and how far its bar has filled. A task moves them along; the bar fills by a linear
    /// animation, so nothing in the card is rebuilt while a story plays.
    @State private var index = 0
    @State private var progress: Double = 0

    var body: some View {
        let slide = slides[index]
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
                                Capsule()
                                    .fill(Color.Bandito.signal)
                                    .scaleEffect(x: fill(k), y: 1, anchor: .leading)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
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
                        .font(BanditoFont.display(size: 16.5, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    Text(slide.text)
                        .font(BanditoFont.text(size: 14, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: compact ? 56 : 72, alignment: .leading)
            .id(index)
            .transition(.opacity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, compact ? 10 : 14)
        .background(Color.Bandito.surface1.opacity(0.72), in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.Bandito.text.opacity(0.09)))
        .task(id: anchorTime) { await play() }
    }

    /// Plays the stories from the anchor: each bar fills over its six seconds, then the next story starts.
    private func play() async {
        var position = WelcomeTimeline.storyPosition(
            anchorIndex: anchorIndex, elapsed: Date().timeIntervalSince(anchorTime))
        while !Task.isCancelled {
            let remaining = WelcomeTimeline.storyDuration * (1 - position.progress)
            withAnimation(.easeOut(duration: 0.25)) { index = position.index }
            var reset = Transaction()
            reset.disablesAnimations = true
            withTransaction(reset) { progress = position.progress }
            withAnimation(.linear(duration: remaining)) { progress = 1 }
            try? await Task.sleep(for: .seconds(remaining))
            position = (index: (position.index + 1) % WelcomeTimeline.storyCount, progress: 0)
        }
    }

    /// Fill of bar `k`: full before the current story, growing on it, empty after it.
    private func fill(_ k: Int) -> Double {
        if k < index { return 1 }
        if k == index { return progress }
        return 0
    }
}
