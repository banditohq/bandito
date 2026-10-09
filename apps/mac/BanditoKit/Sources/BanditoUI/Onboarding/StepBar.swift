import BanditoDesign
import BanditoL10n
import SwiftUI

/// The five first-run steps as a row of numbered dots joined by hairlines. `current` is 0-based.
struct OnboardingStepBar: View {
    var current: Int

    private var labels: [String] {
        [
            L10n.Onboarding.Steps.intro, L10n.Onboarding.Steps.account, L10n.Onboarding.Steps.server,
            L10n.Onboarding.Steps.agent, L10n.Onboarding.Steps.tour,
        ]
    }

    var body: some View {
        // All five labels when the row fits; otherwise only the current label (the others stay as numbers).
        ViewThatFits(in: .horizontal) {
            row(showsAllLabels: true)
            row(showsAllLabels: false)
        }
    }

    private func row(showsAllLabels: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(labels.enumerated()), id: \.offset) { k, label in
                let isCurrent = k == current
                Text("\(k + 1)")
                    .font(BanditoFont.font(size: 12, weight: 600))
                    .foregroundStyle(isCurrent ? Color.Bandito.onSignal : Color.Bandito.text3)
                    .frame(width: 24, height: 24)
                    .background(isCurrent ? Color.Bandito.signalFill : Color.Bandito.text.opacity(0.06), in: Circle())
                    .overlay(Circle().stroke(Color.Bandito.text.opacity(isCurrent ? 0 : 0.1)))
                if showsAllLabels || isCurrent {
                    Text(label)
                        .font(BanditoFont.font(size: 13, weight: isCurrent ? 600 : 400))
                        .foregroundStyle(isCurrent ? Color.Bandito.text : Color.Bandito.text3)
                        .lineLimit(1)
                        .fixedSize()
                }
                if k < labels.count - 1 {
                    Rectangle()
                        .fill(Color.Bandito.text.opacity(0.1))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
