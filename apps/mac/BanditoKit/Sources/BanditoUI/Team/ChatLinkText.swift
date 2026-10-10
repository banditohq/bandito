import AppKit
import BanditoKit
import SwiftUI

/// Makes the file paths and web addresses of a message into links, and opens them.
///
/// A file link carries its path as written (`bandito-file://open?path=…`), so the view can resolve it against the
/// agent's folder when it is clicked. A web link keeps its address.
enum ChatLinkText {
    static let fileScheme = "bandito-file"

    /// The link URL of a file path as written in the message.
    static func fileURL(path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = fileScheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        return parts.url
    }

    /// The path a file link carries, or `nil` for any other URL.
    static func filePath(of url: URL) -> String? {
        guard url.scheme == fileScheme,
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
            !value.isEmpty
        else { return nil }
        return value
    }

    /// The text with its links set. Links already in the text (Markdown links) are left as they are. The ranges
    /// come from the characters the person reads, so Markdown markers never shift them.
    static func linked(_ text: AttributedString) -> AttributedString {
        var result = text
        let plain = String(text.characters)
        for link in ChatLinks.find(in: plain) {
            let lower = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: link.range.lowerBound))
            let upper = result.index(result.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: link.range.upperBound))
            guard result[lower..<upper].link == nil else { continue }
            switch link.target {
            case .file(let path), .path(let path):
                result[lower..<upper].link = fileURL(path: path)
            case .url(let address):
                result[lower..<upper].link = URL(string: address)
            }
        }
        return result
    }

    /// Opens a link from a message. A path is asked of the server first (`fs.stat`, which also expands `~/`): a
    /// folder opens in Files, a file opens in the workbench panel beside the chat, and ⌥ shows a file in Files instead.
    /// A path that is not there opens nothing. A web address opens in the browser tab of the panel; ⌘ opens it in
    /// the browser of the Mac instead.
    @MainActor
    static func open(_ url: URL, agentID: String, folder: String?, server: ServerModel, router: Router) {
        let flags = NSEvent.modifierFlags
        if let path = filePath(of: url) {
            let requested = ChatLinks.absolutePath(path, folder: folder)
            Task { @MainActor in
                guard let entry = try? await server.stat(requested) else { return }
                switch entry.kind {
                case .dir:
                    router.openInFiles(entry.path, isFile: false)
                case .file, .symlink:
                    if flags.contains(.option) {
                        router.openInFiles(entry.path, isFile: true)
                    } else {
                        router.showInWorkbench(.file(path: entry.path), agentID: agentID)
                    }
                case .other:
                    return
                }
            }
            return
        }
        guard url.scheme == "http" || url.scheme == "https" else { return }
        if flags.contains(.command) {
            NSWorkspace.shared.open(url)
            return
        }
        let model = BrowserStore.shared.model(for: server)
        model.addressText = url.absoluteString
        model.submitAddress()
        router.showInWorkbench(.browser, agentID: agentID)
    }
}
