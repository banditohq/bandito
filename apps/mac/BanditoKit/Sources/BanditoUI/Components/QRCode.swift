import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code of a string, drawn with CoreImage (no AppKit), for pairing a new device.
public struct QRCodeView: View {
    public let text: String
    /// Edge of the square in points.
    public let size: CGFloat

    public init(text: String, size: CGFloat = 180) {
        self.text = text
        self.size = size
    }

    public var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Black modules on white, scaled so every module is a whole number of pixels.
    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
