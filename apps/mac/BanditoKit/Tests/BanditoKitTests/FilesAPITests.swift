import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct FilesAPITests {
    nonisolated static let entry =
        #"{"name":"a.md","path":"/w/a.md","kind":"file","size":3,"modified_ms":1,"hidden":false,"readonly":false,"ext":"md"}"#

    nonisolated static let emptyListing = #"{"path":"/w","parent":null,"entries":[],"truncated":false,"skipped":0}"#

    /// Handlers for every fs.* method, each answering with a plausible result.
    nonisolated static func fsHandlers(_ extra: [String: FakeTransport.Handler] = [:]) -> [String: FakeTransport.Handler] {
        var handlers: [String: FakeTransport.Handler] = [
            "fs.list": { _ in emptyListing },
            "fs.stat": { _ in entry },
            "fs.read": { _ in
                #"{"path":"/w/a.md","content":"hi","etag":"e1","size":2,"modified_ms":1,"readonly":false}"#
            },
            "fs.write": { _ in #"{"etag":"e2"}"# },
            "fs.create_file": { _ in entry },
            "fs.mkdir": { _ in entry },
            "fs.rename": { _ in entry },
            "fs.copy": { _ in entry },
            "fs.trash": { _ in #"{"trashed_to":"/Users/me/.Trash/a.md"}"# },
            "fs.search": { _ in "[\(entry)]" },
            "fs.projects": { _ in
                #"[{"path":"/w/p","name":"p","is_git":true,"modified_ms":5}]"#
            },
        ]
        handlers.merge(extra) { _, new in new }
        return handlers
    }

    func lastRequest(_ method: String, _ fake: FakeTransport) async -> [String: Any] {
        paramsOf(JSONRPC.requests(of: method, in: await fake.sentTexts()).last ?? "{}")
    }

    @Test func listSendsPathAndHidden() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.fsHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let listing = try await model.list("/w", hidden: true)

        #expect(listing.path == "/w")
        let p = await lastRequest("fs.list", fake)
        #expect(p["path"] as? String == "/w")
        #expect(p["hidden"] as? Bool == true)
        await model.disconnect()
    }

    @Test func statReadAndCreateCallTheRightMethods() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.fsHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        #expect(try await model.stat("/w/a.md").name == "a.md")
        let text = try await model.readText("/w/a.md")
        #expect(text.etag == "e1")
        #expect(text.content == "hi")
        #expect(try await model.createFile("/w/new.md").path == "/w/a.md")
        #expect(try await model.mkdir("/w/dir").kind == .file)
        #expect(await lastRequest("fs.mkdir", fake)["path"] as? String == "/w/dir")
        _ = try await model.rename(from: "/w/a", to: "/w/b")
        let renamed = await lastRequest("fs.rename", fake)
        #expect(renamed["from"] as? String == "/w/a")
        #expect(renamed["to"] as? String == "/w/b")
        _ = try await model.copy(from: "/w/a", to: "/w/c")
        #expect(await lastRequest("fs.copy", fake)["to"] as? String == "/w/c")
        let trashed = try await model.trash("/w/c")
        #expect(trashed == "/Users/me/.Trash/a.md")
        await model.disconnect()
    }

    @Test func writeTextSendsEtagAndCreateFlag() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.fsHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let etag = try await model.writeText(path: "/w/a.md", content: "hi", etag: "e1")
        #expect(etag == "e2")
        var p = await lastRequest("fs.write", fake)
        #expect(p["etag"] as? String == "e1")
        #expect(p["create"] as? Bool == false)
        #expect(p["content"] as? String == "hi")

        _ = try await model.writeText(path: "/w/new.md", content: "", create: true)
        p = await lastRequest("fs.write", fake)
        #expect(p["etag"] == nil)
        #expect(p["create"] as? Bool == true)
        await model.disconnect()
    }

    @Test func staleEtagSurfacesConflictWithCurrentEtag() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(extra: Self.fsHandlers()),
            errors: [
                "fs.write": { _ in
                    #"{"code":-32020,"message":"conflict","data":{"reason":"conflict","etag":"e9"}}"#
                }
            ])
        let (model, _) = makeModel([fake])
        await model.connect()

        do {
            _ = try await model.writeText(path: "/w/a.md", content: "x", etag: "e1")
            Issue.record("expected a conflict")
        } catch let error as RPCError {
            #expect(error.code == -32020)
            #expect(error.reason == "conflict")
            #expect(error.etag == "e9")
        }
        await model.disconnect()
    }

    @Test func searchAndProjectsOmitUnsetLimits() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: Self.fsHandlers()))
        let (model, _) = makeModel([fake])
        await model.connect()

        let found = try await model.search(root: "/w", query: "rep")
        #expect(found.count == 1)
        let s = await lastRequest("fs.search", fake)
        #expect(s["root"] as? String == "/w")
        #expect(s["query"] as? String == "rep")
        #expect(s["limit"] == nil)

        let projects = try await model.projects(limit: 5)
        #expect(projects.first?.isGit == true)
        #expect(await lastRequest("fs.projects", fake)["limit"] as? Int == 5)
        _ = try await model.projects()
        #expect(await lastRequest("fs.projects", fake)["limit"] == nil)
        await model.disconnect()
    }

    // MARK: upload

    @Test func uploadSplitsIntoMiBChunksAndCommits() async throws {
        let size = 2_621_440  // 2.5 MiB
        let url = try makeTempFile(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeTransport(
            handlers: daemonHandlers(
                extra: [
                    "fs.upload.begin": { _ in #"{"upload_id":"u1"}"# },
                    "fs.upload.append": { params in
                        #"{"written":\#(decodedLength(object(params)["data"]))}"#
                    },
                    "fs.upload.commit": { _ in Self.entry },
                ]))
        let (model, _) = makeModel([fake])
        await model.connect()

        var progress: [Double] = []
        let entry = try await model.upload(local: url, to: "/w/big.bin") { progress.append($0) }

        let texts = await fake.sentTexts()
        let appends = JSONRPC.requests(of: "fs.upload.append", in: texts).map(paramsOf)
        #expect(appends.map { intValue($0["offset"]) } == [0, 1_048_576, 2_097_152])
        #expect(appends.map { decodedLength($0["data"]) } == [1_048_576, 1_048_576, 524_288])
        #expect(appends.allSatisfy { $0["upload_id"] as? String == "u1" })
        let commits = JSONRPC.requests(of: "fs.upload.commit", in: texts).map(paramsOf)
        #expect(commits.count == 1)
        #expect(commits.first?["upload_id"] as? String == "u1")
        #expect(commits.first?["overwrite"] as? Bool == false)
        #expect(JSONRPC.requests(of: "fs.upload.abort", in: texts).isEmpty)
        let begin = paramsOf(JSONRPC.requests(of: "fs.upload.begin", in: texts).first ?? "{}")
        #expect(begin["path"] as? String == "/w/big.bin")
        #expect(progress.last == 1.0)
        #expect(progress.count == 3)
        #expect(entry.name == "a.md")
        await model.disconnect()
    }

    @Test func failedAppendAbortsTheUpload() async throws {
        let size = 2_621_440
        let url = try makeTempFile(size: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let fake = FakeTransport(
            handlers: daemonHandlers(
                extra: [
                    "fs.upload.begin": { _ in #"{"upload_id":"u1"}"# },
                    "fs.upload.append": { params in
                        #"{"written":\#(decodedLength(object(params)["data"]))}"#
                    },
                    "fs.upload.abort": { _ in "{}" },
                ]),
            errors: [
                "fs.upload.append": { params in
                    intValue(object(params)["offset"]) == 1_048_576
                        ? #"{"code":-32020,"message":"io","data":{"reason":"io"}}"# : nil
                }
            ])
        let (model, _) = makeModel([fake])
        await model.connect()

        do {
            _ = try await model.upload(local: url, to: "/w/big.bin") { _ in }
            Issue.record("expected the upload to fail")
        } catch let error as RPCError {
            #expect(error.reason == "io")
        }

        let texts = await fake.sentTexts()
        #expect(JSONRPC.requests(of: "fs.upload.append", in: texts).count == 2)
        #expect(JSONRPC.requests(of: "fs.upload.commit", in: texts).isEmpty)
        let abort = paramsOf(JSONRPC.requests(of: "fs.upload.abort", in: texts).first ?? "{}")
        #expect(abort["upload_id"] as? String == "u1")
        await model.disconnect()
    }

    // MARK: raw URL

    @Test func wssServerGetsHTTPSRawURLWithBearerToken() throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "vps", endpoint: .webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!), token: "tok"),
            [])

        let request = try #require(model.rawURLRequest(path: "/w/a b+c.txt"))

        #expect(request.url?.scheme == "https")
        #expect(request.url?.host() == "srv.example.ts.net")
        #expect(request.url?.path() == "/v1/files/raw")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.url?.absoluteString.contains("path=/w/a%20b%2Bc.txt") == true)
    }

    @Test func plusIsNeverSentRaw() throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "vps", endpoint: .webSocket(url: URL(string: "wss://srv.example.ts.net/v1/rpc")!), token: "tok"),
            [])

        let request = try #require(model.rawURLRequest(path: "/a+b/c&d=e#f%g.txt"))

        let query = try #require(request.url?.query(percentEncoded: true))
        #expect(!query.contains("+"))
        #expect(!query.contains("&d"))
        #expect(!query.contains("#"))
        #expect(query.contains("%2B"))
        #expect(query.contains("%26"))
        #expect(query.contains("%3D"))
        #expect(query.contains("%23"))
        #expect(query.contains("%25"))
    }

    @Test func loopbackWebSocketGetsTokenOverHTTP() throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "tunnel", endpoint: .webSocket(url: URL(string: "ws://127.0.0.1:7878/v1/rpc")!), token: "tok"),
            [])

        let request = try #require(model.rawURLRequest(path: "/w/a.txt"))

        #expect(request.url?.scheme == "http")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func lanWebSocketNeverGetsTheToken() throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "lan", endpoint: .webSocket(url: URL(string: "ws://192.168.1.20:7878/v1/rpc")!), token: "tok"),
            [])

        // The token may not travel over this connection, so there is no request at all.
        #expect(model.rawURLRequest(path: "/w/a.txt") == nil)
    }

    @Test func lanWebSocketWithoutTokenSendsNoHeader() throws {
        let (model, _) = makeModel(
            config: ServerConfig(
                name: "lan", endpoint: .webSocket(url: URL(string: "ws://192.168.1.20:7878/v1/rpc")!), token: nil),
            [])

        let request = try #require(model.rawURLRequest(path: "/w/a.txt"))

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func localServerRawURLIsAFileURL() throws {
        let (model, _) = makeModel([])

        let request = try #require(model.rawURLRequest(path: "/Users/me/a.txt"))

        #expect(request.url == URL(fileURLWithPath: "/Users/me/a.txt"))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: features

    @Test func supportsReadsTheDaemonFeatures() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(
                extra: [
                    "daemon.info": { _ in
                        #"{"version":"0.0.0","hostname":"t","os":"macos","arch":"arm64","started_at":1,"last_seq":1,"features":["files","terminals"]}"#
                    }
                ]))
        let (model, _) = makeModel([fake])
        #expect(!model.supports("files"))
        await model.connect()

        #expect(model.supports("files"))
        #expect(model.supports("terminals"))
        #expect(!model.supports("secrets"))
        await model.disconnect()
    }
}
