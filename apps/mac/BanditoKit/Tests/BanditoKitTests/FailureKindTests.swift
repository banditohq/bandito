import Foundation
import Network
import Testing

@testable import BanditoKit

@Suite struct FailureKindTests {
    // MARK: transport

    @Test func networkFrameworkErrorIsNoAnswer() {
        // The "Network.NWError error 2 - No such file or directory" a new user saw: the local socket is missing.
        #expect(FailureKind.classify(NWError.posix(.ENOENT)) == .noAnswer)
        #expect(FailureKind.classify(NWError.posix(.ECONNREFUSED)) == .noAnswer)
    }

    @Test func posixNetworkErrorsAreNoAnswer() {
        #expect(FailureKind.classify(POSIXError(.ENOENT)) == .noAnswer)
        #expect(FailureKind.classify(POSIXError(.ECONNREFUSED)) == .noAnswer)
        #expect(FailureKind.classify(POSIXError(.ETIMEDOUT)) == .noAnswer)
        #expect(FailureKind.classify(POSIXError(.ECONNRESET)) == .noAnswer)
    }

    @Test func urlNetworkErrorsAreNoAnswer() {
        #expect(FailureKind.classify(URLError(.cannotConnectToHost)) == .noAnswer)
        #expect(FailureKind.classify(URLError(.timedOut)) == .noAnswer)
        #expect(FailureKind.classify(URLError(.notConnectedToInternet)) == .noAnswer)
    }

    @Test func clientSideDisconnectAndTimeoutAreNoAnswer() {
        let closed = RPCError(code: RPCError.disconnected, message: "disconnected from the server")
        let slow = RPCError(code: RPCError.timedOut, message: "timed out")
        #expect(FailureKind.classify(closed) == .noAnswer)
        #expect(FailureKind.classify(slow) == .noAnswer)
    }

    // MARK: RPC

    @Test func unauthorizedMeansTheDeviceWasRevoked() {
        let error = RPCError(code: RPCError.unauthorized, message: "unauthorized")
        #expect(FailureKind.classify(error) == .deviceRevoked)
    }

    @Test func aRejectedKeyIsNotNoAnswer() {
        let rejected = RPCError(code: RPCError.keyRejected, message: "the server rejected the device key (HTTP 401)")
        #expect(FailureKind.classify(rejected) == .keyRejected)
        // The bare system error of a failed handshake stays what it was: nothing says the server answered.
        #expect(FailureKind.classify(URLError(.badServerResponse)) != .keyRejected)
    }

    @Test func dataReasonWinsOverTheMessage() {
        let error = RPCError(
            code: RPCError.fileError, message: "could not write", data: .object(["reason": .string("conflict")]))
        #expect(FailureKind.classify(error) == .reason("conflict"))
    }

    @Test func snakeCasePrefixOfTheMessageIsTheReason() {
        let error = RPCError(code: RPCError.terminalError, message: "not_found: terminal not found: t1")
        #expect(FailureKind.classify(error) == .reason("not_found"))
    }

    @Test func messageWithoutAReasonStaysTechnical() {
        let error = RPCError(code: -32000, message: "Something Odd: happened")
        #expect(FailureKind.classify(error) == .other(technical: "Something Odd: happened"))
    }

    // MARK: everything else

    @Test func unknownErrorKeepsItsDescriptionAsTechnicalText() {
        let error = NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil)
        guard case .other(let technical) = FailureKind.classify(error) else {
            Issue.record("expected .other for an unknown error")
            return
        }
        #expect(!technical.isEmpty)
    }

    @Test func posixErrorOutsideTheNetworkSetIsNotNoAnswer() {
        #expect(FailureKind.classify(POSIXError(.EACCES)) != .noAnswer)
    }

    @Test func leadingReasonNeedsLowerCaseSnakeCase() {
        #expect(FailureKind.leadingReason(of: "not_found: x") == "not_found")
        #expect(FailureKind.leadingReason(of: "NotFound: x") == nil)
        #expect(FailureKind.leadingReason(of: "no colon here") == nil)
        #expect(FailureKind.leadingReason(of: ": empty") == nil)
    }
}
