#if os(macOS)
import AppKit

/// What a ⌘V in the chat field attaches, read from a pasteboard by `PasteboardAttachments.read`. Text is not here: the
/// field pastes text as it always did.
enum PasteboardAttachment: Equatable {
    /// Files on this Mac, pictures or not. They are attached the way a drop of files is (`AttachmentTrays.add(urls:)`).
    case files([URL])
    /// One picture as PNG bytes: the PNG on the pasteboard, or its TIFF converted to PNG.
    case picture(Data)
    /// Nothing to attach: the paste goes to the field.
    case none
}

/// Reads the clipboard for ⌘V. Pure over the pasteboard it is given, so tests use a pasteboard of their own.
enum PasteboardAttachments {
    /// The files first (all of them), then a picture when the pasteboard holds no text. A picture that comes with text
    /// (a web page copied with its image) stays a text paste, as before.
    static func read(_ pasteboard: NSPasteboard) -> PasteboardAttachment {
        let urls = fileURLs(pasteboard)
        if !urls.isEmpty {
            return .files(urls)
        }
        let text = pasteboard.string(forType: .string) ?? ""
        guard text.isEmpty, let png = pngData(pasteboard) else { return .none }
        return .picture(png)
    }

    /// The file URLs on the pasteboard, in order. A web address is not a file.
    static func fileURLs(_ pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }

    /// The first picture on the pasteboard as PNG: `.png` as it is, `.tiff` converted. Nil when there is neither.
    static func pngData(_ pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
#endif
