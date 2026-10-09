import Foundation
import Testing

@testable import BanditoKit

// Browser input: macOS keys → CDP key events, view points → page points, and bandito-preview URLs.

@Test func letterKeyMapsToCodeAndVirtualKeyCode() throws {
    // kVK_ANSI_A = 0
    let key = try #require(BrowserKeys.descriptor(keyCode: 0, characters: "a"))
    #expect(key.key == "a")
    #expect(key.code == "KeyA")
    #expect(key.windowsVirtualKeyCode == 65)
    #expect(key.text == "a")
}

@Test func digitKeyMapsToDigitCode() throws {
    // kVK_ANSI_1 = 18
    let key = try #require(BrowserKeys.descriptor(keyCode: 18, characters: "1"))
    #expect(key.code == "Digit1")
    #expect(key.windowsVirtualKeyCode == 49)
}

@Test func returnBackspaceAndArrowsMapToNamedKeys() throws {
    let enter = try #require(BrowserKeys.descriptor(keyCode: 36, characters: "\r"))
    #expect(enter.key == "Enter")
    #expect(enter.code == "Enter")
    #expect(enter.windowsVirtualKeyCode == 13)
    #expect(enter.text == "\r")

    let backspace = try #require(BrowserKeys.descriptor(keyCode: 51, characters: "\u{7f}"))
    #expect(backspace.key == "Backspace")
    #expect(backspace.windowsVirtualKeyCode == 8)
    #expect(backspace.text == nil)

    // kVK_LeftArrow = 123, kVK_UpArrow = 126
    let left = try #require(BrowserKeys.descriptor(keyCode: 123, characters: nil))
    #expect(left.key == "ArrowLeft")
    #expect(left.windowsVirtualKeyCode == 37)
    let up = try #require(BrowserKeys.descriptor(keyCode: 126, characters: nil))
    #expect(up.key == "ArrowUp")
    #expect(up.windowsVirtualKeyCode == 38)
}

@Test func spaceAndEscapeAndTab() throws {
    let space = try #require(BrowserKeys.descriptor(keyCode: 49, characters: " "))
    #expect(space.key == " ")
    #expect(space.code == "Space")
    #expect(space.windowsVirtualKeyCode == 32)
    #expect(space.text == " ")

    let escape = try #require(BrowserKeys.descriptor(keyCode: 53, characters: "\u{1b}"))
    #expect(escape.key == "Escape")
    #expect(escape.windowsVirtualKeyCode == 27)

    let tab = try #require(BrowserKeys.descriptor(keyCode: 48, characters: "\t"))
    #expect(tab.key == "Tab")
    #expect(tab.windowsVirtualKeyCode == 9)
}

@Test func unknownKeyCodeIsNil() {
    #expect(BrowserKeys.descriptor(keyCode: 200, characters: nil) == nil)
}

@Test func modifierBitmaskMatchesCDP() {
    #expect(BrowserKeys.bitmask([]) == 0)
    #expect(BrowserKeys.bitmask([.alt]) == 1)
    #expect(BrowserKeys.bitmask([.control]) == 2)
    #expect(BrowserKeys.bitmask([.meta]) == 4)
    #expect(BrowserKeys.bitmask([.shift]) == 8)
    #expect(BrowserKeys.bitmask([.control, .shift]) == 10)
}

@Test func commandShortcutsDoNotCarryText() throws {
    // Cmd+A: the key is still "a", but a shortcut must not insert text.
    let key = try #require(BrowserKeys.descriptor(keyCode: 0, characters: "a", modifiers: [.meta]))
    #expect(key.key == "a")
    #expect(key.text == nil)
}

// MARK: Geometry

@Test func displayRectFitsThePageInsideTheView() {
    // 1600×900 page in an 800×600 view: scale 0.5, 800×450, centred vertically.
    let rect = PageGeometry.displayRect(viewWidth: 800, viewHeight: 600, pageWidth: 1600, pageHeight: 900)
    #expect(rect.origin.x == 0)
    #expect(rect.origin.y == 75)
    #expect(rect.width == 800)
    #expect(rect.height == 450)
}

