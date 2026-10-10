import BanditoKit
import Foundation
import Observation
import BanditoL10n

/// Whether the Markdown viewer shows the rendered page, the source, or both.
enum ViewerMode: Sendable, Equatable {
    case read, edit, split
}

/// When the viewer saves by itself. Pure, so it is tested alone.
enum AutosaveRules {
    /// Silence after the last keystroke before the text is written.
    static let delay: Duration = .seconds(1)
    /// How long the check mark stays after a save.
    static let savedMarkSeconds: Double = 1.2

    enum Decision: Equatable {
        /// Write now.
        case save
        /// A save is running: try again when it ends.
        case wait
        /// Nothing to write, or writing is not allowed (read only, a conflict waits for the person).
        case skip
    }

    static func decision(isDirty: Bool, readOnly: Bool, hasConflict: Bool, isSaving: Bool) -> Decision {
        guard isDirty, !readOnly, !hasConflict else { return .skip }
        return isSaving ? .wait : .save
    }
}

/// One open file in the viewer: its text, what is saved on the server, and the etag that guards saves.
@MainActor
@Observable
final class FileDocument {
    enum Phase: Equatable {
        case loading, ready, failed(UserFacingMessage), tooLarge, binary
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
    private(set) var saveError: UserFacingMessage?
    /// True for a moment after a successful save: the header shows a check mark.
    private(set) var showsSavedMark = false
    var mode: ViewerMode

    @ObservationIgnored private weak var server: ServerModel?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var savedMarkTask: Task<Void, Never>?

    init(entry: FsEntry) {
        self.entry = entry
        path = entry.path
        name = entry.name
        category = FileTypes.category(name: entry.name, ext: entry.ext, kind: entry.kind)
        viewer = FileTypes.viewer(for: category) ?? .binary
        readOnly = entry.readonly
        mode = viewer == .markdown ? .read : .edit
    }

    var isDirty: Bool { text != savedText }

    /// Loads the text for text viewers. Images, PDFs and media load their own bytes.
    func load(server: ServerModel) async {
        guard [.markdown, .text].contains(viewer) else {
            phase = .ready
            return
        }
        self.server = server
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
        scheduleAutosave()
    }

    /// Writes the text after a second of silence, unless the rules say no.
    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard !readOnly, phase == .ready else { return }
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: AutosaveRules.delay)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Not cancelled by itself: the task only forgets its handle, then writes.
            self.autosaveTask = nil
            await self.runFlush()
        }
    }

    /// True when the text has changes that could not be written (an error or a conflict): the person must decide.
    var needsAttention: Bool {
        isDirty && !readOnly && (saveError != nil || conflict != nil)
    }

    /// Writes unsaved text now (leaving the tab, closing it, a new file) and drops the pending debounce. Waits for a
    /// running save first, so a text typed during it is not lost. A conflict, an error or a read-only file leave the
    /// text as it is.
    func flush() async {
        autosaveTask?.cancel()
        autosaveTask = nil
        await runFlush()
    }

    private func runFlush() async {
        guard let server else { return }
        while true {
            switch AutosaveRules.decision(
                isDirty: isDirty, readOnly: readOnly, hasConflict: conflict != nil, isSaving: isSaving)
            {
            case .skip:
                return
            case .wait:
                // Sleeps until the running write ends, however this task was started or cancelled.
                await withCheckedContinuation { saveWaiters.append($0) }
            case .save:
                await save(server: server)
                // A failed save is not repeated until the next keystroke.
                if saveError != nil || conflict != nil { return }
            }
        }
    }

    private func finishSaving() {
        isSaving = false
        let waiters = saveWaiters
        saveWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func flashSavedMark() {
        savedMarkTask?.cancel()
        showsSavedMark = true
        savedMarkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(AutosaveRules.savedMarkSeconds))
            guard !Task.isCancelled else { return }
            self?.showsSavedMark = false
        }
    }

    /// Writes the text with the etag from the last read. A `conflict` keeps the edit and fetches the server's copy.
    func save(server: ServerModel) async {
        guard !isSaving, !readOnly, isDirty else { return }
        isSaving = true
        saveError = nil
        defer { finishSaving() }
        do {
            let written = text
            etag = try await server.writeText(path: path, content: written, etag: etag)
            savedText = written
            flashSavedMark()
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
        defer { finishSaving() }
        do {
            let written = text
            etag = try await server.writeText(path: path, content: written, etag: copy.etag)
            savedText = written
            conflict = nil
            flashSavedMark()
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
    static func message(for error: Error) -> UserFacingMessage {
        guard let rpc = error as? RPCError, let reason = rpc.reason else {
            return UserFacingError.message(for: error)
        }
        switch reason {
        case "not_found": return UserFacingMessage(text: L10n.Files.Error.notFound)
        case "exists": return UserFacingMessage(text: L10n.Files.Error.exists)
        case "not_a_directory": return UserFacingMessage(text: L10n.Files.Error.notDirectory)
        case "is_a_directory": return UserFacingMessage(text: L10n.Files.Error.isDirectory)
        case "not_a_file": return UserFacingMessage(text: L10n.Files.Error.notFile)
        case "permission_denied": return UserFacingMessage(text: L10n.Files.Error.permissionDenied)
        case "too_large": return UserFacingMessage(text: L10n.Files.Error.tooLarge)
        case "binary": return UserFacingMessage(text: L10n.Files.Error.binary)
        case "conflict": return UserFacingMessage(text: L10n.Files.Error.conflict)
        case "invalid_path": return UserFacingMessage(text: L10n.Files.Error.invalidPath)
        case "outside_roots": return UserFacingMessage(text: L10n.Files.Error.outsideRoots)
        case "io": return UserFacingMessage(text: L10n.Files.Error.io)
        default: return UserFacingError.message(for: error)
        }
    }
}
