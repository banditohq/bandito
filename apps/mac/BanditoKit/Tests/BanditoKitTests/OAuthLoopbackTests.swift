import Foundation
import Testing

@testable import BanditoKit

@Suite struct OAuthLoopbackTests {
    private func request(_ line: String, headers: [String] = []) -> Data {
        Data(([line] + headers + ["", ""]).joined(separator: "\r\n").utf8)
    }

    private func verdict(_ line: String, state: String = "S1") -> OAuthLoopback.Verdict {
        OAuthLoopback.evaluate(request(line), expectedState: state)
    }

    @Test func theRightCallbackIsTaken() {
        let found = verdict("GET /callback?code=abc&state=S1&iss=https%3A%2F%2Fmcp.example HTTP/1.1")
        #expect(found == .callback(OAuthCallback(state: "S1", code: "abc", iss: "https://mcp.example", error: nil)))
    }

    @Test func aDeniedAnswerWithTheRightStateIsACallbackToo() {
        let found = verdict("GET /callback?error=access_denied&state=S1 HTTP/1.1")
        #expect(found == .callback(OAuthCallback(state: "S1", code: nil, iss: nil, error: "access_denied")))
    }

    @Test func anotherStateOrNoStateIsRefusedWithoutEndingTheWait() {
        #expect(verdict("GET /callback?code=abc&state=OTHER HTTP/1.1") == .wrongState)
        #expect(verdict("GET /callback?code=abc HTTP/1.1") == .wrongState)
        #expect(verdict("GET /callback?code=abc&state= HTTP/1.1") == .wrongState)
        #expect(OAuthLoopback.response(for: .wrongState, acceptLanguage: nil).starts(with: Data("HTTP/1.1 400".utf8)))
    }

    @Test func anotherPathOrMethodIsNotFound() {
        for line in [
            "GET / HTTP/1.1", "GET /callback/ HTTP/1.1", "GET /favicon.ico HTTP/1.1", "GET /callbackx?state=S1 HTTP/1.1",
            "POST /callback?code=a&state=S1 HTTP/1.1", "HEAD /callback?code=a&state=S1 HTTP/1.1",
            "GET http://evil.example/other?state=S1 HTTP/1.1",
        ] {
            #expect(verdict(line) == .notFound, "\(line)")
        }
        #expect(OAuthLoopback.response(for: .notFound, acceptLanguage: nil).starts(with: Data("HTTP/1.1 404".utf8)))
    }

    @Test func aRequestThatIsNotHTTPIsBad() {
        #expect(verdict("hello") == .badRequest)
        #expect(verdict("GET /callback") == .badRequest)
        #expect(OAuthLoopback.evaluate(Data([0xff, 0xfe, 0x0d, 0x0a, 0x0d, 0x0a]), expectedState: "S1") == .badRequest)
    }

    @Test func aHeadThatHasNotAllArrivedWaits() {
        #expect(OAuthLoopback.evaluate(Data("GET /callback?code=a&sta".utf8), expectedState: "S1") == .incomplete)
        #expect(OAuthLoopback.evaluate(Data(), expectedState: "S1") == .incomplete)
    }

    @Test func aRequestOverTheLimitIsRefused() {
        let long = String(repeating: "a", count: OAuthLoopback.maxRequestBytes + 10)
        // Without the end of the head yet, and with it.
        #expect(OAuthLoopback.evaluate(Data(long.utf8), expectedState: "S1") == .tooLarge)
        #expect(verdict("GET /callback?state=S1&code=\(long) HTTP/1.1") == .tooLarge)
        #expect(OAuthLoopback.response(for: .tooLarge, acceptLanguage: nil).starts(with: Data("HTTP/1.1 431".utf8)))
    }

    @Test func theAcceptLanguageHeaderIsFoundInTheHead() {
        let data = request("GET /callback HTTP/1.1", headers: ["Host: 127.0.0.1:45819", "accept-language: ru-RU,ru;q=0.9"])
        #expect(OAuthLoopback.acceptLanguage(in: data) == "ru-RU,ru;q=0.9")
        #expect(OAuthLoopback.acceptLanguage(in: request("GET / HTTP/1.1")) == nil)
    }

    @Test func theLanguageFollowsTheBrowser() {
        #expect(OAuthLoopback.language(for: nil) == "en")
        #expect(OAuthLoopback.language(for: "ru-RU,ru;q=0.9,en;q=0.8") == "ru")
        #expect(OAuthLoopback.language(for: "zh-CN") == "zh-Hans")
        #expect(OAuthLoopback.language(for: "pt-PT, en;q=0.5") == "pt-BR")
        #expect(OAuthLoopback.language(for: "de;q=0.4, fr;q=0.8") == "fr")
        #expect(OAuthLoopback.language(for: "ja") == "ja")
        #expect(OAuthLoopback.language(for: "ko-KR") == "ko")
        #expect(OAuthLoopback.language(for: "es-419") == "es")
        #expect(OAuthLoopback.language(for: "it-IT, sv;q=0.8") == "en", "no match: English")
        #expect(OAuthLoopback.language(for: "ru;q=0, de") == "de", "q=0 means not wanted")
        #expect(OAuthLoopback.language(for: ";;,,,") == "en")
    }

    @Test func thePageSpeaksAllNineLanguages() throws {
        let done = ["en": "Done", "ru": "Готово", "ja": "完了", "zh-Hans": "完成", "ko": "완료", "es": "Listo",
            "pt-BR": "Pronto", "de": "Fertig", "fr": "Terminé"]
        for (code, word) in done {
            let reply = OAuthLoopback.response(
                for: .callback(OAuthCallback(state: "S1", code: "c")), acceptLanguage: code)
            let text = try #require(String(data: reply, encoding: .utf8))
            #expect(text.hasPrefix("HTTP/1.1 200 OK"), "\(code)")
            #expect(text.contains(word), "\(code)")
            #expect(text.contains("lang=\"\(code)\""), "\(code)")
            #expect(text.contains("Connection: close"))
        }
    }

    @Test func aDeniedCallbackGetsTheFailurePage() throws {
        let reply = OAuthLoopback.response(
            for: .callback(OAuthCallback(state: "S1", error: "access_denied")), acceptLanguage: "en")
        let text = try #require(String(data: reply, encoding: .utf8))
        #expect(text.contains("did not finish"))
        #expect(!text.contains("Done"))
    }

    @Test func theContentLengthIsRight() throws {
        let reply = OAuthLoopback.response(for: .callback(OAuthCallback(state: "S1", code: "c")), acceptLanguage: "ru")
        let marker = Data("\r\n\r\n".utf8)
        let split = try #require(reply.range(of: marker))
        let head = try #require(String(data: reply[..<split.lowerBound], encoding: .utf8))
        let body = reply[split.upperBound...]
        #expect(head.contains("Content-Length: \(body.count)"))
    }
}
