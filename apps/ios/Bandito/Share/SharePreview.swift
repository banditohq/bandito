#if DEBUG
import BanditoDesign
import SwiftUI
import UIKit

/// `-share-preview`: the share sheet drawn inside the app with made-up agents, text and pictures (the screenshots). It
/// sends nothing: the model has no inbox.
enum SharePreview {
    static func isRequested(in arguments: [String]) -> Bool {
        arguments.contains("-share-preview")
    }

    @MainActor
    static func model(empty: Bool) -> ShareModel {
        let agents = empty ? [] : ["Forge", "Watch", "Scout", "Quill"].map {
            WidgetSnapshot.Listing(server: "preview", id: $0.lowercased(), name: $0, role: "")
        }
        let model = ShareModel(agents: agents, inbox: nil, defaults: nil)
        model.apply(
            SharedContent(
                text: "Look at this page\nhttps://bandito.dev/docs", images: [picture(0.55), picture(0.1)]))
        if ProcessInfo.processInfo.arguments.contains("-share-saved") { model.showSavedForPreview() }
        return model
    }

    private static func picture(_ hue: Double) -> PreparedImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        let image = renderer.image { context in
            UIColor(hue: hue, saturation: 0.35, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
        }
        return PreparedImage(jpeg: Data(), thumbnail: image)
    }
}
#endif
