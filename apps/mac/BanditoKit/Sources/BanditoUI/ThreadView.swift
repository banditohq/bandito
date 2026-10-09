import BanditoDesign
import BanditoKit
import SwiftUI

struct ThreadView: View {
    var server: ServerModel
    var agent: Agent
    @State private var draft = ""
    @State private var sendError: String?
    /// Failures of interrupt, approval and history loading.
    @State private var actionError: String?

    private var thread: AgentThread { server.thread(for: agent.id) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    ThreadItemsView(
                        items: thread.items, server: server,
                        showsLoadEarlier: server.hasMoreHistory[agent.id] == true,
                        onLoadEarlier: loadEarlier,
                        onError: { actionError = $0 })
                }
                // Follow the newest item only: prepending older history must not jump to the bottom.
                .onChange(of: thread.items.last?.id) { _, _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .top) { HeaderPill(agent: agent, status: thread.status) }

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
                draft: $draft, agentName: agent.name, running: thread.turnRunning,
                onSend: send, onStop: stop
            )
            .frame(maxWidth: 800)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(Color.Bandito.bg)
        .task(id: agent.id) { await loadHistory() }
    }

    private func loadHistory() async {
        do { try await server.loadHistory(agent.id) } catch { actionError = error.localizedDescription }
    }

    private func loadEarlier() {
        Task {
            do { try await server.loadOlder(agent.id) } catch { actionError = error.localizedDescription }
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

/// The rows of a thread. Separate from the scroll view so it can be rendered
/// on its own (snapshots, previews).
struct ThreadItemsView: View {
    var items: [ThreadItem]
    var server: ServerModel
    var showsLoadEarlier = false
    var onLoadEarlier: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            if showsLoadEarlier {
                Button("Load earlier", action: onLoadEarlier)
                    .buttonStyle(QuietButtonStyle())
                    .frame(maxWidth: .infinity)
            }
            ForEach(items) { item in
                ThreadItemView(item: item, server: server, onError: onError)
                    .id(item.id)
            }
            Color.clear.frame(height: 1).id("bottom")
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .padding(.top, 64)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

struct HeaderPill: View {
    var agent: Agent
    var status: AgentStatus

    var body: some View {
        HStack(spacing: 8) {
            AgentAvatar(name: agent.name, size: 22)
            Text(agent.name).font(.system(size: 13, weight: .semibold))
            StatusDot(status: status)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.Bandito.line, lineWidth: 1))
        .padding(.top, 12)
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
        .frame(maxWidth: 800)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

struct Composer: View {
    @Binding var draft: String
    var agentName: String
    var running: Bool
    var onSend: () -> Void
    var onStop: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message \(agentName)", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...10)
                .onSubmit(onSend)
                .padding(.vertical, 6)
            if running {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.Bandito.surface3, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop")
            }
            Button(action: onSend) {
                Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.Bandito.bg)
                    .frame(width: 28, height: 28)
                    .background(Color.Bandito.text, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

struct ThreadItemView: View {
    var item: ThreadItem
    var server: ServerModel
    var onError: (String) -> Void

    var body: some View {
        switch item {
        case .user(_, let text, let source, _, _):
            HStack {
                Spacer(minLength: 80)
                Text(text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(source == .user ? Color.Bandito.surface3 : Color.Bandito.surface2,
                        in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant(_, let text, _):
            Bubble(text: text)
        case .streaming(let text):
            Bubble(text: text).opacity(0.85)
        case .tool(let row):
            ToolRowView(row: row)
        case .approval(let row):
            ApprovalCard(row: row, server: server, onError: onError)
        case .note(_, let text, let kind, _):
            HStack {
                Spacer()
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(kind == .error ? Color.Bandito.danger : Color.Bandito.text3)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }
}

/// Agent text. Inline Markdown is rendered; anything that does not parse is shown verbatim.
private struct Bubble: View {
    var text: String

    var body: some View {
        HStack {
            Group {
                if let rendered = try? AttributedString(
                    markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
                {
                    Text(rendered)
                } else {
                    Text(verbatim: text)
                }
            }
            .textSelection(.enabled)
            .lineSpacing(3)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 80)
        }
    }
}

private struct ToolRowView: View {
    var row: ToolRow
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 8) {
                    Group {
                        switch row.ok {
                        case nil: ProgressView().controlSize(.mini)
                        case true?: Image(systemName: "checkmark").foregroundStyle(Color.Bandito.ok)
                        case false?: Image(systemName: "xmark").foregroundStyle(Color.Bandito.danger)
                        }
                    }
                    .frame(width: 14)
                    Text(row.title)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text2)
                        .lineLimit(1)
                    Spacer()
                    if row.output?.isEmpty == false {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10)).foregroundStyle(Color.Bandito.text3)
                    }
                }
            }
            .buttonStyle(.plain)
            if open, let out = row.output, !out.isEmpty {
                ScrollView(.horizontal) {
                    Text(out)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.Bandito.text2)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 240)
                .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 4)
    }
}

struct ApprovalCard: View {
    var row: ApprovalRow
    var server: ServerModel
    var onError: (String) -> Void
    @State private var always = false
    @State private var busy = false

    var body: some View {
        switch row.state {
        case .pending:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("needs you")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.Bandito.signal)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.Bandito.signal.opacity(0.14), in: Capsule())
                    Text(row.reason).font(.system(size: 12)).foregroundStyle(Color.Bandito.text3)
                }
                Text(row.command ?? row.title)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10))
                if let diff = row.diff {
                    ScrollView {
                        Text(diff).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .padding(10)
                    .background(Color.Bandito.bg, in: RoundedRectangle(cornerRadius: 10))
                }
                HStack(spacing: 10) {
                    // Deliberately no keyboard shortcuts: approving a command is a click, never a stray Return.
                    Button("Deny") { decide(.deny) }
                        .buttonStyle(QuietButtonStyle())
                    Button("Approve") { decide(.allow) }
                        .buttonStyle(SignalButtonStyle())
                    Toggle("Always allow this here", isOn: $always)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text2)
                    Spacer()
                }
                .disabled(busy)
            }
            .padding(14)
            .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.Bandito.signal.opacity(0.5), lineWidth: 1))
        case .approved(let by, _):
            resolvedLine(icon: "checkmark.circle", text: by == .user ? "Approved by you · \(row.title)" : "Allowed by a rule · \(row.title)")
        case .denied(let by):
            resolvedLine(icon: "xmark.circle", text: by == .user ? "Denied by you · \(row.title)" : "Denied · \(row.title)")
        }
    }

    private func resolvedLine(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.Bandito.text3)
        .padding(.horizontal, 4)
    }

    private func decide(_ d: Decision) {
        busy = true
        Task {
            do {
                try await server.resolve(row.approvalId, d, remember: always && d == .allow)
            } catch {
                onError(error.localizedDescription)
            }
            busy = false
        }
    }
}
