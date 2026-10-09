import BanditoDesign
import BanditoKit
import BanditoL10n
import SwiftUI

/// The folder popover of the new agent sheet: recent folders (per server), repositories the server
/// found, the folder tree, and creating a folder. Choosing a folder sets `selection`.
struct FolderPicker: View {
    var server: ServerModel
    @Binding var selection: String
    var onChoose: () -> Void

    @State private var listing: FsListing?
    @State private var repos: [ProjectHint] = []
    @State private var recent = RecentFolders()
    @State private var query = ""
    @State private var newFolder: String?
    @State private var error: String?
    /// "Clone from a link": the form replaces the folder tree while it is open.
    @State private var cloneOpen = false
    @State private var cloneURL = ""
    @State private var cloneName = ""
    @State private var cloneBusy = false
    @State private var cloneError: String?

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                sidebar
                    .frame(width: 190)
                Rectangle().fill(Color.Bandito.line).frame(width: 1)
                Group {
                    if cloneOpen {
                        cloneForm
                    } else {
                        tree
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .frame(width: 540, height: 380)
        .background(Color.Bandito.surface2)
        .task {
            recent = RecentFolders.load(serverID: server.id.uuidString)
            repos = (try? await server.projects(limit: 30)) ?? []
            await open(selection.isEmpty ? "~" : selection)
        }
    }

    // MARK: Parts

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.FolderPicker.search, text: $query)
                .textFieldStyle(.plain)
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .onSubmit {
                    if FolderPickerLogic.isPath(query) {
                        Task { await open(query.trimmingCharacters(in: .whitespaces)) }
                        query = ""
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.Bandito.text.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(10)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                groupLabel(L10n.FolderPicker.recent)
                ForEach(recent.paths, id: \.self) { path in
                    row(icon: "folder", tint: Color.Bandito.text3, name: FolderPickerLogic.name(of: path), active: false) {
                        Task { await open(path) }
                    }
                }
                groupLabel(L10n.FolderPicker.repos)
                    .padding(.top, 8)
                ForEach(repos) { repo in
                    row(icon: "arrow.triangle.branch", tint: Color.Bandito.ok, name: repo.name, active: false) {
                        Task { await open(repo.path) }
                    }
                }
            }
            .padding(8)
        }
    }

    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            breadcrumb
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(visibleDirectories, id: \.path) { entry in
                        row(icon: "folder", tint: BanditoPalette.peach, name: entry.name, active: false) {
                            Task { await open(entry.path) }
                        } trailing: {
                            if entry.hidden {
                                Text(L10n.FolderPicker.hidden)
                                    .font(BanditoFont.font(size: 11, weight: 400))
                                    .foregroundStyle(Color.Bandito.text3.opacity(0.7))
                            }
                        }
                    }
                    if newFolder != nil {
                        TextField(L10n.FolderPicker.newFolderPlaceholder, text: Binding(
                            get: { newFolder ?? "" }, set: { newFolder = $0 })
                        )
                        .textFieldStyle(.plain)
                        .font(BanditoFont.font(size: 13, weight: 400))
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .onSubmit { Task { await createFolder() } }
                    }
                }
                .padding(6)
            }
            if let error {
                Text(error)
                    .font(BanditoFont.font(size: 11.5, weight: 400))
                    .foregroundStyle(Color.Bandito.danger)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    private var breadcrumb: some View {
        let parts = FolderPickerLogic.breadcrumb(for: listing?.path ?? "")
        return HStack(spacing: 3) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("›").foregroundStyle(Color.Bandito.text3)
                }
                Button(part.name) { Task { await open(part.path) } }
                    .banditoButton(.link)
                    .font(BanditoFont.font(size: 12.5, weight: index == parts.count - 1 ? 600 : 400))
                    .foregroundStyle(index == parts.count - 1 ? Color.Bandito.text : Color.Bandito.text3)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button(L10n.FolderPicker.newFolder) { newFolder = newFolder == nil ? "" : nil }
                .banditoButton(.quiet(size: .regular))
                .disabled(listing == nil)
            Button(L10n.FolderPicker.clone) {
                cloneOpen.toggle()
                cloneError = nil
            }
                .banditoButton(.quiet(size: .regular))
                .disabled(listing == nil || cloneBusy)
            Spacer(minLength: 0)
            Button(L10n.FolderPicker.choose(name: FolderPickerLogic.name(of: listing?.path ?? "")), action: choose)
                .banditoButton(.signal(size: .regular))
                .disabled(listing == nil)
        }
        .padding(10)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.Bandito.line).frame(height: 1)
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(BanditoFont.font(size: 10.5, weight: 600))
            .tracking(0.8)
            .foregroundStyle(Color.Bandito.text3)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }

    private func row<Trailing: View>(
        icon: String, tint: Color, name: String, active: Bool, action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12.5))
                    .foregroundStyle(tint)
                Text(name)
                    .font(BanditoFont.font(size: 12.5, weight: 400))
                    .foregroundStyle(Color.Bandito.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(active ? Color.Bandito.signal.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .banditoButton(.row(cornerRadius: 8))
    }

    private var visibleDirectories: [FsEntry] {
        FolderPickerLogic.directories(listing?.entries ?? [], matching: query)
    }

    // MARK: Actions

    private func open(_ path: String) async {
        do {
            listing = try await server.list(path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createFolder() async {
        guard let name = newFolder?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
            let parent = listing?.path
        else { return }
        do {
            let entry = try await server.mkdir(parent + "/" + name)
            newFolder = nil
            await open(entry.path)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var canClone: Bool {
        !cloneURL.trimmingCharacters(in: .whitespaces).isEmpty && CloneLogic.isValidName(cloneName) && listing != nil
    }

    /// The URL and the folder name. The name follows the URL until it is typed over.
    private var cloneForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.FolderPicker.cloneHint(folder: FolderPickerLogic.name(of: listing?.path ?? "")))
                .font(BanditoFont.font(size: 12, weight: 400))
                .foregroundStyle(Color.Bandito.text3)
            TextField(L10n.FolderPicker.cloneURL, text: $cloneURL)
                .textFieldStyle(.roundedBorder)
                .disabled(cloneBusy)
            TextField(L10n.FolderPicker.cloneName, text: $cloneName)
                .textFieldStyle(.roundedBorder)
                .disabled(cloneBusy)
            if cloneBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.FolderPicker.cloning)
                        .font(BanditoFont.font(size: 12, weight: 400))
                        .foregroundStyle(Color.Bandito.text2)
                }
            }
            if let cloneError {
                Text(cloneError)
                    .font(BanditoFont.font(size: 11, weight: 400, mono: true))
                    .foregroundStyle(Color.Bandito.danger)
                    .lineLimit(8)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button(L10n.Common.cancel) { cloneOpen = false }
                    .banditoButton(.quiet(size: .regular))
                    .disabled(cloneBusy)
                Button(L10n.FolderPicker.cloneGo) {
                    Task { await runClone() }
                }
                .banditoButton(.signal(size: .regular))
                .disabled(!canClone || cloneBusy)
            }
        }
        .padding(16)
        .onChange(of: cloneURL) { old, new in
            if cloneName.isEmpty || cloneName == GitRemote.folderName(from: old) {
                cloneName = GitRemote.folderName(from: new) ?? ""
            }
        }
    }

    /// Clones into the folder on screen, then opens the new folder. The git error (stderr) is shown as it is.
    private func runClone() async {
        guard let parent = listing?.path, canClone else { return }
        let url = cloneURL.trimmingCharacters(in: .whitespaces)
        let dest = CloneLogic.destination(parent: parent, name: cloneName.trimmingCharacters(in: .whitespaces))
        cloneBusy = true
        cloneError = nil
        defer { cloneBusy = false }
        do {
            let result = try await server.clone(url: url, to: dest)
            cloneOpen = false
            cloneURL = ""
            cloneName = ""
            await open(result.path)
        } catch let failure as RPCError {
            cloneError = failure.cloneStderr ?? failure.message
        } catch {
            cloneError = error.localizedDescription
        }
    }

    private func choose() {
        guard let path = listing?.path else { return }
        selection = path
        recent.remember(path)
        recent.save(serverID: server.id.uuidString)
        onChoose()
    }
}

/// Text rules of the folder picker. Pure, so it can be tested.
enum FolderPickerLogic {
    /// A typed path rather than a search: starts with `/` or `~`.
    static func isPath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// The last component of a path (`/work/billing` gives `billing`).
    static func name(of path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        return last.isEmpty ? path : last
    }

    /// Folders of a listing (no files, no links), filtered by a search text, in the listing's order.
    static func directories(_ entries: [FsEntry], matching query: String) -> [FsEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            entry.kind == .dir && (needle.isEmpty || entry.name.lowercased().contains(needle))
        }
    }

    /// Crumbs from the root down to `path`, each with the path it leads to.
    static func breadcrumb(for path: String) -> [(name: String, path: String)] {
        guard !path.isEmpty else { return [] }
        var crumbs: [(name: String, path: String)] = [("/", "/")]
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            crumbs.append((String(part), current))
        }
        return crumbs
    }
}
