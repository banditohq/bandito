import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI
import UIKit

/// Inbox, the second tab: everything that waits for the person on every connected server. A swipe to the right allows,
/// a swipe to the left refuses; a risky approval opens its sheet instead of allowing at once, and asks for Face ID when
/// the setting says so. A press on a row opens the sheet with the details. Empty: a sleeping raccoon.
struct InboxScreen: View {
    let servers: [ServerModel]
    let settings: IOSSettings
    /// The owner's check for risky approvals (Face ID, else the passcode).
    var authenticator: any BiometricAuthenticating = DeviceAuthenticator()
    /// An Inbox item to open at once: a notice's route sets it (the approval's item id), and the screen clears it.
    var focus: Binding<String?> = .constant(nil)
    /// Opens an agent's chat: the app switches to the Crew and pushes it.
    var openChat: ((UUID, String) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The toast after an answer ("Allowed — Forge goes on"), set by RootView.
    @Environment(\.answerToast) private var answerToast
    /// The items answered here, hidden at once while the server takes the answer (the daemon's event removes them for good).
    @State private var answered: Set<String> = []
    /// The item whose sheet is open (a snapshot: the sheet shows what was opened).
    @State private var opened: InboxItem?
    @State private var failed = false

    var body: some View {
        let items = InboxRules.items(in: servers).filter { !answered.contains($0.id) }
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    list(items)
                }
            }
            // Rows that come in or go out (an answer, a new approval) and the empty state animate on the list's ids.
            .animation(reduceMotion ? nil : BanditoMotion.ease, value: items.map(\.id))
            .navigationTitle(L10n.Ios.Tab.inbox)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(.hidden, for: .navigationBar)
            .background(Color.Bandito.bg.ignoresSafeArea())
            .sheet(item: $opened) { item in
                InboxDetailSheet(
                    item: item, riskyNeedsFaceID: settings.riskyNeedsFaceID,
                    openChat: openChat.map { open in { open(item.serverID, item.agentID) } }
                ) { action in
                    await act(item, action)
                }
            }
            .alert(L10n.Ios.Inbox.failed, isPresented: $failed) {
                Button(L10n.Common.close, role: .cancel) {}
            }
        }
        .onChange(of: focus.wrappedValue) { _, id in
            openFocused(id, in: InboxRules.items(in: servers))
        }
        // A focus that waits for its item (a notice pressed on a cold start) opens once the item is listed.
        .onChange(of: InboxRules.items(in: servers).map(\.id)) { _, _ in
            openFocused(focus.wrappedValue, in: InboxRules.items(in: servers))
        }
        .task(id: servers.map(\.id)) {
            openFocused(focus.wrappedValue, in: InboxRules.items(in: servers))
            await loadUnlistedAgents()
            // The launch argument `-inbox-detail` opens the first item's sheet, for the screenshots.
            if ProcessInfo.processInfo.arguments.contains("-inbox-detail"), opened == nil {
                opened = items.first
            }
        }
    }

    /// Opens the sheet of the focused item when it is in the list, then clears the focus (a notice's route). A focus whose
    /// item is not listed yet stays until it is.
    private func openFocused(_ id: String?, in items: [InboxItem]) {
        guard let id, let item = InboxRules.focusedItem(id, in: items) else { return }
        opened = item
        focus.wrappedValue = nil
    }

    private func list(_ items: [InboxItem]) -> some View {
        let sections = InboxRules.sections(items, servers: servers.map(\.id), grouped: servers.count > 1)
        return List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        row(item)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                } header: {
                    if let title = section.title {
                        CrewSectionLabel(title: title)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.Bandito.bg.ignoresSafeArea())
    }

    /// One row, with its swipe actions and the same actions for VoiceOver (`accessibilityActions`).
    @ViewBuilder private func row(_ item: InboxItem) -> some View {
        let opensSheet = InboxAnswer.needsFaceID(item, riskyNeedsFaceID: settings.riskyNeedsFaceID)
        Button {
            opened = item
        } label: {
            InboxRow(item: item).equatable()
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.Bandito.surface1)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if item.canAllow {
                Button {
                    if opensSheet {
                        opened = item
                    } else {
                        Task { await allowFromSwipe(item) }
                    }
                } label: {
                    Label(L10n.Approval.approve, systemImage: "checkmark")
                }
                .tint(Color.Bandito.ok)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if item.canDeny {
                Button(role: .destructive) {
                    Task { await act(item, .deny) }
                } label: {
                    Label(L10n.Approval.deny, systemImage: "xmark")
                }
                .tint(Color.Bandito.danger)
            }
        }
        .accessibilityActions {
            if item.canAllow {
                Button(L10n.Approval.approve) {
                    if opensSheet { opened = item } else { Task { await allowFromSwipe(item) } }
                }
            }
            if item.canDeny {
                Button(L10n.Approval.deny) { Task { await act(item, .deny) } }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if CrewFacts.emptyNotice(servers: servers) != nil {
            ConnectionNoticeView.forEmpty(servers: servers)
                .padding(BanditoSpace.s6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            quietState
        }
    }

    private var quietState: some View {
        VStack(spacing: BanditoSpace.s3) {
            CrewAvatar(
                name: "", look: CrewLook(color: .peach, face: .sleeping, customHex: nil), mood: .sleeping, size: 72)
            Text(L10n.Ios.Inbox.empty)
                .font(BanditoFont.display(size: 16.5, weight: 600))
                .foregroundStyle(Color.Bandito.text)
                .multilineTextAlignment(.center)
            Text(L10n.Ios.Inbox.emptyMessage)
                .font(BanditoFont.text(size: 13.5))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A swipe (or its VoiceOver action) on a plain approval: allowed at once, a failure is an alert.
    private func allowFromSwipe(_ item: InboxItem) async {
        let outcome = await act(item, .allow(remember: false))
        if outcome == .failed { failed = true }
    }

    /// Sends the person's answer to the item's server. A sent answer hides the item (the list animates its removal) and
    /// gives a haptic: success for an answer that lets the agent go on, warning for a refusal.
    @discardableResult
    private func act(_ item: InboxItem, _ action: InboxAct) async -> InboxAnswer.Outcome {
        guard let server = servers.first(where: { $0.id == item.serverID }) else { return .failed }
        do {
            let outcome: InboxAnswer.Outcome
            switch action {
            case .allow(let remember):
                outcome = try await InboxAnswer.allow(
                    item, server: server, remember: remember, riskyNeedsFaceID: settings.riskyNeedsFaceID,
                    authenticator: authenticator, reason: L10n.Ios.Inbox.faceIDReason)
            case .deny:
                switch item.kind {
                case .form: try await InboxAnswer.rejectForm(item, server: server)
                case .connect: try await InboxAnswer.declineConnect(item, server: server)
                default: try await InboxAnswer.deny(item, server: server)
                }
                outcome = .sent
            case .submit(let values):
                try await InboxAnswer.submit(item, server: server, values: values)
                outcome = .sent
            case .reply(let text):
                try await InboxAnswer.reply(text, to: item, server: server)
                outcome = .sent
            }
            guard outcome == .sent else { return outcome }
            let generator = UINotificationFeedbackGenerator()
            if case .deny = action {
                generator.notificationOccurred(.warning)
            } else {
                generator.notificationOccurred(.success)
            }
            let toast: AnswerToastMessage
            switch action {
            case .allow:
                toast = AnswerToastMessage(text: L10n.Ios.AnswerToast.allowed(name: item.agentName), allowed: true)
            case .deny:
                toast = AnswerToastMessage(text: L10n.Ios.AnswerToast.denied(name: item.agentName), allowed: false)
            case .submit, .reply:
                toast = AnswerToastMessage(text: L10n.Ios.AnswerToast.sent(name: item.agentName), allowed: true)
            }
            answerToast?.show(toast)
            _ = answered.insert(item.id)
            return .sent
        } catch {
            return .failed
        }
    }

    /// An agent that waits for the person, whose chat is not loaded, lists nothing yet: its chat is read once, which
    /// brings its approvals and forms. Only connected servers are asked.
    private func loadUnlistedAgents() async {
        for server in servers where server.state == .connected {
            for agent in server.sortedAgents where !server.threadSummary(for: agent.id).loaded {
                guard server.needsPerson(agent.id) else { continue }
                try? await server.loadHistory(agent.id)
            }
        }
    }
}
