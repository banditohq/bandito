import Foundation

// Shared bots and skills on bandito.dev (docs/ARCHITECTURE.md#sharing, the accounts API in docs/ACCOUNTS_API.md).
// The platform's wire is snake_case and is decoded with a plain `JSONDecoder`, so every key here is written out.

/// What a shared item is.
public enum ShareKind: String, Codable, Sendable, Hashable, CaseIterable {
    case bot
    case skill
}

/// Who can find a shared item. `everyone` is listed and indexed; `link` is reachable by its link only.
public enum ShareVisibility: String, Codable, Sendable, Hashable, CaseIterable {
    case everyone = "public"
    case link
}

/// The reasons a person can give when reporting a shared item (`POST /shares/:id/report`).
public enum ShareReportReason: String, Codable, Sendable, Hashable, CaseIterable {
    case spam
    case malicious
    case secrets
    case offensive
    case other
}

/// A shared item as the owner sees it in "My shares" (`GET /shares/mine`): every field but the payload.
public struct ShareSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ShareKind
    public var visibility: ShareVisibility
    public var title: String
    public var summary: String
    public var lang: String?
    public var version: Int
    public var installs: Int
    /// True when the platform hid the item after reports; the owner sees it, nobody else does.
    public var hidden: Bool
    public var createdAt: Int64
    public var updatedAt: Int64

    public init(
        id: String, kind: ShareKind, visibility: ShareVisibility, title: String, summary: String, lang: String?,
        version: Int, installs: Int, hidden: Bool, createdAt: Int64, updatedAt: Int64
    ) {
        self.id = id
        self.kind = kind
        self.visibility = visibility
        self.title = title
        self.summary = summary
        self.lang = lang
        self.version = version
        self.installs = installs
        self.hidden = hidden
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, visibility, title, summary, lang, version, installs, hidden
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ShareKind.self, forKey: .kind)
        visibility = try c.decode(ShareVisibility.self, forKey: .visibility)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        version = try c.decode(Int.self, forKey: .version)
        installs = try c.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
    }
}

/// The author of a shared item as a page shows it. A missing login or name is shown as "anonymous" by the UI.
public struct ShareAuthor: Codable, Sendable, Hashable {
    public var login: String?
    public var name: String?

    public init(login: String?, name: String?) {
        self.login = login
        self.name = name
    }
}

/// One shared item in full (`GET /shares/:id`, no sign-in needed): the summary, the author and the payload.
public struct SharedItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ShareKind
    public var visibility: ShareVisibility
    public var title: String
    public var summary: String
    public var lang: String?
    public var author: ShareAuthor
    public var version: Int
    public var installs: Int
    public var createdAt: Int64
    public var updatedAt: Int64
    /// The bot or skill itself (see `SharePayload`). Kept as JSON so it is installed exactly as it was published.
    public var payload: JSONValue

    public init(
        id: String, kind: ShareKind, visibility: ShareVisibility, title: String, summary: String, lang: String?,
        author: ShareAuthor, version: Int, installs: Int, createdAt: Int64, updatedAt: Int64, payload: JSONValue
    ) {
        self.id = id
        self.kind = kind
        self.visibility = visibility
        self.title = title
        self.summary = summary
        self.lang = lang
        self.author = author
        self.version = version
        self.installs = installs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, visibility, title, summary, lang, author, version, installs, payload
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(ShareKind.self, forKey: .kind)
        visibility = try c.decode(ShareVisibility.self, forKey: .visibility)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
        author = try c.decodeIfPresent(ShareAuthor.self, forKey: .author) ?? ShareAuthor(login: nil, name: nil)
        version = try c.decode(Int.self, forKey: .version)
        installs = try c.decodeIfPresent(Int.self, forKey: .installs) ?? 0
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        payload = try c.decode(JSONValue.self, forKey: .payload)
    }
}

/// What `POST /shares` takes. `payload` is the daemon's export, passed on as it is.
public struct ShareDraft: Encodable, Sendable {
    public var kind: ShareKind
    public var visibility: ShareVisibility
    public var lang: String
    public var title: String
    public var summary: String
    public var payload: JSONValue

    public init(
        kind: ShareKind, visibility: ShareVisibility, lang: String, title: String, summary: String, payload: JSONValue
    ) {
        self.kind = kind
        self.visibility = visibility
        self.lang = lang
        self.title = title
        self.summary = summary
        self.payload = payload
    }
}

/// What `PATCH /shares/:id` takes. A nil field is left out of the request, so it stays as it is on the platform.
public struct ShareUpdate: Encodable, Sendable {
    public var visibility: ShareVisibility?
    public var title: String?
    public var summary: String?
    public var payload: JSONValue?

    public init(
        visibility: ShareVisibility? = nil, title: String? = nil, summary: String? = nil, payload: JSONValue? = nil
    ) {
        self.visibility = visibility
        self.title = title
        self.summary = summary
        self.payload = payload
    }
}

/// The answer to `POST /shares`: the new id and the page's address (`https://bandito.dev/s/<id>`).
public struct ShareCreated: Decodable, Sendable, Hashable {
    public var id: String
    public var url: String

    public init(id: String, url: String) {
        self.id = id
        self.url = url
    }
}

/// A platform refusal or a failed call to the sharing API. `looksLikeSecret` names the field that holds the key; the
/// UI says which field to clean up. Everything else maps to one short text.
public enum ShareFailure: Error, Sendable, Equatable {
    /// `422 looks_like_secret`: a key or token was found in `field` (a payload path, `title` or `summary`).
    case looksLikeSecret(field: String)
    /// `429 rate`: too many shares in a day for this account.
    case rate
    /// `409 too_many`: the account already has the maximum number of shares.
    case tooMany
    /// `410 hidden`: the item was hidden after reports.
    case hidden
    /// `404 not_found`: no such item, or it is not this account's (for changes).
    case notFound
    /// `401 unauthorized`: sign in again.
    case unauthorized
    /// `400`/`422 invalid`: the platform refused the shape of the request.
    case invalid
    /// Any other error code the app does not know yet.
    case api(code: String, status: Int)
    /// The request got no answer (offline, TLS, timeout).
    case network(String)
    /// An answer that does not match the contract.
    case badResponse

    /// The failure of an `ok: false` answer: its `error` code, and the `field` of a secret refusal. A code the app
    /// does not know becomes `api`.
    static func from(code: String, status: Int, field: String?) -> ShareFailure {
        switch code {
        case "looks_like_secret": return .looksLikeSecret(field: field ?? "")
        case "rate": return .rate
        case "too_many": return .tooMany
        case "hidden": return .hidden
        case "not_found": return .notFound
        case "unauthorized": return .unauthorized
        case "invalid": return .invalid
        default: return .api(code: code, status: status)
        }
    }

    /// For an answer without a known code: the HTTP status decides.
    static func from(status: Int) -> ShareFailure {
        switch status {
        case 401: return .unauthorized
        case 404: return .notFound
        case 410: return .hidden
        case 429: return .rate
        default: return .api(code: "http_\(status)", status: status)
        }
    }
}

/// The `ok: false` body of a sharing answer, with the `field` of a secret refusal.
struct ShareFailureBody: Decodable {
    var ok: Bool?
    var error: String?
    var field: String?
}

/// The id of a shared item: 22 characters of base62, about 131 random bits. Anything else is not an id: a link or a
/// `bandito://` URL with another shape is ignored, and nothing is sent with it.
public enum ShareID {
    public static let length = 22

    public static func isValid(_ id: String) -> Bool {
        id.utf8.count == length && id.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }
    }
}
