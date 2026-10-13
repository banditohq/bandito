import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The "to the newest" capsule over the composer: a down arrow, and "3 new" when messages came in while the person
/// was above. It comes up on a spring and goes with a fade; under Reduce Motion it only fades. The shadow is on this
/// one surface, never on the rows under it.
struct ThreadJumpOverlay: View {
    var visible: Bool
    var unseen: Int
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue

    private var reduced: Bool {
        MotionLevel(stored: motionLevel).reducesMotion(systemReduceMotion: reduceMotion)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if visible {
                // The text under the capsule fades into the page, so the capsule never sits on a half-read line.
                LinearGradient(
                    colors: [Color.Bandito.bg.opacity(0), Color.Bandito.bg.opacity(0.9)],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                ThreadJumpButton(unseen: unseen, action: action)
                    .padding(.bottom, 10)
                    .transition(ThreadJumpRules.transition(reduced: reduced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(ThreadJumpRules.animation(reduced: reduced), value: visible)
    }
}

/// The capsule itself.
struct ThreadJumpButton: View {
    var unseen: Int
    var action: () -> Void

    private var caption: String? {
        switch ThreadJumpRules.caption(unseen: unseen) {
        case .arrowOnly: nil
        case .count(let count): L10n.Thread.jumpNew(count: count)
        case .overflow: L10n.Thread.jumpMany
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                if let caption {
                    Circle().fill(Color.Bandito.signal).frame(width: 6, height: 6)
                    Text(caption)
                        .font(BanditoFont.text(size: 12.5, weight: 500))
                        .monospacedDigit()
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, caption == nil ? 12 : 14)
            .frame(minWidth: 34, minHeight: 34)
            .background(.ultraThinMaterial, in: Capsule())
            .background(Color.Bandito.surface2.opacity(0.82), in: Capsule())
            .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            .contentShape(Capsule())
        }
        .banditoButton(.row(cornerRadius: 17, hoverOpacity: 0.06))
        .help(L10n.Thread.jumpToLatest)
        .accessibilityLabel(L10n.Thread.jumpToLatest)
        .accessibilityValue(caption ?? "")
    }
}
