import Foundation

// Files on the server (docs/ARCHITECTURE.md#files): `fs.*` calls, chunked upload, and the raw
// download URL.

private struct PathParams: Encodable {
    var path: String
}

private struct TwoPathParams: Encodable {
    var from: String
    var to: String
}

extension ServerModel {
    /// Upload chunk size before base64: 1 MiB, the daemon's limit per `fs.upload.append`.
    nonisolated static let uploadChunkSize = 1 << 20
    /// Largest file `upload` sends: the daemon's total limit per upload.
    nonisolated static let uploadSizeLimit: Int64 = 4 << 30

    public func list(_ path: String, hidden: Bool = false) async throws -> FsListing {
        struct P: Encodable { var path: String; var hidden: Bool }
        return try await rpc().call("fs.list", P(path: path, hidden: hidden), as: FsListing.self)
    }

    public func stat(_ path: String) async throws -> FsEntry {
        try await rpc().call("fs.stat", PathParams(path: path), as: FsEntry.self)
    }

    /// Reads a text file of up to 2 MiB. Keep its `etag` for `writeText`.
    public func readText(_ path: String) async throws -> TextFile {
        try await rpc().call("fs.read", PathParams(path: path), as: TextFile.self)
    }

    /// Writes a text file and returns its new etag.
    ///
    /// Overwriting needs the `etag` from the last `readText`; a stale one throws `RPCError` with
    /// `reason == "conflict"` and the current etag in `etag`. `create: true` makes a new file and
    /// throws `reason == "exists"` if the path is taken.
    public func writeText(path: String, content: String, etag: String? = nil, create: Bool = false) async throws
        -> String
    {
        struct P: Encodable { var path: String; var content: String; var etag: String?; var create: Bool }
        struct Reply: Decodable { var etag: String }
        let reply = try await rpc().call(
            "fs.write", P(path: path, content: content, etag: etag, create: create), as: Reply.self)
        return reply.etag
    }

    public func createFile(_ path: String) async throws -> FsEntry {
        try await rpc().call("fs.create_file", PathParams(path: path), as: FsEntry.self)
    }

    public func mkdir(_ path: String) async throws -> FsEntry {
        try await rpc().call("fs.mkdir", PathParams(path: path), as: FsEntry.self)
    }

    public func rename(from: String, to: String) async throws -> FsEntry {
        try await rpc().call("fs.rename", TwoPathParams(from: from, to: to), as: FsEntry.self)
    }

    public func copy(from: String, to: String) async throws -> FsEntry {
        try await rpc().call("fs.copy", TwoPathParams(from: from, to: to), as: FsEntry.self)
    }

    /// Moves a path to the server's trash. Returns where it went.
    public func trash(_ path: String) async throws -> String {
        struct Reply: Decodable { var trashedTo: String }
        return try await rpc().call("fs.trash", PathParams(path: path), as: Reply.self).trashedTo
    }

    /// Names under `root` that contain `query`. `limit` is 1…1000 (the daemon's default is 200).
    public func search(root: String, query: String, limit: Int? = nil) async throws -> [FsEntry] {
        struct P: Encodable { var root: String; var query: String; var limit: Int? }
        return try await rpc().call(
            "fs.search", P(root: root, query: query, limit: limit), as: [FsEntry].self)
    }

    /// Folders that look like projects. `limit` is 1…200 (the daemon's default is 30).
    public func projects(limit: Int? = nil) async throws -> [ProjectHint] {
        struct P: Encodable { var limit: Int? }
        return try await rpc().call("fs.projects", P(limit: limit), as: [ProjectHint].self)
    }

