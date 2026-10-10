import Foundation

// Wire model for `integrations.*` (docs/ARCHITECTURE.md#integrations): MCP servers the owner adds for the agents.
// Values in `env` and `headers` are literals or `secret:<NAME>` references; no RPC answer carries a secret's value.

public enum IntegrationKind: String, Codable, Sendable, CaseIterable {
    /// A program the daemon starts, which speaks MCP over its stdin and stdout.
    case stdio
    /// A server reached over streamable HTTP.
    case http
}

/// How an integration signs in (`auth` on the wire): `oauth` is a sign-in in the browser, whose tokens only the
/// daemon holds (docs/ARCHITECTURE.md#integrations).
public enum IntegrationAuth: String, Codable, Sendable {
    case none
    case oauth
}

/// The catalog template of an integration is ahead of it (`template_update` of `integrations.list`, feature
/// `template_updates`). `from` and `to` are the versions of a pinned package; both are nil when the template's address
/// moved, since an address has no version.
public struct TemplateUpdate: Codable, Sendable, Hashable {
    public var from: String?
    public var to: String?

    public init(from: String? = nil, to: String? = nil) {
        self.from = from
        self.to = to
    }

    /// The address moved: there are no versions to show.
    public var isNewAddress: Bool {
        (from ?? "").isEmpty && (to ?? "").isEmpty
    }
}

public struct Integration: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: IntegrationKind
    public var command: String?
    public var args: [String]
    public var url: String?
    public var env: [String: String]
    public var headers: [String: String]
    public var enabled: Bool
    /// Unix milliseconds.
    public var createdAt: Int64
    /// `oauth` when the owner signed in in the browser; an older daemon has no field, which reads as `none`.
    public var auth: IntegrationAuth
    /// Set when the template this integration came from has moved on; `update_from_template` brings it up to date.
    public var templateUpdate: TemplateUpdate?

    public init(
        id: String, name: String, kind: IntegrationKind, command: String? = nil, args: [String] = [],
        url: String? = nil, env: [String: String] = [:], headers: [String: String] = [:],
        enabled: Bool = true, createdAt: Int64 = 0, auth: IntegrationAuth = .none,
        templateUpdate: TemplateUpdate? = nil
    ) {
        self.templateUpdate = templateUpdate
        self.id = id
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.url = url
        self.env = env
        self.headers = headers
        self.enabled = enabled
        self.createdAt = createdAt
        self.auth = auth
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(IntegrationKind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
        // A value this app does not know is read as `none`: the row still lists.
        auth = (try? c.decodeIfPresent(IntegrationAuth.self, forKey: .auth)).flatMap { $0 } ?? .none
        templateUpdate = (try? c.decodeIfPresent(TemplateUpdate.self, forKey: .templateUpdate)).flatMap { $0 }
    }
}

/// A header the catalog asks for: its wire key, its labels, and how its value is built from a secret.
public struct IntegrationHeaderKey: Codable, Sendable, Hashable {
    public var key: String
    public var labelEn: String
    public var labelRu: String
    /// True when the value is a secret the owner types in (the app stores it as a server secret).
    public var secret: Bool
    /// The value with `{secret}` where the secret's reference goes, for example `Bearer {secret}`.
    public var valueTemplate: String

    public init(key: String, labelEn: String, labelRu: String, secret: Bool, valueTemplate: String) {
        self.key = key
        self.labelEn = labelEn
        self.labelRu = labelRu
        self.secret = secret
        self.valueTemplate = valueTemplate
    }

    public func label(languageCode: String) -> String {
        IntegrationCatalogEntry.isRussian(languageCode) ? labelRu : labelEn
    }
}

/// The texts of one template in another app language, from `l10n` on the wire. A field the daemon left out reads as
/// empty, and the app then falls back to English.
public struct IntegrationTranslation: Codable, Sendable, Hashable {
    public var description: String
    public var long: String
    public var abilities: [String]
    public var needs: String
    /// The label of each header or env key, by the key's name.
    public var labels: [String: String]

    public init(description: String, long: String, abilities: [String], needs: String, labels: [String: String] = [:]) {
        self.description = description
        self.long = long
        self.abilities = abilities
        self.needs = needs
        self.labels = labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        long = try c.decodeIfPresent(String.self, forKey: .long) ?? ""
        abilities = try c.decodeIfPresent([String].self, forKey: .abilities) ?? []
        needs = try c.decodeIfPresent(String.self, forKey: .needs) ?? ""
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }
}

