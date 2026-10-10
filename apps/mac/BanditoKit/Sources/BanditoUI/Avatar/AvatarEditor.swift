import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// The avatar editor, shown in a popover from the avatar: the preview and a line about it, three tabs (face, emoji,
/// picture) and the background color row. Every change of the look goes to `look` at once; the owner decides when it
/// is applied (the inspector sends it when the popover closes, the new agent sheet keeps it in its draft).
///
/// What must survive the popover closing (a picture read from disk, the tab, the error) lives in `model`, which the
/// owner keeps. See `AvatarEditorModel` for why.
struct AvatarEditor: View {
    let name: String
    @Binding var look: AvatarLook
    let model: AvatarEditorModel
    /// The picture as shown now, decoded; nil without one.
    var picture: CGImage?
    /// Whether the server keeps pictures (`avatar_pictures`). Without it the picture tab says so.
    var pictureSupported: Bool
    /// Stores a framed picture (PNG bytes). Throws on failure; the editor shows the error.
    var onSetPicture: (Data) async throws -> Void
    /// Removes the picture. Throws on failure.
    var onRemovePicture: () async throws -> Void

    @State private var emojiText = ""
    @FocusState private var emojiFocused: Bool

    enum Tab: Hashable {
        case face, emoji, picture
    }

    /// Largest PNG the daemon accepts for a picture (1 MB).
    static let maxPictureBytes = 1024 * 1024

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            header
            SegmentedPicker(
                selection: $model.tab,
                options: [
                    (Tab.face, L10n.Avatar.tabFace),
                    (Tab.emoji, L10n.Avatar.tabEmoji),
                    (Tab.picture, L10n.Avatar.tabPicture),
                ])
            .frame(maxWidth: .infinity)
            switch model.tab {
            case .face: faceTab
            case .emoji: emojiTab
            case .picture: pictureTab
            }
            // Framing a picture takes the whole popover; the color waits until it is saved or cancelled.
            if !(model.tab == .picture && model.framing != nil) {
                AvatarColorRow(look: $look)
            }
        }
        .padding(AvatarEditorLayout.inset)
        .frame(width: AvatarEditorLayout.width)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            AvatarArtView(name: name, look: look, picture: picture, size: 72)
            VStack(alignment: .leading, spacing: 3) {
                let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    Text(title)
                        .font(BanditoFont.font(size: 15, weight: 600))
                        .foregroundStyle(Color.Bandito.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(L10n.Avatar.hint)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Face

    private var faceTab: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 6) {
            ForEach(AvatarFace.faces, id: \.self) { face in
                let selected = look.emoji == nil && look.face == face
                Button {
                    look.face = face
                    // An emoji is drawn instead of the face: picking a face means the face is what should show.
                    look.emoji = nil
                    emojiText = ""
                } label: {
                    RaccoonAvatar(
                        name: name, color: look.palette, face: face, size: 40, mood: .idle,
                        customHex: look.customHex)
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .stroke(selected ? Color.Bandito.text : Color.clear, lineWidth: 2))
                }
                .banditoButton(.row(cornerRadius: 15, hoverOpacity: 0.08))
                .help(faceName(face))
                .accessibilityLabel(faceName(face))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    // MARK: Emoji

    /// The words typed into the field when they are not an emoji: they filter the grid by name.
    private var searchQuery: String {
        AvatarEmoji.last(of: emojiText) == nil ? emojiText : ""
    }

    private var emojiTab: some View {
        let shown = AvatarEmoji.search(searchQuery, in: AvatarEmoji.popular)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.Bandito.text3)
                    TextField(L10n.Avatar.emojiField, text: $emojiText)
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 13.5, weight: 400))
                        .focused($emojiFocused)
                        .accessibilityLabel(L10n.Avatar.emojiField)
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.Bandito.line))
                Button {
                    // The system palette types into the focused field, so the field takes the focus first.
                    emojiFocused = true
                    DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                } label: {
                    Image(systemName: "face.smiling")
                        .font(.system(size: 14))
                }
                .banditoButton(.icon(size: 32, label: L10n.Avatar.allEmoji))
            }
            if shown.isEmpty {
                Text(L10n.Avatar.noMatches)
                    .font(BanditoFont.font(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                emojiGrid(shown)
            }
            if look.emoji != nil {
                Button(L10n.Avatar.noEmoji) {
                    look.emoji = nil
                    emojiText = ""
                }
                .banditoButton(.link)
                .font(BanditoFont.font(size: 12.5, weight: 500))
            }
        }
        // The system palette types into the field above; the newest character becomes the emoji.
        .onChange(of: emojiText) { _, text in
            guard let emoji = AvatarEmoji.last(of: text) else { return }
            look.emoji = emoji
            if emojiText != emoji { emojiText = emoji }
        }
    }

    private func emojiGrid(_ items: [String]) -> some View {
        let cell = AvatarEditorLayout.emojiCell
        let spacing = AvatarEditorLayout.emojiSpacing
        return ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cell), spacing: 0), count: AvatarEditorLayout.emojiColumns),
                spacing: spacing
            ) {
                ForEach(items, id: \.self) { emoji in
                    let selected = look.emoji == emoji
                    Button {
                        look.emoji = emoji
                        emojiText = ""
                    } label: {
                        Text(emoji)
                            .font(.system(size: 20))
                            .frame(width: cell, height: cell)
                            .background(
                                selected ? Color.Bandito.text.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .banditoButton(.row(cornerRadius: 9, hoverOpacity: 0.08))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .frame(height: AvatarEditorLayout.gridHeight(count: items.count))
    }

    // MARK: Names

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
