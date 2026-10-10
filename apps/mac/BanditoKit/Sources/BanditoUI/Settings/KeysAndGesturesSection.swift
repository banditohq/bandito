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

    /// Below this content width the two key columns become one, so no row is squeezed.
    static let twoColumnsMinWidth: CGFloat = 760

    var body: some View {
        // The page takes exactly the width the window gives it and clips anything wider. Without this, a
        // wide header or footer pushes the settings sidebar out of the window.
        GeometryReader { geometry in
            page(width: geometry.size.width)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
        .onDisappear { stopRecording() }
    }

    private func page(width: CGFloat) -> some View {
        let contentWidth = width - 2 * 34
        return VStack(alignment: .leading, spacing: 0) {
            header
            toolbar
                .padding(.bottom, 14)
            if tab == .keys {
                keyGroups(twoColumns: contentWidth >= Self.twoColumnsMinWidth)
                keysFooter
            } else {
                gestureCards
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(SettingsSection.keysGestures.title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                Text(L10n.Settings.keysIntro)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.Bandito.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if tab == .keys {
                presetPicker
            }
        }
        .padding(.bottom, 18)
    }

    /// The preset switch: a segmented control when it fits, otherwise a compact select that names the current preset.
    private var presetPicker: some View {
        ViewThatFits(in: .horizontal) {
            SegmentedPicker(
                selection: Binding(get: { preset }, set: { choose($0) }),
                options: KeymapPreset.allCases.map { ($0, $0.title) })
                .fixedSize()
            BanditoSelect(
                selection: Binding(get: { preset }, set: { choose($0) }),
                sections: [SelectSection(options: KeymapPreset.allCases.map { SelectOption(value: $0, title: $0.title) })],
                label: L10n.Keys.presetMenu(name: preset.title), placeholder: preset.title,
                field: { _ in
                    // The field names the set ("Set: Bandito"); the panel lists the sets.
                    HStack(spacing: 8) {
                        Text(L10n.Keys.presetMenu(name: preset.title))
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .fixedSize()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.Bandito.text3)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.Bandito.text)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.Bandito.text.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(Color.Bandito.text.opacity(0.12), lineWidth: 1))
                },
                footer: { _ in EmptyView() },
                style: .compact)
                .fixedSize()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.Bandito.text3)
                TextField(L10n.Keys.search, text: $query)
                    .banditoField()
                    .font(.system(size: 13))
                    .foregroundStyle(Color.Bandito.text)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.Bandito.text.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.Bandito.text.opacity(0.08)))
            SegmentedPicker(
                selection: $tab,
                options: [(Tab.keys, L10n.Keys.tabKeys), (Tab.gestures, L10n.Keys.tabGestures)])
                .fixedSize()
        }
    }

    // MARK: keys

    /// Groups in the order of `KeyContext`: two columns when there is room, otherwise one.
    private func keyGroups(twoColumns: Bool) -> some View {
        let groups = KeyContext.allCases.compactMap { context -> (KeyContext, [Command])? in
            let commands = Command.all.filter { $0.context == context && matches($0) }
            return commands.isEmpty ? nil : (context, commands)
        }
        return ScrollView {
            Group {
                if twoColumns {
                    let left = groups.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
                    let right = groups.enumerated().filter { !$0.offset.isMultiple(of: 2) }.map(\.element)
                    HStack(alignment: .top, spacing: 26) {
                        column(left)
                        column(right)
                    }
                } else {
                    column(groups)
                }
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let waiting, let taken = waiting.conflicts.first {
                Text(L10n.Keys.conflict(name: taken.title))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.Bandito.signalGlow)
                    .lineLimit(1)
                Button(L10n.Keys.replace) { replace(waiting) }
                    .banditoButton(.quiet(size: .regular))
                    .fixedSize()
            }
            Button {
                startRecording(command)
            } label: {
                keyCap(text: isRecording ? L10n.Keys.recording : (keymap.binding(for: command.id)?.symbols ?? "—"),
                       custom: custom, recording: isRecording)
            }
            .banditoButton(.row(cornerRadius: 6, hoverOpacity: 0.08))
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
            .lineLimit(1)
            .fixedSize()
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

    /// Status and actions. The buttons fold into one «…» menu when the row is too narrow; the error line sits below.
    private var keysFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                footerRow(folded: false)
                footerRow(folded: true)
            }
            if let message {
                UserFacingErrorView(message: message)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.text.opacity(0.06)).frame(height: 1)
        }
    }

    private func footerRow(folded: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.Bandito.signal)
                .frame(width: 8, height: 8)
            Text(L10n.Keys.customizedCount(count: keymap.customizedCount))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.Bandito.text3)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 8)
            if folded {
                Menu {
                    Button(L10n.Keys.exportButton) { exportKeys() }
                    Button(L10n.Keys.importButton) { importKeys() }
                    Divider()
                    Button(L10n.Keys.resetAll, role: .destructive) { resetAll() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.Bandito.text2)
                        .frame(width: 30, height: 26)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .banditoButton(.icon(size: 30, label: L10n.Keys.moreActions))
                .fixedSize()
            } else {
                Button(L10n.Keys.exportButton) { exportKeys() }
                    .banditoButton(.quiet(size: .regular))
                    .fixedSize()
                Button(L10n.Keys.importButton) { importKeys() }
                    .banditoButton(.quiet(size: .regular))
                    .fixedSize()
                Button(L10n.Keys.resetAll) { resetAll() }
                    .banditoButton(.quiet(size: .regular))
                    .foregroundStyle(Color.Bandito.danger)
                    .fixedSize()
            }
        }
    }

    private func resetAll() {
        stopRecording()
        pending = nil
        keymap.resetAll()
        preset = .bandito
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
                // Two cards when there is room, one when the window is narrow, so the card text is never squeezed.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
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
