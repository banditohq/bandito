import Foundation

// The agent bundles of the daemon: a named set of templates made in one go (`agents.bundles`,
// `agents.create_bundle`; docs/ARCHITECTURE.md#agent-bundles). Feature `agent_bundles`.

/// The texts of one bundle in a language other than English and Russian.
public struct BundleTranslation: Decodable, Sendable, Hashable {
    public var name: String
    public var description: String

    public init(name: String = "", description: String = "") {
        self.name = name
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
    }
}

/// One entry of `agents.bundles`: a set of 3 to 5 templates, with the names and descriptions in each language.
public struct AgentBundle: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var nameEn: String
    public var nameRu: String
    public var descriptionEn: String
    public var descriptionRu: String
    /// The other seven languages, by tag (`de`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `zh-Hans`).
    public var l10n: [String: BundleTranslation]
    /// An SF Symbol.
    public var icon: String
    /// The tile colour as `#RRGGBB`.
    public var accent: String?
    /// The template ids of the set, in the order the daemon makes them.
    public var templates: [String]
    /// `dev`, `ops`, `research`, `writing`, `business` or `personal`: the categories of the bots.
    public var category: String

    public init(
        id: String, nameEn: String, nameRu: String, descriptionEn: String = "", descriptionRu: String = "",
        l10n: [String: BundleTranslation] = [:], icon: String = "square.stack.3d.up", accent: String? = nil,
        templates: [String] = [], category: String = "personal"
    ) {
        self.id = id
        self.nameEn = nameEn
        self.nameRu = nameRu
        self.descriptionEn = descriptionEn
        self.descriptionRu = descriptionRu
        self.l10n = l10n
        self.icon = icon
        self.accent = accent
        self.templates = templates
        self.category = category
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        nameEn = try c.decode(String.self, forKey: .nameEn)
        nameRu = try c.decodeIfPresent(String.self, forKey: .nameRu) ?? nameEn
        descriptionEn = try c.decodeIfPresent(String.self, forKey: .descriptionEn) ?? ""
        descriptionRu = try c.decodeIfPresent(String.self, forKey: .descriptionRu) ?? descriptionEn
        // A malformed translation drops the whole set: the bundle then reads in English, and the list still shows.
        l10n = (try? c.decodeIfPresent([String: BundleTranslation].self, forKey: .l10n)).flatMap { $0 } ?? [:]
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "square.stack.3d.up"
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        templates = try c.decodeIfPresent([String].self, forKey: .templates) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "personal"
    }

    private enum CodingKeys: String, CodingKey {
        case id, nameEn, nameRu, descriptionEn, descriptionRu, l10n, icon, accent, templates, category
    }

    private func translation(_ languageCode: String) -> BundleTranslation? {
        CatalogLanguage.translationKey(in: l10n.keys, languageCode: languageCode).flatMap { l10n[$0] }
    }

    /// The name in the app's language: Russian for `ru`, a translation, else English.
    public func name(languageCode: String) -> String {
        if CatalogLanguage.isRussian(languageCode) { return nameRu.isEmpty ? nameEn : nameRu }
        if let text = translation(languageCode)?.name, !text.isEmpty { return text }
        return nameEn
    }

    /// The description in the app's language: Russian for `ru`, a translation, else English.
    public func description(languageCode: String) -> String {
        if CatalogLanguage.isRussian(languageCode) { return descriptionRu.isEmpty ? descriptionEn : descriptionRu }
        if let text = translation(languageCode)?.description, !text.isEmpty { return text }
        return descriptionEn
    }
}

/// One template of a bundle as the daemon made it: the agent, or the reason it was not made. A made agent with an
/// `error` means a step after the agent failed (a skill, a schedule); the agent exists.
public struct BundleEntry: Decodable, Sendable {
    public var templateId: String
    public var agent: Agent?
    public var error: String?

    public init(templateId: String, agent: Agent? = nil, error: String? = nil) {
        self.templateId = templateId
        self.agent = agent
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateId = try c.decode(String.self, forKey: .templateId)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case templateId, agent, error
    }
}

/// The answer of `agents.create_bundle`: one entry per template, in the bundle's order, and the integrations the set
/// lists that are not connected (each once; `required` when any template needs it).
public struct BundleCreation: Decodable, Sendable {
    public var agents: [BundleEntry]
    public var missingIntegrations: [MissingIntegration]

    public init(agents: [BundleEntry] = [], missingIntegrations: [MissingIntegration] = []) {
        self.agents = agents
        self.missingIntegrations = missingIntegrations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agents = try c.decodeIfPresent([BundleEntry].self, forKey: .agents) ?? []
        missingIntegrations = try c.decodeIfPresent([MissingIntegration].self, forKey: .missingIntegrations) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case agents, missingIntegrations
    }
}

/// The body of `agents.create_bundle`. `runtime` nil keeps each template's runtime; `workspaceId` nil is the shared one.
/// `templates` nil makes every template of the set; a list makes only those (a retry makes the ones still missing).
public struct NewBundle: Encodable, Sendable, Equatable {
    public var bundleId: String
    /// The app's language as the daemon keys it (`CatalogLanguage.requestCode`).
    public var language: String
    public var runtime: String?
    public var workspaceId: String?
    public var templates: [String]?

    public init(
        bundleId: String, language: String, runtime: String? = nil, workspaceId: String? = nil,
        templates: [String]? = nil
    ) {
        self.bundleId = bundleId
        self.language = language
        self.runtime = runtime
        self.workspaceId = workspaceId
        self.templates = templates
    }
}
