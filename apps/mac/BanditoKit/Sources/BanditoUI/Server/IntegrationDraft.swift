import BanditoKit
import Foundation

/// One key and value of an integration's environment or headers, as the editor shows it.
public struct IntegrationPair: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var key = ""
    /// A literal value, or the secret the owner types in when `isSecret` is set.
    public var value = ""
    /// The value is a secret: it is kept as a server secret, and the integration holds `secret:<NAME>`.
    public var isSecret = false
    /// The secret's name when the stored row already refers to one. Typing a value replaces that secret.
    public var storedSecret: String?
    /// How a catalog builds the value from the secret, for example `Bearer {secret}`. Nil when the value is the secret.
    public var template: String?

    public init(
        key: String = "", value: String = "", isSecret: Bool = false, storedSecret: String? = nil,
        template: String? = nil
    ) {
        self.key = key
        self.value = value
        self.isSecret = isSecret
        self.storedSecret = storedSecret
        self.template = template
    }
}

/// A secret the save writes. Integration secrets go to no agent's environment (`agents` is empty): the integration
/// reads them by name when a session starts.
public struct IntegrationSecretWrite: Equatable, Sendable {
    public var name: String
    public var value: String
    public var agents: [String]

    public init(name: String, value: String, agents: [String] = []) {
        self.name = name
        self.value = value
        self.agents = agents
    }
}

/// What saving an integration sends: the secrets first, then either `integrations.add` or `integrations.update`.
public struct IntegrationSave: Sendable {
    public var secrets: [IntegrationSecretWrite]
    /// Set when the integration is new.
    public var create: NewIntegration?
    /// Set when the integration exists: the fields to change.
    public var patch: IntegrationPatch?
}

/// The add, edit and custom sheet's state, and everything it checks and builds. Pure: the sheet only binds to it.
public struct IntegrationDraft: Equatable, Sendable {
    /// The id of the integration being edited; nil when it is new.
    public var editingID: String?
    /// The name the integration had when it was opened: it may keep that name.
    public var originalName: String?
    public var name = ""
    public var kind: IntegrationKind = .stdio
    public var command = ""
    /// The arguments, separated by spaces.
    public var argsText = ""
    public var url = ""
    public var env: [IntegrationPair] = []
    public var headers: [IntegrationPair] = []

    public init() {}

    /// A problem that stops the save, in the order the sheet explains it.
    public enum Problem: Equatable, Sendable {
        case nameEmpty
        case nameInvalid
        case nameTaken
        case commandEmpty
        case urlInvalid
        case keyEmpty
        case keyInvalid(String)
        case secretMissing(String)
        case secretNameInvalid(String)
        /// A row that held a secret and has the switch off with no value: it would overwrite the secret.
        case valueMissing(String)
    }

    /// The names a server integration may take: 1 to 40 characters of `a-z 0-9 _ -`, and not `bandito`.
    public static let nameLimit = 40
    static let reservedName = "bandito"

    // MARK: - starting points

    /// A new integration from a catalog template. The secret headers are typed in; the name is the template's id.
    public static func fromCatalog(_ entry: IntegrationCatalogEntry) -> IntegrationDraft {
        var draft = IntegrationDraft()
        draft.name = entry.id
        draft.kind = entry.kind
        draft.command = entry.command ?? ""
        draft.argsText = entry.args.joined(separator: " ")
        draft.url = entry.url ?? ""
        draft.headers = entry.headersKeys.map { header in
            IntegrationPair(key: header.key, isSecret: header.secret, template: header.valueTemplate)
        }
        return draft
    }

    /// A new integration of its own: stdio or HTTP, nothing filled in.
    public static func custom(kind: IntegrationKind) -> IntegrationDraft {
        var draft = IntegrationDraft()
        draft.kind = kind
        return draft
    }

    /// An existing integration, as its row stands. A value that is exactly `secret:<NAME>` opens as a secret, so
    /// typing a new value replaces it; other values are shown as they are.
    public static func editing(_ integration: Integration) -> IntegrationDraft {
        var draft = IntegrationDraft()
        draft.editingID = integration.id
        draft.originalName = integration.name
        draft.name = integration.name
        draft.kind = integration.kind
        draft.command = integration.command ?? ""
        draft.argsText = integration.args.joined(separator: " ")
        draft.url = integration.url ?? ""
        draft.env = integration.env.sorted { $0.key < $1.key }.map(pair)
        draft.headers = integration.headers.sorted { $0.key < $1.key }.map(pair)
        return draft
    }

