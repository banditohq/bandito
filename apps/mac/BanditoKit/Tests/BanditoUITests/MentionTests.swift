import BanditoL10n
import Foundation
import Testing

@testable import BanditoKit
@testable import BanditoUI

private func entry(
    _ kind: MentionKind, _ id: String, _ label: String, words: [String] = [], connected: Bool = true,
    template: String? = nil
) -> MentionEntry {
    MentionEntry(kind: kind, id: id, label: label, searchWords: words, connected: connected, templateID: template)
}

private func chip(_ kind: MentionKind, _ id: String, _ label: String, pending: String? = nil) -> DraftMention {
    DraftMention(mention: Mention(kind: kind, id: id, label: label), pendingTemplate: pending)
}

@Suite struct MentionTriggerTests {
    @Test func opensAfterASpaceOrAtTheStart() {
        #expect(MentionTrigger.match(in: "@")?.query == "")
        #expect(MentionTrigger.match(in: "@li")?.query == "li")
        #expect(MentionTrigger.match(in: "ask @Sc")?.query == "Sc")
        #expect(MentionTrigger.match(in: "two\n@x")?.query == "x")
    }

    @Test func staysClosedForAddressesAndFinishedWords() {
        #expect(MentionTrigger.match(in: "mail joe@example.com") == nil)
        #expect(MentionTrigger.match(in: "@li ") == nil)
        #expect(MentionTrigger.match(in: "@Google Drive and") == nil)
        #expect(MentionTrigger.match(in: "at @ five") == nil)
        #expect(MentionTrigger.match(in: "no at sign") == nil)
        #expect(MentionTrigger.match(in: "") == nil)
        #expect(MentionTrigger.match(in: "@" + String(repeating: "a", count: MentionTrigger.maxQuery + 1)) == nil)
    }

    @Test func theRangeCoversTheAtAndTheWord() throws {
        let draft = "ask @Sc"
        let match = try #require(MentionTrigger.match(in: draft))
        #expect(String(draft[match.range]) == "@Sc")
    }
}

@Suite struct MentionDraftTests {
    @Test func aPickReplacesTheTypedWordWithTheLabelAndASpace() throws {
        let draft = "ask @Sc"
        let match = try #require(MentionTrigger.match(in: draft))
        let result = MentionDraft.insert(entry(.agent, "a2", "Scout"), replacing: match, in: draft, list: [])
        #expect(result.draft == "ask @Scout ")
        #expect(result.list == [chip(.agent, "a2", "Scout")])
    }

