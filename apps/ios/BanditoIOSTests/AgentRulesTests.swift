import BanditoKit
import Foundation
import Testing

// The module of the app is named after its product (PRODUCT_NAME), not after its target.
@testable import Bandito

/// The rules of the agent forms: the runtime and model a new agent starts on, its folder, the rights, and the bodies of
/// `agents.create` and `agents.create_bundle`. The bodies are encoded the way the RPC client encodes them.
@Suite struct AgentRulesTests {
    // MARK: runtime and model

    @Test func theFirstInstalledRuntimeIsTheDefault() throws {
        let none = try runtimes(installed: [])
        #expect(AgentRules.defaultRuntime(none) == nil)
        let grokOnly = try runtimes(installed: [.grok])
        #expect(AgentRules.defaultRuntime(grokOnly) == .grok)
        let all = try runtimes(installed: [.grok, .codex, .claude])
        #expect(AgentRules.defaultRuntime(all) == .claude)
    }

    @Test func claudeStartsOnHaikuWhenTheListHasIt() {
        let models = [model("sonnet", "Sonnet 4.5"), model("haiku", "Haiku 4.5")]
        #expect(AgentRules.preferredModel(runtime: .claude, models: models) == "haiku")
    }

    @Test func claudeStartsOnTheNewestHaikuByVersion() {
        let models = [
            model("claude-haiku-4-5", "Haiku 4.5"), model("claude-haiku-5-5", "Haiku 5.5"),
            model("claude-opus-5", "Opus 5"),
        ]
        #expect(AgentRules.preferredModel(runtime: .claude, models: models) == "claude-haiku-5-5")
    }

    @Test func otherRuntimesAndListsWithoutHaikuKeepTheirDefault() {
        let models = [model("gpt-5", "GPT-5")]
        #expect(AgentRules.preferredModel(runtime: .claude, models: models) == nil)
        #expect(AgentRules.preferredModel(runtime: .codex, models: [model("haiku", "Haiku 4.5")]) == nil)
    }

    @Test func aVersionIsTheNumbersInTheName() {
        #expect(AgentRules.version(of: "Haiku 4.5") == [4, 5])
        #expect(AgentRules.version(of: "Haiku") == [])
    }

    // MARK: folder

    @Test func aFolderNameKeepsWhatAFolderCanHave() {
        #expect(AgentRules.folderName(for: "Forge") == "Forge")
        #expect(AgentRules.folderName(for: "a/b:c*d") == "a-b-c-d")
        #expect(AgentRules.folderName(for: "  Ledger  ") == "Ledger")
        #expect(AgentRules.folderName(for: "") == "agent")
        #expect(AgentRules.folderName(for: "..") == "agent")
        #expect(AgentRules.folderName(for: String(repeating: "x", count: 100)).count == AgentRules.nameLimit)
    }

    @Test func aTakenNameGetsANumber() {
        #expect(AgentRules.candidate(base: "Forge", attempt: 1) == "Forge")
        #expect(AgentRules.candidate(base: "Forge", attempt: 2) == "Forge 2")
        #expect(AgentRules.candidate(base: "Forge", attempt: 3) == "Forge 3")
    }

    @Test func aFolderPathDoesNotDoubleTheSlash() {
        #expect(AgentRules.folderPath(root: "/home/me/Bandito", name: "Forge") == "/home/me/Bandito/Forge")
        #expect(AgentRules.folderPath(root: "/home/me/Bandito/", name: "Forge") == "/home/me/Bandito/Forge")
        #expect(AgentRules.folderPath(root: "/", name: "Forge") == "/Forge")
    }

    @Test func theAgentsFolderIsTheSavedOneFirst() {
        let root = AgentRules.defaultRoot(
            saved: "/srv/agents/", projectFolders: ["/a/x", "/a/y"], home: "/home/me")
        #expect(root == "/srv/agents")
    }

    @Test func theAgentsFolderIsTheParentOfTheMostProjects() {
        let root = AgentRules.defaultRoot(
            saved: nil, projectFolders: ["/work/site", "/work/api", "/other/tool"], home: "/home/me")
        #expect(root == "/work")
    }

