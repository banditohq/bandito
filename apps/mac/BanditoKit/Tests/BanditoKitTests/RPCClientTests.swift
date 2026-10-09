import Foundation
import Testing

@testable import BanditoKit

@MainActor
@Suite struct RPCClientTests {
    @Test func answersAreMatchedByID() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        async let first: String = client.call("first", NoParams(), as: String.self)
        async let second: String = client.call("second", NoParams(), as: String.self)
        try await eventually { await fake.sentTexts().count == 2 }
        let texts = await fake.sentTexts()
        let idFirst = try #require(JSONRPC.id(of: "first", in: texts))
        let idSecond = try #require(JSONRPC.id(of: "second", in: texts))

        // Answer in reverse order: each caller must still get its own result.
        await fake.push(JSONRPC.response(id: idSecond, result: #""two""#))
        await fake.push(JSONRPC.response(id: idFirst, result: #""one""#))
        let one = try await first
        let two = try await second
        #expect(one == "one")
        #expect(two == "two")
        await client.close()
    }

    @Test func errorResponseBecomesRPCError() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        let call = Task { try await client.call("bad", NoParams(), as: String.self) }
        try await eventually { await fake.sentTexts().count == 1 }
        let id = try #require(JSONRPC.id(of: "bad", in: await fake.sentTexts()))
        await fake.push(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32602,"message":"bad params"}}"#)

        do {
            _ = try await call.value
            Issue.record("expected an RPCError")
        } catch let error as RPCError {
            #expect(error == RPCError(code: RPCError.invalidParams, message: "bad params"))
        }
        await client.close()
    }

    @Test func silentServerTimesOutOnceAndClientKeepsWorking() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        do {
            _ = try await client.call("silent", NoParams(), as: String.self, timeout: .milliseconds(100))
            Issue.record("expected a timeout")
        } catch let error as RPCError {
            #expect(error.code == RPCError.timedOut)
        }

        // The late answer finds no waiter: nothing is resumed twice, and the next call still works.
        let silentId = try #require(JSONRPC.id(of: "silent", in: await fake.sentTexts()))
        await fake.push(JSONRPC.response(id: silentId, result: #""late""#))
        let next = Task { try await client.call("next", NoParams(), as: String.self) }
        try await eventually { await fake.sentTexts().count == 2 }
        let nextId = try #require(JSONRPC.id(of: "next", in: await fake.sentTexts()))
        await fake.push(JSONRPC.response(id: nextId, result: #""ok""#))
        let result = try await next.value
        #expect(result == "ok")
        await client.close()
    }

    @Test func closeFailsPendingCalls() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        let pending = Task { try await client.call("hang", NoParams(), as: String.self) }
        try await eventually { await fake.sentTexts().count == 1 }
        await client.close()

        do {
            _ = try await pending.value
            Issue.record("expected disconnected")
        } catch let error as RPCError {
            #expect(error.code == RPCError.disconnected)
        }
        do {
            _ = try await client.call("after-close", NoParams(), as: String.self)
            Issue.record("expected disconnected")
        } catch let error as RPCError {
            #expect(error.code == RPCError.disconnected)
        }
    }

    @Test func undecodableEventIsCountedAndSkipped() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        await fake.push(
            #"{"jsonrpc":"2.0","method":"event","params":{"seq":"oops","agent_id":"a","ts":1,"kind":"message.assistant","payload":{"text":"x"}}}"#)
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 1, text: "ok")))

        var events = client.events.makeAsyncIterator()
        let first = await events.next()
        #expect(first?.seq == 1)
        #expect(first?.body == .messageAssistant(text: "ok"))
        #expect(await client.decodeFailures == 1)
        await client.close()
    }

    @Test func slowConsumerLosesNoEvents() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        // More than the old 10 000-event buffer, delivered before anyone reads.
        let total = 10_500
        for seq in 1...total {
            await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: seq, text: "e")))
        }
        var events = client.events.makeAsyncIterator()
        var received: Int64 = 0
        for _ in 0..<total {
            guard let e = await events.next() else { break }
            received = e.seq
        }
        #expect(received == Int64(total))
        await client.close()
    }
}

@MainActor
@Suite struct RPCWireTests {
    @Test func errorDataCarriesReasonAndEtag() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        let call = Task { try await client.call("fs.write", NoParams(), as: String.self) }
        try await eventually { await fake.sentTexts().count == 1 }
        let id = try #require(JSONRPC.id(of: "fs.write", in: await fake.sentTexts()))
        await fake.push(
            JSONRPC.errorResponse(
                id: id, error: #"{"code":-32020,"message":"conflict","data":{"reason":"conflict","etag":"e9"}}"#))

        do {
            _ = try await call.value
            Issue.record("expected a conflict")
        } catch let error as RPCError {
            #expect(error.code == -32020)
            #expect(error.reason == "conflict")
            #expect(error.etag == "e9")
            #expect(error.data == .object(["reason": .string("conflict"), "etag": .string("e9")]))
        }
        await client.close()
    }

    @Test func errorWithoutDataHasNoReasonOrEtag() async throws {
        let error = RPCError(code: RPCError.invalidParams, message: "bad params")
        #expect(error.data == nil)
        #expect(error.reason == nil)
        #expect(error.etag == nil)
    }

    @Test func otherNotificationsReachTheNotificationStreamAndEventsStillWork() async throws {
        let fake = FakeTransport(autoRespond: false)
        let client = RPCClient(transport: fake)
        try await client.start()

        await fake.push(#"{"jsonrpc":"2.0","method":"term.gap","params":{"id":"t1","lost":7}}"#)
        await fake.push(JSONRPC.notification(JSONRPC.messageEvent(seq: 1, text: "ok")))

        var notifications = client.notifications.makeAsyncIterator()
        let note = try #require(await notifications.next())
        #expect(note.method == "term.gap")
        struct Gap: Decodable {
            var id: String
            var lost: UInt64
        }
        let gap = try RPCClient.decoder.decode(Gap.self, from: note.params)
        #expect(gap.id == "t1")
        #expect(gap.lost == 7)

        var events = client.events.makeAsyncIterator()
        #expect(await events.next()?.seq == 1)
        await client.close()
    }
}
