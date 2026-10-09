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

    var body: some View {
        // The background, the top bar (with the language control) and the step bar belong to the flow.
        // One layout, picked from the space there is: wide or narrow (the demo leaves below 1040 pt), full or compact
        // (short window). Not ViewThatFits: it keeps every candidate alive, four demos and four story cards animating
        // at once, and measured them all on every frame.
        GeometryReader { geometry in
            layout(wide: geometry.size.width >= Self.wideWidth, compact: geometry.size.height < Self.fullHeight)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// Narrowest content width that still has room for the demo beside the intro (540 + 40 + 460).
    static let wideWidth: CGFloat = 1040
    /// Shortest content height for the full layout (mascot, big headline, story card, footer).
    static let fullHeight: CGFloat = 640

    private func layout(wide: Bool, compact: Bool) -> some View {
        VStack(spacing: 0) {
            if wide {
                wideLayout(compact: compact)
            } else {
                narrowLayout(compact: compact)
            }
        }
    }

    private func wideLayout(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 40) {
            intro(compact: compact)
                .frame(width: 540, alignment: .leading)
            WelcomeDemoCard(start: demoStart) {
                demoStart = Date()
            }
        }
    }

    private func narrowLayout(compact: Bool) -> some View {
        // Without the demo the column keeps a readable measure instead of running across the window.
        intro(compact: compact)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func intro(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 22) {
            if !compact {
                RaccoonMark()
            }
            // The headline is never cut: the first size whose two lines fit the column is used.
            if compact {
                ViewThatFits(in: .horizontal) {
                    headline(size: 44)
                    headline(size: 40)
                    headline(size: 36)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    headline(size: 62)
                    headline(size: 52)
                    headline(size: 44)
                    headline(size: 36)
                }
            }
            Text(L10n.Onboarding.Welcome.subtitle)
                .font(BanditoFont.font(size: 17, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(3)
            StoryCard(anchorIndex: $storyAnchorIndex, anchorTime: $storyAnchorTime, compact: compact)
            // Side by side when there is room, one under the other otherwise. Labels never wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    startButton
                    hasAccountButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    startButton
                    hasAccountButton
                }
            }
            // Under the buttons, in the same column, so it lines up with them on every width.
            if !compact {
                Text(L10n.Onboarding.Welcome.footer)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.top, -8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headline(size: CGFloat) -> some View {
        (Text(L10n.Onboarding.Welcome.headline)
            + Text("\n")
            + Text(L10n.Onboarding.Welcome.headlineAccent)
                .foregroundStyle(
                    LinearGradient(
                        colors: [AvatarColor.peach.color, Color.Bandito.signal, Color.Bandito.signalFillEnd],
                        startPoint: .leading, endPoint: .trailing)))
            .font(BanditoFont.font(size: size, weight: 600))
            .foregroundStyle(Color.Bandito.text)
            .lineSpacing(-4)
            .fixedSize()
    }

    private var startButton: some View {
        Button(action: onContinue) {
            HStack(spacing: 10) {
                Text(L10n.Onboarding.Welcome.start)
                Image(systemName: "arrow.right")
            }
            .fixedSize()
        }
        .banditoButton(.signal(size: .large))
        .fixedSize()
    }

    private var hasAccountButton: some View {
        Button(L10n.Onboarding.Welcome.hasAccount, action: onContinue)
            .banditoButton(.quiet(size: .large))
            .fixedSize()
    }
}

/// The brand mark (72 pt raccoon tile) floating gently.
private struct RaccoonMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    var body: some View {
        let reduced = MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
        // Five-second cycle, like the design's bnd-float keyframes: up 8 pt and tilt -2°. A repeating animation, so
        // nothing is redrawn while it floats.
        RaccoonAvatar(name: "Bandito", color: .peach, size: 72)
            .offset(y: up ? -8 : 0)
            .rotationEffect(.degrees(up ? -2 : 0))
            .onAppear { float(reduced) }
            .onChange(of: reduced) { float(reduced) }
    }

    @State private var up = false

    private func float(_ reduced: Bool) {
        guard !reduced else {
            up = false
            return
        }
        withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) { up = true }
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
                        .font(BanditoFont.font(size: 18, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                    Text(slide.text)
                        .font(BanditoFont.font(size: 14, weight: 400))
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