/// One template from `integrations.catalog`, shown in the "Каталог" grid.
public struct IntegrationCatalogEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var descriptionEn: String
    public var descriptionRu: String
    public var kind: IntegrationKind
    public var command: String?
    public var args: [String]
    public var url: String?
    /// A pattern to fill in by hand when the url has placeholders, for example `https://…/mcp/<SERVER_ID>`.
    public var urlHint: String?
    public var headersKeys: [IntegrationHeaderKey]
    /// The environment variables a program asks for (a stdio template), like the headers of a web one.
    public var envKeys: [IntegrationHeaderKey]
    public var docsUrl: String
    public var icon: String
    /// The group of the sidebar: `dev`, `productivity`, `data`, `web`, `design` or `other`. Nil for an older daemon.
    public var category: String?
    /// The brand color as `#RRGGBB`, for the tile. Nil for an older daemon.
    public var accent: String?
    public var publisher: String?
    /// The maker's own server, or a reference server of the MCP project.
    public var official: Bool
    public var homepage: String?
    public var longEn: String?
    public var longRu: String?
    public var abilitiesEn: [String]
    public var abilitiesRu: [String]
    public var needsEn: String?
    public var needsRu: String?
    /// `oauth` for a service that signs in in the browser; nil (or `none`) for one that takes a key.
    public var auth: IntegrationAuth
    /// The texts for the other app languages, by language code (`pt-BR`, `zh-Hans`, …). Empty for an older daemon.
    public var l10n: [String: IntegrationTranslation]

    /// Whether Connect starts a sign-in in the browser instead of opening the sheet of keys.
    public var usesOAuth: Bool { auth == .oauth }

    public init(
        id: String, name: String, descriptionEn: String, descriptionRu: String, kind: IntegrationKind,
        command: String? = nil, args: [String] = [], url: String? = nil, urlHint: String? = nil,
        headersKeys: [IntegrationHeaderKey] = [], envKeys: [IntegrationHeaderKey] = [], docsUrl: String, icon: String,
        category: String? = nil, accent: String? = nil, publisher: String? = nil, official: Bool = false, homepage: String? = nil,
        longEn: String? = nil, longRu: String? = nil, abilitiesEn: [String] = [], abilitiesRu: [String] = [],
        needsEn: String? = nil, needsRu: String? = nil, auth: IntegrationAuth = .none,
        l10n: [String: IntegrationTranslation] = [:]
    ) {
        self.id = id
        self.name = name
        self.descriptionEn = descriptionEn
        self.descriptionRu = descriptionRu
        self.kind = kind
        self.command = command
        self.args = args
        self.url = url
        self.urlHint = urlHint
        self.headersKeys = headersKeys
        self.envKeys = envKeys
        self.docsUrl = docsUrl
        self.icon = icon
        self.category = category
        self.accent = accent
        self.publisher = publisher
        self.official = official
        self.homepage = homepage
        self.longEn = longEn
        self.longRu = longRu
        self.abilitiesEn = abilitiesEn
        self.abilitiesRu = abilitiesRu
        self.needsEn = needsEn
        self.needsRu = needsRu
        self.auth = auth
        self.l10n = l10n
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        descriptionEn = try c.decode(String.self, forKey: .descriptionEn)
        descriptionRu = try c.decode(String.self, forKey: .descriptionRu)
        kind = try c.decode(IntegrationKind.self, forKey: .kind)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        url = try c.decodeIfPresent(String.self, forKey: .url)
        urlHint = try c.decodeIfPresent(String.self, forKey: .urlHint)
        headersKeys = try c.decodeIfPresent([IntegrationHeaderKey].self, forKey: .headersKeys) ?? []
        envKeys = try c.decodeIfPresent([IntegrationHeaderKey].self, forKey: .envKeys) ?? []
        docsUrl = try c.decode(String.self, forKey: .docsUrl)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category)
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        official = try c.decodeIfPresent(Bool.self, forKey: .official) ?? false
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        longEn = try c.decodeIfPresent(String.self, forKey: .longEn)
        longRu = try c.decodeIfPresent(String.self, forKey: .longRu)
        abilitiesEn = try c.decodeIfPresent([String].self, forKey: .abilitiesEn) ?? []
        abilitiesRu = try c.decodeIfPresent([String].self, forKey: .abilitiesRu) ?? []
        needsEn = try c.decodeIfPresent(String.self, forKey: .needsEn)
        needsRu = try c.decodeIfPresent(String.self, forKey: .needsRu)
        auth = (try? c.decodeIfPresent(IntegrationAuth.self, forKey: .auth)).flatMap { $0 } ?? .none
        // A malformed translation drops the whole set: the template then reads in English, and the catalog still lists.
        l10n = (try? c.decodeIfPresent([String: IntegrationTranslation].self, forKey: .l10n)).flatMap { $0 } ?? [:]
    }

    /// The translation to show in `languageCode`, from `l10n`. Nil for Russian and English, which have their own
    /// fields, and for a language with no translation: the accessors then use those fields.
    func translation(languageCode: String) -> IntegrationTranslation? {
        if Self.isRussian(languageCode) { return nil }
        let wanted = Self.normalizedLanguage(languageCode)
        guard let key = l10n.keys.first(where: { Self.normalizedLanguage($0) == wanted }) else { return nil }
        return l10n[key]
    }

    /// The description in the app's language: a translation, else Russian for `ru`, else English.
    public func description(languageCode: String) -> String {
        if let text = translation(languageCode: languageCode)?.description, !text.isEmpty { return text }
        return Self.isRussian(languageCode) ? descriptionRu : descriptionEn
    }

    /// The longer text of the detail page; the short description when the daemon has none.
    public func longDescription(languageCode: String) -> String {
        if let text = translation(languageCode: languageCode)?.long, !text.isEmpty { return text }
        let text = Self.isRussian(languageCode) ? longRu : longEn
        return text ?? description(languageCode: languageCode)
    }

    /// The short points of what the service can do.
    public func abilities(languageCode: String) -> [String] {
        if let points = translation(languageCode: languageCode)?.abilities, !points.isEmpty { return points }
        return Self.isRussian(languageCode) ? abilitiesRu : abilitiesEn
    }

    /// What the owner needs before connecting: a key, an account, a program.
    public func needs(languageCode: String) -> String? {
        if let text = translation(languageCode: languageCode)?.needs, !text.isEmpty { return text }
        return Self.isRussian(languageCode) ? needsRu : needsEn
    }

    /// The label of a header or env key in the app's language: the translation's label, else the built-in one.
    public func label(for key: IntegrationHeaderKey, languageCode: String) -> String {
        if let text = translation(languageCode: languageCode)?.labels[key.key], !text.isEmpty { return text }
        return key.label(languageCode: languageCode)
    }

    static func isRussian(_ languageCode: String) -> Bool {
        languageCode.lowercased().hasPrefix("ru")
    }

    /// A language code as the catalog keys it: `pt_BR` and `pt-br` are `pt-br`.
    static func normalizedLanguage(_ languageCode: String) -> String {
        languageCode.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}

