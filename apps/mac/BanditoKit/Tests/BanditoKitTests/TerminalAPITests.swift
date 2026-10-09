import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct TerminalAPITests {
    nonisolated static let info =
        #"{"id":"t1","title":"sh","cwd":"/w","command":["/bin/zsh"],"pid":7,"cols":80,"rows":24,"created_at":1,"state":{"state":"running"},"offset":5}"#

    /// `term.attach` answer: `info`, the first byte `start`, and base64 `data` up to the current offset.
    nonisolated static func attachReply(start: Int, data: String) -> String {
        #"{"info":\#(info),"start":\#(start),"data":"\#(data)"}"#
    }

    nonisolated static func notification(_ method: String, _ params: String) -> String {
        #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(params)}"#
    }

    // MARK: attach and routing

    @Test func attachDeliversSnapshotThenLiveOutputOfItsOwnTerminalOnly() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 0, data: "aGVsbG8=") }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        let stream = try await model.attach("t1")
        await fake.push(Self.notification("term.output", #"{"id":"t2","offset":0,"data":"eA=="}"#))
        await fake.push(Self.notification("term.output", #"{"id":"t1","offset":5,"data":"IQ=="}"#))
        await fake.push(Self.notification("term.closed", #"{"id":"t1"}"#))

        let chunks = await collect(stream, count: 3)
        #expect(chunks == [.output(Data("hello".utf8)), .output(Data("!".utf8)), .closed])
        #expect(stream.nextOffset == 6)
        await model.disconnect()
    }

    @Test func gapExitAndClosedAreDelivered() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 0, data: "") }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        let stream = try await model.attach("t1")
        await fake.push(Self.notification("term.gap", #"{"id":"t1","lost":4}"#))
        await fake.push(Self.notification("term.output", #"{"id":"t1","offset":4,"data":"ZGU="}"#))
        await fake.push(Self.notification("term.exit", #"{"id":"t1","code":3,"signal":null}"#))
        await fake.push(Self.notification("term.closed", #"{"id":"t1"}"#))

        let chunks = await collect(stream, count: 4)
        #expect(chunks == [.gap(lost: 4), .output(Data("de".utf8)), .exit(code: 3, signal: nil), .closed])
        #expect(stream.nextOffset == 6)
        await model.disconnect()
    }

    @Test func overlappingOutputIsTrimmedAndAGapBeforeAttachIsReported() async throws {
        // The snapshot starts at 10 although the caller asked for 0: the 10 bytes in between are lost.
        let fake = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 10, data: "ZGU=") }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        let stream = try await model.attach("t1", from: 0)
        // Bytes 10..11 arrive again (already in the snapshot), then byte 12 is new.
        await fake.push(Self.notification("term.output", #"{"id":"t1","offset":10,"data":"ZGU="}"#))
        await fake.push(Self.notification("term.output", #"{"id":"t1","offset":12,"data":"Zg=="}"#))

        let chunks = await collect(stream, count: 3)
        #expect(chunks == [.gap(lost: 10), .output(Data("de".utf8)), .output(Data("f".utf8))])
        #expect(stream.nextOffset == 13)
        await model.disconnect()
    }

    @Test func detachStopsOutputAndEndsTheStream() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(
                extra: [
                    "term.attach": { _ in Self.attachReply(start: 0, data: "") },
                    "term.detach": { _ in "{}" },
                ]))
        let (model, _) = makeModel([fake])
        await model.connect()

        let stream = try await model.attach("t1")
        try await model.detach("t1")
        await fake.push(Self.notification("term.output", #"{"id":"t1","offset":0,"data":"eA=="}"#))

        #expect(await collect(stream, count: 1).isEmpty)
        let detaches = JSONRPC.requests(of: "term.detach", in: await fake.sentTexts())
        #expect(detaches.count == 1)
        #expect(paramsOf(detaches[0])["id"] as? String == "t1")
        await model.disconnect()
    }

    // MARK: reconnect

    @Test func reconnectReattachesFromTheNextOffset() async throws {
        let first = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 0, data: "YWJj") }]))
        let second = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 3, data: "ZGU=") }]))
        let (model, queue) = makeModel([first, second], reconnectDelay: .milliseconds(20))
        await model.connect()
        let stream = try await model.attach("t1")
        #expect(await collect(stream, count: 1) == [.output(Data("abc".utf8))])

        await first.dropConnection()

        try await eventually { model.state == .connected && queue.made.count == 2 }
        let attaches = JSONRPC.requests(of: "term.attach", in: await second.sentTexts())
        #expect(attaches.count == 1)
        #expect(JSONRPC.intParam("from", in: attaches.first ?? "") == 3)
        #expect(await collect(stream, count: 1) == [.output(Data("de".utf8))])
        await model.disconnect()
    }

    @Test func aTerminalThatIsGoneEndsItsStreamOnReconnect() async throws {
        let first = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 0, data: "YWJj") }]))
        let second = FakeTransport(
            handlers: daemonHandlers(),
            errors: [
                "term.attach": { _ in
                    #"{"code":-32021,"message":"not_found: no such terminal"}"#
                }
            ])
        let (model, queue) = makeModel([first, second], reconnectDelay: .milliseconds(20))
        await model.connect()
        let stream = try await model.attach("t1")
        #expect(await collect(stream, count: 1) == [.output(Data("abc".utf8))])

        await first.dropConnection()

        try await eventually { model.state == .connected && queue.made.count == 2 }
        #expect(await collect(stream, count: 1) == [.closed])
        await model.disconnect()
    }

    // MARK: calls

    @Test func terminalCallsSendTheDocumentedMethodsAndParams() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(
                extra: [
                    "term.list": { _ in "[\(Self.info)]" },
                    "term.open": { _ in Self.info },
                    "term.input": { _ in "{}" },
                    "term.resize": { _ in Self.info },
                    "term.rename": { _ in Self.info },
                    "term.close": { _ in "{}" },
                ]))
        let (model, _) = makeModel([fake])
        await model.connect()

        #expect(try await model.terminals().map(\.id) == ["t1"])

        let opened = try await model.openTerminal(
            cwd: "/w", command: ["/bin/zsh", "-l"], title: "sh", cols: 80, rows: 24, env: ["LANG": "C"])
        #expect(opened.id == "t1")
        #expect(opened.state == .running)
        let open = paramsOf(JSONRPC.requests(of: "term.open", in: await fake.sentTexts())[0])
        #expect(open["cwd"] as? String == "/w")
        #expect(open["command"] as? [String] == ["/bin/zsh", "-l"])
        #expect(open["title"] as? String == "sh")
        #expect(intValue(open["cols"]) == 80)
        #expect(intValue(open["rows"]) == 24)
        #expect((open["env"] as? [String: String]) == ["LANG": "C"])

        try await model.input(Data("ls\n".utf8), to: "t1")
        let input = paramsOf(JSONRPC.requests(of: "term.input", in: await fake.sentTexts())[0])
        #expect(input["id"] as? String == "t1")
        #expect(input["data"] as? String == "bHMK")

        _ = try await model.resize("t1", cols: 100, rows: 30)
        let resize = paramsOf(JSONRPC.requests(of: "term.resize", in: await fake.sentTexts())[0])
        #expect(intValue(resize["cols"]) == 100)
        #expect(intValue(resize["rows"]) == 30)

        _ = try await model.rename("t1", title: "build")
        #expect(paramsOf(JSONRPC.requests(of: "term.rename", in: await fake.sentTexts())[0])["title"] as? String == "build")

        try await model.closeTerminal("t1")
        #expect(paramsOf(JSONRPC.requests(of: "term.close", in: await fake.sentTexts())[0])["id"] as? String == "t1")
        await model.disconnect()
    }

    // MARK: held output, aborted attaches, limits

    @Test func abortingAnAttachDeliversWhatWasHeldThenTheError() async throws {
        let stream = TerminalStream(id: "t1")
        stream.receiveOutput(offset: 0, data: Data("ab".utf8))

        stream.abortAttach(error: "io: link lost")
        #expect(await collect(stream, count: 2) == [.output(Data("ab".utf8)), .error("io: link lost")])

        // The stream is still open and follows output again.
        stream.receiveOutput(offset: 2, data: Data("c".utf8))
        #expect(await collect(stream, count: 1) == [.output(Data("c".utf8))])
        #expect(stream.nextOffset == 3)
    }

    @Test func heldOutputIsCappedAndTheLossShowsAsAGap() async throws {
        let stream = TerminalStream(id: "t1")
        let mib = 1 << 20
        // Five MiB arrive while the attach is in flight; the cap is four.
        for i in 0..<5 {
            stream.receiveOutput(offset: UInt64(i * mib), data: Data(count: mib))
        }

        stream.completeAttach(from: nil, start: 0, data: Data())

        let chunks = await collect(stream, count: 5)
        #expect(chunks.first == .gap(lost: UInt64(mib)))
        #expect(chunks.dropFirst().count == 4)
        #expect(chunks.dropFirst().allSatisfy { $0 == .output(Data(count: mib)) })
        #expect(stream.nextOffset == UInt64(5 * mib))
    }

    @Test func aFailedReattachReportsTheErrorAndKeepsTheStream() async throws {
        let first = FakeTransport(
            handlers: daemonHandlers(extra: ["term.attach": { _ in Self.attachReply(start: 0, data: "YWJj") }]))
        let second = FakeTransport(
            handlers: daemonHandlers(),
            errors: [
                "term.attach": { _ in
                    #"{"code":-32000,"message":"io: boom"}"#
                }
            ])
        let (model, queue) = makeModel([first, second], reconnectDelay: .milliseconds(20))
        await model.connect()
        let stream = try await model.attach("t1")
        #expect(await collect(stream, count: 1) == [.output(Data("abc".utf8))])

        await first.dropConnection()

        try await eventually { model.state == .connected && queue.made.count == 2 }
        #expect(await collect(stream, count: 1) == [.error("io: boom")])
        await model.disconnect()
    }

    @Test func inputOverTheLimitIsRefusedBeforeItIsSent() async throws {
        let fake = FakeTransport(handlers: daemonHandlers(extra: ["term.input": { _ in "{}" }]))
        let (model, _) = makeModel([fake])
        await model.connect()

        await #expect(throws: RPCError.self) {
            try await model.input(Data(count: (64 << 10) + 1), to: "t1")
        }
        try await model.input(Data(count: 64 << 10), to: "t1")

        let inputs = JSONRPC.requests(of: "term.input", in: await fake.sentTexts())
        #expect(inputs.count == 1)
        await model.disconnect()
    }

    @Test func terminalSizeOutsideOneToAThousandIsRefusedBeforeItIsSent() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(
                extra: [
                    "term.open": { _ in Self.info },
                    "term.resize": { _ in Self.info },
                ]))
        let (model, _) = makeModel([fake])
        await model.connect()

        await #expect(throws: RPCError.self) { _ = try await model.openTerminal(cols: 0, rows: 24) }
        await #expect(throws: RPCError.self) { _ = try await model.openTerminal(cols: 80, rows: 1001) }
        await #expect(throws: RPCError.self) { _ = try await model.resize("t1", cols: 1001, rows: 24) }
        _ = try await model.openTerminal(cols: 1000, rows: 1)

        #expect(JSONRPC.requests(of: "term.open", in: await fake.sentTexts()).count == 1)
        #expect(JSONRPC.requests(of: "term.resize", in: await fake.sentTexts()).isEmpty)
        await model.disconnect()
    }
}