    /// Copies a local file to `remotePath` on the server in 1 MiB chunks. Files larger than 4 GiB are
    /// refused before anything is sent (`reason == "too_large"`).
    ///
    /// `progress` gets the fraction sent (0…1) after each chunk. Reading and base64 encoding run off the
    /// main actor. On any failure the upload is aborted on the server and the error is thrown again.
    /// `overwrite: false` fails with `reason == "exists"` if the path is taken.
    public func upload(
        local: URL, to remotePath: String, overwrite: Bool = false, progress: (Double) -> Void
    ) async throws -> FsEntry {
        struct Begin: Encodable { var path: String }
        struct Begun: Decodable { var uploadId: String }
        struct Append: Encodable { var uploadId: String; var offset: Int64; var data: String }
        struct Written: Decodable { var written: Int64 }
        struct Commit: Encodable { var uploadId: String; var overwrite: Bool }
        struct Abort: Encodable { var uploadId: String }

        let client = try rpc()
        let source = try UploadSource(url: local)
        defer { source.close() }
        guard source.size <= Self.uploadSizeLimit else {
            throw RPCError(
                code: RPCError.fileError, message: "too_large: the file is larger than 4 GiB",
                data: .object(["reason": .string("too_large")]))
        }
        let total = source.size

        let begun = try await client.call("fs.upload.begin", Begin(path: remotePath), as: Begun.self)
        var offset: Int64 = 0
        do {
            while let piece = try await Task.detached(priority: .utility, operation: { try source.nextChunk() }).value {
                let reply = try await client.call(
                    "fs.upload.append",
                    Append(uploadId: begun.uploadId, offset: offset, data: piece.base64),
                    as: Written.self)
                guard reply.written == Int64(piece.count) else {
                    throw RPCError(code: RPCError.fileError, message: "io: the server stored fewer bytes than sent")
                }
                offset += Int64(piece.count)
                progress(total > 0 ? Double(offset) / Double(total) : 1)
            }
            if total == 0 { progress(1) }
            return try await client.call(
                "fs.upload.commit", Commit(uploadId: begun.uploadId, overwrite: overwrite), as: FsEntry.self)
        } catch {
            _ = try? await client.call("fs.upload.abort", Abort(uploadId: begun.uploadId))
            throw error
        }
    }

    /// A GET request for `GET /v1/files/raw?path=…`, for streaming a file's bytes (images, video, PDF).
    ///
    /// - This Mac (unix socket): a `file://` URL to `path`, no network.
    /// - WebSocket server: the same origin over http(s), with `Authorization: Bearer` when the server has a
    ///   token. The token is sent only where `WebSocketTransport` allows tokens (TLS or loopback). A server
    ///   that has a token but is reached without TLS gets `nil`: no request, so no token travels in the clear.
    ///   A server without a token gets a request without the header.
    public func rawURLRequest(path: String) -> URLRequest? {
        switch config.endpoint {
        case .local:
            return URLRequest(url: URL(fileURLWithPath: path))
        case .ssh:
            // Not yet: a raw URL needs the SSH tunnel's local port, which the model does not own.
            return nil
        case .webSocket(let server):
            if config.token != nil, !WebSocketTransport.allowsToken(for: server) { return nil }
            guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = components.scheme?.lowercased() == "wss" ? "https" : "http"
            components.path = "/v1/files/raw"
            components.percentEncodedQuery = "path=" + Self.queryEncoded(path)
            components.fragment = nil
            guard let url = components.url else { return nil }
            var request = URLRequest(url: url)
            if let token = config.token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            return request
        }
    }

    /// Percent-encodes a query value the way the daemon's form decoder reads it: `+`, `&`, `=`, `#`
    /// and `;` are always encoded (a bare `+` would read as a space).
    static func queryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=#;")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

/// Reads an upload's source in chunks. `FileHandle` is not Sendable; the upload loop reads one chunk at a
/// time, never in parallel, so the handle is only touched by one task at once.
final class UploadSource: @unchecked Sendable {
    let size: Int64
    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = ((try FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// The next chunk, base64-encoded with its raw byte count, or nil at the end of the file.
    func nextChunk() throws -> (base64: String, count: Int)? {
        guard let data = try handle.read(upToCount: ServerModel.uploadChunkSize), !data.isEmpty else { return nil }
        return (data.base64EncodedString(), data.count)
    }

    func close() {
        try? handle.close()
    }
}
