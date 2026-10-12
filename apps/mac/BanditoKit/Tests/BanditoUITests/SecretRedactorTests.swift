import Foundation
import Testing

@testable import BanditoUI

/// The filter that runs over a problem report before the person sees it: what it must hide, and what it must leave.
@Suite struct SecretRedactorTests {
    private let mark = SecretRedactor.mark
    private let redactor = SecretRedactor()

    /// Built from two halves: a whole token in the source would trip secret scanners.
    private let t0 = "sk-ant-api03-AbCd" + "Ef1234567890xyzQQ"
    private let t1 = "sk-proj12345" + "67890abcdefgh"
    private let t2 = "ghp_1234567890abcdef" + "ghijABCDEFGHIJ123456"
    private let t3 = "github_pat_11ABCDEFG012" + "3456789_abcdefghijklmnop"
    private let t4 = "xoxb-12345678901" + "2-abcdefghijklmn"
    private let t5 = "AKIAIOSFOD" + "NN7EXAMPLE"
    private let t6 = "bdt_abcdef" + "0123456789"
    private let t7 = "bat_abcdef" + "0123456789"
    private let t8 = "123456789:AAHdqTcvCH1v" + "GWJxfSeofSAs0K5PALDsaw"
    private let t9 = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NT" + "Y3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r"
    private let t10 = "Zk3nQ8vL1xP9wR2t" + "Y7uB4mC6dF0gH5jA"
    private let t11 = "MIIEvQI" + "BADANBg"
    private let t12 = "pa55" + "word"

    private func hides(_ secret: String, in text: String, with redactor: SecretRedactor? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
        let out = (redactor ?? self.redactor).redact(text)
        #expect(!out.contains(secret), "\(secret) is still in: \(out)", sourceLocation: sourceLocation)
        #expect(out.contains(mark), "no marker in: \(out)", sourceLocation: sourceLocation)
    }

    private func keeps(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(redactor.redact(text) == text, "changed: \(redactor.redact(text))", sourceLocation: sourceLocation)
    }

    // MARK: what must go

    @Test func tokensOfTheKnownServices() {
        hides("\(t0)", in: "key \(t0) failed")
        hides("\(t1)", in: "using \(t1) now")
        hides("\(t2)", in: "push with \(t2)")
        hides("\(t3)", in: "\(t3)")
        hides("\(t4)", in: "slack \(t4) ok")
        hides("\(t5)", in: "aws \(t5)")
        hides("\(t6)", in: "token \(t6) refused")
        hides("\(t7)", in: "agent \(t7)")
    }

    @Test func bearerAndAuthorizationHeaders() {
        hides("abc.def.ghi12345", in: "Authorization: Bearer abc.def.ghi12345")
        hides("dXNlcjpwYXNzd29yZA==", in: "Authorization: Basic dXNlcjpwYXNzd29yZA==")
        let jwt = "\(t9)"
        hides("eyJzdWIi", in: "session \(jwt)")
        #expect(redactor.redact("bearer abcdefgh12345").contains("bearer ‹скрыто›"))
    }

    @Test func aTelegramKey() {
        hides("\(t8)", in: "bot \(t8) is up")
    }

