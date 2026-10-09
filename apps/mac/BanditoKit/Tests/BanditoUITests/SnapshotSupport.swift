import AppKit
import SwiftUI
import Testing

/// Shared PNG renderer for UI snapshot tests (no window, no app).
/// Output directory: $BANDITO_SNAPSHOTS or the temp directory.
@MainActor
enum SnapshotSupport {
    static var outDir: URL {
        let path = ProcessInfo.processInfo.environment["BANDITO_SNAPSHOTS"] ?? NSTemporaryDirectory() + "bandito-snapshots"
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Renders `view` in dark mode at 2× into `<outDir>/<name>.png` and returns the file URL.
    static func render(_ view: some View, _ name: String, size: CGSize) throws -> URL {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
        renderer.scale = 2
        let image = try #require(renderer.nsImage, "render \(name)")
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        let url = outDir.appending(path: "\(name).png")
        try png.write(to: url)
        return url
    }
}
