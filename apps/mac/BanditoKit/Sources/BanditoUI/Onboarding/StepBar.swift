import BanditoDesign
import BanditoL10n
import SwiftUI

/// The first-run steps as a row of numbered dots joined by hairlines. `current` is 0-based.
struct OnboardingStepBar: View {
    var current: Int

    private var labels: [String] {
        [
            L10n.Onboarding.Steps.intro, L10n.Onboarding.Steps.features, L10n.Onboarding.Steps.account,
            L10n.Onboarding.Steps.server, L10n.Onboarding.Steps.runtimes, L10n.Onboarding.Steps.crew,
            L10n.Onboarding.Steps.task,
        ]
    }

    var body: some View {
        // All labels when the row fits; otherwise only the current label (the others stay as numbers).
        // `FirstFit`, not `ViewThatFits`: the bar sits in the flow's frame and would measure both rows at every change.
        FirstFit(count: 2) { index, _ in
            row(showsAllLabels: index == 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.Onboarding.stepOf(step: "\(min(current + 1, labels.count))", total: "\(labels.count)"))
        .accessibilityValue(labels.indices.contains(current) ? labels[current] : "")
    }

    private func row(showsAllLabels: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(labels.enumerated()), id: \.offset) { k, label in
                let isCurrent = k == current
                let isDone = k < current
                Text("\(k + 1)")
                    .font(BanditoFont.text(size: 12, weight: 600))
                    .foregroundStyle(isCurrent ? Color.Bandito.onSignal : (isDone ? Color.Bandito.text2 : Color.Bandito.text3))
                    .frame(width: 24, height: 24)
                    .background(isCurrent ? Color.Bandito.signalFill : Color.Bandito.text.opacity(isDone ? 0.10 : 0.06), in: Circle())
                    .overlay(Circle().stroke(Color.Bandito.text.opacity(isCurrent ? 0 : 0.1)))
                if showsAllLabels || isCurrent {
                    Text(label)
                        .font(BanditoFont.text(size: 13, weight: isCurrent ? 600 : 400))
                        .foregroundStyle(isCurrent ? Color.Bandito.text : Color.Bandito.text3)
                        .lineLimit(1)
                        .fixedSize()
                }
                if k < labels.count - 1 {
                    Rectangle()
                        .fill(Color.Bandito.text.opacity(isDone ? 0.22 : 0.1))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}
