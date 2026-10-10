import BanditoKit
import Foundation

/// What the sheet "Своя интеграция" does to a draft: take a parsed config, keep the technical name in step with the
/// title. Pure, so the tests can drive it.
extension IntegrationDraft {
    /// Fills the draft from a server found in a pasted config. The kind, the command or the address, the variables
    /// and the headers are replaced; a title the owner already typed stays.
    mutating func apply(_ server: ParsedServer, existingNames: [String]) {
        kind = server.kind
        switch server.kind {
        case .stdio:
            commandLine = server.commandLine
            url = ""
        case .http:
            url = server.url
            commandLine = ""
        }
        env = server.env.map(Self.pair)
        headers = server.headers.map(Self.pair)
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let name = server.name {
            setTitle(name, existingNames: existingNames)
        } else {
            refreshName(existingNames: existingNames)
        }
    }

    /// A new title. The name follows it until the owner edits the name.
    mutating func setTitle(_ text: String, existingNames: [String]) {
        title = text
        refreshName(existingNames: existingNames)
    }

    /// The owner typed the technical name: it no longer follows the title.
    mutating func setName(_ text: String) {
        name = text
        nameEdited = true
    }

    /// The name made from the title: `github`, or `github-2` when `github` is taken. Empty while the title is empty.
    mutating func refreshName(existingNames: [String]) {
        guard !nameEdited else { return }
        let source = title.trimmingCharacters(in: .whitespacesAndNewlines)
        name = source.isEmpty ? "" : IntegrationSlug.make(from: source, taken: Set(existingNames))
    }

    private static func pair(_ parsed: ParsedPair) -> IntegrationPair {
        IntegrationPair(key: parsed.key, value: parsed.value, isSecret: parsed.isSecret, template: parsed.template)
    }
}
