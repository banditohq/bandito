import BanditoL10n
import Foundation

// The loopback redirect of the browser sign-in (RFC 8252 section 7.3, feature `oauth_loopback`). Many services refuse
// a custom scheme at registration, so the daemon registers `http://127.0.0.1:45819/callback` and the app listens on
// that address while the owner is in the browser. This file is the pure part: what a request means and what to answer.
// The socket itself is `BanditoUI/Market/OAuthLoopbackListener.swift`.

public enum OAuthLoopback {
    /// Fixed: the registration at the service names this exact address.
    public static let port: UInt16 = 45819
    public static let path = "/callback"
    /// A request longer than this is refused; a real callback is a few hundred bytes.
    public static let maxRequestBytes = 8 * 1024

    /// What one request means for the sign-in that waits.
    public enum Verdict: Equatable, Sendable {
        /// The head of the request has not all arrived yet.
        case incomplete
        /// The answer of the service, for the sign-in that waits.
        case callback(OAuthCallback)
        /// A callback with another state (a stale tab, or anybody on this Mac): 400, and the listener goes on.
        case wrongState
        /// Not `GET /callback`: 404.
        case notFound
        /// Too long, or not HTTP: 400 / 431.
        case badRequest
        case tooLarge
    }

    /// Decides what the bytes read so far are. Only the head is looked at (a callback has no body).
    public static func evaluate(_ data: Data, expectedState: String) -> Verdict {
        let end = Data("\r\n\r\n".utf8)
        guard let headEnd = data.range(of: end) else {
            return data.count > maxRequestBytes ? .tooLarge : .incomplete
        }
        if headEnd.upperBound > maxRequestBytes { return .tooLarge }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return .badRequest }
        let first = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .badRequest }
        guard parts[0] == "GET", let target = URLComponents(string: String(parts[1])), target.path == Self.path else {
            return .notFound
        }
        let items = target.queryItems ?? []
        func value(_ name: String, max: Int) -> String? {
            guard let text = items.first(where: { $0.name == name })?.value, !text.isEmpty, text.count <= max
            else { return nil }
            return text
        }
        let callback = OAuthCallback(
            state: value("state", max: 512), code: value("code", max: 4096), iss: value("iss", max: 2048),
            error: value("error", max: 64))
        // Constant time is not needed: the state is a one-time 256-bit value, and a wrong guess spends nothing.
        guard let state = callback.state, state == expectedState else { return .wrongState }
        return .callback(callback)
    }

    /// The full HTTP answer for a verdict, ready to write to the socket. `acceptLanguage` is the request's header.
    public static func response(for verdict: Verdict, acceptLanguage: String?) -> Data {
        switch verdict {
        case .callback(let callback):
            let ok = callback.error == nil && callback.code != nil
            return http(200, "OK", html: page(ok: ok, language: language(for: acceptLanguage)))
        case .wrongState, .badRequest:
            return http(400, "Bad Request", text: "Bad request")
        case .notFound:
            return http(404, "Not Found", text: "Not found")
        case .tooLarge:
            return http(431, "Request Header Fields Too Large", text: "Too large")
        case .incomplete:
            return http(400, "Bad Request", text: "Bad request")
        }
    }

    /// The `Accept-Language` header of a request head, if it has one.
    public static func acceptLanguage(in data: Data) -> String? {
        guard let text = String(data: data.prefix(maxRequestBytes), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "accept-language" {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - language

    /// The app language that fits an `Accept-Language` header best (by weight, then order); English when none does.
    public static func language(for header: String?) -> String {
        guard let header else { return "en" }
        let entries: [(tag: String, q: Double, order: Int)] = header.split(separator: ",").enumerated().compactMap {
            order, item in
            let pieces = item.split(separator: ";")
            guard let tag = pieces.first?.trimmingCharacters(in: .whitespaces), !tag.isEmpty else { return nil }
            var q = 1.0
            if pieces.count > 1, let weight = pieces[1].split(separator: "=").last, let value = Double(weight.trimmingCharacters(in: .whitespaces)) {
                q = value
            }
            return (tag, q, order)
        }
        for entry in entries.sorted(by: { ($0.q, -$0.order) > ($1.q, -$1.order) }) where entry.q > 0 {
            if let code = match(entry.tag) { return code }
        }
        return "en"
    }

    private static func match(_ tag: String) -> String? {
        let lower = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = lower.split(separator: "-").first.map(String.init) ?? lower
        switch base {
        case "en", "ru", "ja", "ko", "es", "de", "fr": return base
        case "pt": return "pt-BR"
        case "zh": return "zh-Hans"
        default: return nil
        }
    }

    /// One line in a given language (the generated resources hold all nine; the page follows the browser, not the app).
    static func text(_ key: String, language: String) -> String {
        let bundle = L10n.bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? L10n.bundle
        return bundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    // MARK: - HTTP

    private static func page(ok: Bool, language: String) -> String {
        let line = text(ok ? "integrations.oauth.loopback.done" : "integrations.oauth.loopback.failed", language: language)
        let mark = ok ? "&#10003;" : "!"
        let accent = ok ? "#6fcf97" : "#f2994a"
        return """
            <!doctype html><html lang="\(language)"><head><meta charset="utf-8">\
            <meta name="viewport" content="width=device-width,initial-scale=1"><title>Bandito</title>\
            <style>html,body{height:100%;margin:0}body{background:#14141a;color:#f2f1ee;\
            font:17px/1.5 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;display:flex;\
            align-items:center;justify-content:center;text-align:center}\
            main{max-width:420px;padding:32px}.m{width:56px;height:56px;border-radius:28px;margin:0 auto 20px;\
            background:\(accent)26;color:\(accent);font-size:28px;line-height:56px}\
            h1{font-size:20px;font-weight:600;margin:0}</style></head><body><main>\
            <div class="m">\(mark)</div><h1>\(line)</h1></main></body></html>
            """
    }

    private static func http(_ status: Int, _ reason: String, html: String) -> Data {
        build(status, reason, type: "text/html; charset=utf-8", body: html)
    }

    private static func http(_ status: Int, _ reason: String, text: String) -> Data {
        build(status, reason, type: "text/plain; charset=utf-8", body: text)
    }

    private static func build(_ status: Int, _ reason: String, type: String, body: String) -> Data {
        let bytes = Data(body.utf8)
        let head = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(type)",
            "Content-Length: \(bytes.count)",
            "Connection: close",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'",
            "", "",
        ].joined(separator: "\r\n")
        return Data(head.utf8) + bytes
    }
}
