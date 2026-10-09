import BanditoKit
import BanditoL10n
import Foundation
import Observation

/// How the browser lays out its entries.
enum FileLayout: Sendable {
    case list, grid
}

/// The file being copied from this Mac to the server right now.
struct UploadJob: Equatable, Sendable {
    var name: String
    var fraction: Double
    /// 1-based position in the batch.
    var index: Int
    var total: Int
}

/// A name already taken in the target folder while uploading. The rest of the batch waits for the answer.
struct UploadConflict: Equatable {
    var url: URL
    var name: String
    var folder: String
    var remaining: [URL]
}

enum UploadChoice: Sendable {
    case replace, keepBoth, cancel
}

/// The state of the folder browser: the listing of one folder, search, selection, and file operations.
///
/// Operations take the `ServerModel` they act on, so the same model can follow the server in front.
@MainActor
@Observable
final class FolderModel {
    /// The absolute path being listed, as the server resolved it.
    private(set) var path: String?
    /// The daemon user's home folder (`~`), absolute. Known after the first listing.
    private(set) var home: String?
    private(set) var entries: [FsEntry] = []
    private(set) var truncated = false
    private(set) var skipped = 0
    private(set) var loadError: UserFacingMessage?
    /// The folder could not be read because the system or the server does not allow it (`permission_denied`).
    private(set) var loadDenied = false
    private(set) var isLoading = false
    private(set) var searchResults: [FsEntry]?
    private(set) var upload: UploadJob?
    private(set) var uploadConflict: UploadConflict?
    /// Something a file operation could not do; shown once, then the user dismisses it.
    var actionError: UserFacingMessage?

    /// Settings → Terminal and files: whether hidden files show when the browser opens.
    static let showHiddenDefaultsKey = "files.showHiddenByDefault"

    /// Starts from the Settings choice; ⇧⌘. changes it for the open browser only.
    var showHidden = UserDefaults.standard.bool(forKey: FolderModel.showHiddenDefaultsKey)
    var layout: FileLayout = .list
    var selection: String?
    var searchText = "" {
        didSet { if searchText != oldValue { searchTask?.cancel() } }
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// The last path asked for, as typed (`~` or absolute). Kept so a failed folder can be listed again.
    @ObservationIgnored private var lastRequested: String?

    /// What the browser shows: search results while a query is set, otherwise the folder.
    var visibleEntries: [FsEntry] {
        searchResults ?? entries
    }

    /// Lists `requested` (an absolute path or `~`). Keeps the selection if the entry is still there.
    func load(_ requested: String, server: ServerModel) async {
        isLoading = true
        defer { isLoading = false }
        lastRequested = requested
        do {
            let listing = try await server.list(requested, hidden: showHidden)
            path = listing.path
            entries = FileSorting.sorted(listing.entries)
            truncated = listing.truncated
            skipped = listing.skipped
            loadError = nil
            loadDenied = false
            if let selection, !entries.contains(where: { $0.path == selection }) { self.selection = nil }
        } catch {
            // The folder that failed is not the one on screen any more: the requested path stands for it.
            path = nil
            entries = []
            truncated = false
            skipped = 0
            loadDenied = (error as? RPCError)?.reason == "permission_denied"
            loadError = FileErrorText.message(for: error)
        }
        if home == nil {
            home = try? await server.list("~").path
        }
    }

    /// Re-lists the folder on screen, after a change. A folder that failed to list is tried again.
    func reload(server: ServerModel) async {
        guard let target = path ?? lastRequested else { return }
        await load(target, server: server)
    }

    // MARK: Search

    /// Runs the search after the query has settled for 300 ms. An empty query returns to the folder.
    func scheduleSearch(in root: String, server: ServerModel) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            do {
                let found = try await server.search(root: root, query: query, limit: 200)
                guard !Task.isCancelled else { return }
                self.searchResults = found.sorted { $0.path < $1.path }
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.actionError = FileErrorText.message(for: error)
            }
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = nil
    }

    // MARK: Operations

    func createFolder(named name: String, in folder: String, server: ServerModel) async {
        await perform { _ = try await server.mkdir(FilePath.join(folder, name)) }
        await reload(server: server)
    }

