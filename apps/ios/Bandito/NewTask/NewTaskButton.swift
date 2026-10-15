import BanditoDesign
import BanditoL10n
import Foundation
import SwiftUI
import UIKit

/// The floating button of the Crew and the Activity: a short tap opens the new-task sheet; a long press opens it with
/// the dictation listening (docs/IOS_APP.md, "Task by voice").
///
/// One drag gesture: a release before 0.35 s is a tap; holding longer fires the long press while the finger is down.
/// A finger that wanders away cancels the press. Every flag is cleared at the release, so a cancelled touch leaves none.
struct NewTaskButton: View {
    let onTap: () -> Void
    let onLongPress: () -> Void

    /// Duration from the touch down that makes a press a long press.
    private static let longPressDuration: TimeInterval = 0.35
    /// How far the finger may wander and still count as a press of this button.
    private static let slop: CGFloat = 30

    /// The press under way: set at the first touch, cleared at the release.
    @State private var pressing = false
    /// This touch is used up (the long press fired, or the finger wandered away): the rest of it does nothing.
    @State private var touchSpent = false
    /// The finger is down. A gesture state is reset by the system also when the touch is cancelled (the sheet that a
    /// long press opens cancels it, and no release comes), so the flags above are cleared on every end of a touch.
    @GestureState private var touching = false
    @State private var longPressTimer: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(Color.Bandito.text)
            Image(systemName: "square.and.pencil")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.Bandito.bg)
            // The one orange mark: a dot in the top right, as on the cream primary button (a signal dot, never a fill).
            Circle()
                .fill(Color.Bandito.signalFill)
                .frame(width: 8, height: 8)
                .offset(x: 17, y: -17)
        }
        .frame(width: 56, height: 56)
        .shadow(color: Color.Bandito.bg.opacity(0.35), radius: 12, x: 0, y: 4)
        .scaleEffect(pressing && !reduceMotion ? 0.92 : 1)
        .animation(reduceMotion ? nil : BanditoMotion.ease, value: pressing)
        .contentShape(Circle())
            .onChange(of: touching) { _, down in
                guard !down else { return }
                cancelPress()
                touchSpent = false
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
                    .onChanged { value in
                        let moved = abs(value.translation.width) >= Self.slop || abs(value.translation.height) >= Self.slop
                        if moved {
                            cancelPress()
                            touchSpent = true
                            return
                        }
                        guard !pressing, !touchSpent else { return }
                        pressing = true
                        // The long press fires while the finger is still down: the dictation starts at once.
                        longPressTimer = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(Self.longPressDuration))
                            guard !Task.isCancelled, pressing else { return }
                            touchSpent = true
                            pressing = false
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            onLongPress()
                        }
                    }
                    .onEnded { value in
                        let wasPressing = pressing
                        let moved = abs(value.translation.width) >= Self.slop || abs(value.translation.height) >= Self.slop
                        cancelPress()
                        // After a long press `pressing` is already false: the release is not a tap.
                        if wasPressing, !moved { onTap() }
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

    private func cancelPress() {
        longPressTimer?.cancel()
        longPressTimer = nil
        pressing = false
    }
}

/// What the floating button does; set by RootView only while there is an agent to give a task to.
struct NewTaskAction {
    let open: @MainActor (_ dictate: Bool) -> Void
}

extension EnvironmentValues {
    @Entry var newTaskAction: NewTaskAction?
}

extension View {
    /// The floating New task button at the bottom right. Put on the root of a tab's navigation stack, so the pushed
    /// screens (the chat with its own box, an agent's card) never show it.
    func newTaskButton() -> some View {
        modifier(NewTaskButtonPlacement())
    }
}

private struct NewTaskButtonPlacement: ViewModifier {
    @Environment(\.newTaskAction) private var action

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
            if let action {
                NewTaskButton(onTap: { action.open(false) }, onLongPress: { action.open(true) })
                    .padding(.trailing, BanditoSpace.s4)
                    .padding(.bottom, BanditoSpace.s2)
            }
        }
    }
}