    @Test func passwordsAndKeysInSettings() {
        hides("hunter2", in: "DB_PASSWORD=hunter2 and more")
        hides("sk-xyz", in: "ANTHROPIC_API_KEY=sk-xyz")
        hides("abc123", in: "OPENAI_API_KEY: abc123")
        hides("hunter2", in: #"{"password": "hunter2", "user": "x"}"#)
        hides("topsecret", in: "client_secret = 'topsecret'")
        hides("s3cr3t", in: "api-key: s3cr3t")
        #expect(redactor.redact("DB_PASSWORD=hunter2 PORT=5432").contains("PORT=5432"))
    }

    @Test func aPasswordInsideALinkAndAPrivateKey() {
        hides("\(t12)", in: "clone https://deploy:\(t12)@git.example.com/repo.git")
        hides("\(t11)", in: "-----BEGIN PRIVATE KEY-----\n\(t11)\n-----END PRIVATE KEY-----")
    }

    @Test func emailsAddressesAndHosts() {
        hides("maria@example.com", in: "signed in as maria@example.com")
        hides("192.168.1.20", in: "connect to 192.168.1.20:7878")
        hides("fe80::1ff:fe23:4567:890a", in: "listening on fe80::1ff:fe23:4567:890a")
        hides("2001:db8::1", in: "peer 2001:db8::1 left")
        hides("2001:0db8:85a3:0000:0000:8a2e:0370:7334", in: "host 2001:0db8:85a3:0000:0000:8a2e:0370:7334")
        hides("bandito-prod.example.internal", in: "wss://bandito-prod.example.internal:7878/v1/rpc failed")
        hides("my-server.example.com", in: "ping my-server.example.com timed out")
        hides("Marias-MacBook-Pro.local", in: "host Marias-MacBook-Pro.local")
        hides("aa:bb:cc:dd:ee:ff", in: "mac aa:bb:cc:dd:ee:ff")
    }

    @Test func theHomeFolderOfThePerson() {
        let out = redactor.redact("open /Users/maria/Library/Logs/Bandito.log and /home/ubuntu/.bandito/db")
        #expect(out == "open ‹скрыто›/Library/Logs/Bandito.log and ‹скрыто›/.bandito/db")
        hides("anna", in: #"C:\Users\anna\AppData\x"#)
    }

    @Test func theWordsOfThisMacAreHiddenWholeWordsOnly() {
        let named = SecretRedactor(terms: ["Maria", "Maria Schneider", "al", " "])
        let out = named.redact("Maria Schneider's MacBook; maria logged in; Mariana stays; also stays")
        #expect(out == "‹скрыто›'s MacBook; ‹скрыто› logged in; Mariana stays; also stays")
    }

    @Test func aLongMixedTokenNobodyKnew() {
        hides("\(t10)", in: "id \(t10) used")
    }

    @Test func redactingTwiceChangesNothingMore() {
        let text = "ANTHROPIC_API_KEY=\(t0) at /Users/maria on 10.0.0.5 maria@example.com"
        let once = redactor.redact(text)
        #expect(redactor.redact(once) == once)
    }

    // MARK: what must stay

    @Test func versionsAndPlainFactsStay() {
        keeps("Bandito for Mac: 0.1.14 (build 142)")
        keeps("Mac: macOS 15.1.0, arm64")
        keeps("12:34:56 [agents] connected (attempt 2)")
        keeps("Features: agent_bundles, bundle_schedules, logs")
        keeps("Server: Linux server 1: connected")
    }

    @Test func wordsThatLookLikeKeysButAreNot() {
        keeps("max_tokens: 4096")
        keeps("Token budget exceeded for the turn")
        keeps("the password field is empty")
        keeps("passwords are stored in the Keychain")
        keeps("Authorization was refused")
    }

    @Test func namesOfFilesAndIdentifiersStay() {
        keeps("ServerModel.swift:120 and Package.resolved")
        keeps("dev.bandito.mac and /Applications/Bandito.app")
        keeps("see bandito.dev and https://github.com/banditohq/bandito/issues/new")
        keeps("README.md, Info.plist, daemon.log")
    }

    @Test func hashesAndIdsStay() {
        keeps("commit 28973e68b7c6c4c0d1a2f3e4d5c6b7a8e9f0a1b2")
        keeps("agent 0199f3c2-8f4e-7a10-9b1c-2d3e4f5a6b7c")
        keeps("sha256 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func otherLanguagesAndEmptyTextStay() {
        keeps("Не удалось подключиться к серверу")
        keeps("接続できませんでした")
        keeps("")
    }

    // MARK: review round: short key words, escaped quotes, more token shapes, paths, short names

    private func halves(_ a: String, _ b: String) -> String { a + b }

    @Test func shortKeyWordsCountOnlyAsAWordOfTheName() {
        hides("s3cr3t", in: "FOO_KEY=s3cr3t")
        hides("s3cr3t", in: "MY_KEY=s3cr3t and more")
        hides("s3cr3t", in: "key: s3cr3t")
        hides("hunter2", in: "DB_PASS=hunter2")
        hides("hunter2", in: "PWD=hunter2")
        hides("hunter2", in: "db.pwd = hunter2")
        hides("abc123", in: "SESSION_ID=abc123")
        hides("abc123", in: "AUTH=abc123")
        hides("a1b2c3", in: "Cookie: session=a1b2c3; theme=dark")
        hides("theme=dark", in: "Set-Cookie: session=a1b2c3; theme=dark; Path=/")
    }

    @Test func plainWordsWithKeyPassOrAuthStay() {
        keeps("the monkey eats a banana")
        keeps("keyboard: US layout")
        keeps("tests passed: 12")
        keeps("author: Maria wrote the guide")
        keeps("pass the salt, please")
        keeps("a key press took 3 ms")
    }

    @Test func quotesEscapedInsideALogLine() {
        hides("abc", in: #"{\"token\":\"abc\"}"#)
        hides("hunter2", in: #"body={\"password\": \"hunter2\", \"user\": \"x\"}"#)
        hides("xyz789abc", in: #"\"Authorization\": \"Bearer xyz789abc\""#)
        hides("xyz789abc", in: #"headers {\"authorization\":\"Basic xyz789abc\"}"#)
        let out = redactor.redact(#"{\"user\":\"maria\",\"token\":\"abc\"}"#)
        #expect(out.contains(#"\"user\":\"maria\""#), "other fields stay: \(out)")
    }

    @Test func moreTokenShapes() {
        hides(halves("sk_live_", "4eC39HqLyjWDarjtT1zdp7dc"), in: "stripe \(halves("sk_live_", "4eC39HqLyjWDarjtT1zdp7dc")) ok")
        hides(halves("sk_test_", "4eC39HqLyjWDarjtT1zdp7dc"), in: halves("sk_test_", "4eC39HqLyjWDarjtT1zdp7dc"))
        hides(halves("rk_live_", "4eC39HqLyjWDarjtT1zdp7dc"), in: halves("rk_live_", "4eC39HqLyjWDarjtT1zdp7dc"))
        hides(halves("npm_", "abcdefghijklmnopqrstuvwxyz0123456789"), in: "//registry:_authToken=" + halves("npm_", "abcdefghijklmnopqrstuvwxyz0123456789"))
        hides(halves("ya29.", "a0AfH6SMBx1234567890abcdefghijkl"), in: "oauth " + halves("ya29.", "a0AfH6SMBx1234567890abcdefghijkl"))
        hides(halves("glpat-", "abcdefghij1234567890"), in: halves("glpat-", "abcdefghij1234567890"))
        hides(halves("hf_", "abcdefghijklmnopqrstuvwxyzABCD"), in: "hub " + halves("hf_", "abcdefghijklmnopqrstuvwxyzABCD"))
        hides(halves("xapp-", "1-A0123456789-abcdef"), in: halves("xapp-", "1-A0123456789-abcdef"))
        hides(halves("AIza", "SyA-1234567890abcdefghijklmnopqrstu"), in: "google " + halves("AIza", "SyA-1234567890abcdefghijklmnopqrstu"))
    }

    @Test func wordsLikeTokenPrefixesStay() {
        keeps("hf_cache is a folder name")
        keeps("npm install and npm_config are ordinary words")
        keeps("glpat is short; sk_live alone too")
    }

    @Test func aHomeFolderNameWithASpaceIsHiddenWhole() {
        let out = redactor.redact("open /Users/Maria Ivanova/Documents/report.txt now")
        #expect(out == "open ‹скрыто›/Documents/report.txt now")
        let named = SecretRedactor(terms: ["Maria Ivanova", "/Users/Maria Ivanova"])
        #expect(named.redact("cwd /Users/Maria Ivanova/work and Maria Ivanova's Mac") == "cwd ‹скрыто›/work and ‹скрыто›'s Mac")
        #expect(redactor.redact("see /Users/maria then stop") == "see ‹скрыто› then stop")
    }

    @Test func aShortServerNameIsHiddenAsAWholeWordOnly() {
        let named = SecretRedactor(terms: ["pi", "Al"])
        #expect(named.redact("server pi is down; Al left; pipeline and api stay; pi.local is a host") == "server ‹скрыто› is down; ‹скрыто› left; pipeline and api stay; ‹скрыто› is a host")
        #expect(named.redact("PI stays in its other case, and a spiral too") == "PI stays in its other case, and a spiral too")
        #expect(SecretRedactor(terms: ["x"]).redact("x marks the spot") == "x marks the spot", "one letter is never a name")
    }
}
