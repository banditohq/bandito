import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Files sidebar: favorite places, the folders where agents work, the server's disk, and the trash.
/// Tapping a place moves the browser there.
struct FilesSidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let server = app.currentServer {
            FilesSidebarContent(server: server)
                .id(server.id)
        } else {
            SidebarPlaceholder(mode: .files)
        }
    }
}

private struct FilesSidebarContent: View {
    let server: ServerModel
    @Environment(Router.self) private var router
    @State private var projectsRoot: String?
    @State private var disk: HostDisk?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(L10n.Files.favorites)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                    VStack(spacing: 1) {
                        ForEach(places) { place in
                            PlaceRow(place: place, isCurrent: router.filesPath == place.path) {
                                router.filesPath = place.path
                            }
                        }
                    }
                    .padding(.horizontal, 8)

                    SectionLabel(L10n.Files.agentsWorking)
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                        .padding(.bottom, 6)
                    VStack(spacing: 1) {
                        ForEach(server.sortedAgents) { agent in
                            AgentPlaceRow(agent: agent, isCurrent: router.filesPath == agent.cwd) {
                                router.filesPath = agent.cwd
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            if let disk {
                DiskBlock(disk: disk)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            Button {
                router.filesPath = trashPath
            } label: {
                Label(L10n.Files.trash, systemImage: "trash")
                    .font(.system(size: 12.5, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .banditoButton(.quiet())
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
        .task(id: server.id) { await loadExtras() }
    }

    private var isMac: Bool {
        guard let os = server.info?.os.lowercased() else { return false }
        return os.contains("mac") || os.contains("darwin")
    }

    /// `~/.Trash` on macOS, the freedesktop trash elsewhere.
    private var trashPath: String {
        isMac ? "~/.Trash" : "~/.local/share/Trash/files"
    }

    private var places: [Place] {
        var result = [
            Place(title: L10n.Files.Places.home, hint: "~", path: "~", icon: "house", tint: Color(hex: 0xBDB2A0)),
            Place(
                title: L10n.Files.Places.projects, hint: projectsRoot ?? "~/projects", path: projectsRoot ?? "~/projects",
                icon: "shippingbox", tint: Color(hex: 0xFFB067)),
            Place(
                title: L10n.Files.Places.memory, hint: "~/bandito/agents", path: "~/bandito/agents",
                icon: "pawprint", tint: Color(hex: 0xC8B6E8)),
        ]
        // Logs are a Linux place; on macOS /var/log is a symlink nobody browses. Unknown OS: show it.
        if !isMac {
            result.append(
                Place(title: L10n.Files.Places.logs, hint: "/var/log", path: "/var/log", icon: "list.bullet.rectangle", tint: Color(hex: 0xBDB2A0)))
        }
        result.append(
            Place(
                title: L10n.Files.Places.downloads, hint: "~/Downloads", path: "~/Downloads", icon: "arrow.down.circle",
                tint: Color(hex: 0xBDB2A0)))
        return result
    }

    private func loadExtras() async {
        if let first = try? await server.projects(limit: 1).first {
            projectsRoot = FilePath.parent(of: first.path)
        }
        if server.supports("host"), let stats = try? await server.hostStats() {
            disk = stats.disks.first
        }
    }
}

/// A favorite place in the list: icon, name, and the path it stands for.
private struct Place: Identifiable {
    var title: String
    var hint: String
    var path: String
    var icon: String
    var tint: Color

    var id: String { path }
}

private struct PlaceRow: View {
    let place: Place
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: place.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(place.tint)
                    .frame(width: 18)
                Text(place.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isCurrent ? Color.Bandito.text : Color.Bandito.text2)
                Spacer(minLength: 6)
                Text(place.hint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isCurrent ? Color.Bandito.text.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
    }
}

private struct AgentPlaceRow: View {
    let agent: Agent
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AgentAvatar(name: agent.name, size: 22)
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.Bandito.text)
                Spacer(minLength: 6)
                Text(agent.cwd)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.Bandito.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isCurrent ? Color.Bandito.text.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
    }
}

/// The server's disk: free space and a bar of used space.
private struct DiskBlock: View {
    let disk: HostDisk

    var body: some View {
        let free = max(disk.total - disk.used, 0)
        let fraction = disk.total > 0 ? min(Double(disk.used) / Double(disk.total), 1) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.Files.Disk.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.Bandito.text2)
                Spacer()
                Text(L10n.Files.Disk.free(size: ByteCountFormatter.string(fromByteCount: free, countStyle: .file)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.Bandito.text)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Bandito.text.opacity(0.08))
                    Capsule().fill(Color.Bandito.text).frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 6)
        }
        .padding(12)
        .background(Color.Bandito.text.opacity(0.03), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.Bandito.text.opacity(0.06)))
    }
}
