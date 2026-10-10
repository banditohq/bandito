import AppKit
import BanditoDesign
import BanditoKit
import BanditoL10n
import Foundation
import SwiftUI

/// A file in the composer, before it is sent. It is uploaded as soon as it is added; the send takes the ones that are
/// ready. A file that cannot be attached stays in the tray as a failed chip until it is removed.
struct DraftFile: Identifiable {
    enum State: Equatable {
        case uploading
        case ready(AgentAttachment)
        case failed(Failure)
    }

    /// Why a file could not be attached: the client's rules (the same as the daemon's), or the upload itself.
    enum Failure: Equatable {
        case problem(AttachmentRules.Problem)
        case upload
    }

    let id = UUID()
    var name: String
    var size: Int64
    /// A local picture for the miniature. `nil` for files that are not pictures, or when the picture cannot be read.
    var preview: NSImage?
    var state: State

    var isImage: Bool { AttachmentRules.isImage(name: name) }

    /// What a failed file says, or `nil` when it did not fail.
    var failureText: String? {
        if case .failed(let failure) = state { return AttachmentTray.message(for: failure) }
        return nil
    }

    /// The words after the name in the chip: the upload, the failure, or the size.
    var detailText: String? {
        switch state {
        case .uploading: L10n.Composer.Attach.uploading
        case .failed(let failure): AttachmentTray.message(for: failure)
        case .ready: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
    }
}

/// Rules of the composer's tray. Pure, so the choices are tested without a server.
enum AttachmentTray {
    /// The message can go when it has text or a file that is ready, and no file is still uploading. A file that
    /// failed does not block the send; it is not sent.
    static func canSend(text: String, files: [DraftFile]) -> Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !readyFiles(files).isEmpty) && !hasUploading(files)
    }

    static func hasUploading(_ files: [DraftFile]) -> Bool {
        files.contains { $0.state == .uploading }
    }

    /// The uploaded files, in the order they were added.
    static func readyFiles(_ files: [DraftFile]) -> [AgentAttachment] {
        files.compactMap { file in
            if case .ready(let attachment) = file.state { return attachment }
            return nil
        }
    }

    /// The rule a name or size breaks, mapped to the failure a chip shows. `nil` when the file can be uploaded.
    static func failure(name: String, size: Int64) -> DraftFile.Failure? {
        AttachmentRules.problem(name: name, size: size).map { DraftFile.Failure.problem($0) }
    }

    /// The words of a failed chip.
    static func message(for failure: DraftFile.Failure) -> String {
        switch failure {
        case .problem(.tooLarge): L10n.Composer.Attach.tooLarge
        case .problem(.badName): L10n.Composer.Attach.badName
        case .problem(.hiddenName): L10n.Composer.Attach.hiddenName
        case .problem(.nameTooLong): L10n.Composer.Attach.nameTooLong
        case .upload: L10n.Composer.Attach.failed
        }
    }
}

/// The files waiting in the composer of each agent. Kept here, not in the view, so a file added to one agent's composer
/// is not lost when the person goes to another agent and back.
///
/// Every file gets one task: it reads the bytes and uploads them. The tasks are chained, so one upload runs at a time.
/// `remove` cancels the file's task, and a task that is cancelled before its upload starts does nothing.
@MainActor
@Observable
final class AttachmentTrays {
    static let shared = AttachmentTrays()

    private var trays: [String: [DraftFile]] = [:]
    /// The task of each file that still has work to do, by the file's id.
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// The last task in the chain: the next upload waits for it.
    @ObservationIgnored private var chainTail: Task<Void, Never>?

    /// Where the bytes of a file come from: a file on disk, or a picture already in memory.
    private enum Source {
        case file(URL)
        case picture(Data)
    }

    /// Uploads one file: its bytes, its name and the agent it goes to. The server's `attachments.upload` in the app.
    typealias Uploader = (Data, String, String) async throws -> AgentAttachment

    static func uploader(_ server: ServerModel) -> Uploader {
        { data, name, agentID in try await server.uploadAttachment(data, name: name, agentId: agentID) }
    }

    func files(for agentID: String) -> [DraftFile] {
        trays[agentID] ?? []
    }

    /// Adds files from disk. A file that breaks a rule is shown as failed at once and is not read.
    func add(urls: [URL], agentID: String, server: ServerModel) {
        add(urls: urls, agentID: agentID, upload: Self.uploader(server))
    }

    /// `add` with the upload given. Tests use it; the app passes the server's upload.
    func add(urls: [URL], agentID: String, upload: @escaping Uploader) {
        for url in urls {
            let name = url.lastPathComponent
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let failure = AttachmentTray.failure(name: name, size: size) {
                append(DraftFile(name: name, size: size, preview: nil, state: .failed(failure)), agentID: agentID)
                continue
            }
            let preview = AttachmentRules.isImage(name: name) ? NSImage(contentsOf: url) : nil
            let file = DraftFile(name: name, size: size, preview: preview, state: .uploading)
            append(file, agentID: agentID)
            enqueue(file.id, name: name, agentID: agentID, upload: upload, source: .file(url))
        }
    }

