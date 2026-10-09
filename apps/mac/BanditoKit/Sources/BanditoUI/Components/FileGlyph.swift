import BanditoDesign
import SwiftUI

/// The square icon that stands for a file or folder: an SF Symbol on a tint of its kind's color.
struct FileGlyph: View {
    var category: FileCategory
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }

    var symbol: String {
        switch category {
        case .folder: "folder.fill"
        case .markdown: "doc.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .text: "doc.plaintext"
        case .config: "gearshape"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        case .binary: "shippingbox"
        case .other: "doc"
        }
    }

    /// Folders amber, code violet, documents blue, video red, images green, config gray (as in the mockups).
    var tint: Color {
        switch category {
        case .folder: Color(hex: 0xFFB067)
        case .code: Color(hex: 0xC8B6E8)
        case .markdown, .text, .pdf, .other: Color(hex: 0xA3BDEB)
        case .video, .audio: Color(hex: 0xF2A093)
        case .image: Color(hex: 0xA9C7A2)
        case .config, .binary: Color(hex: 0xBDB2A0)
        }
    }
}
