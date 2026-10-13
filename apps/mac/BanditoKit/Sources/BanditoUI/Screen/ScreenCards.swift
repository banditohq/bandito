#if os(macOS)
import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import Observation
import SwiftUI

/// What every workplace's screen is doing, for the cards of the Screen sidebar. It asks `screen.status` (which starts
/// nothing) for each workplace; the chosen one has its own model and poll, this keeps the rest current. A value is
/// written only when it changed.
@MainActor
@Observable
final class ScreenOverview {
    let server: ServerModel
    private(set) var states: [String: ScreenCardState] = [:]

    init(server: ServerModel) {
        self.server = server
    }

    func state(of id: String) -> ScreenCardState {
        states[id] ?? .unknown
    }

    /// The screen of `id` was just put to sleep: its card says so now, not at the next poll.
    func markAsleep(_ id: String) {
        if states[id] != .asleep { states[id] = .asleep }
    }

    func poll(_ workspaces: [Workspace]) async {
        guard server.supports("screen") else { return }
        for workspace in workspaces {
            let previous = states[workspace.id] ?? .unknown
            var next = previous
            do {
                let status = try await server.screenStatus(workspace: WorkspacePickerLogic.rpcParameter(workspace.id))
                next = ScreenCardRules.state(status: status, refusal: nil, workspaceID: workspace.id, previous: previous)
            } catch let error as RPCError {
                next = ScreenCardRules.state(status: nil, refusal: error, workspaceID: workspace.id, previous: previous)
            } catch {
                // A dropped connection says nothing about the screen; the card keeps what it showed.
            }
            if states[workspace.id] != next { states[workspace.id] = next }
        }
        let ids = Set(workspaces.map(\.id))
        if states.keys.contains(where: { !ids.contains($0) }) {
            states = states.filter { ids.contains($0.key) }
        }
    }
}

@MainActor
final class ScreenOverviews {
    static let shared = ScreenOverviews()
    private var overviews: [UUID: ScreenOverview] = [:]

    func overview(for server: ServerModel) -> ScreenOverview {
        if let overview = overviews[server.id] { return overview }
        let overview = ScreenOverview(server: server)
        overviews[server.id] = overview
        return overview
    }
}

/// What a card shows. Equatable, so a poll that changes nothing redraws nothing.
struct ScreenCardData: Equatable, Identifiable {
    let id: String
    let name: String
    let isContainer: Bool
    let state: ScreenCardState
    /// The state of the container itself; the shared server always runs.
    let live: WorkspaceLiveState
    let selected: Bool

    /// The line under the name.
    var subtitle: String {
        switch state {
        case .running: L10n.Screen.Card.running
        case .asleep: L10n.Screen.Card.asleep
        case .unknown: L10n.Screen.Card.checking
        case .unavailable: L10n.Screen.Card.unavailable
        }
    }

    static func make(workspaces: [Workspace], states: [String: ScreenCardState], selectedID: String) -> [ScreenCardData] {
        workspaces.map { workspace in
            ScreenCardData(
                id: workspace.id,
                name: workspace.kind == .shared ? L10n.Workspace.Shared.title : workspace.name,
                isContainer: workspace.kind == .container, state: states[workspace.id] ?? .unknown,
                live: WorkspacePickerLogic.liveState(workspace), selected: workspace.id == selectedID)
        }
    }
}

/// The card of one workplace's screen: a preview of its last picture, the name, the screen's state, and (for a
/// container that is not running) the container's state.
struct ScreenCard: View, Equatable {
    let data: ScreenCardData
    let preview: ScreenPreviewBox
    let onSelect: () -> Void

    nonisolated static func == (lhs: ScreenCard, rhs: ScreenCard) -> Bool {
        lhs.data == rhs.data && lhs.preview === rhs.preview
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    ScreenThumbnail(preview: preview, state: data.state)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Image(systemName: data.isContainer ? "shippingbox" : "house")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.Bandito.text3)
                                .accessibilityHidden(true)
                            Text(data.name)
                                .font(BanditoFont.text(size: 13, weight: 600))
                                .foregroundStyle(Color.Bandito.text)
                                .lineLimit(2)
                        }
                        Text(data.subtitle)
                            .font(BanditoFont.text(size: 11.5, weight: 400))
                            .foregroundStyle(Color.Bandito.text3)
                            .lineLimit(2)
                        if data.isContainer, data.live != .containerRunning {
                            Text(WorkspaceStateText.text(data.live))
                                .font(BanditoFont.text(size: 11, weight: 400))
                                .foregroundStyle(WorkspaceStateText.color(data.live))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    data.selected ? Color.Bandito.signal.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(data.selected ? Color.Bandito.signal.opacity(0.25) : Color.clear)
                }
                .contentShape(Rectangle())
            }
            .banditoButton(.row(cornerRadius: 11))
            .accessibilityAddTraits(data.selected ? .isSelected : [])

            // The daemon cannot show this workplace's screen: say why, and where the fix is.
            if data.state == .unavailable {
                Text(L10n.Screen.Card.unavailableHint)
                    .font(BanditoFont.text(size: 11.5, weight: 400))
                    .lineSpacing(2)
                    .foregroundStyle(Color.Bandito.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
        }
    }

    private var dotColor: Color {
        switch data.state {
        case .running: Color.Bandito.ok
        case .asleep, .unknown: BanditoPalette.idle
        case .unavailable: Color.Bandito.danger
        }
    }
}

/// The preview: the last picture of the screen, or a dark tile while there is none. Reads its own box, so a new
/// picture redraws only this tile.
private struct ScreenThumbnail: View {
    let preview: ScreenPreviewBox
    let state: ScreenCardState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(
                    colors: [Color(red: 0.23, green: 0.16, blue: 0.1), Color(red: 0.11, green: 0.16, blue: 0.23)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image = preview.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .opacity(state == .running ? 1 : 0.45)
            } else {
                Image(systemName: state == .unavailable ? "exclamationmark.triangle" : "display")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text3)
            }
        }
        .frame(width: 60, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.Bandito.text.opacity(0.1)) }
        .accessibilityHidden(true)
    }
}
#endif
