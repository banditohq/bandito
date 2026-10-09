import Foundation
import Testing

@testable import BanditoKit

// The preview web view of one port (PreviewProxy): only that port, the headers and the body carried over,
// and no cache or cookies shared between previews (docs/APP_SPEC.md, Browser).

@Test func aPreviewWebViewServesOnlyTheRoutesOfItsOwnPort() throws {
    let own = try #require(URL(string: "bandito-preview://p3000/admin?x=1"))
    let other = try #require(URL(string: "bandito-preview://p4000/"))
    let found = try #require(PreviewProxy.target(for: own, servingPort: 3000))
    #expect(found.path == "/v1/proxy/3000/admin")
    #expect(found.query == "x=1")
    #expect(PreviewProxy.target(for: other, servingPort: 3000) == nil)
}

@Test func theServiceGetsTheTypeButNeverTheCredentialsOrTheHost() {
    let sent = PreviewProxy.forwardedHeaders([
        "Authorization": "Bearer secret",
        "Cookie": "session=abc",
        "Host": "localhost:3000",
        "Connection": "keep-alive",
        "Content-Type": "application/json",
        "Accept": "text/html",
        "Accept-Encoding": "gzip, br",
        "X-Request-Id": "7",
    ])
    #expect(sent["Authorization"] == nil)
    #expect(sent["Cookie"] == nil)
    #expect(sent["Host"] == nil)
    #expect(sent["Connection"] == nil)
    #expect(sent["Content-Type"] == "application/json")
    #expect(sent["Accept"] == "text/html")
    #expect(sent["X-Request-Id"] == "7")
    // The bytes are handed back as sent: no compression the proxy would have to undo.
    #expect(sent["Accept-Encoding"] == "identity")
}

@Test func aFormBodyTravelsWhetherItIsAPlainBodyOrAStream() throws {
    var plain = URLRequest(url: try #require(URL(string: "bandito-preview://p3000/submit")))
    plain.httpBody = Data("a=1&b=2".utf8)
    #expect(PreviewProxy.body(of: plain) == Data("a=1&b=2".utf8))

    var streamed = URLRequest(url: try #require(URL(string: "bandito-preview://p3000/submit")))
    streamed.httpBodyStream = InputStream(data: Data("{\"n\":3}".utf8))
    #expect(PreviewProxy.body(of: streamed) == Data("{\"n\":3}".utf8))
}

@Test func theEncodingAndLengthOfTheReceivedBytesAreNotPassedBack() {
    let back = PreviewProxy.responseHeaders([
        "Content-Type": "text/html",
        "Content-Encoding": "gzip",
        "Content-Length": "99",
        "Cache-Control": "no-store",
    ])
    #expect(back["Content-Encoding"] == nil)
    #expect(back["Content-Length"] == nil)
    #expect(back["Content-Type"] == "text/html")
    #expect(back["Cache-Control"] == "no-store")
}

@Test func aPreviewSessionHasNoCacheAndItsOwnCookies() {
    let config = PreviewProxy.previewConfiguration()
    #expect(config.urlCache == nil)
    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(config.httpCookieStorage != nil)
    #expect(config.httpCookieStorage !== HTTPCookieStorage.shared)
    #expect(PreviewProxy.previewConfiguration().httpCookieStorage !== config.httpCookieStorage)
}

@Test func theDaemonSessionForTabsHasNoCache() {
    let config = DaemonHTTP.configuration()
    #expect(config.urlCache == nil)
    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
}
