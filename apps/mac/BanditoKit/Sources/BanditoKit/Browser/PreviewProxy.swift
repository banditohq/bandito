import Foundation

// What a preview web view asks the daemon for, and what it gets back (ServerModel+Daemon, PreviewURL).
// A web view serves one port only. The request headers and body go on, the credentials do not; the response
// goes back with its encoding and length left out, because the proxy hands the bytes over as the service sent them.

public enum PreviewProxy {
    /// The daemon's proxy path and query for `url`, when `url` is a route of `port`: the port the web view was
    /// opened for. Nil for another port, which the web view is answered with 404 for.
    public static func target(for url: URL, servingPort port: Int) -> (path: String, query: String?)? {
        guard PreviewURL.port(of: url) == port else { return nil }
        return PreviewURL.proxyParts(for: url)
    }

    /// Request headers that go on to the service: all but credentials, cookies, `Host`, and the hop-by-hop
    /// headers. `Accept-Encoding` is always `identity`.
    public static func forwardedHeaders(_ headers: [String: String]) -> [String: String] {
        var sent: [String: String] = [:]
        for (name, value) in headers where !dropped(name, from: requestDropped) {
            sent[name] = value
        }
        sent["Accept-Encoding"] = "identity"
        return sent
    }

    /// The body of a request, from `httpBody` or from `httpBodyStream` (WebKit gives a stream for a form post).
    public static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    /// Response headers that go back to the web view: all but the encoding and the length of the bytes as they
    /// were received, and the hop-by-hop headers.
    public static func responseHeaders(_ headers: [String: String]) -> [String: String] {
        headers.filter { !dropped($0.key, from: responseDropped) }
    }

    /// The session of one preview web view: no cache, and cookies of its own, shared with no other preview.
    public static func previewConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = HTTPCookieStorage()
        return configuration
    }

    private static let requestDropped: Set<String> = [
        "authorization", "cookie", "host", "content-length", "accept-encoding",
        "connection", "keep-alive", "proxy-authorization", "proxy-connection", "te", "trailer",
        "transfer-encoding", "upgrade",
    ]

    private static let responseDropped: Set<String> = [
        "content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive", "trailer", "upgrade",
    ]

    private static func dropped(_ name: String, from set: Set<String>) -> Bool {
        set.contains(name.lowercased())
    }
}

/// The session of the daemon's HTTP routes that the app calls (the browser tab list): no cache at all.
public enum DaemonHTTP {
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }
}