    @Test func pickingTheSameThingTwiceKeepsOneMention() throws {
        let first = MentionDraft.insert(
            entry(.agent, "a2", "Scout"), replacing: try #require(MentionTrigger.match(in: "@S")), in: "@S", list: [])
        let draft = first.draft + "and @S"
        let second = MentionDraft.insert(
            entry(.agent, "a2", "Scout"), replacing: try #require(MentionTrigger.match(in: draft)), in: draft,
            list: first.list)
        #expect(second.list.count == 1)
        #expect(second.draft == "@Scout and @Scout ")
    }

    @Test func twoThingsWithTheSameNameGetDifferentLabels() throws {
        let one = chip(.file, "/w/a/main.rs", "main.rs")
        let match = try #require(MentionTrigger.match(in: "@ma"))
        let result = MentionDraft.insert(entry(.file, "/w/b/main.rs", "main.rs"), replacing: match, in: "@ma", list: [one])
        #expect(result.list.map(\.mention.label) == ["main.rs", "main.rs (2)"])
        #expect(result.draft == "@main.rs (2) ")
    }

    @Test func aLabelIsOneShortLine() {
        #expect(MentionDraft.uniqueLabel("a\nb", among: []) == "a b")
        #expect(MentionDraft.uniqueLabel("   ", among: []) == "?")
        #expect(MentionDraft.uniqueLabel(String(repeating: "x", count: 100), among: []).count == 80)
    }

    @Test func textThatWasDeletedTakesItsChipWithIt() {
        let list = [chip(.agent, "a2", "Scout"), chip(.integration, "i1", "Linear")]
        #expect(MentionDraft.reconcile(list, in: "ask @Scout about @Linear") == list)
        #expect(MentionDraft.reconcile(list, in: "ask @Scout about it") == [list[0]])
        #expect(MentionDraft.reconcile(list, in: "") == [])
    }

    @Test func backspaceTakesTheWholeChipAtTheEnd() {
        let list = [chip(.integration, "i1", "Linear")]
        let withSpace = MentionDraft.removeTrailingChip(draft: "ask @Linear ", list: list)
        #expect(withSpace?.draft == "ask ")
        #expect(withSpace?.list == [])
        let bare = MentionDraft.removeTrailingChip(draft: "@Linear", list: list)
        #expect(bare?.draft == "")
        #expect(bare?.list == [])
    }

    @Test func backspaceElsewhereDeletesOneCharacterAsUsual() {
        let list = [chip(.integration, "i1", "Linear")]
        #expect(MentionDraft.removeTrailingChip(draft: "@Linear now", list: list) == nil)
        #expect(MentionDraft.removeTrailingChip(draft: "@Linear  ", list: list) == nil)
        #expect(MentionDraft.removeTrailingChip(draft: "x@Linear ", list: list) == nil)
        #expect(MentionDraft.removeTrailingChip(draft: "hello ", list: list) == nil)
        #expect(MentionDraft.removeTrailingChip(draft: "@Linear ", list: []) == nil)
    }

    @Test func theLongestLabelWinsOverOneThatEndsTheSame() {
        let list = [chip(.integration, "i1", "Drive"), chip(.integration, "i2", "Google Drive")]
        let result = MentionDraft.removeTrailingChip(draft: "use @Google Drive ", list: list)
        #expect(result?.draft == "use ")
        #expect(result?.list == [list[0]])
    }

    @Test func aServiceThatIsNotConnectedWaitsAndThenGoes() {
        let waiting = chip(.integration, "catalog:linear", "Linear", pending: "linear")
        let agent = chip(.agent, "a2", "Scout")
        let list = [agent, waiting]
        #expect(MentionDraft.pendingService(in: list) == waiting)
        // Nothing goes to the daemon until it is connected, and a pending id never does.
        #expect(MentionDraft.wire(list, in: "@Scout @Linear") == [agent.mention])
        let done = MentionDraft.connected(list, template: "linear", integrationID: "i-77")
        #expect(MentionDraft.pendingService(in: done) == nil)
        #expect(MentionDraft.wire(done, in: "@Scout @Linear").map(\.id) == ["a2", "i-77"])
        // Only mentions that are still in the text go.
        #expect(MentionDraft.wire(done, in: "@Scout").map(\.id) == ["a2"])
    }

    @Test func pickingAServiceThatIsNotConnectedMakesAPendingMention() throws {
        let linear = entry(.integration, "catalog:linear", "Linear", connected: false, template: "linear")
        let match = try #require(MentionTrigger.match(in: "@lin"))
        let result = MentionDraft.insert(linear, replacing: match, in: "@lin", list: [])
        #expect(result.list.first?.pendingTemplate == "linear")
        #expect(result.list.first?.mention.id == "catalog:linear")
    }
}

@Suite struct MentionSearchTests {
    private let services = [
        entry(.integration, "catalog:linear", "Linear", words: ["linear"], connected: false, template: "linear"),
        entry(.integration, "i-gh", "GitHub", words: ["github"], template: "github"),
        entry(.integration, "i-gd", "Google Drive", words: ["google-drive"], template: "gdrive"),
    ]
    private let agents = [entry(.agent, "a2", "Scout"), entry(.agent, "a3", "Forge")]
    private let tabs = [entry(.browserTab, "T1", "Docs — Café", words: ["example.com"])]

    private func sections(_ query: String, files: [MentionEntry] = []) -> [MentionSection] {
        MentionSearch.sections(query: query, services: services, agents: agents, files: files, tabs: tabs)
    }

    @Test func anEmptyWordListsEveryGroupInOrderWithConnectedServicesFirst() {
        let all = sections("")
        #expect(all.map(\.group) == [.services, .agents, .browser])
        #expect(all[0].entries.map(\.label) == ["GitHub", "Google Drive", "Linear"])
    }

    @Test func aWordFindsByNameEnglishNameAndWordsInTheName() {
        #expect(MentionSearch.flatten(sections("sco")).map(\.label) == ["Scout"])
        #expect(MentionSearch.flatten(sections("drive")).map(\.label) == ["Google Drive"])
        #expect(MentionSearch.flatten(sections("google-d")).map(\.label) == ["Google Drive"])
        #expect(MentionSearch.flatten(sections("zzz")).isEmpty)
    }

