import ActivityKit
import AppIntents
import BanditoDesign
import BanditoL10n
import SwiftUI
import WidgetKit

// The pictures of the turn's Live Activity: the lock screen card and the Dynamic Island's regions. Shared by the widget
// extension and the app (the tests render them). Nothing moves: the raccoon stands in the pose of the phase.

extension TurnActivityAttributes.Phase {
    var mood: AvatarMood {
        switch self {
        case .running: .working
        case .done: .idle
        case .needsYou: .needsYou
        case .failed: .error
        }
    }

    var tint: Color {
        switch self {
        case .running: Color.Bandito.info
        case .done: Color.Bandito.ok
        case .needsYou: Color.Bandito.signal
        case .failed: Color.Bandito.danger
        }
    }

    var symbol: String {
        switch self {
        case .running: "bolt.fill"
        case .done: "checkmark.circle.fill"
        case .needsYou: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    /// The words under the name once the turn is no longer running.
    var endLabel: String {
        switch self {
        case .running: ""
        case .done: L10n.Ios.Live.done
        case .needsYou: L10n.Status.needsYou
        case .failed: L10n.Ios.Live.failed
        }
    }
}

/// The agent's avatar, still.
struct TurnAvatar: View {
    let attributes: TurnActivityAttributes
    let phase: TurnActivityAttributes.Phase
    let size: CGFloat

    var body: some View {
        RaccoonFace(
            resolved: attributes.avatarSeed.resolved(name: attributes.agentName),
            tint: attributes.avatarSeed.tint(name: attributes.agentName),
            pose: AvatarPose.make(
                mood: phase.mood, time: 0, phase: AvatarPose.phase(for: attributes.agentName), reduceMotion: true),
            size: size)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The elapsed time while the turn runs, a symbol once it has ended.
struct TurnTrailing: View {
    let state: TurnActivityAttributes.ContentState
    var fontSize: CGFloat = 15

    var body: some View {
        if state.phase == .running {
            Text(timerInterval: state.startedAt...Date.distantFuture, pauseTime: nil, countsDown: false, showsHours: false)
                .font(BanditoFont.mono(size: fontSize, weight: 500))
                .monospacedDigit()
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.trailing)
                .frame(width: fontSize * 3.6, alignment: .trailing)
                .lineLimit(1)
        } else {
            Image(systemName: state.phase.symbol)
                .font(.system(size: fontSize + 3, weight: .semibold))
                .foregroundStyle(state.phase.tint)
                .accessibilityHidden(true)
        }
    }
}

/// The agent's name and, under it, what it does now (or how the turn ended).
struct TurnTitle: View {
    let attributes: TurnActivityAttributes
    let state: TurnActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attributes.agentName)
                .font(BanditoFont.display(size: 15, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Text(state.phase == .running ? state.doing : state.phase.endLabel)
                .font(BanditoFont.text(size: 13))
                .foregroundStyle(state.phase == .running ? Color.Bandito.text2 : state.phase.tint)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// "Stop": the live button, only while the turn runs.
struct TurnStopButton: View {
    let attributes: TurnActivityAttributes

    var body: some View {
        Button(intent: StopTurnIntent(serverID: attributes.serverID, agentID: attributes.agentID)) {
            HStack(spacing: BanditoSpace.s2) {
                Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                Text(L10n.Thread.stop).font(BanditoFont.text(size: 14, weight: 600))
            }
            .foregroundStyle(Color.Bandito.text)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(Capsule().fill(Color.Bandito.surface3))
            .overlay(Capsule().stroke(Color.Bandito.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The lock screen card: avatar 44, name and line, time on the right, Stop underneath.
struct TurnLockScreenView: View {
    let attributes: TurnActivityAttributes
    let state: TurnActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            HStack(spacing: BanditoSpace.s3) {
                TurnAvatar(attributes: attributes, phase: state.phase, size: 44)
                TurnTitle(attributes: attributes, state: state)
                Spacer(minLength: BanditoSpace.s2)
                TurnTrailing(state: state)
            }
            if state.phase == .running {
                TurnStopButton(attributes: attributes)
            }
        }
        .padding(BanditoSpace.s4)
    }
}
