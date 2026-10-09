import BanditoDesign
import SwiftUI

/// Color role of a section label.
public enum SectionLabelTone: Sendable {
    case muted, signal
}

/// Uppercase section heading such as "КОМАНДА" or "ЖДУТ ВАС".
public struct SectionLabel: View {
    public let text: String
    public var tone: SectionLabelTone

    public init(_ text: String, tone: SectionLabelTone = .muted) {
        self.text = text
        self.tone = tone
    }

    public var body: some View {
        Text(text.uppercased())
            .font(BanditoFont.font(size: 11, weight: 600))
            .tracking(0.9)
            .foregroundStyle(tone == .signal ? Color.Bandito.signal : Color.Bandito.text3)
    }
}
