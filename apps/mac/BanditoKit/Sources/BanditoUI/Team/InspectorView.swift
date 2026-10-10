import BanditoDesign
import BanditoKit
import BanditoL10n
import CoreGraphics
import SwiftUI

/// The details of the agent (⌘I), shown in the workbench: header, three tabs, and the tab's content.
/// The close button sits on the workbench's panel, so the header has one only when `onClose` is given.
struct InspectorView: View {
    var server: ServerModel
    var agent: Agent
    @Binding var tab: InspectorTab
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SegmentedPicker(
                selection: $tab,
                options: [
                    (InspectorTab.details, L10n.Inspector.details),
                    (InspectorTab.memory, L10n.Memory.title),
                    (InspectorTab.whereRuns, L10n.Inspector.whereRuns),
                ]
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .details: DetailsTab(server: server, agent: agent)
                    case .memory: MemoryTab(server: server, agent: agent)
                    case .whereRuns: WhereTab(server: server, agent: agent)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.Bandito.surface1)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.Bandito.line).frame(width: 1)
        }
        // Every inspector tab change (picker, or opened on a tab by the app) makes the tab sound.
        .onChange(of: tab) { _, _ in SoundPlayer.play(.tab) }
    }

    private var header: some View {
        IdentityCard(server: server, agent: agent, onClose: onClose)
            .id(agent.id)
    }

    private var subtitle: String {
        let model = agent.model.map {
            RuntimeModelDisplay.name(id: $0, runtime: agent.runtime, lists: server.runtimeModels)
        }
        return [agent.role.isEmpty ? nil : agent.role, agent.runtime.title, model].compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// The editable top card of the inspector: avatar, name and role. Name and role are saved on Return and when the
/// field loses focus. The close button sits top right.
private struct IdentityCard: View {
    var server: ServerModel
    var agent: Agent
    var onClose: (() -> Void)?

    @State private var name = ""
    @State private var role = ""
    @State private var error: UserFacingMessage?
    @State private var pickingAvatar = false
    /// What the avatar editor keeps while its popover is closed (a picture read from disk): choosing a file closes it.
    @State private var avatarEditor = AvatarEditorModel()
    /// The avatar as the editor shows it. Changes stay local while the editor is open and are sent when it closes.
    @State private var look = AvatarLook(palette: .peach, customHex: nil, face: .chevronDash, emoji: nil)
    @State private var avatarSync = InFlightCounter()
    @FocusState private var focused: Field?

    private enum Field: Hashable { case name, role }

    private func closeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Bandito.text3)
                .frame(width: 30, height: 30)
                .overlay(Circle().stroke(Color.Bandito.line, lineWidth: 1))
                .contentShape(Circle())
        }
        .banditoButton(.row(cornerRadius: 15, hoverOpacity: 0.08))
        .help(L10n.Common.close)
        .padding(16)
    }

    var body: some View {
        HStack(spacing: 14) {
            avatarButton
            VStack(alignment: .leading, spacing: 3) {
                TextField(L10n.AgentSheet.name, text: $name)
                    .textFieldStyle(.plain)
                    .font(BanditoFont.font(size: 19, weight: 650))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .focused($focused, equals: .name)
                    .onSubmit(commitName)
                // The field is always there: with no role, its placeholder asks for one (with a pencil).
                HStack(spacing: 5) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.Bandito.text3)
                    TextField(L10n.Inspector.addRole, text: $role)
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 12.5, weight: 400))
                        .foregroundStyle(Color.Bandito.text3)
                        .lineLimit(1)
                        .focused($focused, equals: .role)
                        .onSubmit(commitRole)
                }
                if let error {
                    UserFacingErrorView(message: error)
                }
            }
            Spacer(minLength: 8)
        }
        // Room on the right for the close button, which sits 16 pt from the top and the right edge.
        .padding(.leading, 20)
        .padding(.trailing, onClose == nil ? 20 : 60)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .topTrailing) {
            if let onClose {
                closeButton(onClose)
            }
        }

        .onChange(of: agent.avatar, initial: true) { _, _ in adoptLook() }
        .onChange(of: avatarSync.isIdle) { _, _ in adoptLook() }
        .onChange(of: pickingAvatar) { _, open in
            if !open { sendLookIfChanged() }
        }
        // The file panel closed the popover; the picture it gave is framed in the editor shown again.
        .onChange(of: avatarEditor.loadedCount) { _, _ in pickingAvatar = true }
        .onChange(of: agent.name, initial: true) { _, value in
            name = IdentityField.text(current: name, saved: value, editing: focused == .name)
        }
        .onChange(of: agent.role, initial: true) { _, value in
            role = IdentityField.text(current: role, saved: value, editing: focused == .role)
        }
        .onChange(of: focused) { previous, current in
            // Leaving a field saves it, like Return does.
            if previous == .name, current != .name { commitName() }
            if previous == .role, current != .role { commitRole() }
        }
    }

    /// Takes the agent's avatar, or the look the name gives when none is saved. Not while the editor is open, and only
    /// when no send is in flight.
    private func adoptLook() {
        guard avatarSync.isIdle, !pickingAvatar else { return }
        look = AvatarLook(spec: agent.avatar, name: agent.name)
    }

    /// The picture of the agent, when it has one and the daemon has loaded it.
    private var picture: CGImage? {
        _ = AvatarPictures.shared.version
        return AvatarPictureCache.pictureKey(for: agent, serverID: server.id.uuidString)
            .flatMap { AvatarPictures.shared.image(for: $0) }
    }

    /// The avatar; a click opens the editor: face, emoji, color and picture.
    private var avatarButton: some View {
        Button {
            pickingAvatar = true
        } label: {
            AvatarArtView(
                name: agent.name, look: look, picture: picture, size: 56,
                mood: AvatarMood.make(status: server.thread(for: agent.id).status, paused: agent.paused))
        }
        .banditoButton(.row(cornerRadius: 16, hoverOpacity: 0.06))
        .help(L10n.Inspector.Avatar.help)
        .task(id: AvatarPictureCache.pictureKey(for: agent, serverID: server.id.uuidString)) {
            guard server.supports("avatar_pictures") else { return }
            AvatarPictures.shared.retain(on: server)
            await AvatarPictures.shared.load(agent: agent, server: server)
        }
        .popover(isPresented: $pickingAvatar, arrowEdge: .bottom) {
            AvatarEditor(
                name: agent.name, look: $look, model: avatarEditor, picture: picture,
                pictureSupported: server.supports("avatar_pictures"),
                onSetPicture: { data in
                    // The daemon keeps a picture only on an avatar that is saved: an agent still on the automatic look
                    // gets the look shown now first.
                    if agent.avatar == nil {
                        _ = try await server.updateAgent(agent.id, patch: AgentPatch(avatar: look.spec))
                    }
                    try await server.setAgentAvatarImage(agent.id, data)
                },
                onRemovePicture: {
                    try await server.clearAgentAvatarImage(agent.id)
                })
        }
    }

    /// Sends the look when the editor closes, if it changed. A daemon without the field ignores it; the look then comes
    /// back from the name, and the editor shows that.
    private func sendLookIfChanged() {
        guard look != AvatarLook(spec: agent.avatar, name: agent.name) else { return }
        let before = AvatarLook(spec: agent.avatar, name: agent.name)
        avatarSync.begin()
        Task {
            defer { avatarSync.end() }
            do {
                _ = try await server.updateAgent(agent.id, patch: AgentPatch(avatar: look.spec))
            } catch {
                look = before
                self.error = UserFacingError.message(for: error)
            }
        }
    }

    private func commitName() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            name = agent.name
            return
        }
        guard value != agent.name else { return }
        save(AgentPatch(name: value)) { name = agent.name }
    }

    private func commitRole() {
        let value = role.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != agent.role else { return }
        save(AgentPatch(role: value)) { role = agent.role }
    }

    /// Sends the change; on failure the field goes back to the saved value and the error shows under the card.
    private func save(_ patch: AgentPatch, revert: @escaping () -> Void) {
        error = nil
        Task {
            do { _ = try await server.updateAgent(agent.id, patch: patch) } catch {
                self.error = UserFacingError.message(for: error)
                revert()
            }
        }
    }
}

/// The rule for a name or role field: the saved value is taken unless the person is typing in that field.
enum IdentityField {
    static func text(current: String, saved: String, editing: Bool) -> String {
        editing ? current : saved
    }
}

// MARK: - Shared pieces

/// A rounded group of rows, as in the design's detail cards.
struct InspectorCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.Bandito.text.opacity(0.025), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.Bandito.line, lineWidth: 1))
    }
}

/// One line of a card: the label on the left, the value (text or control) on the right.
struct InspectorRow<Value: View>: View {
    var label: String
    /// The calm layout of the agent's details: rows of 32 pt with 16 pt sides.
    var compact = false
    @ViewBuilder var value: Value

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            Spacer(minLength: 10)
            value
                .font(BanditoFont.font(size: 13, weight: 500))
                .foregroundStyle(Color.Bandito.text)
        }
        .padding(.horizontal, compact ? 16 : 14)
        .padding(.vertical, compact ? 3 : 11)
        .frame(minHeight: compact ? 32 : nil)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.Bandito.text.opacity(0.05)).frame(height: 1)
        }
    }
}

/// Error line for a failed change in a tab.
struct InspectorError: View {
    var message: UserFacingMessage

    var body: some View {
        UserFacingErrorView(message: message)
    }
}
