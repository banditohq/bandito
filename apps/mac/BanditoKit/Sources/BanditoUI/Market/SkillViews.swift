import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

// The Skills page of the Marketplace: the cards, the page of one skill, and the sheet that installs it.

/// A skill's tile: the first letter of its name on a stable palette colour. Cream is left out: the white letter
/// does not read on it.
struct SkillTile: View {
    let skill: SkillEntry
    let size: CGFloat
    var glow = false

    private static let palette: [AvatarColor] = [.peach, .sky, .sage, .rose, .lilac]

    private var color: Color {
        Self.palette[MarketTileStyle.paletteIndex(for: skill.id, count: Self.palette.count)].color
    }

    var body: some View {
        MarketTileSurface(color: color, size: size, glow: glow) {
            Text(String(skill.name.prefix(1)).uppercased())
                .font(BanditoFont.display(size: size * 0.42, weight: 700))
        }
    }
}

/// The reasons an install target is not offered, in words.
enum SkillText {
    static func conflictEveryone() -> String { L10n.Market.Skill.conflictEveryone }

    static func conflictAgent(_ name: String) -> String { L10n.Market.Skill.conflictAgent(agent: name) }

    static func block(_ block: SkillLogic.Block) -> String {
        switch block {
        case .installed: L10n.Market.Skill.installed
        case .conflict: L10n.Market.Skill.nameTaken
        }
    }

    /// An install or remove that failed: the daemon's reason in words the person can act on, else the generic one.
    static func message(for error: Error) -> UserFacingMessage {
        switch SkillLogic.failure(for: error) {
        case .folderNotOurs: UserFacingMessage(text: L10n.Market.Skill.Error.notOurs)
        case .notInstalled: UserFacingMessage(text: L10n.Market.Skill.Error.notInstalled)
        case .unsafePath: UserFacingMessage(text: L10n.Market.Skill.Error.unsafePath)
        case nil: UserFacingError.message(for: error)
        }
    }
}

// MARK: - the page

struct SkillsPage: View {
    let model: SkillsMarketModel
    let query: String
    let languageCode: String
    let agents: [Agent]
    var onView: (SkillEntry) -> Void
    var onInstall: (SkillEntry) -> Void
    var onRemoveEverywhere: (SkillEntry) -> Void
    var onUpdate: (SkillEntry) -> Void
    var onRetry: () -> Void

    @Environment(Router.self) private var router

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        let shown = SkillLogic.visible(
            model.skills, filter: router.marketSkillFilter, query: query, languageCode: languageCode)
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(L10n.Market.Skills.catalog)
            if !shown.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(shown) { skill in
                        SkillCard(
                            skill: skill, languageCode: languageCode,
                            canInstall: SkillLogic.canInstall(skill, agents: agents),
                            updating: model.busy.contains { $0.hasPrefix(skill.id + "|") },
                            onView: { onView(skill) }, onInstall: { onInstall(skill) },
                            onRemove: { onRemoveEverywhere(skill) }, onUpdate: { onUpdate(skill) })
                    }
                }
            } else if let failure = model.failure {
                UserFacingErrorView(message: failure, onRetry: onRetry)
            } else if model.loaded {
                Text(emptyText)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .padding(.vertical, 6)
            }
        }
    }

    private var emptyText: String {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.Market.noResults }
        return router.marketSkillFilter == .installed ? L10n.Market.Skills.noneInstalled : L10n.Market.Skills.empty
    }
}

struct SkillCard: View {
    let skill: SkillEntry
    let languageCode: String
    let canInstall: Bool
    /// An install or an update of this skill is running.
    var updating = false
    var onView: () -> Void
    var onInstall: () -> Void
    var onRemove: () -> Void
    var onUpdate: () -> Void = {}

