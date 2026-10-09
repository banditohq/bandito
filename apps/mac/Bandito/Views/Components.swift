import BanditoDesign
import BanditoKit
import SwiftUI

/// Round avatar with the agent's initial on a color derived from its name.
struct AgentAvatar: View {
    var name: String
    var size: CGFloat = 40

    private static let palette: [Color] = [
        Color.Bandito.signal, Color.Bandito.ok, Color.Bandito.info, Color.Bandito.danger, Color.Bandito.text2,
    ]

    var body: some View {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        Circle()
            .fill(Self.palette[hash % Self.palette.count].opacity(0.9))
            .frame(width: size, height: size)
            .overlay(
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Color.Bandito.bg)
            )
    }
}

struct StatusDot: View {
    var status: AgentStatus

    var color: Color {
        switch status {
        case .idle: Color.Bandito.text3
        case .working: Color.Bandito.ok
        case .needsYou: Color.Bandito.signal
        case .error: Color.Bandito.danger
        case .offline: Color.Bandito.text3.opacity(0.4)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.Bandito.bg, lineWidth: 2))
            .shadow(color: status == .needsYou ? color.opacity(0.7) : .clear, radius: 4)
    }
}

/// Small rounded label, e.g. the agent's role.
struct Chip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.Bandito.text2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.Bandito.surface3, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// Primary action: orange fill, white text (brand rule).
struct SignalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.Bandito.onSignal)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                LinearGradient(
                    colors: [Color.Bandito.signalFill, Color.Bandito.signalFillEnd], startPoint: .top,
                    endPoint: .bottom),
                in: Capsule()
            )
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.Bandito.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.Bandito.surface3, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