    @Test func caseAndAccentsDoNotMatter() {
        #expect(MentionSearch.flatten(sections("CAFE")).map(\.label) == ["Docs — Café"])
        #expect(MentionSearch.flatten(sections("café")).map(\.label) == ["Docs — Café"])
        #expect(MentionSearch.flatten(sections("SCOUT")).map(\.label) == ["Scout"])
    }

    @Test func theEnglishNameOfAGroupAlwaysListsTheGroup() {
        #expect(MentionSearch.flatten(sections("services")).map(\.label) == ["GitHub", "Google Drive", "Linear"])
        #expect(MentionSearch.flatten(sections("agents")).map(\.label) == ["Scout", "Forge"])
        #expect(MentionSearch.flatten(sections("browser")).map(\.label) == ["Docs — Café"])
    }

    @Test func filesAreTheDaemonsAnswerAndAreNotFilteredAgain() {
        let files = [entry(.file, "/w/src/lib.rs", "lib.rs"), entry(.file, "/w/Cargo.toml", "Cargo.toml")]
        // The daemon matched "rs" anywhere in the name; a prefix filter would drop Cargo.toml.
        let found = sections("rs", files: files).first { $0.group == .files }
        #expect(found?.entries.count == 2)
    }

    @Test func aGroupShowsAtMostItsShareUntilItIsNamed() {
        let many = (0..<20).map { entry(.file, "/w/f\($0)", "f\($0)") }
        let plain = sections("", files: many).first { $0.group == .files }
        #expect(plain?.entries.count == MentionSearch.perGroup[.files])
        let named = sections("files", files: many).first { $0.group == .files }
        #expect(named?.entries.count == MentionSearch.namedGroupLimit)
    }

    @Test func foldingJoinsCaseWidthAndAccents() {
        #expect(SearchFolding.fold("Модель") == SearchFolding.fold("мОДЕЛЬ"))
        #expect(SearchFolding.fold("Español") == SearchFolding.fold("espanol"))
        #expect(SearchFolding.matches(query: "", candidates: []))
        #expect(!SearchFolding.matches(query: "x", candidates: []))
    }

    @Test func aliasListsSplitOnCommasOfAnyWidth() {
        #expect(SearchFolding.words("модель, сменить модель，нейросеть、ии") == ["модель", "сменить модель", "нейросеть", "ии"])
        #expect(SearchFolding.words(" , ") == [])
    }
}

private func template(_ id: String, _ name: String) -> IntegrationCatalogEntry {
    IntegrationCatalogEntry(
        id: id, name: name, descriptionEn: name + " things.", descriptionRu: name + " (ru)", kind: .http,
        url: "https://\(id).example/mcp", docsUrl: "", icon: "")
}

@Suite struct MentionSourcesTests {
    private func agent(integrations: [String]?) -> Agent {
        Agent(id: "me", name: "Me", runtime: .claude, cwd: "/w/app", integrations: integrations)
    }

    private let catalog = [template("github", "GitHub"), template("linear", "Linear")]

    @Test func connectedServicesComeFromTheAgentsListAndTheRestOfTheCatalogIsMarked() {
        let connected = [Integration(id: "i1", name: "github", kind: .http, url: "https://github.example/mcp")]
        let rows = MentionSources.services(
            catalog: catalog, integrations: connected, agent: agent(integrations: nil), languageCode: "en")
        #expect(rows.map(\.label) == ["GitHub", "Linear"])
        #expect(rows.map(\.connected) == [true, false])
        #expect(rows[0].id == "i1")
        #expect(rows[1].id == "catalog:linear")
        #expect(rows[1].templateID == "linear")
        #expect(rows.allSatisfy { $0.market != nil })
    }

    @Test func anAgentWithItsOwnListSeesOnlyThoseConnectedServices() {
        let connected = [
            Integration(id: "i1", name: "github", kind: .http, url: "https://github.example/mcp"),
            Integration(id: "i2", name: "mine", kind: .stdio, command: "run"),
        ]
        let rows = MentionSources.services(
            catalog: catalog, integrations: connected, agent: agent(integrations: ["i2"]), languageCode: "en")
        // GitHub is connected but not this agent's, so it is not offered as a connected one; it is not "not connected"
        // either, so the row is the catalog's.
        #expect(rows.filter(\.connected).map(\.label) == ["mine"])
    }

