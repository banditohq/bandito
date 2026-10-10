import BanditoKit
import BanditoL10n
import Foundation

// The pure parts of `@` mentions in the composer: when the menu is open, which rows it lists, what a pick leaves in
// the draft, and how a chip goes with Backspace. The views (`MentionMenuView`, `Composer`) only draw and call these.

/// Search that ignores case, accents and width: "Модель" finds "модель", "café" finds "cafe".
enum SearchFolding {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The words of an alias list from the strings file: separated by commas (also the full-width ones).
    static func words(_ list: String) -> [String] {
        list.components(separatedBy: CharacterSet(charactersIn: ",，、;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// True when `query` begins one of the candidates, or one of the words in it. An empty query matches everything.
    static func matches(query: String, candidates: [String]) -> Bool {
        let needle = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        for candidate in candidates {
            let folded = fold(candidate)
            if folded.hasPrefix(needle) { return true }
            if folded.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
                .contains(where: { $0.hasPrefix(needle) })
            {
                return true
            }
        }
        return false
    }
}

/// The groups of the `@` menu, in the order they are listed.
enum MentionGroup: CaseIterable, Sendable {
    case services, agents, files, browser

    var kind: MentionKind {
        switch self {
        case .services: .integration
        case .agents: .agent
        case .files: .file
        case .browser: .browserTab
        }
    }

    init(kind: MentionKind) {
        switch kind {
        case .integration: self = .services
        case .agent: self = .agents
        case .file: self = .files
        case .browserTab: self = .browser
        }
    }

    var title: String {
        switch self {
        case .services: L10n.Mention.groupServices
        case .agents: L10n.Mention.groupAgents
        case .files: L10n.Mention.groupFiles
        case .browser: L10n.Mention.groupBrowser
        }
    }

    /// The group's name in English: it finds the group whatever the app's language is.
    var englishWords: [String] {
        switch self {
        case .services: ["services", "service", "integrations"]
        case .agents: ["agents", "agent", "team"]
        case .files: ["files", "file", "folder"]
        case .browser: ["browser", "tab"]
        }
    }

    /// The group's names in the app's language (`mention.alias.<kind>`).
    var aliases: [String] {
        SearchFolding.words(aliasText)
    }

    private var aliasText: String {
        switch self {
        case .services: L10n.Mention.Alias.integration
        case .agents: L10n.Mention.Alias.agent
        case .files: L10n.Mention.Alias.file
        case .browser: L10n.Mention.Alias.browserTab
        }
    }

    /// Everything that finds the group.
    var searchWords: [String] { englishWords + aliases + [title] }
}

/// One row of the `@` menu.
struct MentionEntry: Identifiable, Equatable {
    let kind: MentionKind
    /// The mention's id: the integration's, the agent's, the file's path, the tab's id. For a service that is not
    /// connected it is `catalog:<template id>`, and it is replaced by the integration's id once connected.
    let id: String
    /// The text after the `@`.
    let label: String
    /// A quiet second line: an address, a folder, a role.
    var detail: String?
    /// More words that find the row (the English name of a service, its catalog id).
    var searchWords: [String] = []
    /// A service the owner has connected. Always true for the other kinds.
    var connected = true
    /// The catalog template of a service, for its logo and for connecting it.
    var templateID: String?
    /// The Marketplace entry of a service: its name, logo and colour are drawn from it.
    var market: MarketEntry?
    /// What a file is, for its icon.
    var fileKind: FsEntryKind?
    var fileExt: String?

    var group: MentionGroup { MentionGroup(kind: kind) }
    var key: String { "\(kind.rawValue):\(id)" }
    static let pendingPrefix = "catalog:"
    var isPending: Bool { kind == .integration && !connected }
}

struct MentionSection: Identifiable, Equatable {
    let group: MentionGroup
    var entries: [MentionEntry]
    var id: MentionGroup { group }
}

/// Which rows the menu lists for what is typed after the `@`.
enum MentionSearch {
    /// Most rows one group lists while the group itself is not named.
    static let perGroup: [MentionGroup: Int] = [.services: 6, .agents: 6, .files: 8, .browser: 5]
    /// Most rows of a group named in full ("@files"): the group's whole shelf.
    static let namedGroupLimit = 12

    /// The sections for `query`. `files` are already the daemon's answer for the query (names that contain it), so
    /// they are not filtered again; the other lists are filtered by name, English name and aliases. A query that finds
    /// a group by its name or alias (`@сервисы`, `@files`) lists the group's rows.
    static func sections(
        query: String, services: [MentionEntry], agents: [MentionEntry], files: [MentionEntry],
        tabs: [MentionEntry]
    ) -> [MentionSection] {
        let lists: [(MentionGroup, [MentionEntry])] = [
            (.services, services), (.agents, agents), (.files, files), (.browser, tabs),
        ]
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return lists.compactMap { group, rows in
            let named = !typed.isEmpty && SearchFolding.matches(query: typed, candidates: group.searchWords)
            var kept: [MentionEntry]
            if typed.isEmpty || named || group == .files {
                kept = rows
            } else {
                kept = rows.filter { SearchFolding.matches(query: typed, candidates: [$0.label] + $0.searchWords) }
            }
            if group == .services {
                // The connected ones come first; each side keeps its order.
                kept = kept.filter(\.connected) + kept.filter { !$0.connected }
            }
            let limit = named && !typed.isEmpty ? namedGroupLimit : (perGroup[group] ?? 6)
            kept = Array(kept.prefix(limit))
            return kept.isEmpty ? nil : MentionSection(group: group, entries: kept)
        }
    }

    static func flatten(_ sections: [MentionSection]) -> [MentionEntry] {
        sections.flatMap(\.entries)
    }
}

/// Tells whether the draft ends in an `@word` being typed.
enum MentionTrigger {
    struct Match: Equatable {
        /// What is typed after the `@`.
        let query: String
        /// The `@` and the query, in the draft.
        let range: Range<String.Index>
    }

    /// Longest query that still counts as a mention being typed.
    static let maxQuery = 40

    /// The `@` that starts the last word of the draft, when it stands at the start or after a space. The caret is
    /// taken to be at the end of the draft. `nil` for an address (`a@b.c`), for `@` followed by a space, and for a
    /// word that is not the last.
    static func match(in draft: String) -> Match? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at != draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        let query = draft[draft.index(after: at)...]
        guard !query.contains(where: { $0.isWhitespace }), query.count <= maxQuery else { return nil }
        return Match(query: String(query), range: at..<draft.endIndex)
    }
}

/// A mention in a draft. A service that is not connected yet waits for the owner's yes to connect it.
struct DraftMention: Hashable {
    var mention: Mention
    /// The catalog template to connect, for a service that is not connected; `nil` otherwise.
    var pendingTemplate: String?
}

/// What a pick leaves in the draft, and how a chip leaves it.
enum MentionDraft {
    /// The label of `entry` in the draft: its own, or with a number when another mention already uses it.
    static func uniqueLabel(_ label: String, among list: [DraftMention]) -> String {
        let clean = label.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = clean.isEmpty ? "?" : String(clean.prefix(60))
        let taken = Set(list.map(\.mention.label))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    /// The draft with the typed `@query` replaced by `@Label` and a space, and the list with the new mention. Picking
    /// the same thing again leaves one mention in the list.
    static func insert(
        _ entry: MentionEntry, replacing match: MentionTrigger.Match, in draft: String, list: [DraftMention]
    ) -> (draft: String, list: [DraftMention]) {
        var list = list
        let existing = list.first {
            $0.mention.kind == entry.kind
                && ($0.mention.id == entry.id || ($0.pendingTemplate != nil && $0.pendingTemplate == entry.templateID))
        }
        let label = existing?.mention.label ?? uniqueLabel(entry.label, among: list)
        if existing == nil {
            list.append(
                DraftMention(
                    mention: Mention(kind: entry.kind, id: entry.id, label: label),
                    pendingTemplate: entry.isPending ? entry.templateID : nil))
        }
        var text = draft
        text.replaceSubrange(match.range, with: "@" + label + " ")
        return (text, list)
    }

    /// The mentions whose `@Label` is still in the text, each once. Text the person deleted takes its chip with it.
    static func reconcile(_ list: [DraftMention], in draft: String) -> [DraftMention] {
        list.filter { draft.contains($0.mention.token) }
    }

    /// Backspace at the end of the draft over a chip: the whole `@Label` goes (and the space after it), and the
    /// mention with it. `nil` when the draft does not end in a chip, so the key deletes one character as usual.
    static func removeTrailingChip(draft: String, list: [DraftMention]) -> (draft: String, list: [DraftMention])? {
        var body = Substring(draft)
        if body.last == " " { body = body.dropLast() }
        // The longest label first, so "@Google Drive" is not taken for "@Drive".
        for item in list.sorted(by: { $0.mention.token.count > $1.mention.token.count }) {
            let token = item.mention.token
            guard body.hasSuffix(token) else { continue }
            let start = body.index(body.endIndex, offsetBy: -token.count)
            if start != body.startIndex, !body[body.index(before: start)].isWhitespace { continue }
            let rest = String(body[..<start])
            return (rest, list.filter { $0 != item })
        }
        return nil
    }

    /// The first service in the list that is not connected, which the send waits on.
    static func pendingService(in list: [DraftMention]) -> DraftMention? {
        list.first { $0.pendingTemplate != nil }
    }

    /// The service connected now: its mention gets the integration's id and stops waiting.
    static func connected(_ list: [DraftMention], template: String, integrationID: String) -> [DraftMention] {
        list.map { item in
            guard item.pendingTemplate == template else { return item }
            var done = item
            done.mention.id = integrationID
            done.pendingTemplate = nil
            return done
        }
    }

    /// What goes to the daemon: the mentions that are in the text and are ready.
    static func wire(_ list: [DraftMention], in text: String) -> [Mention] {
        reconcile(list, in: text).filter { $0.pendingTemplate == nil }.map(\.mention)
    }
}

/// The rows of the menu that the server's lists and the typed word make. Pure, so the order and the caps are tested.
enum MentionSources {
    /// The services: the connected ones the agent may use, then the catalog entries that are not connected.
    static func services(
        catalog: [IntegrationCatalogEntry], integrations: [Integration], agent: Agent, languageCode: String
    ) -> [MentionEntry] {
        let allowed = agent.integrations.map(Set.init)
        var rows: [MentionEntry] = []
        for entry in MarketLogic.entries(catalog: catalog, integrations: integrations, languageCode: languageCode) {
            if let integration = entry.integration {
                guard integration.enabled, allowed?.contains(integration.id) ?? true else { continue }
                rows.append(
                    MentionEntry(
                        kind: .integration, id: integration.id, label: entry.name,
                        detail: entry.isOwn ? nil : entry.description,
                        searchWords: [integration.name, entry.template?.id ?? ""].filter { !$0.isEmpty },
                        connected: true, templateID: entry.template?.id, market: entry))
            } else if let template = entry.template, !entry.isOwn {
                rows.append(
                    MentionEntry(
                        kind: .integration, id: MentionEntry.pendingPrefix + template.id, label: entry.name,
                        detail: entry.description, searchWords: [template.id], connected: false,
                        templateID: template.id, market: entry))
            }
        }
        return rows
    }

    /// The teammates, other than the one in this chat, in the sidebar's order.
    static func agents(_ agents: [Agent], excluding current: String) -> [MentionEntry] {
        agents.filter { $0.id != current }.map {
            MentionEntry(kind: .agent, id: $0.id, label: $0.name, detail: $0.role.isEmpty ? nil : $0.role)
        }
    }

    /// Files and folders found under the agent's folder. Hidden ones are left out.
    static func files(_ found: [FsEntry], root: String) -> [MentionEntry] {
        found.filter { !$0.hidden }.map {
            MentionEntry(
                kind: .file, id: $0.path, label: $0.name, detail: relative($0.path, to: root),
                fileKind: $0.kind, fileExt: $0.ext)
        }
    }

    /// The open pages of the browser. A page without a title is named by its address.
    static func tabs(_ tabs: [BrowserTab]) -> [MentionEntry] {
        tabs.filter(\.isPage).map {
            let title = $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = URL(string: $0.url)?.host ?? $0.url
            return MentionEntry(
                kind: .browserTab, id: $0.id, label: title.isEmpty ? host : title, detail: $0.url,
                searchWords: [host])
        }
    }

    /// The folder a file is in, relative to the agent's folder; the path as it is when it lies outside.
    static func relative(_ path: String, to root: String) -> String {
        let base = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(base) else { return path }
        let rest = String(path.dropFirst(base.count))
        let folder = (rest as NSString).deletingLastPathComponent
        return folder.isEmpty ? "./" : folder
    }
}
