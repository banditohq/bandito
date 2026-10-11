import Foundation
import Testing

@testable import BanditoKit

/// The Telegram wire shapes, read with the app's decoder (snake_case keys become camelCase), the `telegram.changed`
/// event, and the probe that hides the section on a daemon without Telegram.
@MainActor
@Suite struct TelegramWireTests {
    @Test func statusReadsTheBotAndTheChats() throws {
        let raw = #"{"configured":true,"bot":{"username":"bandito_dev_bot","name":"Bandito"},"running":true,"last_error":null,"chats":[{"chat_id":42,"title":"Anna","language":"ru","linked_at":1786000000000,"approvals":true,"answers":"telegram"}]}"#
        let status = try RPCClient.decoder.decode(TelegramStatus.self, from: Data(raw.utf8))
        #expect(status.configured)
        #expect(status.bot == TelegramBot(username: "bandito_dev_bot", name: "Bandito"))
        #expect(status.running)
        #expect(status.lastError == nil)
        #expect(
            status.chats == [
                TelegramChat(
                    chatId: 42, title: "Anna", language: "ru", linkedAt: 1_786_000_000_000, approvals: true,
                    answers: .telegram)
            ])
    }

    @Test func statusWithoutATokenHasNoBotAndNoChats() throws {
        let raw = #"{"configured":false,"bot":null,"running":false,"last_error":null,"chats":[]}"#
        let status = try RPCClient.decoder.decode(TelegramStatus.self, from: Data(raw.utf8))
        #expect(!status.configured)
        #expect(status.bot == nil)
        #expect(status.chats.isEmpty)
    }

    @Test func statusCarriesTheLastError() throws {
        let raw = #"{"configured":true,"bot":{"username":"b","name":"B"},"running":false,"last_error":"conflict","chats":[]}"#
        let status = try RPCClient.decoder.decode(TelegramStatus.self, from: Data(raw.utf8))
        #expect(status.lastError == "conflict")
        #expect(!status.running)
    }

    @Test func linkReadsTheCodeAndWhenItEnds() throws {
        let raw = #"{"code":"ABCD2345","url":"https://t.me/bandito_dev_bot?start=ABCD2345","expires_at":1786000600000}"#
        let link = try RPCClient.decoder.decode(TelegramLink.self, from: Data(raw.utf8))
        #expect(
            link
                == TelegramLink(
                    code: "ABCD2345", url: "https://t.me/bandito_dev_bot?start=ABCD2345", expiresAt: 1_786_000_600_000))
    }

    @Test func telegramChangedEventDecodesWithoutData() throws {
        let raw = #"{"seq":7,"agent_id":"","ts":1,"kind":"telegram.changed","payload":{}}"#
        let event = try RPCClient.decoder.decode(Event.self, from: Data(raw.utf8))
        guard case .telegramChanged = event.body else {
            Issue.record("wrong body \(event.body)")
            return
        }
    }

    @Test func applyingTheEventCountsAChange() {
        let (model, _) = makeModel([FakeTransport(handlers: [:])])
        #expect(model.telegramRevision == 0)
        model.apply(Event(seq: 7, agentId: "", ts: 1, body: .telegramChanged))
        model.apply(Event(seq: 8, agentId: "", ts: 2, body: .telegramChanged))
        #expect(model.telegramRevision == 2)
    }

    @Test func anOlderDaemonHidesTheTelegramSection() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(),
            errors: ["telegram.status": { _ in #"{"code":-32601,"message":"Method not found: telegram.status"}"# }])
        let (model, _) = makeModel([fake])
        await model.connect()
        await model.checkTelegramSupport()
        #expect(model.telegramSupport == .unsupported)
    }

    @Test func theProbeIsUnknownUntilItAnswer() async throws {
        let (model, _) = makeModel([FakeTransport(handlers: [:])])
        #expect(model.telegramSupport == .unknown)
        // Not connected: the probe cannot answer, so the state stays unknown.
        await model.checkTelegramSupport()
        #expect(model.telegramSupport == .unknown)
    }

    @Test func aDaemonWithTelegramKeepsTheSection() async throws {
        let fake = FakeTransport(
            handlers: daemonHandlers(extra: [
                "telegram.status": { _ in #"{"configured":false,"bot":null,"running":false,"last_error":null,"chats":[]}"# }
            ]))
        let (model, _) = makeModel([fake])
        await model.connect()
        await model.checkTelegramSupport()
        #expect(model.telegramSupport == .supported)
    }
}
