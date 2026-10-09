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
