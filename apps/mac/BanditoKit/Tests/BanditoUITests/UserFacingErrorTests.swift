import BanditoKit
import BanditoL10n
import Foundation
import Network
import Testing

@testable import BanditoUI

@Suite struct UserFacingErrorTests {
    // MARK: transport: the server does not answer

    @Test func missingSocketIsAServerThatDoesNotAnswer() {
        // The "Network.NWError error 2 - No such file or directory" of the first launch.
        let message = UserFacingError.message(for: NWError.posix(.ENOENT))
        #expect(message.text == L10n.Failure.noAnswer)
        #expect(message.canRetry)
        #expect(message.technical == nil)
    }

    @Test func refusedConnectionIsAServerThatDoesNotAnswer() {
        let message = UserFacingError.message(for: POSIXError(.ECONNREFUSED))
        #expect(message.text == L10n.Failure.noAnswer)
        #expect(message.canRetry)
    }

    @Test func noRawSystemWordingReachesTheSentence() {
        let message = UserFacingError.message(for: NWError.posix(.ENOENT))
        #expect(!message.text.contains("NWError"))
        #expect(!message.text.contains("error 2"))
        #expect(!message.text.contains("No such file"))
    }

    // MARK: RPC

    @Test func revokedDeviceAsksToConnectAgain() {
        let message = UserFacingError.message(for: RPCError(code: RPCError.unauthorized, message: "unauthorized"))
        #expect(message.text == L10n.Failure.deviceRevoked)
        #expect(!message.canRetry)
        #expect(message.technical == nil)
    }

    @Test func knownDaemonReasonsGetShortSentences() {
        let cases: [(String, String)] = [
            ("not_found", L10n.Failure.Reason.notFound),
            ("forbidden", L10n.Failure.Reason.forbidden),
            ("conflict", L10n.Failure.Reason.conflict),
            ("exists", L10n.Failure.Reason.exists),
            ("not_empty", L10n.Failure.Reason.notEmpty),
            ("too_large", L10n.Failure.Reason.tooLarge),
            ("binary", L10n.Failure.Reason.binary),
            ("io", L10n.Failure.Reason.io),
            ("unsupported", L10n.Failure.Reason.unsupported),
            ("clone_failed", L10n.Failure.Reason.cloneFailed),
            ("decode_failed", L10n.Failure.Reason.decodeFailed),
        ]
        for (reason, text) in cases {
            let message = UserFacingError.message(for: RPCError(
                code: RPCError.fileError, message: "something", data: .object(["reason": .string(reason)])))
            #expect(message.text == text, "reason \(reason)")
            #expect(message.technical == nil, "reason \(reason)")
        }
    }

    @Test func reasonInTheMessagePrefixIsUsed() {
        let message = UserFacingError.message(for: RPCError(code: RPCError.terminalError, message: "not_found: t1"))
        #expect(message.text == L10n.Failure.Reason.notFound)
    }

    @Test func unknownReasonIsGenericWithTheReasonUnderDetails() {
        let message = UserFacingError.message(for: RPCError(code: -32000, message: "missing_component: browser"))
        #expect(message.text == L10n.Failure.generic)
        #expect(message.technical == "reason: missing_component")
        #expect(!message.canRetry)
    }

    // MARK: everything else

    @Test func unknownErrorIsGenericWithItsDescriptionUnderDetails() {
        struct Odd: Error, CustomStringConvertible {
            var description: String { "odd thing happened" }
        }
        let message = UserFacingError.message(for: Odd())
        #expect(message.text == L10n.Failure.generic)
        #expect(message.technical?.contains("odd thing happened") == true)
        #expect(!message.canRetry)
    }

    @Test func otherKindKeepsItsTechnicalText() {
        let message = UserFacingError.message(for: .other(technical: "boom"))
        #expect(message.text == L10n.Failure.generic)
        #expect(message.technical == "boom")
    }

    @Test func noAnswerKindOffersRetry() {
        let message = UserFacingError.message(for: .noAnswer)
        #expect(message.canRetry)
        #expect(message.technical == nil)
    }

    @Test func decodeWarningKindIsAReadableSentence() {
        let message = UserFacingError.message(for: FailureKind.reason("decode_failed"))
        #expect(message.text == L10n.Failure.Reason.decodeFailed)
    }

    // MARK: wrapping

    @Test func wrappedKeepsTechnicalTextAndRetry() {
        let original = UserFacingMessage(text: "inner", technical: "details", canRetry: true)
        let wrapped = original.wrapped { "Upload failed: \($0)" }
        #expect(wrapped.text == "Upload failed: inner")
        #expect(wrapped.technical == "details")
        #expect(wrapped.canRetry)
    }
}
