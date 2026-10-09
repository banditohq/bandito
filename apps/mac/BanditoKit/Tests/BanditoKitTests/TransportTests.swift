import Foundation
import Testing

@testable import BanditoKit

@Suite struct TransportTests {
    @Test func tokenMayOnlyTravelOverTLSOrLoopback() {
        #expect(WebSocketTransport.allowsToken(for: URL(string: "wss://bandito.example.com/v1/rpc")!))
        #expect(WebSocketTransport.allowsToken(for: URL(string: "ws://127.0.0.1:7878/v1/rpc")!))
        #expect(WebSocketTransport.allowsToken(for: URL(string: "ws://[::1]:7878/v1/rpc")!))
        #expect(WebSocketTransport.allowsToken(for: URL(string: "ws://localhost:7878/v1/rpc")!))
        #expect(!WebSocketTransport.allowsToken(for: URL(string: "ws://192.168.1.20:7878/v1/rpc")!))
        #expect(!WebSocketTransport.allowsToken(for: URL(string: "http://bandito.example.com/v1/rpc")!))
    }

    @Test func connectRefusesToSendTokenInTheClear() async throws {
        let transport = WebSocketTransport(url: URL(string: "ws://192.168.1.20:7878/v1/rpc")!, token: "secret")
        do {
            try await transport.connect()
            Issue.record("expected the token to be refused")
        } catch let error as RPCError {
            #expect(
                error
                    == RPCError(
                        code: RPCError.insecureTransport,
                        message: "refusing to send the device token over an unencrypted connection"))
        }
    }
}