    @Test func aDisabledServiceIsNotOffered() {
        var off = Integration(id: "i1", name: "github", kind: .http, url: "https://github.example/mcp")
        off.enabled = false
        let rows = MentionSources.services(
            catalog: catalog, integrations: [off], agent: agent(integrations: nil), languageCode: "en")
        #expect(rows.filter(\.connected).isEmpty)
    }

    @Test func teammatesExcludeTheCurrentAgent() {
        let a = Agent(id: "a1", name: "Forge", runtime: .claude, cwd: "/w/a")
        let b = Agent(id: "a2", name: "Scout", role: "researcher", runtime: .claude, cwd: "/w/b")
        let rows = MentionSources.agents([a, b], excluding: "a1")
        #expect(rows.map(\.label) == ["Scout"])
        #expect(rows[0].detail == "researcher")
    }

    @Test func tabsAreNamedByTitleOrAddress() {
        let json = #"[{"id":"T1","type":"page","title":"Docs","url":"https://example.com/docs"},{"id":"T2","type":"page","title":" ","url":"https://other.dev/x"},{"id":"T3","type":"service_worker","title":"sw","url":"https://sw"}]"#
        let tabs = (try? RPCClient.decoder.decode([BrowserTab].self, from: Data(json.utf8))) ?? []
        let rows = MentionSources.tabs(tabs)
        #expect(rows.map(\.label) == ["Docs", "other.dev"])
        #expect(rows.map(\.id) == ["T1", "T2"])
    }

    @Test func filesShowTheirFolderRelativeToTheAgentsFolder() {
        #expect(MentionSources.relative("/w/app/src/lib.rs", to: "/w/app") == "src")
        #expect(MentionSources.relative("/w/app/Cargo.toml", to: "/w/app/") == "./")
        #expect(MentionSources.relative("/elsewhere/a.txt", to: "/w/app") == "/elsewhere/a.txt")
    }

    @Test func aMentionFindsTheMarketplaceEntryForItsLogo() {
        let connected = [Integration(id: "i1", name: "github", kind: .http, url: "https://github.example/mcp")]
        let byID = MentionServices.market(
            for: Mention(kind: .integration, id: "i1", label: "GitHub"), catalog: catalog, integrations: connected,
            languageCode: "en")
        #expect(byID?.template?.id == "github")
        // The integration is gone: the label still finds the service.
        let byName = MentionServices.market(
            for: Mention(kind: .integration, id: "gone", label: "linear"), catalog: catalog, integrations: [],
            languageCode: "en")
        #expect(byName?.template?.id == "linear")
        #expect(
            MentionServices.market(
                for: Mention(kind: .agent, id: "a", label: "Scout"), catalog: catalog, integrations: [],
                languageCode: "en") == nil)
    }
}