    func createFile(named name: String, in folder: String, server: ServerModel) async {
        await perform { _ = try await server.createFile(FilePath.join(folder, name)) }
        await reload(server: server)
    }

    /// Renames inside the entry's own folder.
    func rename(_ entry: FsEntry, to name: String, server: ServerModel) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != entry.name, let folder = FilePath.parent(of: entry.path) else { return }
        await perform { _ = try await server.rename(from: entry.path, to: FilePath.join(folder, trimmed)) }
        await reload(server: server)
    }

    /// ⌘D: a copy next to the original, named `… копия`.
    func duplicate(_ entry: FsEntry, server: ServerModel) async {
        let taken = Set(entries.map(\.name))
        let name = FileNaming.copyName(for: entry.name, isFolder: entry.kind == .dir, existing: taken)
        guard let folder = FilePath.parent(of: entry.path) else { return }
        await perform { _ = try await server.copy(from: entry.path, to: FilePath.join(folder, name)) }
        await reload(server: server)
    }

    func trash(_ entry: FsEntry, server: ServerModel) async {
        await perform { _ = try await server.trash(entry.path) }
        if selection == entry.path { selection = nil }
        await reload(server: server)
    }

    /// Runs `body`, and shows its error instead of throwing.
    private func perform(_ body: () async throws -> Void) async {
        do {
            try await body()
        } catch {
            actionError = FileErrorText.message(for: error)
        }
    }

    // MARK: Uploads

    /// Copies files from this Mac into `folder`, one after another. A name that is taken stops the batch and
    /// asks (`uploadConflict`); `resolveUploadConflict` then continues with the rest.
    func uploadFiles(_ urls: [URL], into folder: String, server: ServerModel) async {
        var queue = urls
        let total = urls.count
        var done = 0
        defer { upload = nil }
        while !queue.isEmpty {
            let url = queue.removeFirst()
            let name = url.lastPathComponent
            done += 1
            upload = UploadJob(name: name, fraction: 0, index: done, total: total)
            do {
                _ = try await server.upload(local: url, to: FilePath.join(folder, name), overwrite: false) { fraction in
                    self.upload?.fraction = fraction
                }
            } catch let error as RPCError where error.reason == "exists" {
                uploadConflict = UploadConflict(url: url, name: name, folder: folder, remaining: queue)
                upload = nil
                return
            } catch {
                actionError = FileErrorText.message(for: error).wrapped { L10n.Files.Upload.failed(name: name, error: $0) }
            }
        }
        await reload(server: server)
    }

    /// The answer to a name clash: replace the file, keep both under a new name, or skip this file.
    func resolveUploadConflict(_ choice: UploadChoice, server: ServerModel) async {
        guard let conflict = uploadConflict else { return }
        uploadConflict = nil
        switch choice {
        case .cancel:
            break
        case .replace:
            do {
                upload = UploadJob(name: conflict.name, fraction: 0, index: 1, total: 1)
                _ = try await server.upload(
                    local: conflict.url, to: FilePath.join(conflict.folder, conflict.name), overwrite: true
                ) { fraction in
                    self.upload?.fraction = fraction
                }
            } catch {
                actionError = FileErrorText.message(for: error).wrapped { L10n.Files.Upload.failed(name: conflict.name, error: $0) }
            }
            upload = nil
        case .keepBoth:
            let taken = Set(entries.map(\.name))
            let name = FileNaming.nextFreeName(for: conflict.name, existing: taken)
            do {
                upload = UploadJob(name: name, fraction: 0, index: 1, total: 1)
                _ = try await server.upload(local: conflict.url, to: FilePath.join(conflict.folder, name)) { fraction in
                    self.upload?.fraction = fraction
                }
            } catch {
                actionError = FileErrorText.message(for: error).wrapped { L10n.Files.Upload.failed(name: name, error: $0) }
            }
            upload = nil
        }
        if !conflict.remaining.isEmpty {
            await uploadFiles(conflict.remaining, into: conflict.folder, server: server)
        } else {
            await reload(server: server)
        }
    }
}
