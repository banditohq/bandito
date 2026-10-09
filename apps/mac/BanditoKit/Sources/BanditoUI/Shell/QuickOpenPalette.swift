import BanditoDesign
import Foundation
import BanditoKit
import BanditoL10n
import SwiftUI

/// The quick-open palette (⌘K, docs/design/Palette.dc.html). One search field over the agents of every
/// server, a few actions, the files of the selected agent's folder, and open terminals and ports.
struct QuickOpenPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(Router.self) private var router

    @State private var query = ""
    @State private var selected = 0
    @State private var files: [FsEntry] = []
    @State private var terminals: [PaletteTerminal] = []
    @State private var ports: [PalettePort] = []
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }
            panel
                .padding(.top, 70)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
        .onAppear { focused = true }
        .task {
            terminals = await loadTerminals()
            ports = await loadPorts()
        }
        .task(id: query) {
            // Files of the selected agent's folder: debounced, and cancelled when the query changes.
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let server = selectedAgentServer,
                let cwd = selectedAgent?.cwd
            else {
                files = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            files = (try? await server.search(root: cwd, query: query, limit: 20)) ?? []
        }
        .onChange(of: query) { _, _ in selected = 0 }
    }

    // MARK: Panel

    private var panel: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.title) { section in
                        Text(section.title)
                            .font(BanditoFont.font(size: 10.5, weight: 600))
                            .tracking(0.8)
                            .foregroundStyle(Color.Bandito.text3)
                            .padding(.horizontal, 10)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                        ForEach(section.rows) { row in
                            rowView(row, index: rowIndex(of: row))
                        }
                    }
                    if rows.isEmpty {
                        Text(L10n.Palette.noResults)
                            .font(BanditoFont.font(size: 13, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 460)
            hintBar
        }
        .frame(width: 660)
        .background(
            Color(hex: 0x1E1A16).opacity(0.97), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.Bandito.text.opacity(0.12)))
        .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: 20)
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape]) { press in
            switch press.key {
            case .upArrow: move(-1)
            case .downArrow: move(1)
            case .escape: close()
            default: activate(rows.indices.contains(selected) ? rows[selected] : nil)
            }
            return .handled
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17))
                .foregroundStyle(Color.Bandito.text2)
            TextField(L10n.Palette.search, text: $query)
                .textFieldStyle(.plain)
                .font(BanditoFont.font(size: 17, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .focused($focused)
            Spacer(minLength: 8)
            Text(L10n.Palette.fieldHint)
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Text("esc")
                .font(BanditoFont.font(size: 11, weight: 400, mono: true))
                .foregroundStyle(Color.Bandito.text2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.Bandito.text.opacity(0.14)))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var hintBar: some View {
        HStack(spacing: 16) {
            Text(L10n.Palette.hintSelect)
            Text(L10n.Palette.hintOpen)
            Text(L10n.Palette.hintMessage)
            Spacer(minLength: 0)
            Text(L10n.Palette.footerCounts(
                servers: L10n.Common.serverCount(count: app.servers.count),
                agents: L10n.Common.agentCount(count: allAgents.count)))
        }
        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.07)).frame(height: 1)
        }
    }

    private func rowView(_ row: PaletteRow, index: Int) -> some View {
        let isSelected = index == selected
        return Button {
            row.run()
        } label: {
            HStack(spacing: 12) {
                row.leading
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlighted(row.title, row.ranges))
                        .font(BanditoFont.font(size: 13.5, weight: 600))
                        .foregroundStyle(row.enabled ? Color.Bandito.text : Color.Bandito.text3)
                        .lineLimit(1)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(BanditoFont.font(size: 12, weight: 400, mono: row.monoSubtitle))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let trailing = row.trailing {
                    Text(trailing)
                        .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
                        .foregroundStyle(Color.Bandito.text3)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.Bandito.text.opacity(0.07) : Color.clear,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!row.enabled)
        .onHover { hovering in
            if hovering, let index = rows.firstIndex(where: { $0.id == row.id }) { selected = index }
        }
    }

    // MARK: Rows

    private struct Section {
        let title: String
        let rows: [PaletteRow]
    }

    private var sections: [Section] {
        let all = rows
        var result: [Section] = []
        for section in PaletteRow.Kind.allCases {
            let inSection = all.filter { $0.kind == section }
            if !inSection.isEmpty {
                result.append(Section(title: section.title, rows: inSection))
            }
        }
        return result
    }

    /// Every row in display order: agents, actions, files and terminals. Arrow keys walk this list.
    private var rows: [PaletteRow] {
        agentRows + actionRows + fileRows + terminalRows + portRows
    }

    private func rowIndex(of row: PaletteRow) -> Int {
        rows.firstIndex { $0.id == row.id } ?? 0
    }

    private var allAgents: [(server: ServerModel, agent: Agent)] {
        app.servers.flatMap { server in server.agents.map { (server: server, agent: $0) } }
    }

    private var agentRows: [PaletteRow] {
        let matches = FuzzyMatch.rank(query, allAgents) { $0.agent.name }
        return matches.map { ranked in
            let entry = ranked.item
            let folder = FolderPickerLogic.name(of: entry.agent.cwd)
            let status = entry.server.thread(for: entry.agent.id).status
            return PaletteRow(
                id: "agent-\(entry.server.id)-\(entry.agent.id)",
                kind: .agents,
                title: entry.agent.name,
                ranges: ranked.match.ranges,
                subtitle: [entry.agent.role, entry.agent.runtime.rawValue, folder].filter { !$0.isEmpty }
                    .joined(separator: " · "),
                monoSubtitle: false,
                leading: AnyView(AgentAvatar(name: entry.agent.name, size: 32, mood: .idle)),
                trailing: status == .needsYou ? L10n.Palette.needsYou : nil,
                enabled: true,
                run: { openAgent(entry.server, entry.agent) })
        }
    }

    private var actionRows: [PaletteRow] {
        var actions: [(id: String, title: String, symbol: String, enabled: Bool, run: () -> Void)] = [
            (
                "action-new-agent",
                query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? L10n.Sidebar.newAgent : L10n.Palette.newAgentNamed(name: query),
                "plus", true,
                { close(); router.sheet = .newAgent }
            ),
        ]
        if let agent = selectedAgent {
            actions.append((
                "action-pause", L10n.Palette.pauseAgent(name: agent.name), "pause", false, {}
            ))
            actions.append((
                "action-terminal", L10n.Palette.newTerminalHere(name: agent.name), "terminal", true,
                {
                    close()
                    router.pendingTerminalCwd = agent.cwd
                    router.select(mode: .terminals)
                }
            ))
            actions.append((
                "action-files", L10n.Palette.openFilesOf(name: agent.name), "folder", true,
                {
                    close()
                    router.filesPath = agent.cwd
                    router.select(mode: .files)
                }
            ))
        }
        return actions.compactMap { action in
            let match = FuzzyMatch.match(query, in: action.title)
            guard match != nil || query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return PaletteRow(
                id: action.id, kind: .actions, title: action.title, ranges: match?.ranges ?? [],
                subtitle: nil, monoSubtitle: false,
                leading: AnyView(IconTile(symbol: action.symbol)), trailing: nil,
                enabled: action.enabled, run: action.run)
        }
    }

    private var fileRows: [PaletteRow] {
        files.map { entry in
            let parent = (entry.path as NSString).deletingLastPathComponent
            return PaletteRow(
                id: "file-\(entry.path)", kind: .files, title: entry.name,
                ranges: FuzzyMatch.match(query, in: entry.name)?.ranges ?? [], subtitle: parent,
                monoSubtitle: true,
                leading: AnyView(IconTile(symbol: entry.kind == .dir ? "folder" : "doc")),
                trailing: L10n.Palette.tagFile, enabled: true,
                run: {
                    close()
                    router.filesPath = parent
                    router.select(mode: .files)
                })
        }
    }

    private var terminalRows: [PaletteRow] {
        let matches = FuzzyMatch.rank(query, terminals) { $0.info.title }
        return matches.map { ranked in
            let item = ranked.item
            return PaletteRow(
                id: "terminal-\(item.server.id)-\(item.info.id)", kind: .files, title: item.info.title,
                ranges: ranked.match.ranges, subtitle: item.info.cwd, monoSubtitle: true,
                leading: AnyView(IconTile(symbol: "terminal")), trailing: L10n.Palette.tagTerminal,
                enabled: true,
                run: {
                    close()
                    app.selectedServerID = item.server.id
                    router.terminalID = item.info.id
                    router.select(mode: .terminals)
                })
        }
    }

    private var portRows: [PaletteRow] {
        let matches = ports.compactMap { port -> (PalettePort, FuzzyMatch.Match)? in
            let text = "\(port.port) \(port.process)"
            return FuzzyMatch.match(query, in: text).map { (port, $0) }
        }
        return matches.map { port, match in
            PaletteRow(
                id: "port-\(port.server.id)-\(port.port)", kind: .files,
                title: L10n.Palette.portTitle(port: "\(port.port)", process: port.process),
                ranges: match.ranges, subtitle: port.server.config.name, monoSubtitle: false,
                leading: AnyView(IconTile(symbol: "globe", tint: Color.Bandito.ok)),
                trailing: L10n.Palette.tagPort, enabled: true,
                run: {
                    close()
                    router.select(mode: .server)
                })
        }
    }

    // MARK: Actions

    private func openAgent(_ server: ServerModel, _ agent: Agent) {
        app.selectedServerID = server.id
        router.selectedAgentID = agent.id
        router.select(mode: .team)
        close()
    }

    private func activate(_ row: PaletteRow?) {
        guard let row, row.enabled else { return }
        row.run()
    }

    private func move(_ step: Int) {
        let count = rows.count
        guard count > 0 else { return }
        selected = (selected + step + count) % count
    }

    private func close() {
        router.paletteOpen = false
    }

    // MARK: Helpers

    /// The agent the Team mode has open, which the palette's actions and file search act on.
    private var selectedAgent: Agent? {
        guard let id = router.selectedAgentID else { return nil }
        return allAgents.first { $0.agent.id == id }?.agent
    }

    private var selectedAgentServer: ServerModel? {
        guard let id = router.selectedAgentID else { return nil }
        return allAgents.first { $0.agent.id == id }?.server
    }

    private func loadTerminals() async -> [PaletteTerminal] {
        guard let server = app.currentServer, server.supports("terminals") else { return [] }
        let list = (try? await server.terminals()) ?? []
        return list.map { PaletteTerminal(server: server, info: $0) }
    }

    private func loadPorts() async -> [PalettePort] {
        guard let server = app.currentServer, server.supports("host") else { return [] }
        let found = (try? await server.hostPorts())?.ports ?? []
        return found.map { PalettePort(server: server, port: $0.port, process: $0.process ?? "") }
    }

    private func highlighted(_ text: String, _ ranges: [Range<Int>]) -> AttributedString {
        var result = AttributedString(text)
        for range in ranges {
            let lower = result.index(result.startIndex, offsetByCharacters: range.lowerBound)
            let upper = result.index(result.startIndex, offsetByCharacters: range.upperBound)
            result[lower..<upper].foregroundColor = BanditoPalette.peach
        }
        return result
    }
}

