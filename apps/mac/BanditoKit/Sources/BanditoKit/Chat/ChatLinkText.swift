import Foundation

/// Makes the file paths and web addresses of a message into links, and opens them.
///
/// A file link carries its path as written (`bandito-file://open?path=…`), so the view can resolve it against the
/// agent's folder when it is clicked. A web link keeps its address.
public enum ChatLinkText {
    public static let fileScheme = "bandito-file"

    /// The link URL of a file path as written in the message.
    public static func fileURL(path: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = fileScheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: path)]
        return parts.url
    }

    /// The path a file link carries, or `nil` for any other URL.
    public static func filePath(of url: URL) -> String? {
        guard url.scheme == fileScheme,
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value,
            !value.isEmpty
        else { return nil }
        return value
    }

    /// The text with its links set. Links already in the text (Markdown links) are left as they are. The ranges
    /// come from the characters the person reads, so Markdown markers never shift them.
    public static func linked(_ text: AttributedString) -> AttributedString {
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
}
