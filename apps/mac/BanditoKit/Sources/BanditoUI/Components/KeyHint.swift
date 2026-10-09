import BanditoDesign
import SwiftUI

/// Keyboard shortcut hint such as `⌘K` or `esc`, shown inside buttons and menus.
public struct KeyHint: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(BanditoFont.font(size: 10.5, weight: 400, mono: true))
            .foregroundStyle(Color.Bandito.text3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.Bandito.text.opacity(0.14), lineWidth: 1)
            )
    }
}