/// One line of the palette.
private struct PaletteRow: Identifiable {
    enum Kind: CaseIterable {
        case agents, actions, files

        var title: String {
            switch self {
            case .agents: L10n.Palette.sectionAgents
            case .actions: L10n.Palette.sectionActions
            case .files: L10n.Palette.sectionFiles
            }
        }
    }

    let id: String
    let kind: Kind
    let title: String
    let ranges: [Range<Int>]
    let subtitle: String?
    let monoSubtitle: Bool
    let leading: AnyView
    let trailing: String?
    let enabled: Bool
    let run: () -> Void

    init(
        id: String, kind: Kind, title: String, ranges: [Range<Int>], subtitle: String?, monoSubtitle: Bool,
        leading: AnyView, trailing: String?, enabled: Bool, run: @escaping () -> Void
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.ranges = ranges
        self.subtitle = subtitle
        self.monoSubtitle = monoSubtitle
        self.leading = leading
        self.trailing = trailing
        self.enabled = enabled
        self.run = run
    }
}

private struct PaletteTerminal {
    let server: ServerModel
    let info: TermInfo
}

private struct PalettePort {
    let server: ServerModel
    let port: Int
    let process: String
}

/// A rounded square with a symbol, the leading icon of action and file rows.
private struct IconTile: View {
    let symbol: String
    var tint: Color = Color.Bandito.text2

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
