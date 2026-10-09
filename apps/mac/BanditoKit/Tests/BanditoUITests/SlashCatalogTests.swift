import Testing

@testable import BanditoKit
@testable import BanditoUI

@Suite struct SlashCatalogTests {
    @Test func menuOpensOnlyWhileTheCommandNameIsBeingTyped() {
        #expect(SlashTrigger.query(for: "/") == "")
        #expect(SlashTrigger.query(for: "/wo") == "wo")
        #expect(SlashTrigger.query(for: "   /ef") == "ef")
        #expect(SlashTrigger.query(for: "/wo ") == nil)
        #expect(SlashTrigger.query(for: "hi /wo") == nil)
        #expect(SlashTrigger.query(for: "") == nil)
    }

    @Test func invocationSplitsNameAndArguments() {
        #expect(SlashInvocationParser.parse("/model  opus ") == SlashInvocation(name: "model", args: "opus"))
        #expect(SlashInvocationParser.parse("/review-pr 42") == SlashInvocation(name: "review-pr", args: "42"))
        #expect(SlashInvocationParser.parse("hello /model") == nil)
        #expect(SlashInvocationParser.parse("/") == nil)
    }

    @Test func filtersBySourceAndPrefix() {
        let entries = [
            SlashEntry(name: "worklog", description: nil, argsHint: "[день]", origin: .mac),
            SlashEntry(name: "review-pr", description: nil, argsHint: "<номер>", origin: .server),
            SlashEntry(name: "effort", description: nil, argsHint: "high", origin: .bandito),
            SlashEntry(name: "standup", description: nil, argsHint: nil, origin: .mine),
        ]
        #expect(SlashMatcher.filter(entries, query: "", source: .all).count == 4)
        #expect(SlashMatcher.filter(entries, query: "re", source: .all).map(\.name) == ["review-pr"])
        #expect(SlashMatcher.filter(entries, query: "", source: .mac).map(\.name) == ["worklog"])
        #expect(SlashMatcher.filter(entries, query: "e", source: .bandito).map(\.name) == ["effort"])
        #expect(SlashMatcher.filter(entries, query: "w", source: .server).isEmpty)
    }

    @Test func prefixMatchIgnoresCase() {
        let entries = [SlashEntry(name: "Worklog", description: nil, argsHint: nil, origin: .mac)]
        #expect(SlashMatcher.filter(entries, query: "WORK", source: .all).count == 1)
    }

    @Test func macCommandIsDroppedWhenTheServerHasTheSameName() {
        let server = [
            AgentCommand(
                name: "git:commit", description: "server copy", argsHint: nil, source: .project, path: "/p",
                runtimeNative: true)
        ]
        let mac = [
            MacCommand(name: "git:commit", kind: .command, description: "mac copy", argsHint: nil, files: []),
            MacCommand(name: "worklog", kind: .command, description: nil, argsHint: "[день]", files: []),
        ]
        let entries = SlashCatalog.entries(server: server, mac: mac, snippets: [])
        #expect(entries.filter { $0.origin == .mac }.map(\.name) == ["worklog"])
        #expect(entries.filter { $0.origin == .server }.map(\.name) == ["git:commit"])
    }

    @Test func entriesKeepSourceOrderAndIncludeSnippets() {
        let entries = SlashCatalog.entries(
            server: [], mac: [], snippets: [Snippet(name: "standup", text: "Yesterday: {what}")])
        let builtins = BuiltinSlash.allCases.map(\.name)
        #expect(entries.map(\.name) == builtins + ["standup"])
        #expect(entries.last?.origin == .mine)
    }

    @Test func builtinListIsFixed() {
        #expect(
            BuiltinSlash.allCases.map(\.name)
                == ["new", "model", "effort", "chapter", "memory", "changes", "terminal", "files", "usage", "pause"])
        #expect(BuiltinSlash.named("effort") == .effort)
        #expect(BuiltinSlash.named("nope") == nil)
    }

    @Test func effortArgumentMustBeALevel() {
        #expect(BuiltinSlash.effortLevel(from: "High") == .high)
        #expect(BuiltinSlash.effortLevel(from: " max ") == .max)
        #expect(BuiltinSlash.effortLevel(from: "ultra") == nil)
        #expect(BuiltinSlash.effortLevel(from: "") == nil)
    }
}
