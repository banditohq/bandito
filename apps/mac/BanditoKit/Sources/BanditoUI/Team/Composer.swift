import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The message box under the thread. Enter sends, Shift+Enter starts a new line. While a turn runs,
/// the send button becomes Stop (⌘. is the menu command, see `BanditoCommands`).
struct Composer: View {
    @Binding var draft: String
    var agentName: String
    var running: Bool
    /// Share of the context window in use, 0 to 1.
    var contextFraction: Double
    var onSend: () -> Void
    var onStop: () -> Void

    @FocusState private var focused: Bool

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                Button(action: attachFile) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.Bandito.text2)
                        .frame(width: 34, height: 34)
                        .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.Thread.attach)

                TextField(L10n.Thread.placeholder(name: agentName), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 14.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.vertical, 8)
                    .onKeyPress(keys: [.return]) { press in
                        // Shift+Return is left to the field, which inserts a line break.
                        if press.modifiers.contains(.shift) { return .ignored }
                        if canSend && !running { onSend() }
                        return .handled
                    }

                contextIndicator
                    .padding(.bottom, 9)

                Button {} label: {
                    Image(systemName: "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.Bandito.text3)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .help(L10n.Thread.dictate)

                sendOrStop
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .background(Color.Bandito.surface2, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 10)

            HStack(spacing: 14) {
                Text(L10n.Thread.hintSend)
                Text(L10n.Thread.hintNewLine)
                Text(L10n.Thread.hintStop)
                Text(L10n.Thread.hintSearch)
            }
            .font(BanditoFont.font(size: 11, weight: 400, mono: true))
            .foregroundStyle(Color.Bandito.text3.opacity(0.7))
        }
        .onAppear { focused = true }
    }

    private var contextIndicator: some View {
        HStack(spacing: 6) {
            ContextRing(fraction: contextFraction, size: 16)
            Text("\(Int((contextFraction * 100).rounded()))%")
                .font(BanditoFont.font(size: 11.5, weight: 400, mono: true))
        }
        .foregroundStyle(Color.Bandito.text3)
        .help(L10n.Composer.contextHint)
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if running {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.Bandito.bg)
                    .frame(width: 34, height: 34)
                    .background(Color.Bandito.text, in: Circle())
            }
            .buttonStyle(.plain)
            .help(L10n.Thread.stop)
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.Bandito.bg)
                    .frame(width: 34, height: 34)
                    .background(Color.Bandito.text, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .help(L10n.Thread.send)
        }
    }

    /// Until uploads exist, an attached file is referred to by its name: the file path goes into the text as `@name`.
    private func attachFile() {
        guard let url = FilePanels.openURL() else { return }
        let separator = draft.isEmpty || draft.hasSuffix(" ") ? "" : " "
        draft += "\(separator)@\(url.lastPathComponent) "
        focused = true
    }
}
