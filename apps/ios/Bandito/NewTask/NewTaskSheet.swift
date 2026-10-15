import AVFoundation
import BanditoDesign
import BanditoKit
import BanditoL10n
import Speech
import SwiftUI
import UIKit

/// A request to open the new-task sheet. New for every request, so the same sheet can open twice.
struct NewTaskRequest: Identifiable {
    let id = UUID()
    /// The dictation starts at once (a long press on the button).
    let dictate: Bool
}

/// What the screen does once the sheet is closed: the sheet cannot open another one while it is still closing.
enum NewTaskFollowUp: Equatable {
    case connect
    case crew
    case chat(serverID: UUID, agentID: String)
}

/// The new-task sheet: pick an agent, write or dictate the task, send. A sent task waits in `ChatOutbox` until its server
/// is online, and the agent's chat opens. The text is kept while the sheet is closed by a swipe.
struct NewTaskSheet: View {
    let servers: [ServerModel]
    let startsDictating: Bool
    /// Called once, before the sheet closes, with what the screen should do next.
    let onFinish: (NewTaskFollowUp) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The draft, kept by the scene until it is sent (a swipe that closed the sheet by mistake loses nothing).
    @SceneStorage("ios.newTask.draft") private var draft = ""
    /// The agent the person picked; nil means the first of the picker (the last one used).
    @State private var selectedID: String?
    /// Made at the first press of the microphone, not before: typing needs no recogniser.
    @State private var dictation: ChatDictation?
    /// The start of the dictation, kept so that closing the sheet can cancel it.
    @State private var dictationTask: Task<Void, Never>?
    @State private var listening = false
    /// Whether the sheet is on screen. A dictation that starts after the sheet closed is stopped at once.
    @State private var isShown = false
    @State private var askingDictation = false
    @State private var notice: DictationNotice?
    @State private var micShown = false
    @FocusState private var focused: Bool

