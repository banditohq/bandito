import Foundation

// Preview URLs: `bandito-preview://p<port>/<path>` is what the web view loads. A scheme handler turns it into
// the server's HTTP proxy path, `<server>/v1/proxy/<port>/<path>`, and sends the device token itself, so the
// token never reaches the web view (docs/APP_SPEC.md, Browser).

public enum PreviewURL {
    public static let scheme = "bandito-preview"

    /// `bandito-preview://p<port>/<path>`, or nil for a port outside 1…65535.
    public static func previewURL(port: Int, path: String = "/") -> URL? {
        guard (1...65_535).contains(port) else { return nil }
        let tail = path.hasPrefix("/") ? path : "/" + path
        return URL(string: "\(scheme)://p\(port)\(tail)")
    }

    /// The HTTP proxy URL of a preview URL, on the server at `serverBase` (an `http(s)` URL).
    /// The query string is kept. Nil for another scheme, a host that is not `p<port>`, or a bad port.
    public static func proxyURL(for url: URL, serverBase: URL) -> URL? {
        guard url.scheme == scheme, let host = url.host, host.hasPrefix("p"),
              let port = Int(host.dropFirst()), (1...65_535).contains(port),
              var components = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)
        else { return nil }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tail = raw?.percentEncodedPath ?? ""
        components.percentEncodedPath = "/v1/proxy/\(port)" + (tail.isEmpty ? "/" : tail)
        components.percentEncodedQuery = raw?.percentEncodedQuery
        components.fragment = nil
        return components.url
    }

    /// The `http(s)` base of a server address: `ws` becomes `http` and `wss` becomes `https`; the path, query and
    /// fragment are dropped.
    public static func httpBase(for server: URL) -> URL? {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "ws", "http": components.scheme = "http"
        case "wss", "https": components.scheme = "https"
        default: return nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
