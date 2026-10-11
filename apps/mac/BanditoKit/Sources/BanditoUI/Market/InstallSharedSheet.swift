import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// The install sheet of a shared bot or skill: what it is, who made it, what it may do, and the warning. The install
/// itself is `agents.create_from_shared` for a bot and `skills.install_shared` for a skill; both then report the
/// platform that the item was installed (`POST /shares/:id/installed`).
@MainActor
@Observable
final class InstallSharedModel {
    enum Load: Equatable {
        case loading
        case loaded(SharedItem)
        case failed(String)
    }

    /// What the install made, for the result lines of the sheet.
    struct BotResult: Equatable {
        var agent: Agent
        var scheduleCount: Int
        var missingServices: [String]
        var unknownServices: [String]
        var starter: String?
        var stepProblems: [String]

        static func == (lhs: BotResult, rhs: BotResult) -> Bool {
            lhs.agent.id == rhs.agent.id && lhs.scheduleCount == rhs.scheduleCount
                && lhs.missingServices == rhs.missingServices && lhs.unknownServices == rhs.unknownServices
                && lhs.starter == rhs.starter && lhs.stepProblems == rhs.stepProblems
        }
    }

    enum Outcome: Equatable {
        case bot(BotResult)
        case skill
    }

    private(set) var load: Load = .loading
    private(set) var offered: [AgentCapability] = []
    var chosen: Set<AgentCapability> = []
    var acknowledged = false
    var promptExpanded = false
    private(set) var inFlight = false
    private(set) var outcome: Outcome?
    private(set) var problem: String?
    private(set) var reported = false

    init(load: Load = .loading) {
        self.load = load
        if case .loaded(let item) = load { prepare(item) }
    }

    /// Reads the item (no sign-in needed). A hidden or removed item shows its own text.
    func fetch(shareID: String, client: () async throws -> AccountClient) async {
        guard ShareID.isValid(shareID) else {
            load = .failed(ShareLogic.fetchMessage(for: .notFound))
            return
        }
        load = .loading
        do {
            let item = try await client().getShare(id: shareID)
            prepare(item)
            load = .loaded(item)
        } catch let failure as ShareFailure {
            load = .failed(ShareLogic.fetchMessage(for: failure))
        } catch {
            load = .failed(ShareLogic.fetchMessage(for: .badResponse))
        }
    }

    private func prepare(_ item: SharedItem) {
        guard let info = SharedPayloadInfo(kind: item.kind, payload: item.payload) else { return }
        if item.kind == .bot {
            offered = ShareLogic.offeredCapabilities(info.capabilities)
            chosen = ShareLogic.defaultCapabilities(offered)
        }
    }

    var item: SharedItem? {
        if case .loaded(let item) = load { return item }
        return nil
    }

    var info: SharedPayloadInfo? {
        item.flatMap { SharedPayloadInfo(kind: $0.kind, payload: $0.payload) }
    }

    func setCapability(_ capability: AgentCapability, _ on: Bool) {
        if on { chosen.insert(capability) } else { chosen.remove(capability) }
    }

    var canInstall: Bool {
        guard let info else { return false }
        return ShareLogic.canInstall(
            hasServer: true, hasItem: item != nil, executables: info.executables, acknowledged: acknowledged,
            inFlight: inFlight) && outcome == nil
    }

    /// Installs the loaded item on `server`. A second call while one runs does nothing.
    func install(on server: ServerModel, client: () async throws -> AccountClient) async {
        guard let item, canInstall else { return }
        inFlight = true
        problem = nil
        defer { inFlight = false }
        do {
            switch item.kind {
            case .bot:
                let created = try await server.createBotFromShare(
                    shareID: item.id, version: item.version, payload: item.payload, language: item.lang,
                    capabilities: ShareLogic.chosenCapabilities(chosen, offered: offered))
                guard let agent = created.agent else {
                    problem = L10n.Share.Problem.generic
                    return
                }
                outcome = .bot(
                    BotResult(
                        agent: agent, scheduleCount: created.scheduleIds.count,
                        missingServices: created.missingServices, unknownServices: created.unknownServices,
                        starter: created.starter.flatMap { $0.isEmpty ? nil : $0 },
                        stepProblems: created.errors.map(\.message)))
            case .skill:
                try await server.installSharedSkill(
                    shareID: item.id, version: item.version, payload: item.payload, agentID: nil)
                outcome = .skill
            }
            // The count is best effort: a failed count does not undo an install that worked.
            if let accountClient = try? await client() {
                try? await accountClient.markInstalled(id: item.id)
            }
        } catch let error as RPCError {
            problem = ShareLogic.installMessage(for: SharedInstallFailure(error))
        } catch {
            problem = L10n.Share.Problem.generic
        }
    }

