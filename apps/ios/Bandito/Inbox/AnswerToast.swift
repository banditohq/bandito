import BanditoDesign
import Foundation
import SwiftUI

/// What the toast says after a person answered an agent: "Allowed — Forge goes on", "Denied — Forge will know".
struct AnswerToastMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    /// True for an answer that lets the agent go on (the check mark), false for a refusal (the cross).
    let allowed: Bool
}

/// Holds the one toast on screen. A new message replaces the shown one and restarts the time; the message leaves after
/// 2.5 s, unless a newer one has replaced it meanwhile. VoiceOver hears the text when it appears.
@Observable @MainActor final class AnswerToastCenter {
    private(set) var current: AnswerToastMessage?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    /// Messages that wait for their turn (`showInTurn`): each gets its own 2.5 s after the one before has left.
    @ObservationIgnored private var queue: [AnswerToastMessage] = []

    /// Shows the message at once, in place of the one on screen (an answer says what it did now).
    func show(_ message: AnswerToastMessage) {
        hideTask?.cancel()
        current = message
        AccessibilityNotification.Announcement(message.text).post()
        let id = message.id
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.current = nil
            guard !self.queue.isEmpty else { return }
            // A short gap, so the next one is seen to be another message.
            try? await Task.sleep(for: .seconds(0.3))
            guard !Task.isCancelled, self.current == nil, !self.queue.isEmpty else { return }
            self.show(self.queue.removeFirst())
        }
    }

    /// Shows the messages one after the other (notices that waited behind the Face ID lock), none replacing another.
    func showInTurn(_ messages: [AnswerToastMessage]) {
        queue += messages
        guard current == nil, !queue.isEmpty else { return }
        show(queue.removeFirst())
    }
}

extension EnvironmentValues {
    /// The toast centre of the app, set once by RootView for every tab. Nil outside the app (previews).
    @Entry var answerToast: AnswerToastCenter?
}

/// The toast itself: a capsule on `surface2` with a hairline, a check or a cross, one or two lines of text.
struct AnswerToastView: View {
    let message: AnswerToastMessage

    var body: some View {
        HStack(spacing: BanditoSpace.s2) {
            Image(systemName: message.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(message.allowed ? Color.Bandito.ok : Color.Bandito.text2)
            Text(message.text)
                .font(BanditoFont.text(size: 14, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
        }
        .padding(.horizontal, BanditoSpace.s4)
        .padding(.vertical, BanditoSpace.s3)
        .background(Capsule().fill(Color.Bandito.surface2))
        .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        .accessibilityElement(children: .combine)
    }
}

/// The toast's place at the bottom of the app, above the tab bar and the New task button. It reads the centre itself,
/// so RootView's body does not run again each time a toast comes or goes. Under Reduce Motion it only fades.
struct AnswerToastHost: View {
    let center: AnswerToastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let message = center.current {
                AnswerToastView(message: message)
                    .padding(.bottom, 96)
                    .padding(.horizontal, BanditoSpace.s4)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .id(message.id)
            }
        }
        // A surface that moves in and out takes the brand's slide (docs/DESIGN_LANGUAGE.md, Motion), and leaves the
        // way it came. It never takes a tap from the screen under it.
        .animation(reduceMotion ? nil : BanditoMotion.slide, value: center.current?.id)
        .allowsHitTesting(false)
    }
}
