import BanditoDesign
import BanditoL10n
import SwiftUI

// MARK: - anchors

/// Reports the frame of a view that the tour points at.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [TourAnchor: Anchor<CGRect>] = [:]

    static func reduce(value: inout [TourAnchor: Anchor<CGRect>], nextValue: () -> [TourAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as the target of tour step `anchor`. Without it on screen, the step is skipped.
    func tourAnchor(_ anchor: TourAnchor) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [anchor: $0] }
    }
}

// MARK: - overlay

/// The tour over the main window: a dimmed layer with a hole around the current target, and a bubble.
/// Shown while `OnboardingModel.tourRequested` is set; the tour ends on "Skip", on the last step, or at once
/// when no target is on screen.
struct TourLayer: View {
    var anchors: [TourAnchor: Anchor<CGRect>]

    @Environment(OnboardingModel.self) private var onboarding
    @State private var tour: TourModel?

    var body: some View {
        GeometryReader { proxy in
            if let tour, let current = tour.current {
                let rects = anchors.mapValues { proxy[$0] }
                // The spotlight follows the target; when the target is gone, the bubble stands alone in the middle.
                let hole = rects[current]?.insetBy(dx: -8, dy: -8)
                ZStack {
                    if let hole {
                        SpotlightShape(hole: hole)
                            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                            .contentShape(Rectangle())
                            .onTapGesture {}
                    } else {
                        Color.black.opacity(0.6)
                            .contentShape(Rectangle())
                            .onTapGesture {}
                    }
                    bubble(for: current, tour: tour, hole: hole, size: proxy.size)
                }
                .banditoAnimation(BanditoMotion.ease, value: current)
                .transition(.opacity)
            }
        }
        .onAppear {
            guard tour == nil else { return }
            var model = TourModel(steps: TourPlan.steps(available: Set(anchors.keys)))
            model.skipMissing(available: Set(anchors.keys))
            if model.isFinished {
                onboarding.endTour()
            } else {
                tour = model
            }
        }
    }

    private var available: Set<TourAnchor> {
        Set(anchors.keys)
    }

    private func bubble(for anchor: TourAnchor, tour: TourModel, hole: CGRect?, size: CGSize) -> some View {
        let width: CGFloat = 320
        let x: CGFloat
        let y: CGFloat
        if let hole {
            let onRight = hole.midX < size.width / 2
            x = onRight ? min(hole.maxX + 18, size.width - width - 16) : max(hole.minX - width - 18, 16)
            y = min(max(hole.minY, 16), size.height - 220)
        } else {
            x = (size.width - width) / 2
            y = (size.height - 220) / 2
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RaccoonAvatar(name: "Bandito", color: .peach, size: 26)
                Text(L10n.Tour.counter(step: String(tour.index + 1), total: String(tour.steps.count)))
                    .font(BanditoFont.text(size: 12, weight: 400))
                    .monospacedDigit()
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(title(anchor))
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            Text(text(anchor))
                .font(BanditoFont.text(size: 13.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(0..<tour.steps.count, id: \.self) { k in
                    Circle()
                        .fill(k == tour.index ? Color.Bandito.signal : Color.Bandito.text.opacity(0.18))
                        .frame(width: 6, height: 6)
                }
            }
            HStack(spacing: 10) {
                Button(L10n.Onboarding.skip) {
                    onboarding.endTour()
                }
                .buttonStyle(.plain)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                Spacer()
                Button(tour.hasNext(available: available) ? L10n.Common.next : L10n.Tour.finish) {
                    advance()
                }
                .banditoButton(.signal(size: .regular))
            }
        }
        .padding(18)
        .frame(width: width, alignment: .leading)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.Bandito.text.opacity(0.1)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
        .offset(x: x, y: y)
    }

    /// Next step whose anchor is on screen; the tour ends after the last one.
    private func advance() {
        guard var next = tour else { return }
        next.next(available: available)
        if next.isFinished {
            tour = nil
            onboarding.endTour()
        } else {
            tour = next
        }
    }

    private func title(_ anchor: TourAnchor) -> String {
        switch anchor {
        case .agents: L10n.Tour.Agents.title
        case .composer: L10n.Tour.Composer.title
        case .approvals: L10n.Tour.Approvals.title
        case .quickOpen: L10n.Tour.QuickOpen.title
        case .modes: L10n.Tour.Modes.title
        }
    }

    private func text(_ anchor: TourAnchor) -> String {
        switch anchor {
        case .agents: L10n.Tour.Agents.text
        case .composer: L10n.Tour.Composer.text
        case .approvals: L10n.Tour.Approvals.text
        case .quickOpen: L10n.Tour.QuickOpen.text
        case .modes: L10n.Tour.Modes.text
        }
    }
}

/// The whole rectangle with one hole, filled with the even-odd rule.
struct SpotlightShape: Shape {
    var hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12))
        return path
    }
}
