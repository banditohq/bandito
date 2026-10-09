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

    /// The daemon's proxy path and query for a preview URL: `/v1/proxy/<port><path>`, percent-encoded as the URL
    /// had it, and the query as it was. Nil for another scheme, a host that is not `p<port>`, or a bad port.
    public static func proxyParts(for url: URL) -> (path: String, query: String?)? {
        guard url.scheme == scheme, let host = url.host, host.hasPrefix("p"),
              let port = Int(host.dropFirst()), (1...65_535).contains(port)
        else { return nil }
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let tail = raw?.percentEncodedPath ?? ""
        return ("/v1/proxy/\(port)" + (tail.isEmpty ? "/" : tail), raw?.percentEncodedQuery)
    }

    /// The HTTP proxy URL of a preview URL, on the server at `serverBase` (an `http(s)` URL).
    /// The query string is kept. Nil where `proxyParts` is nil. The app itself asks the daemon through
    /// `ServerModel.daemonRequest(encodedPath:encodedQuery:)` instead.
    public static func proxyURL(for url: URL, serverBase: URL) -> URL? {
        guard let parts = proxyParts(for: url), var components = URLComponents(url: serverBase, resolvingAgainstBaseURL: false)
        else { return nil }
        components.percentEncodedPath = parts.path
        components.percentEncodedQuery = parts.query
        components.fragment = nil
        return components.url
    }
}
