import Foundation
import SwiftUI
#if os(macOS)
import AppKit
import PDFKit
#endif

/// The AppKit and PDFKit pieces of the Files mode. Everything else in `Files/` is SwiftUI.
@MainActor
enum FileBridge {
    /// Puts `text` on the general pasteboard.
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Asks where to save a download, or `nil` if the user cancelled.
    static func saveURL(suggestedName: String) -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return nil
        #endif
    }

    /// Asks for the files to upload from this Mac. Empty if the user cancelled.
    static func openURLs() -> [URL] {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
        #else
        return []
        #endif
    }

    /// An image from raw bytes, or `nil` if they are not an image this OS can draw.
    static func image(from data: Data) -> Image? {
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }

    /// The pixel size of an image, used to fit it to the panel.
    static func imageSize(from data: Data) -> CGSize? {
        #if os(macOS)
        return NSImage(data: data)?.size
        #else
        return nil
        #endif
    }
}

#if os(macOS)
/// PDF pages through PDFKit, scrolled continuously and fitted to the width.
struct PDFDocumentView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif

#if !os(macOS)
/// PDFs need PDFKit's view; elsewhere the PDF is not shown.
struct PDFDocumentView: View {
    let data: Data

    var body: some View {
        Text("")
    }
}
#endif
