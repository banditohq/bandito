import BanditoDesign
import BanditoL10n
import SwiftUI

/// Settings → Keys and gestures: every shortcut by context, with recording, conflicts, presets,
/// export and import; and the six trackpad gestures with a swipe sensitivity slider.
struct KeysAndGesturesSection: View {
    @Environment(Keymap.self) private var keymap
    @Environment(GestureSettings.self) private var gestures

    @State private var tab: Tab = .keys
    @State private var query = ""
    @State private var preset: KeymapPreset = .bandito
    /// The command being recorded now, if any.
    @State private var recording: String?
    /// A recorded shortcut that another command already uses, waiting for "Replace".
    @State private var pending: PendingBinding?
    @State private var message: UserFacingMessage?
    @State private var recorder = KeyRecorderBox()

    enum Tab: Hashable {
        case keys, gestures
    }

    struct PendingBinding: Equatable {
        var commandID: String
        var binding: KeyBinding
        var conflicts: [Command]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            toolbar
                .padding(.bottom, 14)
            if tab == .keys {
                keyGroups
                keysFooter
            } else {
                gestureCards
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDisappear { stopRecording() }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(SettingsSection.keysGestures.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(L10n.Settings.keysIntro)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
            Spacer(minLength: 12)
            if tab == .keys {
                SegmentedPicker(
                    selection: Binding(get: { preset }, set: { choose($0) }),
                    options: KeymapPreset.allCases.map { ($0, $0.title) })
            }
        }
        .padding(.bottom, 18)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
                TextField(L10n.Keys.search, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.Bandito.text.opacity(0.08)))
            SegmentedPicker(
                selection: $tab,
                options: [(Tab.keys, L10n.Keys.tabKeys), (Tab.gestures, L10n.Keys.tabGestures)])
        }
    }

    // MARK: keys

    /// Groups in the order of `KeyContext`, split over two columns.
    private var keyGroups: some View {
        let groups = KeyContext.allCases.compactMap { context -> (KeyContext, [Command])? in
            let commands = Command.all.filter { $0.context == context && matches($0) }
            return commands.isEmpty ? nil : (context, commands)
        }
        let left = groups.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let right = groups.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
        return ScrollView {
            HStack(alignment: .top, spacing: 26) {
                column(left)
                column(right)
            }
            .padding(.bottom, 12)
        }
    }

    private func column(_ groups: [(KeyContext, [Command])]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.0) { context, commands in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Color.Bandito.text3)
                        .padding(.top, 6)
                        .padding(.bottom, 4)
                    ForEach(commands) { command in
                        commandRow(command)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func commandRow(_ command: Command) -> some View {
        let custom = keymap.isCustomized(command.id)
        let isRecording = recording == command.id
        let waiting = pending.flatMap { $0.commandID == command.id ? $0 : nil }
        return HStack(spacing: 10) {
            Text(command.title)
                .font(.system(size: 13))
                .foregroundStyle(custom ? Color.Bandito.signalGlow : Color.Bandito.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let waiting, let taken = waiting.conflicts.first {
                Text(L10n.Keys.conflict(name: taken.title))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.signalGlow)
                    .lineLimit(1)
                Button(L10n.Keys.replace) { replace(waiting) }
                    .buttonStyle(QuietButtonStyle(size: .regular))
            }
            Button {
                startRecording(command)
            } label: {
                keyCap(text: isRecording ? L10n.Keys.recording : (keymap.binding(for: command.id)?.symbols ?? "—"),
                       custom: custom, recording: isRecording)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(command.title)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isRecording ? Color.Bandito.signal.opacity(0.06) : .clear))
    }

    private func keyCap(text: String, custom: Bool, recording: Bool) -> some View {
        let tint = recording || custom ? Color.Bandito.signal : Color.Bandito.text.opacity(0.14)
        return Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(recording || custom ? Color.Bandito.signalGlow : Color.Bandito.text)
            .padding(.horizontal, 9)
            .frame(minWidth: 44, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(recording ? Color.Bandito.signal.opacity(0.12) : Color.Bandito.text.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(tint.opacity(recording || custom ? 0.8 : 1)))
    }

    private var keysFooter: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.Bandito.signal)
                .frame(width: 8, height: 8)
            Text(L10n.Keys.customizedCount(count: keymap.customizedCount))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text3)
            if let message {
                UserFacingErrorView(message: message)
            }
            Spacer()
            Button(L10n.Keys.exportButton) { exportKeys() }
                .buttonStyle(QuietButtonStyle(size: .regular))
            Button(L10n.Keys.importButton) { importKeys() }
                .buttonStyle(QuietButtonStyle(size: .regular))
            Button(L10n.Keys.resetAll) {
                stopRecording()
                pending = nil
                keymap.resetAll()
                preset = .bandito
            }
            .buttonStyle(QuietButtonStyle(size: .regular))
            .foregroundStyle(Color.Bandito.danger)
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    private func matches(_ command: Command) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return command.title.localizedCaseInsensitiveContains(needle)
            || (keymap.binding(for: command.id)?.symbols.localizedCaseInsensitiveContains(needle) ?? false)
    }

    private func choose(_ newPreset: KeymapPreset) {
        stopRecording()
        pending = nil
        preset = newPreset
        keymap.apply(preset: newPreset)
    }

    // MARK: recording

    private func startRecording(_ command: Command) {
        pending = nil
        message = nil
        recording = command.id
        recorder.start { capture in
            handle(capture, for: command)
        }
    }

    private func handle(_ capture: KeyCapture, for command: Command) {
        recording = nil
        switch capture {
        case .cancel:
            return
        case .clear:
            keymap.set(nil, for: command.id)
        case .binding(let binding):
            let conflicts = keymap.conflicts(for: binding, in: command.context, excluding: command.id)
            if conflicts.isEmpty {
                keymap.set(binding, for: command.id)
            } else {
                pending = PendingBinding(commandID: command.id, binding: binding, conflicts: conflicts)
            }
        }
    }

    private func replace(_ waiting: PendingBinding) {
        for other in waiting.conflicts {
            keymap.set(nil, for: other.id)
        }
        keymap.set(waiting.binding, for: waiting.commandID)
        pending = nil
    }

    private func stopRecording() {
        recorder.stop()
        recording = nil
    }

    // MARK: export and import

    private func exportKeys() {
        guard let url = FilePanels.saveURL(suggestedName: "bandito-keys.json") else { return }
        do {
            try keymap.exportData().write(to: url, options: .atomic)
            message = nil
        } catch {
            message = UserFacingError.message(for: error)
        }
    }

    private func importKeys() {
        guard let url = FilePanels.openURL() else { return }
        do {
            try keymap.importData(Data(contentsOf: url))
            preset = .bandito
            message = nil
        } catch {
            message = UserFacingMessage(text: L10n.Keys.importFailed)
        }
    }

    // MARK: gestures

    private var gestureCards: some View {
        @Bindable var gestures = gestures
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(Gesture.allCases, id: \.self) { gesture in
                        gestureCard(gesture)
                    }
                }
                HStack(spacing: 14) {
                    Text(L10n.Gestures.sensitivity)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text)
                    Text(L10n.Gestures.softer)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                    Slider(value: $gestures.swipeSensitivity, in: 0...1)
                        .tint(Color.Bandito.signal)
                    Text(L10n.Gestures.sharper)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.Bandito.text3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .banditoCard()
            }
            .padding(.top, 4)
        }
    }

    private func gestureCard(_ gesture: Gesture) -> some View {
        let on = gestures.isEnabled(gesture)
        return HStack(alignment: .center, spacing: 14) {
            Image(systemName: gesture.systemImage)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Color.Bandito.signalGlow)
                .frame(width: 96, height: 72)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.Bandito.bg))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.Bandito.text.opacity(0.08)))
            VStack(alignment: .leading, spacing: 4) {
                Text(gesture.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                Text(gesture.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.Bandito.text3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(gesture.whereUsed)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.text3.opacity(0.8))
            }
            Spacer(minLength: 0)
            Toggle(
                gesture.title,
                isOn: Binding(
                    get: { gestures.isEnabled(gesture) },
                    set: { gestures.setEnabled(gesture, $0) })
            )
            .labelsHidden()
            .toggleStyle(BanditoToggleStyle())
            .accessibilityValue(on ? "on" : "off")
        }
        .padding(12)
        .banditoCard()
    }
}

/// Holds the recorder for the life of the view. On platforms without key monitoring it does nothing.
@MainActor
final class KeyRecorderBox {
    #if os(macOS)
    private let recorder = KeyRecorder()
    #endif

    func start(_ onCapture: @escaping (KeyCapture) -> Void) {
        #if os(macOS)
        recorder.start(onCapture)
        #endif
    }

    func stop() {
        #if os(macOS)
        recorder.stop()
        #endif
    }
}
