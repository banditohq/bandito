import BanditoDesign
import BanditoKit
import CoreGraphics
import SwiftUI

/// The square the owner frames a picture in: the picture moves under a drag, and the crop is the square inside the
/// frame. The image is drawn at the scale `AvatarCropLayout` gives, so what is shown is what is saved.
struct AvatarCropFrame: View {
    let image: CGImage
    @Binding var crop: AvatarCrop
    /// Edge of the square on screen, in points.
    var side: CGFloat
    /// A circle for the profile photo, the avatar tile for an agent.
    var circular = false

    /// The drag translation already applied, so each change moves the crop by the new step only.
    @State private var applied: CGSize = .zero

    private var radius: CGFloat { circular ? side / 2 : side * 17 / 52 }

    private var imageSize: CGSize { CGSize(width: image.width, height: image.height) }

    var body: some View {
        let placement = AvatarCropLayout.placement(crop: crop, imageSize: imageSize, frame: side)
        ZStack(alignment: .topLeading) {
            if let placement {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(
                        width: imageSize.width * placement.scale, height: imageSize.height * placement.scale)
                    .offset(x: placement.offset.x, y: placement.offset.y)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.Bandito.line, lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let step = CGSize(
                        width: value.translation.width - applied.width,
                        height: value.translation.height - applied.height)
                    applied = value.translation
                    let delta = AvatarCropLayout.centerDelta(
                        translation: step, crop: crop, imageSize: imageSize, frame: side)
                    crop.pan(by: delta, in: imageSize)
                }
                .onEnded { _ in applied = .zero })
        .accessibilityHidden(true)
    }
}
