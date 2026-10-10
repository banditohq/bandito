#if canImport(AppKit)
import AppKit
#endif
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
    @FocusState private var newFolderFocused: Bool
    /// True while a create is waiting for the daemon: a second Return does not send another mkdir.
    @State private var creatingFolder = false
    @State private var error: UserFacingMessage?
    /// "Clone from a link": the form replaces the folder tree while it is open.
    @State private var cloneOpen = false
    @State private var cloneURL = ""
    @State private var cloneName = ""
    @State private var cloneBusy = false
    @State private var cloneError: UserFacingMessage?

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
                .banditoField()
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
                    // "New folder" comes first in the list, as in Finder, with its name selected for typing.
                    if newFolder != nil {
                        newFolderRow
                    }
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
                }
                .padding(6)
            }
            if let error, newFolder == nil {
                UserFacingErrorView(message: error)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    /// The row for a new folder: folder icon, a name field that has focus, Return creates and chooses the folder,
    /// Escape cancels. A failure shows in red under the row.
    private var newFolderRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12.5))
                    .foregroundStyle(BanditoPalette.peach)
                TextField(L10n.FolderPicker.newFolderName, text: Binding(
                    get: { newFolder ?? "" }, set: { newFolder = $0 })
                )
                .banditoField()
                .font(BanditoFont.font(size: 12.5, weight: 400))
                .focused($newFolderFocused)
                .onSubmit { Task { await createFolder() } }
                .onExitCommand { newFolder = nil; error = nil }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.Bandito.signal.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            if let error {
                UserFacingErrorView(message: error)
                    .padding(.horizontal, 8)
            }
        }
        .onAppear {
            newFolderFocused = true
            selectNameText()
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
            Button(L10n.FolderPicker.newFolder) {
                if newFolder == nil {
                    error = nil
                    newFolder = L10n.FolderPicker.newFolderName
                } else {
                    newFolder = nil
                }
            }
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
            self.error = UserFacingError.message(for: error)
        }
    }

    /// Selects the whole name, so typing replaces "New folder" as in Finder. The field editor takes the selection once
    /// the field has focus, so the request waits one turn of the run loop.
    private func selectNameText() {
        #if canImport(AppKit)
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
        #endif
    }

    private func createFolder() async {
        guard !creatingFolder, let typed = newFolder, let parent = listing?.path else { return }
        // Checked before the daemon is asked: an empty name, a slash, "." or ".." never reaches mkdir.
        if let problem = FolderPickerLogic.newFolderProblem(typed) {
            error = UserFacingMessage(text: problem.message)
            return
        }
        let name = typed.trimmingCharacters(in: .whitespaces)
        creatingFolder = true
        defer { creatingFolder = false }
        error = nil
        do {
            let entry = try await server.mkdir(parent + "/" + name)
            newFolder = nil
            // The new folder is chosen at once: the agent works in it.
            await open(entry.path)
            // Only a folder that opened is chosen; a failed open keeps the previous listing, which is not the new folder.
            if error == nil { choose() }
        } catch {
            self.error = UserFacingError.message(for: error)
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
                .banditoField()
                .disabled(cloneBusy)
            TextField(L10n.FolderPicker.cloneName, text: $cloneName)
                .banditoField()
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
                UserFacingErrorView(message: cloneError)
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
            cloneError = UserFacingMessage(
                text: L10n.Failure.Reason.cloneFailed, technical: failure.cloneStderr ?? failure.message)
        } catch {
            cloneError = UserFacingError.message(for: error)
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
    /// Why a new folder's name cannot be used, or nil when it can. The rule is the clone's name rule (`CloneLogic`).
    enum NewFolderProblem: Equatable {
        case empty
        case invalid

        var message: String {
            switch self {
            case .empty: L10n.FolderPicker.nameEmpty
            case .invalid: L10n.FolderPicker.nameInvalid
            }
        }
    }

    static func newFolderProblem(_ typed: String) -> NewFolderProblem? {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        return CloneLogic.isValidName(trimmed) ? nil : .invalid
    }

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
