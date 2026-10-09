import BanditoDesign
import BanditoKit
import SwiftUI

/// Agent status dot: idle, working (sage glow), needs you (orange glow and pulsing ring),
/// error, offline (dimmed). VoiceOver reads the status name.
public struct StatusDot: View {
    /// Status shown by the dot.
    public var status: AgentStatus
    /// Diameter of the dot in points.
    public var size: CGFloat
    /// Color of the ring that separates the dot from the avatar underneath (the surface color).
    public var ringColor: Color

    public init(status: AgentStatus, size: CGFloat = 11, ringColor: Color = Color.Bandito.bg) {
        self.status = status
        self.size = size
        self.ringColor = ringColor
    }

    public var body: some View {
        ZStack {
            if status == .needsYou {
                PulseRing(size: size, color: Color.Bandito.signal)
            }
            Circle()
                .fill(fill)
                .overlay(Circle().strokeBorder(ringColor, lineWidth: max(1.5, size * 2.5 / 11)))
                .frame(width: size, height: size)
                .shadow(color: glow, radius: size * 0.6)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var fill: Color {
        switch status {
        case .idle: BanditoPalette.idle
        case .working: Color.Bandito.ok
        case .needsYou: Color.Bandito.signal
        case .error: Color.Bandito.danger
        case .offline: BanditoPalette.idle.opacity(0.4)
        }
    }

    private var glow: Color {
        switch status {
        case .working: Color.Bandito.ok.opacity(0.6)
        case .needsYou: Color.Bandito.signal.opacity(0.7)
        case .idle, .error, .offline: .clear
        }
    }

    /// English status names for VoiceOver. Localization is added with BanditoL10n later.
    private var accessibilityText: String {
        switch status {
        case .idle: "Idle"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .error: "Error"
        case .offline: "Offline"
        }
    }
}

/// Ring that expands and fades around the dot. It starts at a visible rest frame, so
/// static renders (snapshots) show it. It pulses on screen unless Reduce Motion is on.
private struct PulseRing: View {
    let size: CGFloat
    let color: Color

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(MotionLevel.storageKey) private var motionLevel = MotionLevel.full.rawValue
    /// Repeating motion stands still: Reduce Motion, or "Less" / "Off" in settings.
    private var still: Bool { reduceMotion || !MotionLevel(stored: motionLevel).allowsRepeatingMotion }

    var body: some View {
        let base = size + 4
        Circle()
            .strokeBorder(color, lineWidth: 2)
            .frame(width: base, height: base)
            .scaleEffect(isExpanded ? (size + 14) / base : 1)
            .opacity(isExpanded ? 0 : 0.55)
            .onAppear(perform: updatePulse)
            .onChange(of: still) { _, _ in updatePulse() }
    }

    /// Starts the repeating pulse, or rests the ring without animation when Reduce Motion is on.
    private func updatePulse() {
        if still {
            withAnimation(nil) {
                isExpanded = false
            }
        } else {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                isExpanded = true
            }
        }
    }
}
