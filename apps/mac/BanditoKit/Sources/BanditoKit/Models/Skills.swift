import Foundation

// The skills catalog of the daemon (`skills.catalog|install|remove`; docs/ARCHITECTURE.md#skills). Feature `skills`.

/// Where a skill comes from: the author's repository at the commit the daemon vendors.
public struct SkillSource: Decodable, Sendable, Hashable {
    public var repo: String
    public var path: String
    public var commit: String
    public var license: String

    public init(repo: String, path: String = "", commit: String = "", license: String = "") {
        self.repo = repo
        self.path = path
        self.commit = commit
        self.license = license
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        repo = try c.decodeIfPresent(String.self, forKey: .repo) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        commit = try c.decodeIfPresent(String.self, forKey: .commit) ?? ""
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case repo, path, commit, license
    }

    /// The page of the skill's folder at the pinned commit, when the repository is on GitHub.
    public var url: URL? {
        guard !repo.isEmpty, !commit.isEmpty,
            repo.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }), !repo.contains("..")
        else { return nil }
        let folder = path.isEmpty ? "" : "/" + path.split(separator: "/").joined(separator: "/")
        return URL(string: "https://github.com/\(repo)/tree/\(commit)\(folder)")
    }

    /// `owner/repo@abcdef0`: what the source line shows.
    public var shortReference: String {
        "\(repo)@\(commit.prefix(7))"
    }
}

/// Folders of one scope kind: the daemon user's, and the agents' own.
public struct SkillPlaces: Decodable, Sendable, Hashable {
    public var user: Bool
    public var projects: [String]

    public init(user: Bool = false, projects: [String] = []) {
        self.user = user
        self.projects = projects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decodeIfPresent(Bool.self, forKey: .user) ?? false
        projects = try c.decodeIfPresent([String].self, forKey: .projects) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case user, projects
    }
}

/// The texts of one skill in a language other than English and Russian.
public struct SkillTranslation: Decodable, Sendable, Hashable {
    public var description: String
    public var long: String

    public init(description: String = "", long: String = "") {
        self.description = description
        self.long = long
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        long = try c.decodeIfPresent(String.self, forKey: .long) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case description, long
    }
}

/// One entry of `skills.catalog`: the catalog fields, and where the skill stands on this server.
public struct SkillEntry: Decodable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var publisher: String
    public var source: SkillSource
    public var descriptionEn: String
    public var descriptionRu: String
    public var longEn: String
    public var longRu: String
    public var warningEn: String?
    public var warningRu: String?
    public var l10n: [String: SkillTranslation]
    public var category: String
    /// The runtimes the skill works in natively. `["claude"]` alone means the others only run it as a command.
    public var runtimes: [String]
    public var files: [String]
    /// Folders that are Bandito's own (the marker file is there).
    public var installed: SkillPlaces
    /// Folders with this name that are not Bandito's: the daemon will not replace them.
    public var conflicts: SkillPlaces
    /// Installs made from an older catalog: the copy there is behind the catalog's commit.
    public var updates: SkillPlaces

    public init(
        id: String, name: String, publisher: String = "", source: SkillSource = SkillSource(repo: ""),
        descriptionEn: String = "", descriptionRu: String = "", longEn: String = "", longRu: String = "",
        warningEn: String? = nil, warningRu: String? = nil, l10n: [String: SkillTranslation] = [:],
        category: String = "dev", runtimes: [String] = ["claude"], files: [String] = [],
        installed: SkillPlaces = SkillPlaces(), conflicts: SkillPlaces = SkillPlaces(),
        updates: SkillPlaces = SkillPlaces()
    ) {
        self.updates = updates
        self.id = id
        self.name = name
        self.publisher = publisher
        self.source = source
        self.descriptionEn = descriptionEn
        self.descriptionRu = descriptionRu
        self.longEn = longEn
        self.longRu = longRu
        self.warningEn = warningEn
        self.warningRu = warningRu
        self.l10n = l10n
        self.category = category
        self.runtimes = runtimes
        self.files = files
        self.installed = installed
        self.conflicts = conflicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher) ?? ""
        source = try c.decodeIfPresent(SkillSource.self, forKey: .source) ?? SkillSource(repo: "")
        descriptionEn = try c.decodeIfPresent(String.self, forKey: .descriptionEn) ?? ""
        descriptionRu = try c.decodeIfPresent(String.self, forKey: .descriptionRu) ?? descriptionEn
        longEn = try c.decodeIfPresent(String.self, forKey: .longEn) ?? ""
        longRu = try c.decodeIfPresent(String.self, forKey: .longRu) ?? longEn
        warningEn = try c.decodeIfPresent(String.self, forKey: .warningEn)
        warningRu = try c.decodeIfPresent(String.self, forKey: .warningRu)
        l10n = (try? c.decodeIfPresent([String: SkillTranslation].self, forKey: .l10n)).flatMap { $0 } ?? [:]
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "dev"
        runtimes = try c.decodeIfPresent([String].self, forKey: .runtimes) ?? ["claude"]
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        installed = try c.decodeIfPresent(SkillPlaces.self, forKey: .installed) ?? SkillPlaces()
        conflicts = try c.decodeIfPresent(SkillPlaces.self, forKey: .conflicts) ?? SkillPlaces()
        updates = try c.decodeIfPresent(SkillPlaces.self, forKey: .updates) ?? SkillPlaces()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, publisher, source, descriptionEn, descriptionRu, longEn, longRu, warningEn, warningRu
        case l10n, category, runtimes, files, installed, conflicts, updates
    }

    private func translation(_ languageCode: String) -> SkillTranslation? {
        CatalogLanguage.translationKey(in: l10n.keys, languageCode: languageCode).flatMap { l10n[$0] }
    }

    /// The description in the app's language: Russian for `ru`, a translation, else English.
    public func description(languageCode: String) -> String {
        if CatalogLanguage.isRussian(languageCode) { return descriptionRu.isEmpty ? descriptionEn : descriptionRu }
        if let text = translation(languageCode)?.description, !text.isEmpty { return text }
        return descriptionEn
    }

    /// The longer text of the skill's page; the short description when there is none.
    public func long(languageCode: String) -> String {
        let text: String
        if CatalogLanguage.isRussian(languageCode) {
            text = longRu.isEmpty ? longEn : longRu
        } else if let own = translation(languageCode)?.long, !own.isEmpty {
            text = own
        } else {
            text = longEn
        }
        return text.isEmpty ? description(languageCode: languageCode) : text
    }

    /// What to check before using the skill. The catalog writes it in English and Russian only: any other language
    /// reads the English one.
    public func warning(languageCode: String) -> String? {
        let text = CatalogLanguage.isRussian(languageCode) ? (warningRu ?? warningEn) : warningEn
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The names a search matches: the skill's own name and the description in the app's language and in English.
    public var searchName: String { name }

    /// True when the skill works natively in Claude Code only.
    public var claudeOnly: Bool { runtimes == ["claude"] }
}