    @Test func withoutAProjectTheAgentsFolderIsBanditoInTheHome() {
        #expect(AgentRules.defaultRoot(saved: nil, projectFolders: ["/work/site"], home: "/home/me")
            == "/home/me/Bandito")
        #expect(AgentRules.defaultRoot(saved: nil, projectFolders: [], home: nil) == nil)
    }

    @Test func aProjectFolderIsNotTheAgentsOwnFolder() {
        #expect(AgentRules.projectFolder(cwd: "/work/site/", homeDir: nil) == "/work/site")
        #expect(AgentRules.projectFolder(cwd: "/work/agent", homeDir: "/work/agent") == nil)
        #expect(AgentRules.projectFolder(cwd: "  ", homeDir: nil) == nil)
    }

    // MARK: form

    @Test func oneAgentNeedsANameARuntimeAndAFolderAndNoRequestUnderWay() {
        #expect(AgentRules.canCreateOne(name: "Ledger", runtime: .claude, folder: "/a/Ledger", busy: false))
        #expect(!AgentRules.canCreateOne(name: "  ", runtime: .claude, folder: "/a/Ledger", busy: false))
        #expect(!AgentRules.canCreateOne(name: "Ledger", runtime: nil, folder: "/a/Ledger", busy: false))
        #expect(!AgentRules.canCreateOne(name: "Ledger", runtime: .claude, folder: "", busy: false))
        #expect(!AgentRules.canCreateOne(name: "Ledger", runtime: .claude, folder: "/a/Ledger", busy: true))
    }

    @Test func theRightsKeepTheChipOrderAndAMissingListMeansAll() {
        #expect(AgentPermission.set(from: nil) == Set(AgentPermission.allCases))
        #expect(AgentPermission.set(from: ["team", "unknown", "terminal"]) == [.team, .terminal])
        #expect(AgentPermission.wire([.screen, .terminal, .files]) == ["terminal", "files", "screen"])
    }

    // MARK: request bodies

    @Test func theCreateBodyCarriesTheFieldsTheFormHas() throws {
        let agent = AgentRules.newAgent(
            name: " Ledger ", role: "Bookkeeper", runtime: .claude, model: "haiku", folder: "/a/Ledger",
            approval: .always, effort: .high, permissions: [.terminal, .files])
        let body = try wire(agent)
        #expect(body["name"] as? String == "Ledger")
        #expect(body["role"] as? String == "Bookkeeper")
        #expect(body["runtime"] as? String == "claude")
        #expect(body["model"] as? String == "haiku")
        #expect(body["cwd"] as? String == "/a/Ledger")
        #expect(body["approval_mode"] as? String == "always")
        #expect(body["effort"] as? String == "high")
        #expect(body["capabilities"] as? [String] == ["terminal", "files"])
    }

    @Test func aDefaultModelIsLeftOutOfTheCreateBody() throws {
        let agent = AgentRules.newAgent(
            name: "Ledger", role: "", runtime: .codex, model: "  ", folder: "/a/Ledger", approval: .risky,
            effort: nil, permissions: [])
        let body = try wire(agent)
        #expect(body["model"] == nil)
        #expect(body["effort"] == nil)
        #expect(body["capabilities"] as? [String] == [])
    }

    @Test func theBundleBodyNamesTheTeamAndTheSwitchedOnSchedules() throws {
        let request = AgentRules.teamRequest(
            bundleID: "web-project", runtime: .claude, languageCode: "en", model: "haiku", folder: "/a/Web",
            scheduleKeys: ["qa-tester:0", "code-reviewer:0"], enabled: ["qa-tester:0"])
        let body = try wire(#require(request))
        #expect(body["bundle_id"] as? String == "web-project")
        #expect(body["runtime"] as? String == "claude")
        #expect(body["model"] as? String == "haiku")
        #expect(body["cwd"] as? String == "/a/Web")
        #expect(body["schedules"] as? [String] == ["qa-tester:0"])
    }

    @Test func aTeamWithoutSchedulesOrFolderSendsNeitherField() throws {
        let request = AgentRules.teamRequest(
            bundleID: "morning-summary", runtime: .claude, languageCode: "ru", model: nil, folder: " ",
            scheduleKeys: [], enabled: [])
        let body = try wire(#require(request))
        #expect(body["cwd"] == nil)
        #expect(body["model"] == nil)
        #expect(body["schedules"] == nil)
    }

    @Test func aTeamNeedsARuntime() {
        #expect(AgentRules.teamRequest(
            bundleID: "docs-upkeep", runtime: nil, languageCode: "en", model: nil, folder: "/a", scheduleKeys: [],
            enabled: []) == nil)
    }

    @Test func aScheduleKeyIsTemplateAndIndex() {
        #expect(AgentRules.scheduleKey(templateID: "qa-tester", index: 0) == "qa-tester:0")
    }

    // MARK: fixtures

    private func model(_ id: String, _ name: String) -> RuntimeModel {
        RuntimeModel(id: id, name: name)
    }

    /// The runtimes of `runtimes.status`, with the given kinds installed.
    private func runtimes(installed: [RuntimeKind]) throws -> [RuntimeStatus] {
        let entries = RuntimeKind.allCases.filter { $0 != .api }.map { kind -> [String: Any] in
            [
                "kind": kind.rawValue, "installed": installed.contains(kind), "logged_in": NSNull(),
                "version": NSNull(), "detail": NSNull(), "supported_capabilities": [String](),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        return try JSONDecoder.wire.decode([RuntimeStatus].self, from: data)
    }

    /// The request body as the RPC client sends it: snake_case keys.
    private func wire<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder.wire.encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension JSONEncoder {
    /// The encoder of an RPC request: snake_case keys, as `RPC.swift` sends them.
    static var wire: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}

extension JSONDecoder {
    /// The decoder of an RPC answer: snake_case keys, as `RPC.swift` reads them.
    static var wire: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