    /// Sends one report. The item stays installed on this Mac; the platform hides it after five reporters.
    func report(_ reason: ShareReportReason, client: () async throws -> AccountClient) async {
        guard let item, !reported else { return }
        do {
            let accountClient = try await client()
            try await accountClient.reportShare(id: item.id, reason: reason, note: "")
            reported = true
        } catch let failure as ShareFailure {
            problem = ShareLogic.publishMessage(for: failure)
        } catch {
            problem = L10n.Share.Problem.generic
        }
    }
}

/// The install sheet. Opened by `bandito://install?share=<id>`, by a pasted link in the Marketplace search, or the
/// Marketplace's own links.
struct InstallSharedSheet: View {
    let shareID: String
    let server: ServerModel?
    @Environment(AccountHub.self) private var accountHub
    @Environment(Router.self) private var router
    @State private var model: InstallSharedModel

    init(shareID: String, server: ServerModel?, model: InstallSharedModel = InstallSharedModel()) {
        self.shareID = shareID
        self.server = server
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch model.load {
            case .loading:
                Text(L10n.Share.Install.loading)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            case .failed(let message):
                Text(message)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
            case .loaded(let item):
                details(item)
            }
            if let problem = model.problem {
                Text(problem)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(Color.Bandito.surface2)
        .task(id: shareID) {
            await model.fetch(shareID: shareID, client: { try await accountHub.prepare() })
        }
    }

    // MARK: details

    @ViewBuilder
    private func details(_ item: SharedItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ShareLogic.kindLabel(item.kind))
                .font(BanditoFont.text(size: 11, weight: 600))
                .foregroundStyle(Color.Bandito.text2)
            Text(item.title)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .lineLimit(2)
            Text("\(authorLine(item)) · \(ShareLogic.versionLabel(item.version))")
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let info = model.info {
                switch item.kind {
                case .bot: botDetails(info)
                case .skill: skillDetails(info)
                }
            }
            Text(L10n.Share.Install.warning)
                .font(BanditoFont.text(size: 12, weight: 500))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            if let outcome = model.outcome {
                outcomeLines(outcome)
            }
        }
    }

    private func authorLine(_ item: SharedItem) -> String {
        let name = item.author.name ?? item.author.login
        return name.map { L10n.Share.Install.by(author: $0) } ?? L10n.Share.Install.anonymous
    }

    @ViewBuilder
    private func botDetails(_ info: SharedPayloadInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let role = info.role, !role.isEmpty {
                labelled(L10n.Share.Install.role, role)
            }
            Text(L10n.Share.Install.capabilities)
                .font(BanditoFont.text(size: 11.5, weight: 600))
                .foregroundStyle(Color.Bandito.text3)
            if model.offered.isEmpty {
                Text(L10n.Share.Install.noCapabilities)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else {
                ForEach(model.offered) { capability in
                    capabilityRow(capability)
                }
            }
            HStack(spacing: 14) {
                Text(L10n.Share.Install.servicesCount(count: info.serviceCount))
                Text(L10n.Share.Install.schedulesCount(count: info.scheduleCount))
            }
            .font(BanditoFont.text(size: 12, weight: 400))
            .foregroundStyle(Color.Bandito.text3)
            if let prompt = info.systemPrompt, !prompt.isEmpty {
                promptBlock(prompt)
            }
        }
    }

    private func capabilityRow(_ capability: AgentCapability) -> some View {
        let risky = ShareLogic.riskyCapabilities.contains(capability.rawValue)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ShareLogic.capabilityTitle(capability))
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                if risky {
                    Text(L10n.Share.Install.riskyCapability)
                        .font(BanditoFont.text(size: 11.5, weight: 400))
                        .foregroundStyle(Color.Bandito.danger)
                }
            }
            Spacer(minLength: 8)
            Toggle(
                ShareLogic.capabilityTitle(capability),
                isOn: Binding(
                    get: { model.chosen.contains(capability) },
                    set: { model.setCapability(capability, $0) })
            )
            .labelsHidden()
            .toggleStyle(BanditoToggleStyle())
        }
    }

    private func promptBlock(_ prompt: String) -> some View {
        let preview = ShareLogic.preview(of: prompt)
        let shown = model.promptExpanded ? prompt : preview.shown
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Share.Install.prompt)
                .font(BanditoFont.text(size: 11.5, weight: 600))
                .foregroundStyle(Color.Bandito.text3)
            Text(shown)
                .font(BanditoFont.mono(size: 11.5, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if preview.isCollapsed {
                Button(model.promptExpanded ? L10n.Share.Preview.collapse : L10n.Share.Preview.expand) {
                    model.promptExpanded.toggle()
                }
                .banditoButton(.link)
            }
        }
    }

    @ViewBuilder
    private func skillDetails(_ info: SharedPayloadInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let license = info.license {
                labelled(L10n.Share.Install.license, license)
            }
            Text(L10n.Share.Install.files(count: info.files.count))
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            if !info.executables.isEmpty {
                Text(L10n.Share.Install.scripts(count: info.executables.count))
                    .font(BanditoFont.text(size: 12.5, weight: 600))
                    .foregroundStyle(Color.Bandito.danger)
                Text(info.executables.joined(separator: "\n"))
                    .font(BanditoFont.mono(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                Toggle(isOn: $model.acknowledged) {
                    Text(L10n.Share.Install.scriptsAck)
                        .font(BanditoFont.text(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(BanditoToggleStyle())
            }
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BanditoFont.text(size: 11.5, weight: 600))
                .foregroundStyle(Color.Bandito.text3)
            Text(value)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: outcome

    @ViewBuilder
    private func outcomeLines(_ outcome: InstallSharedModel.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch outcome {
            case .skill:
                Text(L10n.Share.Install.doneSkill)
            case .bot(let result):
                Text(L10n.Share.Install.doneBot)
                if result.scheduleCount > 0 {
                    Text(L10n.Share.Install.schedulesOff(count: result.scheduleCount))
                }
                if !result.missingServices.isEmpty {
                    Text(L10n.Share.Install.missingServices(names: result.missingServices.joined(separator: ", ")))
                }
                if !result.unknownServices.isEmpty {
                    Text(L10n.Share.Install.unknownServices(names: result.unknownServices.joined(separator: ", ")))
                }
                if !result.stepProblems.isEmpty {
                    Text(L10n.Share.Install.partial)
                }
            }
        }
        .font(BanditoFont.text(size: 12.5, weight: 400))
        .foregroundStyle(Color.Bandito.text2)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: buttons

    private var buttons: some View {
        HStack(spacing: 10) {
            reportMenu
            Spacer(minLength: 8)
            Button(L10n.Common.close) { router.sheet = nil }
                .banditoButton(.quiet())
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if case .bot(let result)? = model.outcome {
            Button(L10n.Share.Install.openBot) { openBot(result) }
                .banditoButton(.signal())
        } else if model.outcome == nil {
            Button(model.inFlight ? L10n.Share.Install.installing : installTitle) {
                guard let server else { return }
                Task { await model.install(on: server, client: { try await accountHub.prepare() }) }
            }
            .banditoButton(.signal())
            .disabled(server == nil || !model.canInstall)
        }
    }

    private var installTitle: String {
        model.item?.kind == .skill ? L10n.Share.Install.addSkill : L10n.Share.Install.addBot
    }

    private var reportMenu: some View {
        Menu {
            ForEach(ShareReportReason.allCases, id: \.self) { reason in
                Button(ShareLogic.reportLabel(reason)) {
                    Task { await model.report(reason, client: { try await accountHub.prepare() }) }
                }
            }
        } label: {
            Text(model.reported ? L10n.Share.Install.reported : L10n.Share.Install.report)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .banditoButton(.quiet())
        .fixedSize()
        .disabled(model.item == nil || model.reported)
    }

    /// Opens the bot's chat with its first message in the input field, as the bot creation from a template does.
    private func openBot(_ result: InstallSharedModel.BotResult) {
        guard let server else { return }
        if let starter = result.starter { router.appendDraft(starter, for: result.agent.id) }
        router.selectAgent(result.agent.id, on: server)
        router.select(mode: .team)
        router.requestComposerFocus(agentID: result.agent.id)
        router.sheet = nil
    }
}

#Preview("Install a bot") {
    InstallSharedSheet(
        shareID: "k3HqT9vZ2Lm8pXcR4wBn7e", server: nil,
        model: InstallSharedModel(load: .loaded(ShareSamples.bot)))
        .environment(AccountHub())
        .environment(Router())
        .padding(40)
        .background(Color.Bandito.bg)
}

#Preview("Install a skill with scripts") {
    InstallSharedSheet(
        shareID: "k3HqT9vZ2Lm8pXcR4wBn7e", server: nil,
        model: InstallSharedModel(load: .loaded(ShareSamples.skill)))
        .environment(AccountHub())
        .environment(Router())
        .padding(40)
        .background(Color.Bandito.bg)
}
