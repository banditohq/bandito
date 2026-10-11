import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import Observation
import SwiftUI

/// The shares of this account: visibility, "Update to the current version", delete. Opened from the Marketplace.
@MainActor
@Observable
final class MySharesModel {
    enum Phase: Equatable {
        case loading
        case signedOut
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var items: [ShareSummary] = []
    /// The shares with a request running: their rows show it and take no second action.
    private(set) var busy: Set<String> = []
    private(set) var problem: String?

    init(phase: Phase = .loading, items: [ShareSummary] = []) {
        self.phase = phase
        self.items = items
    }

    func reload(signedIn: Bool, client: () async throws -> AccountClient) async {
        guard signedIn else {
            phase = .signedOut
            items = []
            return
        }
        phase = .loading
        do {
            items = try await client().myShares()
            phase = .loaded
        } catch let failure as ShareFailure {
            phase = .failed(ShareLogic.fetchMessage(for: failure))
        } catch {
            phase = .failed(L10n.Share.Problem.generic)
        }
    }

    func setVisibility(_ item: ShareSummary, _ visibility: ShareVisibility, client: () async throws -> AccountClient) async {
        guard item.visibility != visibility, !busy.contains(item.id) else { return }
        await run(item.id) {
            try await client().updateShare(id: item.id, ShareUpdate(visibility: visibility))
        }
        reloadedItem(item.id, visibility: visibility)
    }

    /// Exports the bot or skill again from the place it was shared from, and saves that as the next version.
    /// Returns the problem text, or nil when the update went through.
    func updateToCurrent(_ item: ShareSummary, servers: [ServerModel], client: () async throws -> AccountClient) async {
        guard !busy.contains(item.id) else { return }
        guard let source = ShareSourceStore.load()[item.id],
            let server = servers.first(where: { $0.id.uuidString == source.serverID })
        else {
            problem = L10n.Share.Mine.noSource
            return
        }
        await run(item.id) {
            let payload: JSONValue
            switch item.kind {
            case .bot:
                guard let agentID = source.agentID, server.agents.contains(where: { $0.id == agentID }) else {
                    throw ShareFailure.notFound
                }
                payload = try await server.exportBot(agentID: agentID)
            case .skill:
                guard let name = source.skillName else { throw ShareFailure.notFound }
                let license = try await client().getShare(id: item.id).payload["license"]?.string
                    ?? ShareLogic.defaultLicense
                payload = try await server.exportSkill(name: name, license: license)
            }
            try await client().updateShare(id: item.id, ShareUpdate(payload: payload))
        }
    }

    func delete(_ item: ShareSummary, client: () async throws -> AccountClient) async {
        guard !busy.contains(item.id) else { return }
        await run(item.id) {
            try await client().deleteShare(id: item.id)
        }
        if problem == nil {
            ShareSourceStore.forget(item.id)
            items.removeAll { $0.id == item.id }
        }
    }

    /// Runs one change of a share. A failure becomes the problem text; the list is read again after a change.
    private func run(_ id: String, _ work: () async throws -> Void) async {
        busy.insert(id)
        problem = nil
        defer { busy.remove(id) }
        do {
            try await work()
        } catch let failure as ShareFailure {
            problem = ShareLogic.fetchMessage(for: failure)
        } catch let error as RPCError {
            problem = ShareLogic.installMessage(for: SharedInstallFailure(error))
        } catch {
            problem = L10n.Share.Problem.generic
        }
    }

    private func reloadedItem(_ id: String, visibility: ShareVisibility) {
        guard problem == nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].visibility = visibility
    }
}

struct MySharesView: View {
    /// The servers of the app: an update exports from the server the share was made on.
    let servers: [ServerModel]
    @Environment(AccountHub.self) private var accountHub
    @Environment(Router.self) private var router
    @State private var model: MySharesModel
    @State private var deleting: ShareSummary?

