import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// The picture tab of the avatar editor: a drop zone while there is no picture, the picture with «Replace» and
/// «Remove» once there is one, and the framing in the same place when a file has been picked.
extension AvatarEditor {
    @ViewBuilder
    var pictureTab: some View {
        if !pictureSupported {
            Text(L10n.Avatar.pictureNeedsDaemon)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let framing = model.framing {
            PictureFraming(
                image: framing, encode: { AvatarPicture.png(image: $0, crop: $1) },
                maxBytes: Self.maxPictureBytes, tooLargeText: L10n.Avatar.pictureTooLarge,
                onSave: { data in
                    try await onSetPicture(data)
                    model.reset()
                },
                onCancel: { model.reset() },
                side: AvatarEditorLayout.cropSide)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if let picture {
                    currentPicture(picture)
                } else {
                    AvatarDropZone(model: model)
                }
                if let error = model.error {
                    UserFacingErrorView(message: error)
                }
            }
        }
    }

    private func currentPicture(_ picture: CGImage) -> some View {
        HStack(spacing: 16) {
            Image(decorative: picture, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
            VStack(alignment: .leading, spacing: 8) {
                Button(L10n.Avatar.replacePicture) { model.chooseFile() }
                    .banditoButton(.quiet())
                Button(L10n.Avatar.removePicture) { removePicture() }
                    .banditoButton(.link)
                    .font(BanditoFont.font(size: 12.5, weight: 500))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // A picture can be dropped over the current one to replace it.
        .onDrop(of: [.fileURL], isTargeted: nil) { model.drop($0) }
    }

    private func removePicture() {
        Task {
            do {
                try await onRemovePicture()
                model.error = nil
            } catch {
                model.error = UserFacingError.message(for: error)
            }
        }
    }
}

/// The dashed zone: a click opens the file panel, a dropped file is read at once.
struct AvatarDropZone: View {
    let model: AvatarEditorModel
    @State private var targeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button {
            model.chooseFile()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(targeted ? Color.Bandito.text : Color.Bandito.text2)
                Text(L10n.Avatar.dropZone)
                    .font(BanditoFont.font(size: 13, weight: 400))
                    .foregroundStyle(targeted ? Color.Bandito.text : Color.Bandito.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
            .background(targeted ? Color.Bandito.text.opacity(0.06) : Color.Bandito.text.opacity(0.02), in: shape)
            .overlay(
                shape.strokeBorder(
                    targeted ? Color.Bandito.text2 : Color.Bandito.text.opacity(0.2),
                    style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
            .contentShape(shape)
        }
        .banditoButton(.row(cornerRadius: 14, hoverOpacity: 0.04))
        .onDrop(of: [.fileURL], isTargeted: $targeted) { model.drop($0) }
        .accessibilityLabel(L10n.Avatar.dropZone)
    }
}
