import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI

/// What one composer's slash menu knows: the server's commands, the commands on this Mac, the saved
/// snippets, and which row is selected. The composer runs what the person picks.
@MainActor
@Observable
final class SlashMenuModel {
    var filter: SlashSourceFilter = .all
    var index = 0
    /// Set by Escape. The menu stays closed until the draft changes.
    var suppressed = false
    /// Shown above the field: an error, or "soon" for commands that are not built yet.
    var notice: UserFacingMessage?
    /// A command from this Mac waiting for the person's yes to install it on the server.
    var pendingInstall: MacCommand?
    var serverCommands: [AgentCommand] = []
    var macCommands: [MacCommand] = []
    var snippets: [Snippet] = SnippetStore.load()
    var editingSnippet = false

    func entries(query: String) -> [SlashEntry] {
        SlashMatcher.filter(allEntries, query: query, source: filter)
    }

    var allEntries: [SlashEntry] {
        SlashCatalog.entries(server: serverCommands, mac: macCommands, snippets: snippets)
    }

    /// How many entries each filter chip shows, ignoring the typed name.
    func count(for filter: SlashSourceFilter) -> Int {
        allEntries.filter { filter.includes($0.origin) }.count
    }

    /// The Mac command with this name, when the server does not have it yet.
    func macCommandToInstall(named name: String) -> MacCommand? {
        guard !serverCommands.contains(where: { $0.name == name }) else { return nil }
        return macCommands.first { $0.name == name }
    }

    func loadServerCommands(server: ServerModel, agentID: String) async {
        guard server.supports("commands") else {
            serverCommands = []
            return
        }
        serverCommands = (try? await server.commands(agentID: agentID)) ?? []
    }

    func loadMacCommands() async {
        macCommands = await Task.detached(priority: .utility) {
            MacCommandScanner.scan(
                claudeHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
        }.value
    }

    func saveSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.name == snippet.name }
        snippets.append(snippet)
        SnippetStore.save(snippets)
    }
}

/// The list above the composer. Filter chips on top, rows grouped by source, a footer with the keys.
struct SlashMenuView: View {
    var entries: [SlashEntry]
    var model: SlashMenuModel
    var onRun: (SlashEntry) -> Void
    var onNewSnippet: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            filters
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if entries.isEmpty {
                        Text(L10n.Slash.none)
                            .font(BanditoFont.text(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 22)
                    }
                    ForEach(SlashOrigin.allCases, id: \.self) { origin in
                        let group = entries.enumerated().filter { $0.element.origin == origin }
                        if !group.isEmpty {
                            Text(groupTitle(origin))
                                .font(BanditoFont.text(size: 10.5, weight: 600))
                                .tracking(0.8)
                                .foregroundStyle(Color.Bandito.text3)
                                .padding(.horizontal, 10)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                            ForEach(group, id: \.element.id) { item in
                                Button { onRun(item.element) } label: {
                                    row(item.element, selected: item.offset == model.index)
                                }
                                .banditoButton(.row(cornerRadius: 8))
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 340)
            footer
        }
        .frame(maxWidth: 640)
        .background(Color(hex: 0x201C18).opacity(0.98), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.Bandito.text.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 14)
    }

    private var filters: some View {
        HStack(spacing: 4) {
            ForEach(SlashSourceFilter.allCases, id: \.self) { filter in
                let on = model.filter == filter
                Button {
                    model.filter = filter
                    model.index = 0
                } label: {
                    HStack(spacing: 4) {
                        Text(filterTitle(filter))
                        Text("\(model.count(for: filter))").opacity(0.6)
                    }
                    .font(BanditoFont.text(size: 12, weight: on ? 600 : 400))
                    .foregroundStyle(on ? Color.Bandito.text : Color.Bandito.text3)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(on ? Color(hex: 0x2C2722) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .banditoButton(.row(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private func row(_ entry: SlashEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text(glyph(entry.origin))
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(tint(entry.origin))
                .frame(width: 26, height: 26)
                .background(tint(entry.origin).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text("/" + entry.name)
                .font(BanditoFont.mono(size: 13, weight: 400))
                .foregroundStyle(selected ? BanditoPalette.peach : Color.Bandito.text)
                .lineLimit(1)
            if let hint = entry.argsHint, !hint.isEmpty {
                Text(hint)
                    .font(BanditoFont.mono(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
            }
            Text(entry.description ?? "")
                .font(BanditoFont.text(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(sourceTitle(entry.origin))
                .font(BanditoFont.text(size: 10.5, weight: 600))
                .foregroundStyle(tint(entry.origin))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(tint(entry.origin).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            selected ? BanditoPalette.peach.opacity(0.1) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? BanditoPalette.peach.opacity(0.3) : Color.clear))
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text(L10n.Slash.footerSelect)
            Text(L10n.Slash.footerRun)
            Text(L10n.Slash.footerComplete)
            Spacer(minLength: 8)
            Button(L10n.Slash.newSnippet, action: onNewSnippet)
                .banditoButton(.link)
                .foregroundStyle(BanditoPalette.peach)
        }
        .font(BanditoFont.text(size: 11.5, weight: 400))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.07)).frame(height: 1)
        }
    }

    private func filterTitle(_ filter: SlashSourceFilter) -> String {
        switch filter {
        case .all: L10n.Slash.filterAll
        case .server: L10n.Slash.filterServer
        case .mac: L10n.Slash.filterMac
        case .bandito: L10n.Slash.filterBandito
        case .mine: L10n.Slash.filterMine
        }
    }

    private func groupTitle(_ origin: SlashOrigin) -> String {
        switch origin {
        case .server: L10n.Slash.groupServer
        case .mac: L10n.Slash.groupMac
        case .bandito: L10n.Slash.groupBandito
        case .mine: L10n.Slash.groupMine
        }
    }

    private func sourceTitle(_ origin: SlashOrigin) -> String {
        switch origin {
        case .server: L10n.Slash.sourceServer
        case .mac: L10n.Slash.sourceMac
        case .bandito: L10n.Slash.sourceBandito
        case .mine: L10n.Slash.sourceMine
        }
    }

    private func glyph(_ origin: SlashOrigin) -> String {
        switch origin {
        case .server: "✓"
        case .mac: "⌘"
        case .bandito: "§"
        case .mine: "✎"
        }
    }

    private func tint(_ origin: SlashOrigin) -> Color {
        switch origin {
        case .server: Color(hex: 0xA9C7A2)
        case .mac: Color(hex: 0xA3BDEB)
        case .bandito: BanditoPalette.peach
        case .mine: Color(hex: 0xC8B6E8)
        }
    }
}

/// Creates a snippet: a name and a text with `{placeholders}`.
struct SnippetEditor: View {
    var onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Slash.snippetTitle)
                .font(BanditoFont.display(size: 15.5, weight: 600))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Color.Bandito.text)
            TextField(L10n.Slash.snippetName, text: $name)
                .banditoField()
            TextEditor(text: $text)
                .font(BanditoFont.text(size: 13, weight: 400))
                .frame(height: 120)
                .banditoEditor()
            Text(L10n.Slash.snippetHint)
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            HStack {
                Spacer()
                Button(L10n.Common.cancel) { dismiss() }
                    .banditoButton(.quiet())
                Button(L10n.Common.save) {
                    onSave(Snippet(name: normalizedName, text: text))
                    dismiss()
                }
                .banditoButton(.signal())
                .disabled(!isValid)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Color.Bandito.surface2)
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Names are typed after a slash, so they follow the same rules as command names.
    private var isValid: Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        return !normalizedName.isEmpty
            && normalizedName.allSatisfy { allowed.contains($0) }
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
