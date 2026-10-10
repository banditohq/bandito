import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// Frames a picture in a square and saves the framed part: the shared step of the agent avatar editor and the profile
/// photo. The crop, the zoom and the save are here; what the bytes are (PNG or JPEG) and where they go is the caller's.
struct PictureFraming: View {
    let image: CGImage
    /// Turns the framed part into bytes; nil when the encoder fails. Runs off the main thread.
    let encode: @Sendable (CGImage, AvatarCrop) -> Data?
    /// The largest the bytes may be.
    let maxBytes: Int
    let tooLargeText: String
    /// Saves the bytes. Throws on failure; the error shows under the frame.
    let onSave: (Data) async throws -> Void
    let onCancel: () -> Void
    var side: CGFloat = 240
    /// Frame the profile photo in a circle.
    var circular = false

    @State private var crop = AvatarCrop()
    @State private var busy = false
    @State private var error: UserFacingMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AvatarCropFrame(image: image, crop: $crop, side: side, circular: circular)
            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(Color.Bandito.text3)
                Slider(value: zoomBinding, in: AvatarCrop.minZoom...AvatarCrop.maxZoom)
                    .accessibilityLabel(L10n.Avatar.zoom)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(Color.Bandito.text3)
            }
            Text(L10n.Avatar.cropHint)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
            if let error {
                UserFacingErrorView(message: error)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(L10n.Common.cancel, action: onCancel)
                    .banditoButton(.quiet())
                Button(L10n.Common.save) { save() }
                    .banditoButton(.signal())
                    .disabled(busy)
            }
        }
        .frame(width: side)
    }

    private var zoomBinding: Binding<Double> {
        Binding(get: { crop.zoom }, set: { crop.setZoom($0) })
    }

    private func save() {
        busy = true
        error = nil
        let image = image, crop = crop, encode = encode, maxBytes = maxBytes
        Task {
            defer { busy = false }
            // Encoding (and the size check) runs off the main thread; saving is awaited as the caller wrote it.
            let data = await Task.detached(operation: { encode(image, crop) }).value
            guard let data else {
                error = UserFacingMessage(text: L10n.Avatar.pictureUnreadable)
                return
            }
            guard data.count <= maxBytes else {
                error = UserFacingMessage(text: tooLargeText)
                return
            }
            do {
                try await onSave(data)
            } catch {
                self.error = UserFacingError.message(for: error)
            }
        }
    }
}