    /// Adds a picture that has no file yet: a screenshot or one from the clipboard. The bytes are PNG.
    func addPicture(_ data: Data, name: String, agentID: String, server: ServerModel) {
        addPicture(data, name: name, agentID: agentID, upload: Self.uploader(server))
    }

    /// `addPicture` with the upload given. Tests use it; the app passes the server's upload.
    func addPicture(_ data: Data, name: String, agentID: String, upload: @escaping Uploader) {
        let size = Int64(data.count)
        if let failure = AttachmentTray.failure(name: name, size: size) {
            append(DraftFile(name: name, size: size, preview: nil, state: .failed(failure)), agentID: agentID)
            return
        }
        let file = DraftFile(name: name, size: size, preview: NSImage(data: data), state: .uploading)
        append(file, agentID: agentID)
        enqueue(file.id, name: name, agentID: agentID, upload: upload, source: .picture(data))
    }

    /// Takes a file out of the tray. Its upload, if one is waiting or running, is cancelled.
    func remove(_ id: UUID, agentID: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        trays[agentID]?.removeAll { $0.id == id }
    }

    /// Takes the sent files out of the tray. Files still uploading, and failed ones, stay.
    func removeSent(_ sent: [AgentAttachment], agentID: String) {
        let paths = Set(sent.map(\.path))
        trays[agentID]?.removeAll { file in
            if case .ready(let attachment) = file.state { return paths.contains(attachment.path) }
            return false
        }
    }

    // MARK: - Private

    /// Files dropped on the chat. Only files count: other drags are refused (`false`). Each file goes through `add`.
    func accept(_ providers: [NSItemProvider], agentID: String, server: ServerModel) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    AttachmentTrays.shared.add(urls: [url], agentID: agentID, server: server)
                }
            }
        }
        return accepted
    }

    private func append(_ file: DraftFile, agentID: String) {
        trays[agentID, default: []].append(file)
    }

    /// Queues the read and upload of one file behind the uploads already queued.
    private func enqueue(_ id: UUID, name: String, agentID: String, upload: @escaping Uploader, source: Source) {
        let previous = chainTail
        let task = Task { [weak self] in
            // One upload at a time: this one starts when the one before it has finished (or was cancelled).
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            do {
                let data: Data
                switch source {
                case .file(let url):
                    data = try await Task.detached(priority: .utility) { try Data(contentsOf: url) }.value
                case .picture(let bytes):
                    data = bytes
                }
                // Removed while it was read: no upload.
                guard !Task.isCancelled else { return }
                let attachment = try await upload(data, name, agentID)
                self.finish(id, agentID: agentID, .ready(attachment))
            } catch {
                if !Task.isCancelled { self.finish(id, agentID: agentID, .failed(.upload)) }
            }
            self.tasks[id] = nil
        }
        tasks[id] = task
        chainTail = task
    }

    private func finish(_ id: UUID, agentID: String, _ state: DraftFile.State) {
        guard let index = trays[agentID]?.firstIndex(where: { $0.id == id }) else { return }
        trays[agentID]?[index].state = state
    }
}

/// Pictures that come from the Mac itself: a region of the screen, or the clipboard.
enum PictureSource {
    /// Asks the person for a region of the screen (`screencapture -i`). Nil when they cancel, or when no picture comes.
    static func screenshot() async -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bandito-\(UUID().uuidString).png")
        let status = await Task.detached(priority: .userInitiated) { () -> Int32 in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", url.path]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            } catch {
                return -1
            }
        }.value
        defer { try? FileManager.default.removeItem(at: url) }
        guard status == 0 else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The picture on the clipboard as PNG, or nil when the clipboard holds no picture.
    static func clipboardPNG() -> Data? {
        guard let image = NSImage(pasteboard: .general), let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// True when the clipboard has a picture and no text, so a paste of a picture is not a paste of text.
    static var clipboardHoldsOnlyPicture: Bool {
        NSPasteboard.general.string(forType: .string) == nil && NSImage(pasteboard: .general) != nil
    }
}

/// The highlight over the chat while files are dragged over it: a dashed frame and the words "Drop to attach".
struct FileDropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.Bandito.signal.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.Bandito.signal, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .overlay {
                Text(L10n.Composer.Attach.dropHint)
                    .font(BanditoFont.font(size: 14, weight: 500))
                    .foregroundStyle(Color.Bandito.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.Bandito.surface2, in: Capsule())
            }
            .padding(10)
            .allowsHitTesting(false)
    }
}
