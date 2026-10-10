import Foundation

// The bot templates of the daemon (`agents.templates`, `agents.create_from_template`;
// docs/ARCHITECTURE.md#agent-templates). Feature `agent_templates`.

/// The texts of one template in a language other than English and Russian.
public struct BotTemplateTranslation: Decodable, Sendable, Hashable {
    public var name: String
    public var description: String
    public var long: String
    public var starter: String
    /// One prompt per schedule of the template, in its order.
    public var schedulePrompts: [String]

    public init(name: String = "", description: String = "", long: String = "", starter: String = "", schedulePrompts: [String] = []) {
        self.name = name
        self.description = description
        self.long = long
        self.starter = starter
        self.schedulePrompts = schedulePrompts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        long = try c.decodeIfPresent(String.self, forKey: .long) ?? ""
        starter = try c.decodeIfPresent(String.self, forKey: .starter) ?? ""
        schedulePrompts = try c.decodeIfPresent([String].self, forKey: .schedulePrompts) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, description, long, starter, schedulePrompts
    }
}

/// A service the template uses: an id of the integrations catalog, and whether the bot cannot do its job without it.
public struct BotIntegration: Decodable, Sendable, Hashable {
    public var id: String
    public var required: Bool

    public init(id: String, required: Bool) {
        self.id = id
        self.required = required
    }
}

/// A run the template offers to schedule.
public struct BotSchedule: Decodable, Sendable, Hashable {
    public var cron: String
    public var promptEn: String
    public var promptRu: String
    /// Whether the create sheet ticks it at first.
    public var enabledByDefault: Bool

    public init(cron: String, promptEn: String = "", promptRu: String = "", enabledByDefault: Bool = false) {
        self.cron = cron
        self.promptEn = promptEn
        self.promptRu = promptRu
        self.enabledByDefault = enabledByDefault
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cron = try c.decode(String.self, forKey: .cron)
        promptEn = try c.decodeIfPresent(String.self, forKey: .promptEn) ?? ""
        promptRu = try c.decodeIfPresent(String.self, forKey: .promptRu) ?? ""
        enabledByDefault = try c.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case cron, promptEn, promptRu, enabledByDefault
    }
}

/// One entry of `agents.templates`. The system prompt of the entry stays on the server; the app does not need it.
public struct BotTemplate: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var nameEn: String
    public var nameRu: String
    public var descriptionEn: String
    public var descriptionRu: String
    public var longEn: String
    public var longRu: String
    public var starterEn: String
    public var starterRu: String
    /// The other seven languages, by tag (`de`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `zh-Hans`).
    public var l10n: [String: BotTemplateTranslation]
    /// `dev`, `ops`, `research`, `writing`, `business` or `personal`.
    public var category: String
    /// An SF Symbol.
    public var icon: String
    /// The tile colour as `#RRGGBB`.
    public var accent: String?
    public var roleEn: String
    /// The runtime the template wants, as the daemon names it.
    public var runtime: String
    public var integrations: [BotIntegration]
    /// Ids of the skills catalog.
    public var skills: [String]
    public var schedules: [BotSchedule]

    public init(
        id: String, nameEn: String, nameRu: String, descriptionEn: String = "", descriptionRu: String = "",
        longEn: String = "", longRu: String = "", starterEn: String = "", starterRu: String = "",
        l10n: [String: BotTemplateTranslation] = [:], category: String = "personal", icon: String = "sparkles",
        accent: String? = nil, roleEn: String = "", runtime: String = "claude", integrations: [BotIntegration] = [],
        skills: [String] = [], schedules: [BotSchedule] = []
    ) {
        self.id = id
        self.nameEn = nameEn
        self.nameRu = nameRu
        self.descriptionEn = descriptionEn
        self.descriptionRu = descriptionRu
        self.longEn = longEn
        self.longRu = longRu
        self.starterEn = starterEn
        self.starterRu = starterRu
        self.l10n = l10n
        self.category = category
        self.icon = icon
        self.accent = accent
        self.roleEn = roleEn
        self.runtime = runtime
        self.integrations = integrations
        self.skills = skills
        self.schedules = schedules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        nameEn = try c.decode(String.self, forKey: .nameEn)
        nameRu = try c.decodeIfPresent(String.self, forKey: .nameRu) ?? nameEn
        descriptionEn = try c.decodeIfPresent(String.self, forKey: .descriptionEn) ?? ""
        descriptionRu = try c.decodeIfPresent(String.self, forKey: .descriptionRu) ?? descriptionEn
        longEn = try c.decodeIfPresent(String.self, forKey: .longEn) ?? ""
        longRu = try c.decodeIfPresent(String.self, forKey: .longRu) ?? longEn
        starterEn = try c.decodeIfPresent(String.self, forKey: .starterEn) ?? ""
        starterRu = try c.decodeIfPresent(String.self, forKey: .starterRu) ?? starterEn
        // A malformed translation drops the whole set: the template then reads in English, and the catalog still lists.
        l10n = (try? c.decodeIfPresent([String: BotTemplateTranslation].self, forKey: .l10n)).flatMap { $0 } ?? [:]
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "personal"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "sparkles"
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        roleEn = try c.decodeIfPresent(String.self, forKey: .roleEn) ?? ""
        runtime = try c.decodeIfPresent(String.self, forKey: .runtime) ?? "claude"
        integrations = try c.decodeIfPresent([BotIntegration].self, forKey: .integrations) ?? []
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        schedules = try c.decodeIfPresent([BotSchedule].self, forKey: .schedules) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, nameEn, nameRu, descriptionEn, descriptionRu, longEn, longRu, starterEn, starterRu, l10n
        case category, icon, accent, roleEn, runtime, integrations, skills, schedules
    }

    private func translation(_ languageCode: String) -> BotTemplateTranslation? {
        CatalogLanguage.translationKey(in: l10n.keys, languageCode: languageCode).flatMap { l10n[$0] }
    }

    private func pick(_ languageCode: String, ru: String, en: String, other: KeyPath<BotTemplateTranslation, String>) -> String {
        if CatalogLanguage.isRussian(languageCode) { return ru.isEmpty ? en : ru }
        if let text = translation(languageCode)?[keyPath: other], !text.isEmpty { return text }
        return en
    }

    /// The name in the app's language: Russian for `ru`, a translation, else English.
    public func name(languageCode: String) -> String {
        pick(languageCode, ru: nameRu, en: nameEn, other: \.name)
    }

    public func description(languageCode: String) -> String {
        pick(languageCode, ru: descriptionRu, en: descriptionEn, other: \.description)
    }

    /// The longer text of the template's page; the short description when there is none.
    public func long(languageCode: String) -> String {
        let text = pick(languageCode, ru: longRu, en: longEn, other: \.long)
        return text.isEmpty ? description(languageCode: languageCode) : text
    }

    /// The first message of the bot, for the input field of the new agent.
    public func starter(languageCode: String) -> String {
        pick(languageCode, ru: starterRu, en: starterEn, other: \.starter)
    }

    /// The names a search matches: the name in the app's language, and the English one.
    public func searchNames(languageCode: String) -> [String] {
        let local = name(languageCode: languageCode)
        return local == nameEn ? [nameEn] : [local, nameEn]
    }

    /// The runtime of the template as the app knows it; nil for a name this app does not know.
    public var runtimeKind: RuntimeKind? {
        RuntimeKind(rawValue: runtime)
    }
}