/// The answer to `integrations.test`: the tools the server lists, or the last part of its stderr when it failed.
public struct IntegrationTest: Codable, Sendable, Hashable {
    public var ok: Bool
    public var tools: [String]
    public var error: String?
    /// The service refused the browser sign-in and it could not be renewed: the owner signs in again.
    public var needsLogin: Bool

    public init(ok: Bool, tools: [String] = [], error: String? = nil, needsLogin: Bool = false) {
        self.ok = ok
        self.tools = tools
        self.error = error
        self.needsLogin = needsLogin
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
        needsLogin = try c.decodeIfPresent(Bool.self, forKey: .needsLogin) ?? false
    }
}

/// The body of `integrations.add`. Optional fields are left out of the request when `nil` or empty.
public struct NewIntegration: Encodable, Sendable, Equatable {
    public var name: String
    public var kind: IntegrationKind
    public var command: String?
    public var args: [String]
    public var url: String?
    public var env: [String: String]
    public var headers: [String: String]
    public var enabled: Bool

    public init(
        name: String, kind: IntegrationKind, command: String? = nil, args: [String] = [], url: String? = nil,
        env: [String: String] = [:], headers: [String: String] = [:], enabled: Bool = true
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.url = url
        self.env = env
        self.headers = headers
        self.enabled = enabled
    }

    enum CodingKeys: String, CodingKey { case name, kind, command, args, url, env, headers, enabled }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(command, forKey: .command)
        if !args.isEmpty { try c.encode(args, forKey: .args) }
        try c.encodeIfPresent(url, forKey: .url)
        if !env.isEmpty { try c.encode(env, forKey: .env) }
        if !headers.isEmpty { try c.encode(headers, forKey: .headers) }
        try c.encode(enabled, forKey: .enabled)
    }
}

/// The fields of `integrations.update`. A `nil` field is not sent. `.clear` sends `null`, which clears `command`
/// or `url`.
public struct IntegrationPatch: Encodable, Sendable {
    public var name: String?
    public var kind: IntegrationKind?
    public var command: FieldChange<String>?
    public var args: [String]?
    public var url: FieldChange<String>?
    public var env: [String: String]?
    public var headers: [String: String]?
    public var enabled: Bool?

    public init(
        name: String? = nil, kind: IntegrationKind? = nil, command: FieldChange<String>? = nil,
        args: [String]? = nil, url: FieldChange<String>? = nil, env: [String: String]? = nil,
        headers: [String: String]? = nil, enabled: Bool? = nil
    ) {
        self.name = name
        self.kind = kind
        self.command = command
        self.args = args
        self.url = url
        self.env = env
        self.headers = headers
        self.enabled = enabled
    }

    /// Keys on the wire. `id` is not a patch field: the request that carries a patch adds it.
    public enum Key: String, CodingKey {
        case id, name, kind, command, args, url, env, headers, enabled
    }

    /// Writes the set fields into an object that may also hold `id`.
    public func encodeFields(into c: inout KeyedEncodingContainer<Key>) throws {
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(kind, forKey: .kind)
        try Self.encodeChange(command, forKey: .command, into: &c)
        try c.encodeIfPresent(args, forKey: .args)
        try Self.encodeChange(url, forKey: .url, into: &c)
        try c.encodeIfPresent(env, forKey: .env)
        try c.encodeIfPresent(headers, forKey: .headers)
        try c.encodeIfPresent(enabled, forKey: .enabled)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try encodeFields(into: &c)
    }

    private static func encodeChange(
        _ change: FieldChange<String>?, forKey key: Key, into c: inout KeyedEncodingContainer<Key>
    ) throws {
        switch change {
        case nil: break
        case .set(let value)?: try c.encode(value, forKey: key)
        case .clear?: try c.encodeNil(forKey: key)
        }
    }
}