    var body: some View {
        let options = NewTaskRules.order(NewTaskRules.options(servers: servers), last: NewTaskRules.lastChoice())
        let chosen = options.first { $0.id == selectedID } ?? options.first
        NavigationStack {
            Group {
                if options.isEmpty {
                    emptyState
                } else {
                    form(options: options, chosen: chosen)
                }
            }
            .background(Color.Bandito.bg.ignoresSafeArea())
            .navigationTitle(L10n.Ios.NewTask.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.Common.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            isShown = true
            micShown = NewTaskRules.microphoneShown(
                speech: SFSpeechRecognizer.authorizationStatus(),
                microphone: AVAudioApplication.shared.recordPermission,
                recognizerAvailable: SFSpeechRecognizer(locale: Locale.current)?.isAvailable ?? false)
            if startsDictating && micShown {
                microphoneTapped()
            } else {
                focused = true
            }
        }
        .onDisappear {
            // Closed during a dictation or while its start is pending (a swipe included): nothing keeps listening.
            isShown = false
            dictationTask?.cancel()
            dictationTask = nil
            stopDictation()
        }
        .alert(L10n.Ios.Chat.Dictation.explainTitle, isPresented: $askingDictation) {
            Button(L10n.Common.cancel, role: .cancel) {}
            Button(L10n.Composer.NewChapter.continue) { startDictation() }
        } message: {
            Text(L10n.Ios.Chat.Dictation.explainMessage)
        }
        .alert(
            L10n.Ios.Chat.Dictation.explainTitle,
            isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } }),
            presenting: notice
        ) { current in
            if current.offersSettings {
                Button(L10n.Ios.Chat.openSettings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button(L10n.Common.close, role: .cancel) {}
        } message: { current in
            Text(current.message)
        }
    }

    // MARK: the form

    private func form(options: [NewTaskOption], chosen: NewTaskOption?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BanditoSpace.s4) {
                Text(L10n.Ios.NewTask.to)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text2)
                    .padding(.horizontal, BanditoSpace.s4)
                agentPicker(options: options, chosen: chosen)
                composer(chosen: chosen)
            }
            .padding(.top, BanditoSpace.s2)
            .padding(.bottom, BanditoSpace.s4)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// The agents in a row, the chosen one outlined. A second server adds its name under the agent's.
    private func agentPicker(options: [NewTaskOption], chosen: NewTaskOption?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: BanditoSpace.s2) {
                ForEach(options) { option in
                    AgentChip(
                        option: option, showsServer: servers.count > 1, selected: option.id == chosen?.id
                    ) {
                        selectedID = option.id
                    }
                }
            }
            .padding(.horizontal, BanditoSpace.s4)
        }
    }

    private func composer(chosen: NewTaskOption?) -> some View {
        let canSend = NewTaskRules.canSend(text: draft, agentChosen: chosen != nil)
        return VStack(alignment: .leading, spacing: BanditoSpace.s3) {
            TextField(L10n.Thread.placeholder, text: $draft, axis: .vertical)
                .lineLimit(3...8)
                .font(BanditoFont.text(size: 16))
                .foregroundStyle(Color.Bandito.text)
                .focused($focused)
                .padding(BanditoSpace.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                        .fill(Color.Bandito.surface1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                        .stroke(Color.Bandito.line, lineWidth: 1)
                )
                .padding(.horizontal, BanditoSpace.s4)

            HStack(spacing: BanditoSpace.s3) {
                if micShown {
                    micButton
                }
                if let chosen, !isOnline(chosen) {
                    Text(L10n.Ios.NewTask.offline)
                        .font(BanditoFont.text(size: 13))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button {
                    if let chosen { send(chosen) }
                } label: {
                    Text(L10n.Thread.send)
                }
                .buttonStyle(SignalButtonStyle())
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .accessibilityIdentifier("newTask.send")
            }
            .padding(.horizontal, BanditoSpace.s4)
        }
    }

    private var micButton: some View {
        Button(action: microphoneTapped) {
            Image(systemName: listening ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(listening ? Color.Bandito.signal : Color.Bandito.text2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(listening ? L10n.Dictation.stop : L10n.Thread.dictate)
        .accessibilityIdentifier("newTask.mic")
    }

    private var emptyState: some View {
        VStack(spacing: BanditoSpace.s4) {
            Spacer()
            Text(L10n.Ios.NewTask.empty)
                .font(BanditoFont.text(size: 15))
                .foregroundStyle(Color.Bandito.text2)
                .multilineTextAlignment(.center)
            Button {
                onFinish(servers.isEmpty ? .connect : .crew)
                dismiss()
            } label: {
                Text(servers.isEmpty ? L10n.Empty.NoServers.action : L10n.Ios.Crew.createAgent)
            }
            .buttonStyle(SignalButtonStyle())
            Spacer()
        }
        .padding(BanditoSpace.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: sending

    private func isOnline(_ option: NewTaskOption) -> Bool {
        servers.first { $0.id == option.serverID }?.state == .connected
    }

    private func send(_ option: NewTaskOption) {
        stopDictation()
        ChatOutbox.shared.enqueue(
            serverID: option.serverID, agentID: option.agentID, text: NewTaskRules.message(for: draft))
        NewTaskRules.remember(NewTaskChoice(serverID: option.serverID, agentID: option.agentID))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        draft = ""
        onFinish(.chat(serverID: option.serverID, agentID: option.agentID))
        dismiss()
    }

    // MARK: dictation

    private func microphoneTapped() {
        if listening {
            stopDictation()
            return
        }
        // The explanation comes before the system's first questions (as in the chat).
        if ChatDictation.hasAsked {
            startDictation()
        } else {
            askingDictation = true
        }
    }

    private func startDictation() {
        let controller = dictation ?? ChatDictation()
        dictation = controller
        let base = draft
        listening = true
        dictationTask?.cancel()
        dictationTask = Task { @MainActor in
            let outcome = await controller.start(
                onPartial: { partial in draft = Self.dictated(base: base, partial: partial) },
                onEnd: { listening = false })
            // The sheet closed while the permissions were asked: the recognition that just started is stopped.
            guard isShown else {
                controller.stop()
                listening = false
                return
            }
            listening = controller.isListening
            switch outcome {
            case .started, .finished:
                break
            case .deniedMicrophone:
                notice = DictationNotice(message: L10n.Ios.Chat.Dictation.deniedMicrophone, offersSettings: true)
            case .deniedSpeech:
                notice = DictationNotice(message: L10n.Ios.Chat.Dictation.deniedSpeech, offersSettings: true)
            case .unavailable:
                notice = DictationNotice(message: L10n.Ios.Chat.Dictation.unavailable, offersSettings: false)
            case .failed:
                notice = DictationNotice(message: L10n.Dictation.failed, offersSettings: false)
            }
        }
    }

    private func stopDictation() {
        dictation?.stop()
        listening = false
    }

    /// The text before the dictation, then the words recognised so far, with a space between them when needed.
    private static func dictated(base: String, partial: String) -> String {
        let needsSpace = !(base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n"))
        return base + (needsSpace ? " " : "") + partial
    }
}

/// A message the dictation alert shows.
private struct DictationNotice: Identifiable {
    let id = UUID()
    let message: String
    /// Whether the alert offers iOS Settings (a refused permission can only be changed there).
    let offersSettings: Bool
}

/// One agent in the picker: its avatar and name, the server's name under it when there is more than one server.
private struct AgentChip: View {
    let option: NewTaskOption
    let showsServer: Bool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: BanditoSpace.s1) {
                CrewAvatar(name: option.agentName, look: option.look, mood: option.mood, size: 40)
                Text(option.agentName)
                    .font(BanditoFont.text(size: 13, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                if showsServer {
                    Text(option.serverName)
                        .font(BanditoFont.text(size: 11))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                }
            }
            .frame(width: 88)
            .padding(.vertical, BanditoSpace.s2)
            .background(
                RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                    .fill(Color.Bandito.surface1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BanditoRadius.md, style: .continuous)
                    .stroke(selected ? Color.Bandito.signal : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.agentName)
        .accessibilityValue(showsServer ? option.serverName : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
