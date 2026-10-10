import BanditoDesign
import BanditoKit
import BanditoL10n
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
    /// The avatar's color and face as shown; the picker changes them at once and sends both.
    @State private var color: AvatarColor = .peach
    @State private var face: AvatarFace = .auto
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

    /// Takes the agent's avatar, or the look the name gives when none is saved. Only when no send is in flight.
    private func adoptLook() {
        guard avatarSync.isIdle else { return }
        let resolved = AvatarResolver.resolve(
            name: agent.name,
            color: agent.avatar.flatMap { AvatarColor(rawValue: $0.color) },
            face: agent.avatar.flatMap { AvatarFace(rawValue: $0.face) } ?? .auto)
        color = resolved.color
        face = resolved.face
    }

    /// The avatar; a click opens the color and face picker of the new agent sheet.
    private var avatarButton: some View {
        Button {
            pickingAvatar = true
        } label: {
            RaccoonAvatar(
                name: agent.name, color: color, face: face, size: 56,
                mood: AvatarMood.make(status: server.thread(for: agent.id).status, paused: agent.paused))
        }
        .banditoButton(.row(cornerRadius: 16, hoverOpacity: 0.06))
        .help(L10n.Inspector.Avatar.help)
        .popover(isPresented: $pickingAvatar, arrowEdge: .bottom) {
            AvatarStylePicker(color: colorChoice, face: faceChoice)
                .padding(14)
        }
    }

    private var colorChoice: Binding<AvatarColor> {
        Binding(get: { color }, set: { sendAvatar(color: $0, face: face) })
    }

    private var faceChoice: Binding<AvatarFace> {
        Binding(get: { face }, set: { sendAvatar(color: color, face: $0) })
    }

    /// Sends the whole avatar (color and face). A daemon without the field ignores it; the look then comes back from
    /// the name, and the picker shows that.
    private func sendAvatar(color next: AvatarColor, face nextFace: AvatarFace) {
        let before = (color, face)
        color = next
        face = nextFace
        avatarSync.begin()
        Task {
            defer { avatarSync.end() }
            do {
                _ = try await server.updateAgent(
                    agent.id, patch: AgentPatch(avatar: AvatarSpec(color: next.rawValue, face: nextFace.rawValue)))
            } catch {
                (color, face) = before
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
