import BanditoKit
import Foundation
import Observation
import BanditoL10n

/// Whether the Markdown viewer shows the rendered page, the source, or both.
enum ViewerMode: Sendable, Equatable {
    case read, edit, split
}

/// One open file in the viewer: its text, what is saved on the server, and the etag that guards saves.
@MainActor
@Observable
final class FileDocument {
    enum Phase: Equatable {
        case loading, ready, failed(String), tooLarge, binary
    }

    /// The server's newer copy after a save was refused with `conflict`.
    struct ServerCopy: Equatable {
        var text: String
        var etag: String
    }

    let entry: FsEntry
    let path: String
    let name: String
    let category: FileCategory
    let viewer: FileViewerKind
    let readOnly: Bool

    private(set) var phase: Phase = .loading
    /// What the editor shows. Changes on every keystroke.
    private(set) var text = ""
    /// The text as the server last had it.
    private(set) var savedText = ""
    private(set) var etag: String?
    private(set) var conflict: ServerCopy?
    private(set) var isSaving = false
    private(set) var saveError: String?
    var mode: ViewerMode

    init(entry: FsEntry) {
        self.entry = entry
        path = entry.path
        name = entry.name
        category = FileTypes.category(name: entry.name, ext: entry.ext, kind: entry.kind)
        viewer = FileTypes.viewer(for: category) ?? .binary
        readOnly = entry.readonly
        mode = viewer == .markdown ? .split : .edit
    }

    var isDirty: Bool { text != savedText }

    /// Loads the text for text viewers. Images, PDFs and media load their own bytes.
    func load(server: ServerModel) async {
        guard [.markdown, .text].contains(viewer) else {
            phase = .ready
            return
        }
        phase = .loading
        do {
            let file = try await server.readText(path)
            text = file.content
            savedText = file.content
            etag = file.etag
            phase = .ready
        } catch let error as RPCError where error.reason == "too_large" {
            phase = .tooLarge
        } catch let error as RPCError where error.reason == "binary" {
            phase = .binary
        } catch {
            phase = .failed(FileErrorText.message(for: error))
        }
    }

    /// Called by the editor and by the checklist toggle.
    func replaceText(_ newText: String) {
        guard newText != text else { return }
        text = newText
    }

    /// Writes the text with the etag from the last read. A `conflict` keeps the edit and fetches the server's copy.
    func save(server: ServerModel) async {
        guard !isSaving, !readOnly, isDirty else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            etag = try await server.writeText(path: path, content: text, etag: etag)
            savedText = text
        } catch let error as RPCError where error.reason == "conflict" {
            await fetchServerCopy(server: server)
        } catch {
            saveError = FileErrorText.message(for: error)
        }
    }

    /// "Keep mine": writes the edit over the server's newer copy.
    func keepMine(server: ServerModel) async {
        guard let copy = conflict else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            etag = try await server.writeText(path: path, content: text, etag: copy.etag)
            savedText = text
            conflict = nil
        } catch let error as RPCError where error.reason == "conflict" {
            await fetchServerCopy(server: server)
        } catch {
            saveError = FileErrorText.message(for: error)
        }
    }

    /// "Take the server's": drops the edit and shows the server's copy.
    func takeServer() {
        guard let copy = conflict else { return }
        text = copy.text
        savedText = copy.text
        etag = copy.etag
        conflict = nil
    }

    /// Asks the server for its current text after a refused save, so the user can compare.
    private func fetchServerCopy(server: ServerModel) async {
        do {
            let file = try await server.readText(path)
            conflict = ServerCopy(text: file.content, etag: file.etag)
        } catch {
            saveError = FileErrorText.message(for: error)
        }
    }
}

/// Short, user-facing text for a file error. Known `reason` codes get their own sentence.
enum FileErrorText {
    static func message(for error: Error) -> String {
        guard let rpc = error as? RPCError, let reason = rpc.reason else {
            return L10n.Files.Error.generic(error: error.localizedDescription)
        }
        switch reason {
        case "not_found": return L10n.Files.Error.notFound
        case "exists": return L10n.Files.Error.exists
        case "not_a_directory": return L10n.Files.Error.notDirectory
        case "is_a_directory": return L10n.Files.Error.isDirectory
        case "not_a_file": return L10n.Files.Error.notFile
        case "permission_denied": return L10n.Files.Error.permissionDenied
        case "too_large": return L10n.Files.Error.tooLarge
        case "binary": return L10n.Files.Error.binary
        case "conflict": return L10n.Files.Error.conflict
        case "invalid_path": return L10n.Files.Error.invalidPath
        case "outside_roots": return L10n.Files.Error.outsideRoots
        case "io": return L10n.Files.Error.io
        default: return L10n.Files.Error.generic(error: rpc.message)
        }
    }
}
