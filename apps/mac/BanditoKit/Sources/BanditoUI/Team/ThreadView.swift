import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The thread of one agent: header, the rows, banners and the composer.
struct ThreadView: View {
    var server: ServerModel
    var agent: Agent
    /// Which tab the inspector opens on; the header's schedules button sets it.
    @Binding var inspectorTab: InspectorTab

    @Environment(Router.self) private var router
    @State private var sendError: UserFacingMessage?
    /// Failures of interrupt, approval and history loading.
    @State private var actionError: UserFacingMessage?
    @State private var loadingOlder = false
    /// Files changed since the last checkpoint; `nil` until loaded or when the server lacks `changes`.
    @State private var changes: ChangesDiff?

    private var thread: AgentThread { server.thread(for: agent.id) }

    /// The composer text of this agent, kept by the Router (see `Router.drafts`).
    private var draft: Binding<String> {
        Binding(get: { router.drafts[agent.id] ?? "" }, set: { router.drafts[agent.id] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader(
                agent: agent,
                status: thread.status,
                turnRunning: thread.turnRunning,
                changes: server.info?.supports("changes") == true ? changes : nil,
                showsChanges: server.info?.supports("changes") == true,
                showsTerminal: server.supports("terminals"),
                models: server.runtimeModels,
                onInspect: {
                    inspectorTab = .details
                    router.inspectorOpen = true
                },
                isLead: LeadAgentStore.shared.id(server: server.id.uuidString) == agent.id,
                onChanges: { router.sheet = .changes(agentID: agent.id) },
                onTerminal: { router.openTerminalHere(agent.cwd) },
                onSchedules: {
                    inspectorTab = .details
                    router.inspectorOpen = true
                },
                onDetails: { router.inspectorOpen.toggle() })

            ScrollViewReader { proxy in
                ScrollView {
                    ThreadItemsView(
                        items: thread.items, server: server,
                        showsLoadEarlier: server.hasMoreHistory[agent.id] == true,
                        onLoadEarlier: loadEarlier,
                        onError: { actionError = $0 },
                        agentName: agent.name,
                        primaryRuntime: agent.runtime.rawValue,
                        typing: thread.turnRunning && !isStreaming)
                }
                // Follow the newest item only: prepending older history must not jump to the bottom.
                .onChange(of: thread.items.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }

            if thread.status == .error, let detail = thread.statusDetail {
                Banner(text: detail)
            }
            if let kind = server.lastError {
                FailureBanner(message: UserFacingError.message(for: kind)) {
                    Task { await server.connect() }
                }
            }
            if let sendError {
                FailureBanner(message: sendError) { send() }
            }
            if let actionError {
                FailureBanner(message: actionError) {
                    Task { await server.connect() }
                }
            }
            Composer(
                draft: draft,
                agentName: agent.name,
                running: thread.turnRunning,
                contextFraction: ContextUsage.fraction(tokens: agent.contextTokens, budget: agent.contextBudget),
                agent: agent,
                server: server,
                onSend: send,
                onStop: stop)
                .frame(maxWidth: 780)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Color.Bandito.bg)
        .task(id: agent.id) {
            await loadHistory()
            await loadChanges()
        }
        // The header names the model from the server's list, so the list is asked once per server, not on opening
        // the inspector. The daemon caches the answer, so a repeat of this request is cheap.
        .task(id: server.id) {
            _ = try? await server.refreshRuntimeModels()
        }
        // Text put here by another screen ("Ask about this place") goes into the composer, once.
        .onChange(of: router.pendingComposerText, initial: true) { _, _ in
            guard let text = router.takeComposerText() else { return }
            router.appendDraft(text, for: agent.id)
        }
        // The change counts are refreshed when a turn ends.
        .onChange(of: thread.turnRunning) { wasRunning, isRunning in
            if wasRunning && !isRunning {
                Task { await loadChanges() }
            }
        }
    }

    private var isStreaming: Bool {
        if case .streaming? = thread.items.last { return true }
        return false
    }

    private func loadHistory() async {
        do { try await server.loadHistory(agent.id) } catch { actionError = UserFacingError.message(for: error) }
    }

    /// Older history is loaded when its top edge scrolls into view; one page at a time.
    private func loadEarlier() {
        guard !loadingOlder else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do { try await server.loadOlder(agent.id) } catch { actionError = UserFacingError.message(for: error) }
        }
    }

    private func loadChanges() async {
        guard server.info?.supports("changes") == true else {
            changes = nil
            return
        }
        // The counts are a convenience: a failed read keeps the last known numbers.
        if let diff = try? await server.changesDiff(agentID: agent.id) {
            changes = diff
        }
    }

    private func stop() {
        Task {
            do { try await server.interrupt(agent.id) } catch { actionError = UserFacingError.message(for: error) }
        }
    }

    /// Sends the draft of this agent. The id is taken now: a failure puts the text back into the draft of the agent it
    /// was sent to, even when the person has gone to another agent by then.
    private func send() {
        let id = agent.id
        let text = router.takeDraft(for: id)
        guard !text.isEmpty else { return }
        sendError = nil
        Task {
            do { try await server.send(text, to: id) } catch {
                sendError = UserFacingError.message(for: error)
                router.restoreDraft(text, for: id)
            }
        }
    }
}

/// The rows of a thread. Separate from the scroll view so it can be rendered on its own (snapshots, previews).
struct ThreadItemsView: View {
    var items: [ThreadItem]
    var server: ServerModel
    var showsLoadEarlier = false
    var onLoadEarlier: () -> Void = {}
    var onError: (UserFacingMessage) -> Void = { _ in }
    var agentName = ""
    var primaryRuntime = ""
    /// Shows the typing indicator after the last row while a turn runs.
    var typing = false

    var body: some View {
        let rows = ThreadRows.build(items)
        LazyVStack(alignment: .leading, spacing: 12) {
            if showsLoadEarlier {
                Color.clear
                    .frame(height: 1)
                    .onAppear(perform: onLoadEarlier)
            }
            ForEach(rows) { row in
                ThreadRowView(
                    row: row, agentName: agentName, primaryRuntime: primaryRuntime, server: server, onError: onError)
                    .banditoRise()
            }
            if typing {
                TypingIndicator(activity: AgentActivity.current(in: items), since: AgentActivity.turnStart(in: items))
            }
            Color.clear.frame(height: 1).id("bottom")
        }
        .frame(maxWidth: 740)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

/// A failure in the thread: the sentence from `UserFacingError`, with "Повторить" when `onRetry` is given.
private struct FailureBanner: View {
    let message: UserFacingMessage
    var onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.Bandito.danger)
            UserFacingErrorView(message: message, onRetry: onRetry)
            Spacer()
        }
        .padding(12)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

private struct Banner: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.Bandito.danger)
            Text(text).font(.system(size: 12)).foregroundStyle(Color.Bandito.text).textSelection(.enabled)
            Spacer()
        }
        .padding(12)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: 780)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}
