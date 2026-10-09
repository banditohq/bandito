import Foundation
import Testing

@testable import BanditoKit

@Suite struct SnippetTests {
    @Test func findsPlaceholdersWithCharacterRanges() {
        let found = SnippetTemplate.placeholders(in: "Hi {name}, {task} and {name}")
        #expect(found.map(\.name) == ["name", "task", "name"])
        #expect(found[0].range == 3..<9)
        #expect(found[1].range == 11..<17)
    }

    @Test func textWithoutBracesHasNoPlaceholders() {
        #expect(SnippetTemplate.placeholders(in: "Plain text").isEmpty)
        #expect(SnippetTemplate.placeholders(in: "Two { braces } and an open {").isEmpty)
    }

    @Test func insertSelectsTheFirstPlaceholderAfterASpace() {
        let result = SnippetTemplate.insert("Hi {name}!", into: "Look:")
        #expect(result.text == "Look: Hi {name}!")
        #expect(result.selection == 9..<15)
    }

    @Test func insertIntoEmptyDraftSelectsFromTheStart() {
        let result = SnippetTemplate.insert("Hi {name}!", into: "")
        #expect(result.text == "Hi {name}!")
        #expect(result.selection == 3..<9)
    }

    @Test func insertWithoutPlaceholdersHasNoSelection() {
        let result = SnippetTemplate.insert("Standup notes", into: "Draft ")
        #expect(result.text == "Draft Standup notes")
        #expect(result.selection == nil)
    }

    @Test func snippetsRoundTripThroughDefaults() {
        let suite = "bandito.tests.snippets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SnippetStore.load(defaults).isEmpty)
        let saved = [Snippet(name: "standup", text: "Yesterday: {what}")]
        SnippetStore.save(saved, to: defaults)
        #expect(SnippetStore.load(defaults) == saved)
    }
}

@Suite struct RecentFoldersTests {
    @Test func keepsEightMostRecentFirst() {
        var recent = RecentFolders()
        for i in 1...10 { recent.remember("/p/\(i)") }
        #expect(recent.paths.count == 8)
        #expect(recent.paths.first == "/p/10")
        #expect(recent.paths.last == "/p/3")
    }

    @Test func rememberingAgainMovesToFrontWithoutDuplicates() {
        var recent = RecentFolders(paths: ["/a", "/b", "/c"])
        recent.remember("/c")
        #expect(recent.paths == ["/c", "/a", "/b"])
        recent.remember("")
        #expect(recent.paths == ["/c", "/a", "/b"])
    }

    @Test func listsArePerServer() {
        let suite = "bandito.tests.recent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        var first = RecentFolders.load(serverID: "server-1", defaults: defaults)
        first.remember("/work/billing")
        first.save(serverID: "server-1", defaults: defaults)

        #expect(RecentFolders.load(serverID: "server-1", defaults: defaults).paths == ["/work/billing"])
        #expect(RecentFolders.load(serverID: "server-2", defaults: defaults).paths.isEmpty)
    }
}
