import BanditoDesign
import BanditoL10n
import SwiftUI

/// Step 1 of 7: the raccoon of points of light, what Bandito is, and the way on.
/// Left: the raccoon, the title and one line, one button and a link. Right: the demo. What Bandito does is told by the
/// next step's three live cards, not twice.
struct WelcomeView: View {
    /// "Let's go" goes to "What you get".
    var onContinue: () -> Void
    /// "I already have a server" goes to the server step.
    var onHaveServer: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    @State private var demoStart = Date()

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
    /// 490 pt of content), and 0 (no raccoon) when even the smallest side (`raccoonMinimumSide`) does not fit beside the
    /// title, the line and the buttons.
    static let raccoonMaximumSide: CGFloat = 240
    static let raccoonMinimumSide: CGFloat = 96
    static func raccoonSide(height: CGFloat) -> CGFloat {
        let side = min(raccoonMaximumSide, height - 250)
        return side >= raccoonMinimumSide ? side : 0
    }

    /// Narrowest content width that still has room for the demo beside the intro (540 + 40 + 460).
    static let wideWidth: CGFloat = 1040
    /// Shortest content height for the full layout (mascot, big headline, footer).
    static let fullHeight: CGFloat = 540

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
