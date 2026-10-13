import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// What the first task needs from a server: `ServerModel` in the app, a fake in the tests.
@MainActor
protocol TaskSending: AnyObject {
    var agents: [Agent] { get }
    func send(_ text: String, to agentId: String) async throws
    /// Reads the agent's thread from the server (not the local echo) into `thread(for:)`.
    func loadHistory(_ agentId: String) async throws
    func thread(for agentId: String) -> AgentThread
}

extension ServerModel: TaskSending {
    func send(_ text: String, to agentId: String) async throws {
        try await send(text, to: agentId, replyTo: nil, attachments: [], mentions: [], viaButton: false)
    }
}

/// What the "First task" step shows and does: four suggestions for the crew that was hired, a field for the person's
/// own, and the send. A send that failed can be tried again without sending the task twice. The daemon has no id for a
/// message the client makes up, so the server's own thread decides: before the first send the thread is read from the
/// server and the messages with this text are counted; after a failed send it is read again, and one more message with
/// this text means the agent has it (the answer was lost). If the thread cannot be read, nothing is sent: the person is
/// told the connection failed and can try again. (Counted, not timed: the server's clock and ours may differ.)
/// The read after a failed send is reliable: the daemon writes the person's message to its journal (`hub.emit` stores the
/// event, in `supervisor.rs` `Cmd::Send`) before it answers `agents.send`, so a message the agent got is in
/// `events.page` by the time any answer, or its loss, can reach us. No waiting for the event is needed.
@MainActor
@Observable
final class FirstTaskModel {
    let server: TaskSending
    let agentID: String
    let teamID: String?

    private(set) var text = ""
    private(set) var sending = false
    private(set) var failure: UserFacingMessage?
    /// The text of the attempt that failed and how many messages with it the server's thread had before it.
    @ObservationIgnored private var attempt: (text: String, baseline: Int)?

    init(server: TaskSending, agentID: String, teamID: String?) {
        self.server = server
        self.agentID = agentID
        self.teamID = teamID
    }

    var suggestions: [FirstTaskSuggestions.Prompt] { FirstTaskSuggestions.prompts(forTeam: teamID) }

    var agentName: String {
        server.agents.first { $0.id == agentID }?.name ?? ""
    }

    var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var canSend: Bool { !sending && !trimmed.isEmpty && !agentName.isEmpty }

    func setText(_ value: String) {
        text = value
        failure = nil
    }

    func choose(_ prompt: FirstTaskSuggestions.Prompt) {
        setText(prompt.text)
    }

    /// Sends the task to the agent. True when the agent has it (also when an earlier failed attempt got through).
    func send() async -> Bool {
        let message = trimmed
        guard canSend else { return false }
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await server.loadHistory(agentID)
        } catch {
            var message = UserFacingError.message(for: error)
            message.canRetry = true
            failure = message
            return false
        }
        let count = userMessages(with: message)
        if let attempt, attempt.text == message, count > attempt.baseline {
            // The earlier request failed on the way back, but the agent has the message: do not send it twice.
            self.attempt = nil
            return true
        }
        let baseline = attempt?.text == message ? attempt?.baseline ?? count : count
        do {
            try await server.send(message, to: agentID)
            attempt = nil
            return true
        } catch {
            attempt = (message, baseline)
            failure = UserFacingMessage(
                text: L10n.Onboarding.Task.failed, technical: UserFacingError.message(for: error).technical, canRetry: true)
            return false
        }
    }

    private func userMessages(with message: String) -> Int {
        server.thread(for: agentID).items.reduce(0) { count, item in
            if case .user(_, let text, _, _, _, _) = item, text == message { return count + 1 }
            return count
        }
    }
}

/// Step 6: "First task". Four suggestions written for the crew, or the person's own words; sending opens the chat of
/// the agent with the reply already coming in.
struct FirstTaskStep: View {
    var model: FirstTaskModel
    /// The task is with the agent: the chat opens and the flow ends.
    var onSent: () -> Void
    /// "Open the chat, I will write later": the chat opens with nothing sent.
    var onLater: () -> Void
    /// "Choose a crew": back to the step that makes the agents, when there is no agent to send to.
    var onChooseCrew: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        let _ = PerfCounters.hit("OnboardingTaskStep")
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.Onboarding.Task.title)
                    .font(BanditoFont.display(size: 35, weight: 600))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.Onboarding.Task.subtitle(name: model.agentName))
                    .font(BanditoFont.text(size: 15, weight: 400))
                    .foregroundStyle(Color.Bandito.text2)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.agentName.isEmpty {
                noAgent
            } else {
                suggestions
                field
                if let failure = model.failure {
                    UserFacingErrorView(message: failure)
                }
                Button(L10n.Onboarding.Task.later, action: onLater)
                    .banditoButton(.link)
                    .fixedSize()
            }
        }
        .frame(maxWidth: 700, alignment: .topLeading)
        .onboardingNext(nextAction)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(L10n.Onboarding.Task.try)
            ForEach(model.suggestions, id: \.self) { prompt in
                let selected = model.trimmed == prompt.text
                Button {
                    model.choose(prompt)
                    fieldFocused = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "sparkles")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(selected ? Color.Bandito.signal : Color.Bandito.text3)
                            .frame(width: 20)
                        Text(prompt.text)
                            .font(BanditoFont.text(size: 14, weight: 500))
                            .foregroundStyle(Color.Bandito.text)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.Bandito.surface1, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(selected ? Color.Bandito.signal : Color.Bandito.text.opacity(0.08), lineWidth: selected ? 1.5 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.sending)
                .banditoAnimation(BanditoMotion.ease, value: selected)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var field: some View {
        TextField(
            L10n.Onboarding.Task.placeholder, text: Binding(get: { model.text }, set: { model.setText($0) }),
            axis: .vertical
        )
        .lineLimit(1...4)
        .banditoField()
        .font(BanditoFont.text(size: 14.5, weight: 400))
        .focused($fieldFocused)
        .disabled(model.sending)
        .onSubmit { send() }
    }

    private var noAgent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.Onboarding.Task.noAgent)
                .font(BanditoFont.text(size: 14, weight: 400))
                .foregroundStyle(Color.Bandito.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button(L10n.Onboarding.Task.chooseCrew, action: onChooseCrew)
                .banditoButton(.signal())
                .fixedSize()
        }
    }

    private var nextAction: OnboardingNextAction? {
        guard !model.agentName.isEmpty else { return nil }
        let title = model.sending ? L10n.Onboarding.Task.sending : L10n.Onboarding.Task.send(name: model.agentName)
        return OnboardingNextAction(title: title, isEnabled: model.canSend) { send() }
    }

    private func send() {
        guard model.canSend else { return }
        Task {
            if await model.send() { onSent() }
        }
    }
}
