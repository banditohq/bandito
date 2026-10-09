import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// Files sidebar: favorite places (the built-in ones and the folders the user added), the folders where agents
/// work, the server's disk, and the trash. Tapping a place moves the browser there.
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
    @State private var home: String?
    @State private var disk: HostDisk?
    /// Shows that a folder is about to be dropped on Favorites.
    @State private var favoritesTargeted = false

    private var thisMac: Bool {
        FilesServer.isThisMac(server.config.endpoint)
    }

    private var isMac: Bool {
        FilesServer.isMac(os: server.info?.os)
    }

    var body: some View {
        let favorites = router.files.favorites
        let allBuiltIn = places
        // A favorite that is also a built-in place (Projects, say) is shown once, as the built-in one.
        let builtInKeys = Set(allBuiltIn.compactMap { FavoritePath.normalized($0.path, home: home) })
        let userPlaces = favorites.paths(for: server.id).filter { !builtInKeys.contains($0) }.map { path in
            Place(title: FilePath.lastComponent(path), path: path, icon: "folder", tint: Color(hex: 0xBDB2A0), isBuiltIn: false)
        }
        let hidden = favorites.hidden(for: server.id)
        let builtIn = allBuiltIn.filter { !hidden.contains($0.path) }

        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(L10n.Files.favorites)
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 6)
                    VStack(spacing: 1) {
                        ForEach(builtIn + userPlaces) { place in
                            placeRow(place)
                        }
                        if !hidden.isEmpty {
                            Button {
                                favorites.unhideAll(serverID: server.id)
                            } label: {
                                Text(L10n.Files.showHiddenPlaces)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color.Bandito.text3)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .frame(height: 26)
                            }
                            .banditoButton(.row(cornerRadius: 8))
                        }
                    }
                    .padding(.horizontal, 8)
                    .background(
                        favoritesTargeted ? Color.Bandito.signal.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
                    .dropDestination(for: String.self) { paths, _ in
                        let candidates = paths.filter { $0.hasPrefix("/") || $0 == "~" || $0.hasPrefix("~/") }
                        guard !candidates.isEmpty else { return false }
                        Task { await addFolders(candidates) }
                        return true
                    } isTargeted: { favoritesTargeted = $0 }

                    // Shown only when some agent works in a folder.
                    let agentsInFolders = server.sortedAgents.filter { !$0.cwd.isEmpty }
                    if !agentsInFolders.isEmpty {
                        SectionLabel(L10n.Files.agentsWorking)
                            .padding(.horizontal, 18)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                        VStack(spacing: 1) {
                            ForEach(agentsInFolders) { agent in
                                AgentPlaceRow(agent: agent, isCurrent: router.filesPath == agent.cwd) {
                                    router.filesPath = agent.cwd
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                    }
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
                    .lineLimit(1)
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

    /// `~/.Trash` on macOS, the freedesktop trash elsewhere.
    private var trashPath: String {
        isMac ? "~/.Trash" : "~/.local/share/Trash/files"
    }

    /// The built-in places. Projects appears only when the server has a folder that holds projects.
    private var places: [Place] {
        var result: [Place] = [
            Place(title: L10n.Files.Places.home, path: "~", icon: "house", tint: Color(hex: 0xBDB2A0), isBuiltIn: true)
        ]
        if let projectsRoot {
            result.append(
                Place(
                    title: L10n.Files.Places.projects, path: projectsRoot, icon: "shippingbox",
                    tint: Color(hex: 0xFFB067), isBuiltIn: true))
        }
        result.append(
            Place(
                title: L10n.Files.Places.memory, path: "~/bandito/agents", icon: "pawprint", tint: Color(hex: 0xC8B6E8),
                isBuiltIn: true))
        // Logs are a Linux place; on macOS /var/log is a symlink nobody browses. Unknown OS: show it.
        if !isMac {
            result.append(
                Place(
                    title: L10n.Files.Places.logs, path: "/var/log", icon: "list.bullet.rectangle",
                    tint: Color(hex: 0xBDB2A0), isBuiltIn: true))
        }
        result.append(
            Place(
                title: L10n.Files.Places.downloads, path: "~/Downloads", icon: "arrow.down.circle",
                tint: Color(hex: 0xBDB2A0), isBuiltIn: true))
        return result
    }

    private func placeRow(_ place: Place) -> some View {
        PlaceRow(place: place, isCurrent: router.filesPath == place.path) {
            router.filesPath = place.path
        }
        .help(FilePath.expandHome(place.path, home: home))
        .contextMenu { placeMenu(place) }
    }

    /// The menu of a favorite: open it, a terminal in it, copy its path, and remove it (or hide a built-in one).
    /// On this Mac, show it in Finder.
    @ViewBuilder
    private func placeMenu(_ place: Place) -> some View {
        let absolute = FilePath.expandHome(place.path, home: home)
        let isAbsolute = !absolute.hasPrefix("~")
        Button { router.filesPath = place.path } label: {
            Label(L10n.Files.Preview.open, systemImage: "arrow.up.forward.square")
        }
        if server.supports("terminals") {
            Button { router.openTerminalHere(absolute) } label: {
                Label(L10n.Files.Menu.terminal, systemImage: "terminal")
            }
            .disabled(!isAbsolute)
        }
        Button { FileBridge.copy(absolute) } label: {
            Label(L10n.Files.Menu.copyPath, systemImage: "doc.on.doc")
        }
        if place.isBuiltIn {
            Button { router.files.favorites.hide(place.path, serverID: server.id) } label: {
                Label(L10n.Files.hidePlace, systemImage: "eye.slash")
            }
        } else {
            Button { router.files.favorites.remove(place.path, serverID: server.id, home: home) } label: {
                Label(L10n.Files.Menu.favoriteRemove, systemImage: "star.slash")
            }
        }
        if thisMac {
            Divider()
            Button { FileBridge.showInFinder(URL(fileURLWithPath: absolute)) } label: {
                Label(L10n.Files.showInFinder, systemImage: "folder")
            }
            .disabled(!isAbsolute)
        }
    }

    /// Adds the dropped paths the server confirms are folders. Anything else is ignored, and so is a path the
    /// server cannot find.
    private func addFolders(_ paths: [String]) async {
        for path in paths {
            guard let entry = try? await server.stat(path), entry.kind == .dir else { continue }
            router.files.favorites.add(entry.path, serverID: server.id, home: home, isMac: isMac)
        }
    }

    /// The home folder is needed to show absolute paths, the projects place, and the disk.
    private func loadExtras() async {
        home = try? await server.stat("~").path
        if let projects = try? await server.projects(limit: 50) {
            projectsRoot = ProjectsRoot.pick(projects)
        }
        if server.supports("host"), let stats = try? await server.hostStats() {
            disk = stats.disks.first
        }
    }
}

/// A favorite place in the list: icon and name. The full path is in the tooltip, not in the row.
private struct Place: Identifiable {
    var title: String
    var path: String
    var icon: String
    var tint: Color
    /// Built-in places can be hidden; the folders the user added are removed.
    var isBuiltIn: Bool

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
                    .lineLimit(1)
                Spacer(minLength: 6)
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
                    .lineLimit(1)
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(isCurrent ? Color.Bandito.text.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 10))
        .help(agent.cwd)
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
                    .lineLimit(1)
                    .fixedSize()
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
