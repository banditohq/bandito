import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Reads the texts, links and pictures out of the extension's input items. Pictures are read one at a time and brought
/// down with ImageIO without decoding the full size, so a big photo does not use up the extension's memory.
enum ShareLoader {
    @MainActor
    static func load(from items: [NSExtensionItem]) async -> SharedContent {
        var texts: [String] = []
        var urls: [String] = []
        var providers: [NSItemProvider] = []
        for item in items {
            if let attributed = item.attributedContentText?.string { texts.append(attributed) }
            providers.append(contentsOf: item.attachments ?? [])
        }
        var content = SharedContent()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard content.images.count < ShareRules.maxImages else { continue }
                if let image = await loadImage(provider) { content.images.append(image) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = await loadURL(provider), !url.isFileURL { urls.append(url.absoluteString) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = await loadText(provider) { texts.append(text) }
            }
        }
        content.text = ShareRules.compose(texts: texts, urls: urls)
        return content
    }

    // MARK: pieces

    @MainActor
    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                if let text = value as? String {
                    continuation.resume(returning: text)
                } else if let url = value as? URL {
                    continuation.resume(returning: url.isFileURL ? nil : url.absoluteString)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @MainActor
    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                if let url = value as? URL {
                    continuation.resume(returning: url)
                } else if let text = value as? String {
                    continuation.resume(returning: URL(string: text))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// A picture as a file (the host's own copy, deleted when the handler returns), else as an item (`UIImage`, `Data`
    /// or a file URL). Either way it is read and shrunk here, inside the handler.
    @MainActor
    private static func loadImage(_ provider: NSItemProvider) async -> PreparedImage? {
        let fromFile: PreparedImage? = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                continuation.resume(returning: prepare(source: CGImageSourceCreateWithURL(url as CFURL, nil)))
            }
        }
        if let fromFile { return fromFile }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.image.identifier) { value, _ in
                if let url = value as? URL {
                    continuation.resume(returning: prepare(source: CGImageSourceCreateWithURL(url as CFURL, nil)))
                } else if let data = value as? Data {
                    continuation.resume(returning: prepare(source: CGImageSourceCreateWithData(data as CFData, nil)))
                } else if let image = value as? UIImage, let data = image.pngData() {
                    continuation.resume(returning: prepare(source: CGImageSourceCreateWithData(data as CFData, nil)))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// The picture with its longer side at most `ShareRules.maxPixel`, upright, as a JPEG; nil for anything unreadable.
    static func prepare(source: CGImageSource?) -> PreparedImage? {
        guard let source else { return nil }
        guard let big = thumbnail(source, maxPixel: ShareRules.maxPixel),
              let jpeg = UIImage(cgImage: big).jpegData(compressionQuality: ShareRules.jpegQuality),
              let small = thumbnail(source, maxPixel: 240)
        else { return nil }
        return PreparedImage(jpeg: jpeg, thumbnail: UIImage(cgImage: small))
    }

    private static func thumbnail(_ source: CGImageSource, maxPixel: Int) -> CGImage? {
        // A picture smaller than the limit is never enlarged.
        var limit = maxPixel
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int, max(width, height) > 0 {
            limit = min(maxPixel, max(width, height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
