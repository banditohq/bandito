import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI

/// What one composer's `@` menu knows: the services, the open browser tabs, the files found for what is typed, the
/// selected row, and the connect step of a service that is not connected. The composer picks and sends.
@MainActor
@Observable
final class MentionMenuModel {
    var index = 0
    /// Set by Escape. The menu stays closed until the draft changes.
    var suppressed = false
    private(set) var services: [MentionEntry] = []
    private(set) var tabs: [MentionEntry] = []
    private(set) var files: [MentionEntry] = []
    /// An error to show above the field.
    var notice: UserFacingMessage?
    /// A service in the draft that is not connected: "Connect X?" waits above the field for the owner's yes.
    var connectPrompt: DraftMention?
    /// A sign-in or a sheet of keys that this composer started, for the service with this template id. The send
    /// goes on when it ends well.
    var connecting: Connecting?
    /// The sheet of keys of a service that signs in with a key.
    var editing: IntegrationCatalogEntry?

    struct Connecting: Equatable {
        var template: String
        /// The integrations there were before, to tell the new one from them.
        var known: Set<String>
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Reads what the menu lists besides the files: the services and the open pages of the browser. Called when the
    /// menu opens.
    func opened(server: ServerModel, agent: Agent) async {
        await MentionServices.shared.ensure(server, force: true)
        refreshServices(server: server, agent: agent)
        let found = await Self.browserTabs(server: server)
        if found != tabs { tabs = found }
    }

    /// Lists the services again from what is known (after a connect, or a change of the agent).
    func refreshServices(server: ServerModel, agent: Agent) {
        guard server.supports("integrations"), let snapshot = MentionServices.shared.snapshot(for: server) else {
            if !services.isEmpty { services = [] }
            return
        }
        let rows = MentionSources.services(
            catalog: snapshot.catalog, integrations: snapshot.integrations, agent: agent,
            languageCode: ModelDescription.currentLanguageCode)
        if rows != services { services = rows }
    }

    /// The pages of the server's browser, when it runs. Nothing when it does not, or when the daemon is older.
    private static func browserTabs(server: ServerModel) async -> [MentionEntry] {
        guard server.supports("browser"),
            let status = try? await server.browserStatus(), status.isRelay,
            let pages = try? await server.browserTabs()
        else { return [] }
        return MentionSources.tabs(pages)
    }

    /// Looks for files under the agent's folder for the typed word, after a short pause. An empty word, or the
    /// name of the group ("@files"), lists the folder itself. An answer to an older word is dropped.
    func updateFiles(query: String, server: ServerModel, agent: Agent) {
        searchTask?.cancel()
        generation += 1
        let mine = generation
        guard server.supports("files"), agent.cwd.hasPrefix("/") else {
            if !files.isEmpty { files = [] }
            return
        }
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = word.isEmpty || SearchFolding.matches(query: word, candidates: MentionGroup.files.searchWords)
        let root = agent.cwd
        searchTask = Task { [weak self] in
            if !listing { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            let found: [FsEntry]
            do {
                if listing {
                    found = try await server.list(root).entries
                } else {
                    found = try await server.search(root: root, query: word, limit: 12)
                }
            } catch {
                found = []
            }
            guard !Task.isCancelled, let self, self.generation == mine else { return }
            let rows = MentionSources.files(found, root: root)
            if rows != self.files { self.files = rows }
        }
    }

    /// The menu closed: a search still on its way has nothing to show.
    func closed() {
        searchTask?.cancel()
        searchTask = nil
        generation += 1
        if !files.isEmpty { files = [] }
    }
}

/// The list above the composer for `@`. Rows are grouped (services, agents, files, browser); the keys are the slash
/// menu's.
struct MentionMenuView: View {
    var sections: [MentionSection]
    var selectedKey: String?
    var server: ServerModel?
    var onPick: (MentionEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(sections) { section in
                        ComposerMenuGroupTitle(text: section.group.title)
                        ForEach(section.entries) { entry in
                            Button { onPick(entry) } label: {
                                row(entry, selected: entry.key == selectedKey)
                            }
                            .banditoButton(.row(cornerRadius: 8))
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            ComposerMenuFooter(
                hints: [L10n.Slash.footerSelect, L10n.Mention.footerInsert, L10n.Slash.footerComplete]
            ) { EmptyView() }
        }
        .composerMenuSurface()
    }

    private func row(_ entry: MentionEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            icon(entry)
                .frame(width: 26, height: 26)
            Text(entry.label)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(selected ? BanditoPalette.peach : Color.Bandito.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(entry.detail ?? "")
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.isPending {
                Text(L10n.Integrations.connect)
                    .font(BanditoFont.text(size: 10.5, weight: 600))
                    .foregroundStyle(BanditoPalette.peach)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(BanditoPalette.peach.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .composerMenuRow(selected: selected)
    }

    @ViewBuilder
    private func icon(_ entry: MentionEntry) -> some View {
        MentionIcon(entry: entry, server: server, size: 26)
    }
}

/// The picture of a mention, in the menu and in a chip: a service's logo tile, an agent's avatar, a file's glyph, or
/// the browser mark.
struct MentionIcon: View {
    var kind: MentionKind
    var market: MarketEntry?
    var agent: Agent?
    var fileKind: FsEntryKind?
    var fileExt: String?
    var name: String
    var server: ServerModel?
    var size: CGFloat

    init(entry: MentionEntry, server: ServerModel?, size: CGFloat) {
        kind = entry.kind
        market = entry.market
        agent = entry.kind == .agent ? server?.agents.first { $0.id == entry.id } : nil
        fileKind = entry.fileKind
        fileExt = entry.fileExt
        name = entry.label
        self.server = server
        self.size = size
    }

    init(mention: Mention, market: MarketEntry?, server: ServerModel?, size: CGFloat) {
        kind = mention.kind
        self.market = market
        agent = mention.kind == .agent ? server?.agents.first { $0.id == mention.id } : nil
        fileKind = nil
        fileExt = (mention.label as NSString).pathExtension.lowercased()
        name = mention.label
        self.server = server
        self.size = size
    }

    var body: some View {
        switch kind {
        case .integration:
            if let market {
                MarketTile(entry: market, size: size)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(BanditoFont.display(size: size * 0.42, weight: 700))
                    .foregroundStyle(Color.Bandito.text2)
                    .frame(width: size, height: size)
                    .background(Color.Bandito.surface3, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            }
        case .agent:
            if let agent {
                AgentAvatarView(agent: agent, server: server, size: size)
            } else {
                symbol("person.fill")
            }
        case .file:
            // A folder is told by its kind; for a chip only the name is known, and a name with no extension is a file.
            let category = FileTypes.category(name: name, ext: fileExt, kind: fileKind ?? .file)
            FileGlyph(category: category, size: size)
        case .browserTab:
            symbol("safari")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Color(hex: 0xA3BDEB))
            .frame(width: size, height: size)
            .background(Color(hex: 0xA3BDEB).opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}
