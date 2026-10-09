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
    @State private var draft = ""
    @State private var sendError: String?
    /// Failures of interrupt, approval and history loading.
    @State private var actionError: String?
    @State private var loadingOlder = false
    /// Files changed since the last checkpoint; `nil` until loaded or when the server lacks `changes`.
    @State private var changes: ChangesDiff?

    private var thread: AgentThread { server.thread(for: agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            ThreadHeader(
                agent: agent,
                status: thread.status,
                turnRunning: thread.turnRunning,
                changes: server.info?.supports("changes") == true ? changes : nil,
                showsChanges: server.info?.supports("changes") == true,
                onChanges: { router.sheet = .changes(agentID: agent.id) },
                onTerminal: { router.select(mode: .terminals) },
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
            if let text = server.lastError {
                Banner(text: text)
            }
            if let sendError {
                Banner(text: sendError)
            }
            if let actionError {
                Banner(text: actionError)
            }
            Composer(
                draft: $draft,
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
        do { try await server.loadHistory(agent.id) } catch { actionError = error.localizedDescription }
    }

    /// Older history is loaded when its top edge scrolls into view; one page at a time.
    private func loadEarlier() {
        guard !loadingOlder else { return }
        loadingOlder = true
        Task {
            defer { loadingOlder = false }
            do { try await server.loadOlder(agent.id) } catch { actionError = error.localizedDescription }
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
            do { try await server.interrupt(agent.id) } catch { actionError = error.localizedDescription }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sendError = nil
        Task {
            do { try await server.send(text, to: agent.id) } catch {
                sendError = error.localizedDescription
                draft = text
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
    var onError: (String) -> Void = { _ in }
    var agentName = ""
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
                ThreadRowView(row: row, agentName: agentName, server: server, onError: onError)
                    .banditoRise()
            }
            if typing {
                TypingIndicator()
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
