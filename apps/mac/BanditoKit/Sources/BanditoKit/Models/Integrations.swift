import Foundation

// Wire model for `integrations.*` (docs/ARCHITECTURE.md#integrations): MCP servers the owner adds for the agents.
// Values in `env` and `headers` are literals or `secret:<NAME>` references; no RPC answer carries a secret's value.

public enum IntegrationKind: String, Codable, Sendable, CaseIterable {
    /// A program the daemon starts, which speaks MCP over its stdin and stdout.
    case stdio
    /// A server reached over streamable HTTP.
    case http
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

    public init(
        id: String, name: String, kind: IntegrationKind, command: String? = nil, args: [String] = [],
        url: String? = nil, env: [String: String] = [:], headers: [String: String] = [:],
        enabled: Bool = true, createdAt: Int64 = 0
    ) {
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
    public var docsUrl: String
    public var icon: String

    public init(
        id: String, name: String, descriptionEn: String, descriptionRu: String, kind: IntegrationKind,
        command: String? = nil, args: [String] = [], url: String? = nil, urlHint: String? = nil,
        headersKeys: [IntegrationHeaderKey] = [], docsUrl: String, icon: String
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
        self.docsUrl = docsUrl
        self.icon = icon
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
        docsUrl = try c.decode(String.self, forKey: .docsUrl)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
    }

    /// The description in the app's language: Russian for `ru`, English for every other language.
    public func description(languageCode: String) -> String {
        Self.isRussian(languageCode) ? descriptionRu : descriptionEn
    }

    static func isRussian(_ languageCode: String) -> Bool {
        languageCode.lowercased().hasPrefix("ru")
    }
}

/// The answer to `integrations.test`: the tools the server lists, or the last part of its stderr when it failed.
public struct IntegrationTest: Codable, Sendable, Hashable {
    public var ok: Bool
    public var tools: [String]
    public var error: String?

    public init(ok: Bool, tools: [String] = [], error: String? = nil) {
        self.ok = ok
        self.tools = tools
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try c.decode(Bool.self, forKey: .ok)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        error = try c.decodeIfPresent(String.self, forKey: .error)
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