    var body: some View {
        let state = SkillLogic.State(skill)
        MarketCardFrame {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SkillTile(skill: skill, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(skill.name)
                            .font(BanditoFont.text(size: 14, weight: 600))
                            .foregroundStyle(Color.Bandito.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(byLine)
                            .font(BanditoFont.text(size: 11, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Text(skill.description(languageCode: languageCode))
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                chips(state)
                if let warning = skill.warning(languageCode: languageCode) {
                    Label {
                        Text(warning)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .foregroundStyle(BanditoPalette.peach)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(L10n.Market.view, action: onView)
                        .banditoButton(.quiet())
                        .fixedSize()
                    Spacer(minLength: 0)
                    actions(state)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        }
        .onTapGesture(perform: onView)
    }

    private var byLine: String {
        [skill.publisher.isEmpty ? nil : L10n.Market.Skill.by(publisher: skill.publisher), skill.source.license.isEmpty ? nil : skill.source.license]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func chips(_ state: SkillLogic.State) -> some View {
        if skill.claudeOnly || state.hasConflict {
            HStack(spacing: 6) {
                if skill.claudeOnly { Chip(text: L10n.Market.Skill.claudeOnly) }
                if state.hasConflict { Chip(text: L10n.Market.Skill.nameTaken, tone: .warning) }
            }
        }
    }

    /// Installed for the server: the word and Remove. On some agents: the count and Install. Else Install.
    @ViewBuilder
    private func actions(_ state: SkillLogic.State) -> some View {
        let hasUpdate = SkillLogic.hasUpdate(skill)
        switch state.badge {
        case .installed:
            if hasUpdate {
                updateButton
            } else {
                Label {
                    Text(L10n.Market.Skill.installed)
                } icon: {
                    Image(systemName: "checkmark")
                }
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.ok)
            }
            Button(L10n.Market.Skill.remove, action: onRemove)
                .banditoButton(.link)
                .fixedSize()
        case .onAgents(let count):
            Text(L10n.Market.Skill.onAgents(count: count))
                .font(BanditoFont.text(size: 12.5, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
            if hasUpdate {
                updateButton
            } else if canInstall {
                installButton
            }
        case .none:
            if canInstall { installButton }
        }
    }

    /// The copy of the skill is behind the catalog: Update installs the catalog's copy in the same place.
    private var updateButton: some View {
        Button(updating ? L10n.Market.Update.updating : L10n.Market.Update.button, action: onUpdate)
            .banditoButton(.lightPill())
            .disabled(updating)
            .fixedSize()
    }

    private var installButton: some View {
        Button(L10n.Market.Skill.install, action: onInstall)
            .banditoButton(.lightPill())
            .fixedSize()
    }
}

// MARK: - the page of one skill

struct SkillDetailPanel: View {
    let skill: SkillEntry
    let agents: [Agent]
    let languageCode: String
    /// Removes are running, by `SkillsMarketModel.busyKey`.
    let busy: Set<String>
    var onClose: () -> Void
    var onInstall: () -> Void
    var onRemove: (SkillLogic.Target) -> Void
    var onUpdate: (SkillLogic.Target) -> Void = { _ in }

    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = SkillLogic.State(skill)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(skill.long(languageCode: languageCode))
                        .font(BanditoFont.text(size: 13.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let warning = skill.warning(languageCode: languageCode) {
                        Label {
                            Text(warning).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                        }
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(BanditoPalette.peach)
                    }
                    if state.isInstalled || state.hasConflict { placesSection(state) }
                    filesSection
                    sourceSection
                }
                .padding(24)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)
            MarketPanelFooter {
                Spacer(minLength: 8)
                Button(L10n.Common.close, action: onClose)
                    .banditoButton(.quiet())
                    .fixedSize()
                Button(L10n.Market.Skill.install, action: onInstall)
                    .banditoButton(.signal())
                    .disabled(!SkillLogic.canInstall(skill, agents: agents))
                    .fixedSize()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SkillTile(skill: skill, size: 48, glow: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(skill.name)
                    .font(BanditoFont.display(size: 18, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    Text(
                        [
                            skill.publisher.isEmpty ? nil : L10n.Market.Skill.by(publisher: skill.publisher),
                            skill.source.license.isEmpty ? nil : skill.source.license,
                        ].compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    if skill.claudeOnly { Chip(text: L10n.Market.Skill.claudeOnly) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    /// Where the skill is: the server's folder, the agents' folders, and any folder of the same name that is not
    /// Bandito's (never replaced, so no button for it).
    private func placesSection(_ state: SkillLogic.State) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.Market.Skill.Section.places)
            if state.installedForEveryone {
                placeRow(L10n.Market.Skill.everyone, target: .everyone, update: skill.updates.user)
            }
            ForEach(state.installedAgents, id: \.self) { id in
                placeRow(
                    SkillLogic.agentName(id, agents: agents), target: .agent(id),
                    update: skill.updates.projects.contains(id))
            }
            if state.conflictForEveryone {
                conflictRow(SkillText.conflictEveryone())
            }
            ForEach(state.conflictAgents, id: \.self) { id in
                conflictRow(SkillText.conflictAgent(SkillLogic.agentName(id, agents: agents)))
            }
        }
    }

    private func placeRow(_ title: String, target: SkillLogic.Target, update: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.Bandito.ok)
            Text(title)
                .font(BanditoFont.text(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            let working = busy.contains(SkillsMarketModel.busyKey(skill.id, target))
            if update {
                Chip(text: L10n.Market.Update.available, tone: .info)
                Button(working ? L10n.Market.Update.updating : L10n.Market.Update.button) { onUpdate(target) }
                    .banditoButton(.lightPill())
                    .disabled(working)
                    .fixedSize()
            }
            Button(L10n.Market.Skill.remove) { onRemove(target) }
                .banditoButton(.quiet())
                .disabled(working)
                .fixedSize()
        }
    }

    private func conflictRow(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(BanditoFont.text(size: 12.5, weight: 400))
        .foregroundStyle(BanditoPalette.peach)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(L10n.Market.Skill.Section.files)
            ForEach(skill.files, id: \.self) { file in
                Text(file)
                    .font(BanditoFont.mono(size: 12, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var sourceSection: some View {
        if !skill.source.repo.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L10n.Market.Skill.Section.source)
                if let url = skill.source.url {
                    Link(destination: url) {
                        Label {
                            Text(skill.source.shortReference).font(BanditoFont.mono(size: 12.5, weight: 500))
                        } icon: {
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .foregroundStyle(Color.Bandito.info)
                    .fixedSize()
                } else {
                    Text(skill.source.shortReference)
                        .font(BanditoFont.mono(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
        }
    }
}

// MARK: - installing

/// Where to install: the whole server, or one agent. Targets that are taken (Bandito's copy is there, or another
/// folder is in the way) are listed with the reason and cannot be chosen.
struct SkillInstallPanel: View {
    let skill: SkillEntry
    let agents: [Agent]
    /// Runs the install; nil when it went through, else why not.
    var onInstall: (SkillLogic.Target) async -> Error?
    /// True while the install runs: the panel then cannot be closed.
    @Binding var installing: Bool
    var onClose: () -> Void

    private enum Choice { case everyone, oneAgent }

    @State private var choice: Choice
    @State private var agentID: String
    @State private var error: UserFacingMessage?

    init(
        skill: SkillEntry, agents: [Agent], installing: Binding<Bool>,
        onInstall: @escaping (SkillLogic.Target) async -> Error?, onClose: @escaping () -> Void
    ) {
        _installing = installing
        self.skill = skill
        self.agents = agents
        self.onInstall = onInstall
        self.onClose = onClose
        let start = SkillLogic.defaultTarget(for: skill, agents: agents)
        if case .agent(let id) = start {
            _choice = State(initialValue: .oneAgent)
            _agentID = State(initialValue: id)
        } else {
            _choice = State(initialValue: .everyone)
            _agentID = State(initialValue: agents.first { SkillLogic.block(.agent($0.id), for: skill) == nil }?.id ?? agents.first?.id ?? "")
        }
    }

    private var target: SkillLogic.Target? {
        switch choice {
        case .everyone: .everyone
        case .oneAgent: agentID.isEmpty ? nil : .agent(agentID)
        }
    }

    private var canInstall: Bool {
        guard let target, !installing else { return false }
        return SkillLogic.block(target, for: skill) == nil
    }

    var body: some View {
        let everyoneBlock = SkillLogic.block(.everyone, for: skill)
        let freeAgents = agents.filter { SkillLogic.block(.agent($0.id), for: skill) == nil }
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                SkillTile(skill: skill, size: 40)
                Text(L10n.Market.Skill.installTitle(name: skill.name))
                    .font(BanditoFont.display(size: 16, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                RadioRow(
                    title: L10n.Market.Skill.everyone,
                    description: everyoneBlock.map(SkillText.block) ?? L10n.Market.Skill.everyoneHint,
                    isSelected: choice == .everyone
                ) { choice = .everyone }
                .disabled(everyoneBlock != nil || installing)
                .opacity(everyoneBlock != nil ? 0.5 : 1)
                RadioRow(
                    title: L10n.Market.Skill.oneAgent,
                    description: agents.isEmpty ? L10n.Market.Skill.noAgents : L10n.Market.Skill.oneAgentHint,
                    isSelected: choice == .oneAgent
                ) { choice = .oneAgent }
                .disabled(freeAgents.isEmpty || installing)
                .opacity(freeAgents.isEmpty ? 0.5 : 1)
                if choice == .oneAgent, !agents.isEmpty {
                    BanditoSelect(
                        selection: $agentID,
                        sections: [
                            SelectSection(
                                options: agents.map { agent in
                                    let block = SkillLogic.block(.agent(agent.id), for: skill)
                                    return SelectOption(
                                        value: agent.id, title: agent.name,
                                        subtitle: block.map(SkillText.block), isEnabled: block == nil)
                                })
                        ],
                        label: L10n.Market.Skill.pickAgent, placeholder: L10n.Market.Skill.pickAgent)
                    .disabled(installing)
                }
                if let error {
                    UserFacingErrorView(message: error)
                }
            }
            .padding(24)
            MarketPanelFooter {
                Spacer(minLength: 8)
                Button(L10n.Common.cancel, action: onClose)
                    .banditoButton(.quiet())
                    .disabled(installing)
                    .fixedSize()
                Button(installing ? L10n.Market.Skill.installing : L10n.Market.Skill.install) { install() }
                    .banditoButton(.signal())
                    .disabled(!canInstall)
                    .fixedSize()
            }
        }
    }

    private func install() {
        guard canInstall, let target else { return }
        installing = true
        error = nil
        Task {
            if let failure = await onInstall(target) {
                error = SkillText.message(for: failure)
                installing = false
            } else {
                installing = false
                onClose()
            }
        }
    }
}
