import BanditoKit
import Foundation
import Observation

/// What the Files mode keeps while the user moves between modes: the open files (tabs) and their editors,
/// and whether the viewer or the folder browser fills the main area. Owned by `Router`.
@MainActor
@Observable
final class FileWorkspace {
    private(set) var tabs = ViewerTabs()
    private(set) var documents: [String: FileDocument] = [:]
    /// The viewer fills the main area; otherwise the folder browser does.
    var showsViewer = false
    /// The server the open files belong to. A different server starts with no tabs.
    private(set) var serverID: UUID?
    /// The folders each server's Files visited, for `<` and `>`. Kept per server, so switching servers keeps them.
    private(set) var histories: [UUID: FolderHistory] = [:]
    /// Favorites and hidden places of the sidebar, shared by the sidebar and the browser.
    let favorites = FileFavorites()

    func bind(to serverID: UUID) {
        guard self.serverID != serverID else { return }
        self.serverID = serverID
        tabs = ViewerTabs()
        documents = [:]
        showsViewer = false
    }

    /// The document of the tab in front, if any.
    var selectedDocument: FileDocument? {
        tabs.selected.flatMap { documents[$0] }
    }

    /// Opens `entry` in a tab and shows the viewer. A file already open is only brought to the front.
    func open(_ entry: FsEntry, server: ServerModel) {
        tabs.open(entry.path)
        showsViewer = true
        if documents[entry.path] == nil {
            let document = FileDocument(entry: entry)
            documents[entry.path] = document
            Task { await document.load(server: server) }
        }
    }

    /// Closes a tab. Callers ask about unsaved changes first.
    func close(_ path: String) {
        tabs.close(path)
        documents[path] = nil
        if tabs.paths.isEmpty { showsViewer = false }
    }

    // MARK: Folder history

    /// The folder on screen for the server in front is `path`, once it is listed. A visit that changes the
    /// folder is recorded; a step back or forward lands on a folder that is already current, so nothing is.
    func arrive(at path: String, serverID: UUID) {
        var history = histories[serverID] ?? FolderHistory()
        let before = history
        history.visit(path)
        if history != before { histories[serverID] = history }
    }

    var canStepBack: Bool {
        serverID.flatMap { histories[$0] }?.canGoBack ?? false
    }

    var canStepForward: Bool {
        serverID.flatMap { histories[$0] }?.canGoForward ?? false
    }

    /// The folder before the current one on the server in front, or `nil` when there is none.
    func stepBack() -> String? {
        step { $0.back() }
    }

    func stepForward() -> String? {
        step { $0.forward() }
    }

    private func step(_ move: (inout FolderHistory) -> String?) -> String? {
        guard let serverID, var history = histories[serverID] else { return nil }
        let folder = move(&history)
        histories[serverID] = history
        return folder
    }

    /// Brings an open tab to the front.
    func select(_ path: String) {
        tabs.open(path)
    }

    func selectNext() {
        tabs.selectNext()
    }

    func selectPrevious() {
        tabs.selectPrevious()
    }
}
