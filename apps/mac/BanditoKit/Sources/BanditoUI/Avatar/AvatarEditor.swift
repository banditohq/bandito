import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// The avatar editor, shown in a popover from the avatar: a large preview, three tabs (face, emoji, picture) and the
/// background color row. Every change of the look goes to `look` at once; the owner decides when it is applied (the
/// inspector sends it when the popover closes, the new agent sheet keeps it in its draft).
struct AvatarEditor: View {
    let name: String
    @Binding var look: AvatarLook
    /// The picture as shown now, decoded; nil without one.
    var picture: CGImage?
    /// Whether the server keeps pictures (`avatar_pictures`). Without it the picture tab says so.
    var pictureSupported: Bool
    /// Stores a framed picture (PNG bytes). Throws on failure; the editor shows the error.
    var onSetPicture: (Data) async throws -> Void
    /// Removes the picture. Throws on failure.
    var onRemovePicture: () async throws -> Void

    @State private var tab: Tab = .face
    /// A picture picked from disk and not yet saved: it is framed in the picture tab.
    @State private var framing: CGImage?
    @State private var error: UserFacingMessage?
    @State private var emojiText = ""

    enum Tab: Hashable {
        case face, emoji, picture
    }

    /// Largest PNG the daemon accepts for a picture (1 MB).
    static let maxPictureBytes = 1024 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                AvatarArtView(name: name, look: look, picture: picture, size: 92)
                Spacer()
            }
            SegmentedPicker(
                selection: $tab,
                options: [
                    (Tab.face, L10n.Avatar.tabFace),
                    (Tab.emoji, L10n.Avatar.tabEmoji),
                    (Tab.picture, L10n.Avatar.tabPicture),
                ])
            .frame(maxWidth: .infinity)
            switch tab {
            case .face: faceTab
            case .emoji: emojiTab
            case .picture: pictureTab
            }
            colorRow
            if let error {
                UserFacingErrorView(message: error)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Face

    private var faceTab: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(AvatarFace.faces, id: \.self) { face in
                let selected = look.face == face
                Button {
                    look.face = face
                } label: {
                    RaccoonAvatar(
                        name: name, color: look.palette, face: face, size: 44, mood: .idle,
                        customHex: look.customHex)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(selected ? Color.Bandito.text : Color.clear, lineWidth: 1.5))
                }
                .banditoButton(.row(cornerRadius: 12, hoverOpacity: 0.08))
                .help(faceName(face))
                .accessibilityLabel(faceName(face))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Emoji

    private var emojiTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField(L10n.Avatar.emojiField, text: $emojiText)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 16))
                    .frame(width: 58, height: 28)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.Bandito.line))
                Button(L10n.Avatar.allEmoji) {
                    NSApp.orderFrontCharacterPalette(nil)
                }
                .banditoButton(.quiet())
                .help(L10n.Avatar.allEmoji)
                Spacer(minLength: 0)
                Button(L10n.Avatar.noEmoji) {
                    look.emoji = nil
                }
                .banditoButton(.quiet())
                .disabled(look.emoji == nil)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                ForEach(AvatarEmoji.popular, id: \.self) { emoji in
                    let selected = look.emoji == emoji
                    Button {
                        look.emoji = emoji
                    } label: {
                        Text(emoji)
                            .font(.system(size: 19))
                            .frame(width: 34, height: 34)
                            .background(
                                selected ? Color.Bandito.text.opacity(0.1) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .banditoButton(.row(cornerRadius: 8, hoverOpacity: 0.08))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        // The system palette types into the field above; the newest character becomes the emoji.
        .onChange(of: emojiText) { _, text in
            guard let emoji = AvatarEmoji.last(of: text) else { return }
            look.emoji = emoji
            if emojiText != emoji { emojiText = emoji }
        }
    }

    // MARK: Picture

    @ViewBuilder
    private var pictureTab: some View {
        if !pictureSupported {
            hint(L10n.Avatar.pictureNeedsDaemon)
        } else if let framing {
            PictureFraming(
                image: framing, encode: { AvatarPicture.png(image: $0, crop: $1) },
                maxBytes: Self.maxPictureBytes, tooLargeText: L10n.Avatar.pictureTooLarge,
                onSave: { data in
                    try await onSetPicture(data)
                    self.framing = nil
                },
                onCancel: { self.framing = nil })
        } else {
            VStack(alignment: .leading, spacing: 10) {
                hint(picture == nil ? L10n.Avatar.pictureEmpty : L10n.Avatar.pictureCurrent)
                HStack(spacing: 8) {
                    Button(L10n.Avatar.chooseFile) { pickFile() }
                        .banditoButton(.signal())
                    if picture != nil {
                        Button(L10n.Avatar.removePicture) { removePicture() }
                            .banditoButton(.quiet())
                    }
                }
                if let error {
                    UserFacingErrorView(message: error)
                }
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.font(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.Avatar.pickerMessage
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Reading and downscaling the file happens off the main thread; only the result is set here.
        Task {
            guard let image = await Task.detached(operation: { AvatarImageFile.load(url) }).value else {
                error = UserFacingMessage(text: L10n.Avatar.pictureUnreadable)
                return
            }
            error = nil
            framing = image
        }
    }

    private func removePicture() {
        Task {
            do {
                try await onRemovePicture()
                error = nil
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    // MARK: Color

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.Avatar.color)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            HStack(spacing: 7) {
                ForEach(AvatarColor.allCases, id: \.self) { candidate in
                    paletteSwatch(candidate)
                }
                Rectangle().fill(Color.Bandito.text.opacity(0.1)).frame(width: 1, height: 18).padding(.horizontal, 3)
                customSwatch
            }
        }
    }

    private func paletteSwatch(_ candidate: AvatarColor) -> some View {
        let selected = look.customHex == nil && look.palette == candidate
        return Button {
            look.palette = candidate
            look.customHex = nil
        } label: {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(candidate.color)
                .frame(width: 22, height: 22)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(candidate.color, lineWidth: 1.5)
                            .frame(width: 28, height: 28)
                    }
                }
        }
        .banditoButton(.row(cornerRadius: 9, hoverOpacity: 0.08))
        .help(colorName(candidate))
        .accessibilityLabel(colorName(candidate))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// «Свой…»: a system color picker whose choice is stored as `#RRGGBB`.
    private var customSwatch: some View {
        let selected = look.customHex != nil
        return HStack(spacing: 6) {
            ColorPicker(L10n.Avatar.customColor, selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 26, height: 22)
            Text(L10n.Avatar.customColor)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(selected ? Color.Bandito.text : Color.Bandito.text3)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                if let hex = look.customHex.flatMap(AvatarHex.value) { return Color(hex: hex) }
                return look.palette.color
            },
            set: { value in
                let components = NSColor(value).usingColorSpace(.sRGB) ?? NSColor.gray
                look.customHex = AvatarHex.hex(
                    red: components.redComponent, green: components.greenComponent, blue: components.blueComponent)
            })
    }

    // MARK: Names

    private func colorName(_ color: AvatarColor) -> String {
        switch color {
        case .peach: L10n.AgentSheet.colorPeach
        case .sky: L10n.AgentSheet.colorSky
        case .sage: L10n.AgentSheet.colorSage
        case .rose: L10n.AgentSheet.colorRose
        case .lilac: L10n.AgentSheet.colorLilac
        case .cream: L10n.AgentSheet.colorCream
        }
    }

    private func faceName(_ face: AvatarFace) -> String {
        switch face {
        case .auto, .chevronDash: L10n.AgentSheet.faceSquint
        case .dots: L10n.AgentSheet.faceDots
        case .carets: L10n.AgentSheet.faceSmile
        case .wink: L10n.AgentSheet.faceWink
        case .surprised: L10n.AgentSheet.faceSurprised
        case .sleeping: L10n.AgentSheet.faceSleeping
        case .glasses: L10n.AgentSheet.faceGlasses
        case .happy: L10n.AgentSheet.faceHappy
        case .serious: L10n.AgentSheet.faceSerious
        }
    }
}
