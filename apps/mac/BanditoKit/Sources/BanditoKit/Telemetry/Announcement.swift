import Foundation

/// A message from the Bandito team, from the pulse reply. The texts are already in the language of the pulse.
/// `banner` is a strip at the top of the main window; `system` is also a macOS notification when that is allowed.
public struct Announcement: Equatable, Identifiable, Sendable, Decodable {
    public enum Level: String, Equatable, Sendable, Decodable {
        case banner, system
    }

    public var id: String
    public var title: String
    public var body: String
    /// The link of the button. Only `https` survives; any other link is dropped and the announcement stays.
    public var url: URL?
    /// The text of the button that opens `url`.
    public var button: String?
    public var level: Level
    public var expiresAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, title, body, url, button, level, expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        level = try container.decode(Level.self, forKey: .level)
        let expires = try container.decode(String.self, forKey: .expiresAt)
        guard let date = Self.parseDate(expires) else {
            throw DecodingError.dataCorruptedError(
                forKey: .expiresAt, in: container, debugDescription: "expires_at is not an ISO 8601 date")
        }
        expiresAt = date
        let link = try container.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
        url = link?.scheme?.lowercased() == "https" ? link : nil
        let label = try container.decodeIfPresent(String.self, forKey: .button)
        button = label?.isEmpty == false ? label : nil
    }

    /// The announcements of a pulse reply, or nil when the reply says `ok: false` or is not a pulse reply at all. An
    /// announcement that does not decode (a missing field, an unknown level, a bad date) is skipped alone.
    static func pulseList(from data: Data) -> [Announcement]? {
        struct Reply: Decodable {
            var ok: Bool
            var announcements: LossyList<Announcement>?
        }
        guard let reply = try? TelemetryWire.decoder.decode(Reply.self, from: data), reply.ok else { return nil }
        return reply.announcements?.items ?? []
    }

    /// ISO 8601, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// Decodes an array and keeps the elements that decode. A bad element is read past and dropped.
struct LossyList<Element: Decodable>: Decodable {
    let items: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [Element] = []
        while !container.isAtEnd {
            if let item = try? container.decode(Element.self) {
                items.append(item)
            } else {
                _ = try container.decode(JSONValue.self)
            }
        }
        self.items = items
    }
}

/// Which announcement to show next. Each one is shown once, and an expired one is never shown.
public enum AnnouncementRules {
    /// The first announcement in the server's order that is not expired at `now` and not shown yet.
    public static func next(_ list: [Announcement], isShown: (String) -> Bool, now: Date) -> Announcement? {
        list.first { $0.expiresAt > now && !isShown($0.id) }
    }
}