@Test func clickInViewBecomesPagePoint() throws {
    let point = try #require(
        PageGeometry.pagePoint(x: 400, y: 75, viewWidth: 800, viewHeight: 600, pageWidth: 1600, pageHeight: 900))
    #expect(point.x == 800)
    #expect(point.y == 0)

    let middle = try #require(
        PageGeometry.pagePoint(x: 400, y: 300, viewWidth: 800, viewHeight: 600, pageWidth: 1600, pageHeight: 900))
    #expect(middle.x == 800)
    #expect(middle.y == 450)
}

@Test func clickOutsideThePageIsNil() {
    // Above and below the displayed picture (the letterbox bars).
    #expect(PageGeometry.pagePoint(x: 400, y: 10, viewWidth: 800, viewHeight: 600, pageWidth: 1600, pageHeight: 900) == nil)
    #expect(PageGeometry.pagePoint(x: 400, y: 590, viewWidth: 800, viewHeight: 600, pageWidth: 1600, pageHeight: 900) == nil)
}

@Test func geometryWithEmptyPageIsNil() {
    #expect(PageGeometry.pagePoint(x: 1, y: 1, viewWidth: 800, viewHeight: 600, pageWidth: 0, pageHeight: 0) == nil)
}

// MARK: bandito-preview URLs

@Test func previewURLMapsToProxyPath() throws {
    let base = try #require(URL(string: "https://srv.example.com"))
    let preview = try #require(URL(string: "bandito-preview://p3000/admin/hooks?tab=new"))
    let proxy = try #require(PreviewURL.proxyURL(for: preview, serverBase: base))
    #expect(proxy.absoluteString == "https://srv.example.com/v1/proxy/3000/admin/hooks?tab=new")
}

@Test func previewRootMapsToSlash() throws {
    let base = try #require(URL(string: "https://srv.example.com/"))
    let preview = try #require(URL(string: "bandito-preview://p5173"))
    let proxy = try #require(PreviewURL.proxyURL(for: preview, serverBase: base))
    #expect(proxy.absoluteString == "https://srv.example.com/v1/proxy/5173/")
}

@Test func previewURLRejectsOtherSchemesAndBadPorts() throws {
    let base = try #require(URL(string: "https://srv.example.com"))
    #expect(PreviewURL.proxyURL(for: try #require(URL(string: "https://p3000/")), serverBase: base) == nil)
    #expect(PreviewURL.proxyURL(for: try #require(URL(string: "bandito-preview://localhost/")), serverBase: base) == nil)
    #expect(PreviewURL.proxyURL(for: try #require(URL(string: "bandito-preview://p0/")), serverBase: base) == nil)
    #expect(PreviewURL.proxyURL(for: try #require(URL(string: "bandito-preview://p70000/")), serverBase: base) == nil)
}

@Test func previewURLBuildsFromPort() {
    #expect(PreviewURL.previewURL(port: 3000, path: "/admin")?.absoluteString == "bandito-preview://p3000/admin")
    #expect(PreviewURL.previewURL(port: 5173, path: "/")?.absoluteString == "bandito-preview://p5173/")
    #expect(PreviewURL.previewURL(port: 0) == nil)
}

@Test func proxyPartsKeepThePathAndQueryAsTheDaemonExpectsThem() throws {
    let page = try #require(URL(string: "bandito-preview://p3000/a%20b/?x=1&y=2"))
    let parts = try #require(PreviewURL.proxyParts(for: page))
    #expect(parts.path == "/v1/proxy/3000/a%20b/")
    #expect(parts.query == "x=1&y=2")
    let root = try #require(URL(string: "bandito-preview://p5173"))
    #expect(PreviewURL.proxyParts(for: root)?.path == "/v1/proxy/5173/")
    #expect(PreviewURL.proxyParts(for: root)?.query == nil)
    let outOfRange = try #require(URL(string: "bandito-preview://p70000/"))
    #expect(PreviewURL.proxyParts(for: outOfRange) == nil)
}
