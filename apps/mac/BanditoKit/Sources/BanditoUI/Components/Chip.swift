import BanditoDesign
import SwiftUI

/// Color role of a chip.
public enum ChipTone: CaseIterable, Sendable {
    case neutral, signal, ok, info, danger
}

/// Small rounded label, e.g. an agent role or a status word. Always pair the color with the text.
public struct Chip: View {
    /// Text shown in the chip.
    public var text: String
    /// Color role: `.neutral` for plain labels, the others for states.
    public var tone: ChipTone

    public init(text: String, tone: ChipTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text)
            .font(BanditoFont.font(size: 11, weight: 500))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

extension ChipTone {
    var foreground: Color {
        switch self {
        case .neutral: Color.Bandito.text2
        case .signal: Color.Bandito.signal
        case .ok: Color.Bandito.ok
        case .info: Color.Bandito.info
        case .danger: Color.Bandito.danger
        }
    }

    var background: Color {
        switch self {
        case .neutral: Color.Bandito.text.opacity(0.07)
        case .signal, .ok, .info, .danger: foreground.opacity(0.12)
        }
    }
}