@Suite struct SlashAliasTests {
    /// The strings of one language, read from the generated resources.
    private func strings(_ code: String) throws -> [String: String] {
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code))
        let dict = NSDictionary(contentsOf: url) as? [String: String]
        return try #require(dict)
    }

    private func entries(language code: String) throws -> [SlashEntry] {
        let table = try strings(code)
        return try BuiltinSlash.allCases.map { command in
            let text = try #require(table["slash.alias.\(command.name)"])
            return SlashEntry(
                name: command.name, description: nil, argsHint: nil, origin: .bandito,
                aliases: SearchFolding.words(text))
        }
    }

    @Test func russianWordsFindTheEnglishCommands() throws {
        let ru = try entries(language: "ru")
        func found(_ query: String) -> [String] { SlashMatcher.filter(ru, query: query, source: .all).map(\.name) }
        #expect(found("модель") == ["model"])
        #expect(found("Модель") == ["model"])
        #expect(found("усилие") == ["effort"])
        #expect(found("новый") == ["new"])
        #expect(found("агент") == ["new"])
        #expect(found("терм") == ["terminal"])
        // The English name always works, in any language.
        #expect(found("model") == ["model"])
        #expect(found("pau") == ["pause"])
    }

    @Test func everyLanguageHasAliasesForEveryCommandAndGroup() throws {
        for language in L10n.languages {
            let table = try strings(language.code)
            for command in BuiltinSlash.allCases {
                let words = SearchFolding.words(table["slash.alias.\(command.name)"] ?? "")
                #expect(!words.isEmpty, "\(language.code) slash.alias.\(command.name)")
            }
            for kind in ["integration", "agent", "file", "browserTab"] {
                let words = SearchFolding.words(table["mention.alias.\(kind)"] ?? "")
                #expect(!words.isEmpty, "\(language.code) mention.alias.\(kind)")
            }
        }
    }

    @Test func aliasesDoNotChangeTheEnglishNamesOrTheOrder() {
        let entries = SlashCatalog.entries(server: [], mac: [], snippets: [])
        #expect(entries.map(\.name) == BuiltinSlash.allCases.map(\.name))
        #expect(entries.allSatisfy { !$0.aliases.isEmpty })
    }

    @Test func aliasesOnlyApplyToTheirOwnCommand() {
        let entries = [
            SlashEntry(name: "model", description: nil, argsHint: nil, origin: .bandito, aliases: ["модель"]),
            SlashEntry(name: "review", description: nil, argsHint: nil, origin: .server),
        ]
        #expect(SlashMatcher.filter(entries, query: "мод", source: .all).map(\.name) == ["model"])
        #expect(SlashMatcher.filter(entries, query: "ре", source: .all).isEmpty)
    }
}

@Suite struct MentionHardeningTests {
    @Test func labelsAreOneCleanLine() {
        let dirty = "a\tb\rc\u{2028}d\u{2029}e\nf  g"
        #expect(MentionDraft.cleanLabel(dirty, fallback: "X") == "a b c d e f g")
        #expect(MentionDraft.cleanLabel("\t\r\u{2028}", fallback: "Files") == "Files")
        #expect(MentionDraft.cleanLabel(String(repeating: "я", count: 200), fallback: "X").count == MentionDraft.maxLabel)
        #expect(MentionDraft.uniqueLabel(" \n ", fallback: "Services", among: []) == "Services")
    }

    @Test func aWholeWordOnlyCountsAsInTheText() {
        let drive = chip(.integration, "i1", "Drive")
        let drive2 = chip(.integration, "i2", "Drive (2)")
        let list = [drive, drive2]
        // Only the longer one is in the text: "@Drive" must not be found inside "@Drive (2)".
        #expect(MentionDraft.reconcile(list, in: "use @Drive (2) now") == [drive2])
        #expect(MentionDraft.reconcile(list, in: "use @Drive now") == [drive])
        #expect(MentionDraft.reconcile(list, in: "@Drive and @Drive (2).") == list)
        #expect(MentionDraft.reconcile(list, in: "@Drive, ok") == [drive])
        #expect(MentionDraft.reconcile(list, in: "x@Drive") == [])
        #expect(MentionDraft.reconcile(list, in: "@Drivers") == [])
        #expect(MentionDraft.reconcile(list, in: "") == [])
    }

    private func connecting(agent: String = "A", name: String = "Linear") -> MentionMenuModel.Connecting {
        MentionMenuModel.Connecting(agentID: agent, name: name, template: "linear", known: [])
    }

    @Test func aSignInFinishesOnlyTheConnectItWasStartedFor() {
        let done = OAuthSignIn.Phase.connected(name: "Linear", integrationID: "i-9")
        #expect(MentionConnectRules.finishedIntegration(connecting: connecting(), agentID: "A", phase: done) == "i-9")
        // The person went to agent B before it ended: nothing is sent.
        #expect(MentionConnectRules.finishedIntegration(connecting: connecting(), agentID: "B", phase: done) == nil)
        // A sign-in begun in the Marketplace, with no connect started here, or for another service.
        #expect(MentionConnectRules.finishedIntegration(connecting: nil, agentID: "A", phase: done) == nil)
        let other = OAuthSignIn.Phase.connected(name: "GitHub", integrationID: "i-1")
        #expect(MentionConnectRules.finishedIntegration(connecting: connecting(), agentID: "A", phase: other) == nil)
        #expect(MentionConnectRules.finishedIntegration(connecting: connecting(), agentID: "A", phase: .idle) == nil)
        #expect(MentionConnectRules.finishedIntegration(connecting: connecting(), agentID: nil, phase: done) == nil)
    }
}