    private static func pair(_ key: String, _ value: String) -> IntegrationPair {
        let prefix = "secret:"
        if value.hasPrefix(prefix) {
            let name = String(value.dropFirst(prefix.count))
            if SecretRules.isValidName(name) {
                return IntegrationPair(key: key, isSecret: true, storedSecret: name)
            }
        }
        return IntegrationPair(key: key, value: value)
    }

    // MARK: - names

    /// The name is 1 to 40 characters of `a-z 0-9 _ -`, and not the crew server's own name.
    public static func isValidName(_ name: String) -> Bool {
        guard (1...nameLimit).contains(name.count), name != reservedName else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (97...122).contains(scalar.value) || (48...57).contains(scalar.value) || scalar.value == 95
                || scalar.value == 45
        }
    }

    /// The secret that holds a value of an integration: the integration's name and the key, in capitals, with
    /// everything else turned into `_`. For `github` and `Authorization` it is `GITHUB_AUTHORIZATION`.
    public static func secretName(integration: String, key: String) -> String {
        let raw = "\(integration)_\(key)".uppercased()
        var result = ""
        for scalar in raw.unicodeScalars {
            let isLetterOrDigit = (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
            if isLetterOrDigit {
                result.unicodeScalars.append(scalar)
            } else if !result.hasSuffix("_") {
                result.append("_")
            }
        }
        result = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "_")).prefix(64))
        if result.isEmpty { return "SECRET" }
        if let first = result.unicodeScalars.first, (48...57).contains(first.value) {
            return String(("_" + result).prefix(64))
        }
        return result
    }

    /// The arguments as the daemon takes them: the text split on spaces.
    public var args: [String] {
        argsText.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
    }

    /// After `integrations.add`: the draft now stands for the saved integration. Typed secret values stay until
    /// `markSecretsWritten()`, so a secret that failed to save can be saved again from the same sheet.
    public mutating func markSaved(id: String) {
        editingID = id
        originalName = trimmed(name)
    }

    /// The secrets are on the server: their typed values are cleared, and the rows keep the references.
    public mutating func markSecretsWritten() {
        for index in headers.indices where headers[index].isSecret {
            headers[index].value = ""
        }
        for index in env.indices where env[index].isSecret {
            env[index].value = ""
        }
    }

    /// Gives every new secret a name nobody holds: the name from the integration and the key, with `_2`, `_3`… added
    /// when the name is taken on the server (`taken`) or by another row of this draft. A secret the row already holds
    /// keeps its name. Other people's secrets are never overwritten.
    public mutating func assignSecretNames(taken: Set<String>) {
        var used = taken
        for item in headers + env where item.storedSecret != nil {
            used.insert(item.storedSecret ?? "")
        }
        let integration = trimmed(name)
        for index in headers.indices where headers[index].isSecret && headers[index].storedSecret == nil {
            guard !trimmed(headers[index].value).isEmpty else { continue }
            let chosen = Self.freeName(base: Self.secretName(integration: integration, key: trimmed(headers[index].key)), used: used)
            headers[index].storedSecret = chosen
            used.insert(chosen)
        }
        for index in env.indices where env[index].isSecret && env[index].storedSecret == nil {
            guard !trimmed(env[index].value).isEmpty else { continue }
            let chosen = Self.freeName(base: Self.secretName(integration: integration, key: trimmed(env[index].key)), used: used)
            env[index].storedSecret = chosen
            used.insert(chosen)
        }
    }

    /// The first of `base`, `base_2`, `base_3`… that is not used. A suffix keeps the name within 64 characters.
    static func freeName(base: String, used: Set<String>) -> String {
        if !used.contains(base) { return base }
        var number = 2
        while true {
            let suffix = "_\(number)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if !used.contains(candidate) { return candidate }
            number += 1
        }
    }

    // MARK: - checks

    /// The first reason the integration cannot be saved, or nil when it can. `existingNames` are the names of every
    /// integration on the server; the one being edited may keep its own.
    public func problem(existingNames: [String]) -> Problem? {
        let name = trimmed(name)
        if name.isEmpty { return .nameEmpty }
        if !Self.isValidName(name) { return .nameInvalid }
        let others = existingNames.filter { $0 != originalName }
        if others.contains(name) { return .nameTaken }
        switch kind {
        case .stdio:
            if trimmed(command).isEmpty { return .commandEmpty }
        case .http:
            if !Self.isURL(trimmed(url)) { return .urlInvalid }
        }
        for item in env + headers {
            if let problem = pairProblem(item, name: name) { return problem }
        }
        return nil
    }

    /// `https://` with a host, or `http://localhost`.
    public static func isURL(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("https://") { return lower.count > "https://".count }
        return lower == "http://localhost" || lower.hasPrefix("http://localhost/") || lower.hasPrefix("http://localhost:")
    }

    private func pairProblem(_ item: IntegrationPair, name: String) -> Problem? {
        let key = trimmed(item.key)
        if key.isEmpty { return .keyEmpty }
        if !Self.isValidKey(key) { return .keyInvalid(key) }
        if item.isSecret, trimmed(item.value).isEmpty, item.storedSecret == nil {
            return .secretMissing(key)
        }
        if !item.isSecret, item.storedSecret != nil, trimmed(item.value).isEmpty {
            return .valueMissing(key)
        }
        if item.isSecret, !trimmed(item.value).isEmpty {
            let secret = item.storedSecret ?? Self.secretName(integration: name, key: key)
            if !SecretRules.isValidName(secret) { return .secretNameInvalid(secret) }
        }
        return nil
    }

    /// Environment and header names: letters, digits, `_`, `-` and `.`.
    public static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (97...122).contains(scalar.value) || (48...57).contains(scalar.value)
                || scalar.value == 95 || scalar.value == 45 || scalar.value == 46
        }
    }

    // MARK: - build

    /// What saving sends. Call it only when `problem(existingNames:)` is nil.
    public func build() -> IntegrationSave {
        let name = trimmed(name)
        var secrets: [IntegrationSecretWrite] = []
        let envMap = resolve(env, name: name, secrets: &secrets)
        let headerMap = resolve(headers, name: name, secrets: &secrets)
        if editingID != nil {
            var patch = IntegrationPatch(
                name: name,
                args: kind == .stdio ? args : [],
                env: envMap,
                headers: headerMap)
            switch kind {
            case .stdio:
                patch.command = .set(trimmed(command))
                patch.url = .clear
            case .http:
                patch.url = .set(trimmed(url))
                patch.command = .clear
            }
            return IntegrationSave(secrets: secrets, create: nil, patch: patch)
        }
        let create = NewIntegration(
            name: name,
            kind: kind,
            command: kind == .stdio ? trimmed(command) : nil,
            args: kind == .stdio ? args : [],
            url: kind == .http ? trimmed(url) : nil,
            env: envMap,
            headers: headerMap,
            enabled: true)
        return IntegrationSave(secrets: secrets, create: create, patch: nil)
    }

    /// The values as the daemon stores them: a secret becomes `secret:<NAME>` (through its template when it has
    /// one), and its value goes into `secrets`. A stored secret that is not retyped keeps its reference.
    private func resolve(
        _ pairs: [IntegrationPair], name: String, secrets: inout [IntegrationSecretWrite]
    ) -> [String: String] {
        var result: [String: String] = [:]
        for item in pairs {
            let key = trimmed(item.key)
            guard !key.isEmpty else { continue }
            guard item.isSecret else {
                result[key] = item.value
                continue
            }
            let typed = trimmed(item.value)
            let secret: String
            if !typed.isEmpty {
                secret = item.storedSecret ?? Self.secretName(integration: name, key: key)
                secrets.append(IntegrationSecretWrite(name: secret, value: typed, agents: []))
            } else if let stored = item.storedSecret {
                secret = stored
            } else {
                continue
            }
            let reference = "secret:\(secret)"
            result[key] = item.template.map { $0.replacingOccurrences(of: "{secret}", with: reference) } ?? reference
        }
        return result
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
