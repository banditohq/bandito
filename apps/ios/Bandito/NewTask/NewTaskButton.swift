import BanditoDesign
import BanditoL10n
import Foundation
import SwiftUI
import UIKit

/// The floating button of the Crew and the Activity: a short tap opens the new-task sheet; a long press opens it with
/// the dictation listening (docs/IOS_APP.md, "Task by voice").
///
/// One drag gesture decides at the release: no timer, no flag that a cancelled touch could leave set. A release that
/// moved away from where the press began is not a press of this button.
struct NewTaskButton: View {
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// Duration from the touch down that makes a press a long press.
    private static let longPressDuration: TimeInterval = 0.35
    /// How far the finger may wander and still count as a press of this button.
    private static let slop: CGFloat = 30

    /// When the finger went down: the first change of the press, read at its release.
    @State private var pressStart: Date?

    var body: some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(Color.Bandito.onSignal)
            .frame(width: 56, height: 56)
            .background(Circle().fill(Color.Bandito.signal))
            .shadow(color: Color.Bandito.signalGlow.opacity(0.35), radius: 10, x: 0, y: 4)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if pressStart == nil { pressStart = Date() }
                    }
                    .onEnded { value in
                        let started = pressStart ?? Date()
                        pressStart = nil
                        guard abs(value.translation.width) < Self.slop, abs(value.translation.height) < Self.slop
                        else { return }
                        if Date().timeIntervalSince(started) >= Self.longPressDuration {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onLongPress()
                        } else {
                            onTap()
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(L10n.Ios.NewTask.title)
            .accessibilityHint(L10n.Ios.NewTask.voiceHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(L10n.Ios.NewTask.voiceHint)) { onLongPress() }
            .accessibilityAction { onTap() }
            .accessibilityIdentifier("newTask.button")
    }
}