    init(servers: [ServerModel], model: MySharesModel = MySharesModel()) {
        self.servers = servers
        _model = State(initialValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.Share.Mine.title)
                .font(BanditoFont.display(size: 18.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
            content
            if let problem = model.problem {
                Text(problem)
                    .font(BanditoFont.text(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 8)
                Button(L10n.Common.close) { router.sheet = nil }
                    .banditoButton(.quiet())
            }
        }
        .padding(24)
        .frame(width: 540, alignment: .leading)
        .background(Color.Bandito.surface2)
        .task { await reload() }
        .confirmationDialog(
            L10n.Share.Mine.deleteTitle(title: deleting?.title ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.Share.Mine.delete, role: .destructive) {
                guard let item = deleting else { return }
                deleting = nil
                Task { await model.delete(item, client: { try await accountHub.prepare() }) }
            }
        } message: {
            Text(L10n.Share.Mine.deleteText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            Text(L10n.Share.Mine.loading)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
        case .signedOut:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.Share.Mine.signIn)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                Button(L10n.Share.SignIn.button) { router.sheet = .account }
                    .banditoButton(.lightPill())
                    .fixedSize()
            }
        case .failed(let message):
            Text(message)
                .font(BanditoFont.text(size: 13, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
        case .loaded:
            if model.items.isEmpty {
                Text(L10n.Share.Mine.empty)
                    .font(BanditoFont.text(size: 13, weight: 400))
                    .foregroundStyle(Color.Bandito.text3)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.items) { item in
                            row(item)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 420)
            }
        }
    }

    private func row(_ item: ShareSummary) -> some View {
        let busy = model.busy.contains(item.id)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ShareLogic.kindLabel(item.kind))
                    .font(BanditoFont.text(size: 11, weight: 600))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Color.Bandito.text.opacity(0.06), in: Capsule())
                Text(item.title)
                    .font(BanditoFont.text(size: 14, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(detailLine(item))
                .font(BanditoFont.text(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            HStack(spacing: 10) {
                SegmentedPicker(
                    selection: Binding(
                        get: { item.visibility },
                        set: { visibility in changeVisibility(item, to: visibility) }),
                    options: ShareVisibility.allCases.map { ($0, ShareLogic.visibilityLabel($0)) }
                )
                .fixedSize()
                .disabled(busy)
                Spacer(minLength: 8)
                if ShareLogic.canUpdate(item, sources: ShareSourceStore.load()) {
                    Button(L10n.Share.Mine.update) {
                        Task {
                            await model.updateToCurrent(item, servers: servers, client: { try await accountHub.prepare() })
                        }
                    }
                    .banditoButton(.lightPill())
                    .disabled(busy)
                }
                Button(L10n.Share.Mine.delete) { deleting = item }
                    .banditoButton(.quiet(tone: .danger))
                    .disabled(busy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func detailLine(_ item: ShareSummary) -> String {
        var parts = [ShareLogic.versionLabel(item.version), L10n.Share.Mine.installs(count: item.installs)]
        if item.hidden { parts.append(L10n.Share.Mine.hidden) }
        return parts.joined(separator: " · ")
    }

    private func reload() async {
        await model.reload(signedIn: accountHub.signedIn, client: { try await accountHub.prepare() })
    }

    private func changeVisibility(_ item: ShareSummary, to visibility: ShareVisibility) {
        let hub = accountHub
        Task {
            await model.setVisibility(item, visibility, client: { try await hub.prepare() })
        }
    }
}

#Preview("My shares: empty") {
    MySharesView(servers: [], model: MySharesModel(phase: .loaded, items: []))
        .environment(AccountHub())
        .environment(Router())
        .padding(40)
        .background(Color.Bandito.bg)
}

#Preview("My shares: three") {
    MySharesView(servers: [], model: MySharesModel(phase: .loaded, items: ShareSamples.mine))
        .environment(AccountHub())
        .environment(Router())
        .padding(40)
        .background(Color.Bandito.bg)
}
