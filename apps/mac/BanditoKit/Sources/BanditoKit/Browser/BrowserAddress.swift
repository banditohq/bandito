import Foundation

/// What the address bar opens for the text typed in it. Pure, so the rules are easy to read and test.
public enum BrowserAddress {
    public enum Outcome: Equatable, Sendable {
        /// Nothing typed: nothing to open.
        case nothing
        /// The URL to open.
        case open(String)
        /// A scheme the app does not open (`file:`, `javascript:`, `data:`, `mailto:`…). Nothing is opened.
        case refused
    }

    /// The outcome for `typed`.
    /// - A text that starts with a scheme (`name:`) opens only as `http://`, `https://` or `about:blank`; any other
    ///   scheme is refused. `host:port` (`localhost:3000`) is not a scheme.
    /// - Without a scheme, `localhost`, an IPv4 address and `host:port` get `http://`; a domain (a dot, no spaces) gets
    ///   `https://`; anything else is a Google search.
    public static func destination(for typed: String) -> Outcome {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .nothing }
        if hasScheme(text) { return schemeOutcome(text) }
        if text.contains(where: \.isWhitespace) { return .open(searchURL(for: text)) }
        if isLocalAddress(text) { return .open("http://" + text) }
        if text.contains(".") { return .open("https://" + text) }
        return .open(searchURL(for: text))
    }

    /// The Google search for `query`. Only the RFC 3986 unreserved characters stay as they are; every other
    /// character is percent-encoded, so `&`, `+`, `=` and spaces cannot change the query.
    public static func searchURL(for query: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: unreserved) ?? query
        return "https://www.google.com/search?q=" + encoded
    }

    /// `name:` at the start, except `host:port` (`localhost:3000`, `example.com:8080/x`), which is an address.
    static func hasScheme(_ text: String) -> Bool {
        guard text.firstMatch(of: #/^[a-zA-Z][a-zA-Z0-9+.-]*:/#) != nil else { return false }
        return !isHostPort(text)
    }

    private static func schemeOutcome(_ text: String) -> Outcome {
        let lower = text.lowercased()
        if lower == "about:blank" || lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return .open(text)
        }
        return .refused
    }

    /// `localhost`, an IPv4 address, or `host:port`, with an optional path, query or fragment.
    private static func isLocalAddress(_ text: String) -> Bool {
        text.wholeMatch(of: #/(?i)localhost([:/?#].*)?/#) != nil
            || text.wholeMatch(of: #/[0-9]{1,3}(\.[0-9]{1,3}){3}([:/?#].*)?/#) != nil
            || isHostPort(text)
    }

    /// `host:port` with a numeric port, optionally followed by a path, query or fragment.
    private static func isHostPort(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*:[0-9]+([/?#].*)?/#) != nil
    }
}
