import BanditoDesign
import BanditoL10n
import Foundation
import SwiftUI
import UIKit

/// The floating button of the Crew and the Activity: a tap opens the new-task sheet; a long press opens it with the
/// dictation already listening (docs/IOS_APP.md, "Task by voice").
struct NewTaskButton: View {
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// When the long press last fired. Its release is not a tap, so the tap that follows it is ignored.
    @State private var longPressedAt: Date?

    var body: some View {
        Button {
            if let at = longPressedAt, Date().timeIntervalSince(at) < 1 {
                longPressedAt = nil
                return
            }
            onTap()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.Bandito.onSignal)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.Bandito.signal))
                .shadow(color: Color.Bandito.signalGlow.opacity(0.35), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0.35) {
            longPressedAt = Date()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress()
        }
        .accessibilityLabel(L10n.Ios.NewTask.title)
        .accessibilityHint(L10n.Ios.NewTask.voiceHint)
        .accessibilityAction(named: Text(L10n.Ios.NewTask.voiceHint)) { onLongPress() }
        .accessibilityIdentifier("newTask.button")
    }
}