/// An integration the template lists that no enabled integration matches.
public struct MissingIntegration: Decodable, Sendable, Hashable {
    public var id: String
    public var required: Bool

    public init(id: String, required: Bool) {
        self.id = id
        self.required = required
    }
}

/// A step that did not work after the agent was created: a skill, a schedule, or the agent itself.
public struct BotStepError: Decodable, Sendable, Hashable {
    /// `skill`, `schedule`, `agent` or `integrations`.
    public var step: String
    /// The skill id, for `skill`.
    public var id: String?
    /// The index in the template's schedules, for `schedule`.
    public var index: Int?
    public var message: String

    public init(step: String, id: String? = nil, index: Int? = nil, message: String) {
        self.step = step
        self.id = id
        self.index = index
        self.message = message
    }
}

/// The answer of `agents.create_from_template`.
public struct BotCreation: Decodable, Sendable {
    /// The new agent; nil only when it cannot be read back (then `errors` says so).
    public var agent: Agent?
    public var scheduleIds: [String]
    public var skillsInstalled: [String]
    public var missingIntegrations: [MissingIntegration]
    public var errors: [BotStepError]

    public init(
        agent: Agent?, scheduleIds: [String] = [], skillsInstalled: [String] = [],
        missingIntegrations: [MissingIntegration] = [], errors: [BotStepError] = []
    ) {
        self.agent = agent
        self.scheduleIds = scheduleIds
        self.skillsInstalled = skillsInstalled
        self.missingIntegrations = missingIntegrations
        self.errors = errors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decodeIfPresent(Agent.self, forKey: .agent)
        scheduleIds = try c.decodeIfPresent([String].self, forKey: .scheduleIds) ?? []
        skillsInstalled = try c.decodeIfPresent([String].self, forKey: .skillsInstalled) ?? []
        missingIntegrations = try c.decodeIfPresent([MissingIntegration].self, forKey: .missingIntegrations) ?? []
        errors = try c.decodeIfPresent([BotStepError].self, forKey: .errors) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case agent, scheduleIds, skillsInstalled, missingIntegrations, errors
    }
}

/// The body of `agents.create_from_template`. `schedules` is always sent: a list, even an empty one, means exactly
/// these runs; leaving it out would give the template's defaults.
public struct NewBot: Encodable, Sendable, Equatable {
    public var templateId: String
    public var name: String
    /// Nil keeps the template's runtime.
    public var runtime: String?
    /// The app's language as the daemon keys it (`CatalogLanguage.requestCode`).
    public var language: String
    /// Indexes into the template's schedules, in order.
    public var schedules: [Int]
    public var workspaceId: String?

    public init(
        templateId: String, name: String, runtime: String? = nil, language: String, schedules: [Int],
        workspaceId: String? = nil
    ) {
        self.templateId = templateId
        self.name = name
        self.runtime = runtime
        self.language = language
        self.schedules = schedules
        self.workspaceId = workspaceId
    }
}
