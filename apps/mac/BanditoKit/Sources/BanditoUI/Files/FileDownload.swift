import BanditoKit
import Foundation

/// "Download to Mac": asks where to save, then copies the file from the server (or the local disk).
@MainActor
enum FileDownload {
    static func save(_ entry: FsEntry, server: ServerModel) async throws {
        guard let request = server.rawURLRequest(path: entry.path), let source = request.url else {
            throw RemoteFile.Failure.unavailable
        }
        guard let destination = FileBridge.saveURL(suggestedName: entry.name) else { return }
        try? FileManager.default.removeItem(at: destination)
        if source.isFileURL {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteFile.Failure.status(http.statusCode)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
