import BanditoKit
import BanditoL10n
import CryptoKit
import Foundation
import Testing

@testable import Bandito

@MainActor
@Suite struct JoinLinkTests {
    private func link(name: String = "Studio 🦝") -> String {
        JoinTicket.make(macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, macName: name).link.absoluteString
    }

    @Test func theScannerTakesAJoinLinkAndNothingElse() {
        #expect(JoinScanReading.of(link()) == .ticket)
        #expect(JoinScanReading.of("Sign in: \(link())") == .ticket)
        #expect(JoinScanReading.of("bandito://pair?v=1&code=otter-lava-mint-orbit-crane-fig&name=Studio&host=10.0.0.2:7879") == .notJoin)
        #expect(JoinScanReading.of("https://example.com/join") == .notJoin)
        #expect(JoinScanReading.of("bandito://join?v=1") == .notJoin)
        #expect(JoinScanReading.of("") == .notJoin)
    }

    @Test func anOpenedUrlIsAJoinTicketOnlyWhenItIsOne() throws {
        let url = try #require(URL(string: link()))
        let ticket = try #require(JoinTicket.parse(url))
        #expect(ticket.macName == "Studio 🦝")
        #expect(JoinTicket.parse(try #require(URL(string: "bandito://join?v=2&t=a&m=b"))) == nil)
        #expect(JoinTicket.parse(try #require(URL(string: "bandito://pair?v=1"))) == nil)
        // A join link is not one of the widget links.
        #expect(BanditoLink(url: url) == nil)
    }

    @Test func theConnectScannerHandsAJoinLinkToTheAccountAndLeavesPairingAlone() async throws {
        let defaults = UserDefaults(suiteName: "ios-join-link-\(UUID().uuidString)")!
        let store = ServerStore(
            fileURL: FileManager.default.temporaryDirectory.appending(path: "bandito-\(UUID().uuidString)/servers.json"),
            defaults: defaults)
        let session = ServerSession(store: store, secrets: MemorySecrets(), connect: { _ in })
        let model = PairModel(session: session, deviceName: "Test iPhone")
        var got: [JoinTicket] = []
        model.onJoin = { got.append($0) }

        model.submitLink(link(), origin: .scan)
        model.submitLink("look: \(link(name: "Other"))", origin: .paste)
        // The camera sees a code many times a second: it is handed on once.
        #expect(got.map(\.macName) == ["Studio 🦝"])
        #expect(model.phase == .choose, "a join link is not a server: the screen stays")

        model.submitLink("bandito://pair?v=1&code=otter-lava-mint-orbit-crane-fig&name=Studio&host=10.0.0.2:7879&fp=\(String(repeating: "ab", count: 32))", origin: .paste)
        if case .confirmLink = model.phase {} else { Issue.record("a pairing link still asks first") }
        #expect(got.count == 1)
    }

    @Test func theQuestionNamesTheMacOrSaysMacWhenTheCodeHasNoName() {
        let named = JoinTicket.make(macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, macName: "Studio 🦝")
        let bare = JoinTicket.make(macPublicKey: Curve25519.KeyAgreement.PrivateKey().publicKey, macName: "\u{202E}")
        #expect(JoinConfirmSheet.displayName(named) == "Studio 🦝")
        #expect(JoinConfirmSheet.displayName(bare) == L10n.Ios.Join.defaultMac)
    }
}
